Code.require_file("support/fixtures.exs", __DIR__)

defmodule MedFabric.Exam.SchemaRecoveryIntegrationTest do
  use ExUnit.Case, async: false

  alias MedFabric.Domain.Evidence
  alias MedFabric.Domain.Review
  alias MedFabric.Exam.AcquisitionIngress
  alias MedFabric.Exam.AcquisitionManifest
  alias MedFabric.Exam.AcquisitionRecovery
  alias MedFabric.Exam.IntegrationFixtures, as: F
  alias MedFabric.Interop.FhirClient
  alias MedFabric.Store.AcquisitionSessions
  alias MedFabric.Store.Deliveries
  alias MedFabric.Store.Encounters
  alias MedFabric.Store.Postgres
  alias MedFabric.Store.Records
  alias MedFabric.Store.Recovery

  setup context, do: F.trusted_tmp(context)
  @uuid "00000000-0000-4000-8000-000000000002"

  test "fresh schema is idempotent, identity is immutable and drift fails closed", %{
    tmp_dir: root
  } do
    c = F.context(root)
    assert {:ok, :ok} = Postgres.migrate(c.db, @uuid)

    assert {:error, :incompatible_deployment} =
             Postgres.migrate(c.db, "00000000-0000-4000-8000-000000000003")

    assert_raise Postgrex.Error, fn ->
      AcquisitionSessions.rows(
        c.db,
        "UPDATE deployment_identity SET deployment_uuid='00000000-0000-4000-8000-000000000003'",
        []
      )
    end

    AcquisitionSessions.rows(c.db, "DROP INDEX one_active_profile", [])
    assert {:error, :schema_drift} = Postgres.migrate(c.db, @uuid)
  end

  test "unexpected existing tables are refused without changing retained rows", %{tmp_dir: root} do
    c = F.context(root)
    Postgrex.query!(c.db, "CREATE TABLE retained_data (value text NOT NULL)", [])
    Postgrex.query!(c.db, "INSERT INTO retained_data VALUES ('retain')", [])
    before = Postgres.identity(c.db)

    tables =
      "SELECT tablename FROM pg_tables WHERE schemaname=current_schema() ORDER BY tablename"

    expected = Postgrex.query!(c.db, tables, []).rows

    assert {:error, :incompatible_schema} = Postgres.migrate(c.db, @uuid)
    assert Postgrex.query!(c.db, tables, []).rows == expected
    assert Postgrex.query!(c.db, "SELECT value FROM retained_data", []).rows == [["retain"]]
    assert Postgres.identity(c.db) == before
  end

  test "receipt shape, source binding, exact terminal identity and source immutability are durable SQL guards",
       %{tmp_dir: root} do
    c = F.context(root)
    {bind, _, _, _} = F.browser(c)

    {:ok, attempt} =
      AcquisitionSessions.scoped(
        c.db,
        bind,
        fn tx, s -> AcquisitionSessions.reserve_attempt(tx, s, "audio") end,
        :update
      )

    assert_raise Postgrex.Error, fn ->
      AcquisitionSessions.rows(
        c.db,
        "UPDATE stream_attempts SET receipt='{}'::jsonb WHERE fence=$1",
        [attempt.fence]
      )
    end

    assert_raise Postgrex.Error, fn ->
      AcquisitionSessions.rows(c.db, "UPDATE acquisition_sessions SET boot='other' WHERE id=$1", [
        bind.id
      ])
    end

    assert_raise Postgrex.Error, fn ->
      AcquisitionSessions.rows(
        c.db,
        "UPDATE acquisitions SET profile='paired_exam',source_kind='device' WHERE id=$1",
        [bind.id]
      )
    end

    assert [[nil]] =
             AcquisitionSessions.rows(
               c.db,
               "SELECT receipt FROM stream_attempts WHERE fence=$1",
               [attempt.fence]
             )
  end

  test "restored namespace remains blocked without later complete authoritative evidence", %{
    tmp_dir: root
  } do
    c = F.context(root)

    assert {:ok, :ok} =
             Encounters.browser_session(
               c.db,
               "recovery_patient",
               "encounter",
               "patient",
               :patient
             )

    [[cut]] = AcquisitionSessions.rows(c.db, "SELECT pg_current_wal_lsn()::text", [])
    assert {:ok, :ok} = Recovery.block(c.db, cut)

    assert {:error, :restore_reconciliation_required} =
             AcquisitionSessions.create_browser(
               c.db,
               "encounter",
               "patient",
               "recovery_patient",
               "page",
               "request"
             )

    assert {:error, :invalid_authority_inventory} =
             Recovery.reconcile(c.db, "{}", String.duplicate("0", 64), %{})

    assert {:ok, %{bytes: bytes, digest: digest}} = Recovery.inventory(c.db)

    assert {:error, :root_ownership_unverified} =
             Recovery.reconcile(c.db, bytes, digest, %{
               old_service_quiescent: true,
               post_cut_point_accounted: true
             })

    {:ok, %{root: owned_root, token: token}} =
      GenServer.call(c.root_owner, {:med_ex_root_ownership, c.artifact_dir})

    proof = %{
      root: owned_root,
      root_owner: c.root_owner,
      root_token: token,
      prefixes: [],
      manifests: %{}
    }

    assert {:ok, ^digest} = Recovery.reconcile(c.db, bytes, digest, proof)
    {:ok, body} = Evidence.pulse_rate(76, DateTime.utc_now(), "clinician")
    assert {:ok, _} = Records.put_manual(c.db, "encounter", "post_cutpoint", "clinician", body)
    assert {:ok, :ok} = Recovery.block(c.db, cut)

    assert {:error, :missing_or_changed_post_cut_point_facts} =
             Recovery.reconcile(c.db, bytes, digest, proof)

    assert {:ok, %{recovery_state: "blocked"}} = Postgres.identity(c.db)
  end

  test "host restore verifies actual journals and manifests and rejects post-cut-point orphan artifacts",
       %{tmp_dir: root} do
    c = F.context(root)
    {bind, spec, _, _} = F.browser(c)
    {:ok, writer, _} = AcquisitionIngress.open(c, bind, "audio", spec.descriptor_ref)
    {:ok, _} = AcquisitionIngress.call(writer, {:frame, F.frame()})
    {:ok, _} = AcquisitionIngress.call(writer, :checkpoint)
    {:ok, _} = AcquisitionIngress.call(writer, {:finish, "1", "2", nil})
    {:ok, _} = AcquisitionManifest.finish(c, bind, %{})
    [[cut]] = AcquisitionSessions.rows(c.db, "SELECT pg_current_wal_lsn()::text", [])
    {:ok, :ok} = Recovery.block(c.db, cut)
    assert {:ok, inventory} = AcquisitionRecovery.inventory(c)
    assert {:ok, _} = AcquisitionRecovery.reconcile(c, inventory.bytes, inventory.digest)
    {:ok, :ok} = Recovery.block(c.db, cut)
    File.mkdir_p!(Path.join([root, "acquisitions-v2", String.duplicate("a", 64)]))

    assert {:error, :unaccounted_acquisition_artifacts} =
             AcquisitionRecovery.reconcile(c, inventory.bytes, inventory.digest)

    assert {:ok, %{recovery_state: "blocked"}} = Postgres.identity(c.db)
  end

  test "an older coherent database cannot omit a later native observation, intent and possibly sent request",
       %{tmp_dir: root} do
    c = F.context(root)
    [[cut]] = AcquisitionSessions.rows(c.db, "SELECT pg_current_wal_lsn()::text", [])
    {:ok, body} = Evidence.pulse_rate(76, DateTime.utc_now(), "clinician")
    {:ok, _} = Records.put_manual(c.db, "encounter", "later_evidence", "clinician", body)
    {:ok, source} = Records.manual(c.db, "encounter", "later_evidence", "clinician")

    {:ok, plan} =
      Review.plan(
        source,
        "clinician",
        "later_decision",
        %{"decision" => "accept"},
        DateTime.utc_now()
      )

    {:ok, %{observations: [id]}} = Records.accept_plan(c.db, plan)
    {:ok, intent} = Deliveries.get(c.db, id)
    {:ok, native} = Deliveries.observation(c.db, id)
    refs = %{"patient_ref" => "Patient/one", "encounter_ref" => "Encounter/one"}

    {:ok, resource} =
      FhirClient.resource_checked(
        native,
        %{"system" => intent.identifier_system, "value" => id},
        refs
      )

    bytes = FhirClient.canonical_bytes(resource)

    {:ok, :ok} =
      Deliveries.save_mapping(c.db, id, %{
        destination: "http://example.invalid/fhir",
        refs: refs,
        version: FhirClient.mapping_version(),
        resource: resource,
        bytes: bytes,
        fingerprint: AcquisitionSessions.hash(bytes),
        qualified: false,
        qualification_ref: nil
      })

    {:ok, claim} = Deliveries.claim_delivery(c.db, id)
    {:ok, :ok} = Deliveries.before_dispatch(c.db, claim)

    {:ok, "unresolved"} =
      Deliveries.record_attempt_outcome(c.db, claim, {:unknown, :response_lost})

    {:ok, :ok} = Recovery.block(c.db, cut)
    {:ok, later} = AcquisitionRecovery.inventory(c)

    schema = "older_test_" <> Base.encode16(:crypto.strong_rand_bytes(8), case: :lower)
    AcquisitionSessions.rows(c.db, "CREATE SCHEMA " <> schema, [])

    on_exit(fn ->
      {:ok, cleanup} = Postgres.start_link(url: System.fetch_env!("DATABASE_URL"))
      AcquisitionSessions.rows(cleanup, "DROP SCHEMA " <> schema <> " CASCADE", [])
      GenServer.stop(cleanup)
    end)

    old =
      start_supervised!(
        Supervisor.child_spec(
          {Postgres, url: System.fetch_env!("DATABASE_URL"), parameters: [search_path: schema]},
          id: :older_database
        )
      )

    {:ok, :ok} = Postgres.migrate(old, @uuid)

    {:ok, :ok} =
      Encounters.open(old, %{
        "exam" => "encounter",
        "patient_actor" => "patient",
        "clinician_actor" => "clinician"
      })

    {:ok, :ok} = Recovery.block(old, cut)

    assert {:error, :missing_or_changed_post_cut_point_facts} =
             AcquisitionRecovery.reconcile(%{c | db: old}, later.bytes, later.digest)

    assert {:ok, %{recovery_state: "blocked"}} = Postgres.identity(old)
    assert [[0]] = AcquisitionSessions.rows(old, "SELECT count(*) FROM observations", [])
  end
end
