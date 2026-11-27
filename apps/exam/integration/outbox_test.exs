Code.require_file("support/fixtures.exs", __DIR__)

defmodule MedFabric.Exam.OutboxIntegrationTest do
  use ExUnit.Case, async: false

  setup context, do: MedFabric.Exam.IntegrationFixtures.trusted_tmp(context)
  alias MedFabric.Exam.IntegrationFixtures, as: F
  alias MedFabric.Store.{Records, Deliveries, AcquisitionSessions, Encounters}
  alias MedFabric.Domain.{Evidence, Review}
  alias MedFabric.Interop.FhirClient

  defp intent(c, qualified) do
    {:ok, body} = Evidence.pulse_rate(76, ~U[2026-11-24 12:00:00Z], "clinician")
    {:ok, _} = Records.put_manual(c.db, "encounter", "manual_one", "clinician", body)
    {:ok, source} = Records.manual(c.db, "encounter", "manual_one", "clinician")

    {:ok, plan} =
      Review.plan(
        source,
        "clinician",
        "review_one",
        %{"decision" => "accept"},
        ~U[2026-11-24 12:01:00Z]
      )

    {:ok, %{observations: [id]}} = Records.accept_plan(c.db, plan)
    {:ok, d} = Deliveries.get(c.db, id)
    {:ok, native} = Deliveries.observation(c.db, id)
    refs = %{"patient_ref" => "Patient/one", "encounter_ref" => "Encounter/one"}

    {:ok, resource} =
      FhirClient.resource_checked(
        native,
        %{"system" => d.identifier_system, "value" => d.identifier_value},
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
        qualified: qualified,
        qualification_ref: if(qualified, do: "qualified-fixture-contract")
      })

    id
  end

  test "unsafe previous request stays unresolved despite one matching resource; pins never redirect",
       %{tmp_dir: root} do
    c = F.context(root)
    id = intent(c, false)
    {:ok, pinned} = Deliveries.get(c.db, id)
    assert {:ok, claim} = Deliveries.claim_delivery(c.db, id)
    assert {:ok, :ok} = Deliveries.before_dispatch(c.db, claim)

    assert {:ok, "unresolved"} =
             Deliveries.record_attempt_outcome(c.db, claim, {:unknown, :timeout})

    assert {:ok, "unresolved"} = Deliveries.reconcile(c.db, id, {:matched, "Observation/one"})
    assert {:ok, "unresolved"} = Deliveries.remediate(c.db, id, "clinician")
    assert {:error, :unsafe_dispatch} = Deliveries.claim_delivery(c.db, id)
    assert {:ok, afterward} = Deliveries.get(c.db, id)
    assert afterward.fingerprint == pinned.fingerprint
    assert afterward.destination == pinned.destination
    assert afterward.identifier_value == pinned.identifier_value

    assert_raise Postgrex.Error, fn ->
      AcquisitionSessions.rows(
        c.db,
        "UPDATE outbox_deliveries SET destination='http://elsewhere.invalid/fhir' WHERE id=$1",
        [id]
      )
    end
  end

  test "expired claim cannot confirm or overwrite a current disposition", %{tmp_dir: root} do
    c = F.context(root)
    id = intent(c, false)
    {:ok, claim} = Deliveries.claim_delivery(c.db, id)
    {:ok, :ok} = Deliveries.before_dispatch(c.db, claim)

    AcquisitionSessions.rows(
      c.db,
      "UPDATE outbox_deliveries SET lease_until=clock_timestamp()-interval '1 second' WHERE id=$1",
      [id]
    )

    assert {:error, :stale_attempt} =
             Deliveries.record_attempt_outcome(c.db, claim, {:matched, "Observation/one"})

    assert {:ok, :unresolved} = Deliveries.expire_claim(c.db, id)
    assert {:ok, %{status: "unresolved", remote_ref: nil}} = Deliveries.get(c.db, id)

    assert {:error, :stale_attempt} =
             Deliveries.record_attempt_outcome(c.db, claim, {:noncommitted, :before_http})
  end

  test "qualified protection covers delayed effects and exact matching confirmation is terminal",
       %{tmp_dir: root} do
    c = F.context(root)
    id = intent(c, true)
    {:ok, claim} = Deliveries.claim_delivery(c.db, id)
    {:ok, :ok} = Deliveries.before_dispatch(c.db, claim)

    assert {:ok, "retryable"} =
             Deliveries.record_attempt_outcome(c.db, claim, {:unknown, :timeout})

    assert {:ok, "confirmed"} = Deliveries.reconcile(c.db, id, {:matched, "Observation/one"})

    assert {:ok,
            %{
              status: "confirmed",
              remote_ref: "Observation/one",
              proof: %{"safe_confirmation" => true}
            }} = Deliveries.get(c.db, id)

    assert {:error, :unsafe_dispatch} = Deliveries.claim_delivery(c.db, id)

    assert {:error, :already_confirmed} =
             Deliveries.record_attempt_outcome(c.db, claim, {:unknown, :late_failure})
  end

  test "unknown reconciliation preserves a conflict even with qualified retry protection", %{
    tmp_dir: root
  } do
    c = F.context(root)
    id = intent(c, true)
    {:ok, claim} = Deliveries.claim_delivery(c.db, id)
    {:ok, :ok} = Deliveries.before_dispatch(c.db, claim)

    assert {:ok, "conflict"} =
             Deliveries.record_attempt_outcome(
               c.db,
               claim,
               {:conflict, :conflicting_remote_record}
             )

    assert {:ok, "conflict"} = Deliveries.reconcile(c.db, id, {:unknown, :empty_search})
    assert {:error, :unsafe_dispatch} = Deliveries.claim_delivery(c.db, id)
    assert {:error, :not_remediable} = Deliveries.remediate(c.db, id, "clinician")

    assert {:ok, "confirmed"} =
             Deliveries.reconcile(c.db, id, {:matched, "Observation/reconciled"})

    assert {:ok, %{status: "confirmed", remote_ref: "Observation/reconciled"}} =
             Deliveries.get(c.db, id)
  end

  test "a native-valid value remains accepted when checked external representation is blocked", %{
    tmp_dir: root
  } do
    c = F.context(root)

    {:ok, body} =
      Evidence.pulse_rate(9_223_372_036_854_775_807, ~U[2026-11-24 12:00:00Z], "clinician")

    {:ok, _} = Records.put_manual(c.db, "encounter", "large_native", "clinician", body)
    {:ok, source} = Records.manual(c.db, "encounter", "large_native", "clinician")

    {:ok, plan} =
      Review.plan(
        source,
        "clinician",
        "review_large",
        %{"decision" => "accept"},
        DateTime.utc_now()
      )

    assert {:ok, %{observations: [id]}} = Records.accept_plan(c.db, plan)

    assert {:ok, :ok} =
             Encounters.open(c.db, %{
               "exam" => "encounter",
               "patient_actor" => "patient",
               "clinician_actor" => "clinician",
               "destination" => "http://example.invalid/fhir",
               "patient_ref" => "Patient/one",
               "encounter_ref" => "Encounter/one"
             })

    assert {:ok, :ok} = MedFabric.Exam.DeliveryWorker.run(c, id)
    assert {:ok, %{status: "blocked", resource: nil}} = Deliveries.get(c.db, id)
    assert [[1]] = AcquisitionSessions.rows(c.db, "SELECT count(*) FROM reviews", [])
    assert [[1]] = AcquisitionSessions.rows(c.db, "SELECT count(*) FROM observations", [])
  end
end
