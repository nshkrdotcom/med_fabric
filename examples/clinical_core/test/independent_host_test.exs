defmodule MedFabric.ClinicalCoreFixtureTest do
  use ExUnit.Case, async: false
  alias MedFabric.Domain.{Evidence, Review}
  alias MedFabric.Interop.FhirClient
  alias MedFabric.Store.{Deliveries, Encounters, Postgres, Records}

  # These are dedicated operator-provided databases. No test resets a schema,
  # drops evidence or substitutes an application-global connection.
  setup_all do
    {:ok, _} = Application.ensure_all_started(:mf_store)
    {:ok, _} = Application.ensure_all_started(:mf_interop)

    handles =
      for suffix <- ["A", "B"], into: %{} do
        url = System.fetch_env!("MF_CORE_DATABASE_URL_" <> suffix)
        uuid = System.fetch_env!("MF_CORE_DEPLOYMENT_UUID_" <> suffix)
        {:ok, db} = Postgres.start_link(url: url)
        {:ok, :ok} = Postgres.migrate(db, uuid)
        {suffix, db}
      end

    assert handles["A"] != handles["B"]
    destination = System.fetch_env!("MF_CORE_FHIR_URL")

    refs = %{
      "patient_ref" => System.fetch_env!("MF_CORE_PATIENT_REF"),
      "encounter_ref" => System.fetch_env!("MF_CORE_ENCOUNTER_REF")
    }

    on_exit(fn ->
      Enum.each(handles, fn {_, db} -> if Process.alive?(db), do: GenServer.stop(db) end)
    end)

    {:ok, dbs: handles, destination: destination, refs: refs}
  end

  test "native acceptance, independent mapping and exact remote confirmation", c do
    assert Code.ensure_loaded?(MedFabric.Exam) == false
    actor = "independent-core-clinician"
    run = Base.encode16(:crypto.strong_rand_bytes(8), case: :lower)
    at = DateTime.utc_now()
    choice = %{"decision" => "accept", "note" => "Synthetic core-host fixture"}

    sources =
      for {label, db} <- c.dbs, into: %{} do
        encounter = "core-" <> label <> "-" <> run

        {:ok, :ok} =
          Encounters.open(db, %{
            "exam" => encounter,
            "patient_actor" => "independent-core-patient",
            "clinician_actor" => actor
          })

        {:ok, evidence} = Evidence.pulse_rate(70, at, actor)
        {:ok, id} = Records.put_manual(db, encounter, "manual-" <> run, actor, evidence)
        {:ok, source} = Records.manual(db, encounter, id, actor)
        {:ok, plan} = Review.plan(source, actor, "review-" <> run, choice, at)
        {:ok, outcome} = Records.accept_plan(db, plan)
        assert length(outcome.observations) == 1
        [observation] = outcome.observations
        {:ok, intent} = Deliveries.get(db, observation)
        assert intent.status == "pending"
        assert intent.destination == nil
        assert intent.identifier_value == observation
        {:ok, ^outcome} = Records.accept_plan(db, plan)
        {:ok, :ok} = Encounters.close(db, encounter, actor)
        {:ok, ^outcome} = Records.accept_plan(db, plan)

        {:ok, changed} =
          Review.plan(
            source,
            actor,
            "review-" <> run,
            Map.put(choice, "note", "Different canonical request"),
            DateTime.add(at, 1)
          )

        assert {:error, :request_conflict} = Records.accept_plan(db, changed)
        {label, {db, observation, intent}}
      end

    {db_a, observation_a, intent_a} = sources["A"]
    {db_b, observation_b, intent_b} = sources["B"]
    assert intent_a.identifier_system != intent_b.identifier_system
    assert {:error, :intent_missing} = Deliveries.get(db_b, observation_a)
    assert {:error, :invalid_pulse_rate} = Evidence.pulse_rate(-1, at, actor)

    # A native valid observation survives an unavailable external representation.
    {:ok, native_b} = Deliveries.observation(db_b, observation_b)

    assert {:error, :representation_unavailable} =
             FhirClient.resource_checked(native_b, identifier(intent_b), %{})

    assert {:ok, :ok} = Deliveries.block_preparation(db_b, observation_b, :references_missing)
    assert {:ok, %{status: "blocked"}} = Deliveries.get(db_b, observation_b)
    assert {:ok, ^native_b} = Deliveries.observation(db_b, observation_b)

    {:ok, native_a} = Deliveries.observation(db_a, observation_a)
    {:ok, resource} = FhirClient.resource_checked(native_a, identifier(intent_a), c.refs)
    bytes = FhirClient.canonical_bytes(resource)
    fingerprint = Base.encode16(:crypto.hash(:sha256, bytes), case: :lower)

    {:ok, :ok} =
      Deliveries.save_mapping(db_a, observation_a, %{
        destination: c.destination,
        refs: c.refs,
        version: FhirClient.mapping_version(),
        resource: resource,
        bytes: bytes,
        fingerprint: fingerprint,
        qualified: false,
        qualification_ref: nil
      })

    {:ok, claim} = Deliveries.claim_delivery(db_a, observation_a)
    {:ok, :ok} = Deliveries.before_dispatch(db_a, claim)
    {:matched, remote} = FhirClient.deliver(resource, base_url: c.destination)
    {:ok, "confirmed"} = Deliveries.record_attempt_outcome(db_a, claim, {:matched, remote})
    assert {:matched, ^remote} = FhirClient.reconcile(resource, base_url: c.destination)

    assert {:ok, %{status: "confirmed", fingerprint: ^fingerprint}} =
             Deliveries.get(db_a, observation_a)

    assert {:error, :unsafe_dispatch} = Deliveries.claim_delivery(db_a, observation_a)
  end

  defp identifier(intent),
    do: %{"system" => intent.identifier_system, "value" => intent.identifier_value}
end
