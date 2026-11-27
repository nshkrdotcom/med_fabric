Code.require_file("support/fixtures.exs", __DIR__)

defmodule MedFabric.Exam.OutboxIntegrationTest do
  use ExUnit.Case, async: false

  alias MedFabric.Domain.Evidence
  alias MedFabric.Domain.Review
  alias MedFabric.Exam.DeliveryWorker
  alias MedFabric.Exam.IntegrationFixtures, as: F
  alias MedFabric.Interop.FhirClient
  alias MedFabric.Store.AcquisitionSessions
  alias MedFabric.Store.Deliveries
  alias MedFabric.Store.Encounters
  alias MedFabric.Store.Records

  setup context, do: F.trusted_tmp(context)

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
    assert [_, _, [_, "result", "unknown", false, "claim_expired"]] = history(c, id)
    assert {:ok, :current} = Deliveries.expire_claim(c.db, id)
    assert length(history(c, id)) == 3

    assert {:error, :stale_attempt} =
             Deliveries.record_attempt_outcome(c.db, claim, {:noncommitted, :before_http})
  end

  test "claim-only expiry appends exact noncommit evidence and fences a late worker", %{
    tmp_dir: root
  } do
    c = F.context(root)
    id = intent(c, false)
    {:ok, pinned} = Deliveries.get(c.db, id)
    {:ok, claim} = Deliveries.claim_delivery(c.db, id)
    assert {:ok, :current} = Deliveries.expire_claim(c.db, id)
    assert length(history(c, id)) == 1

    expire(c, id)
    assert {:ok, :retryable} = Deliveries.expire_claim(c.db, id)
    token = claim.token

    assert [
             [^token, "claim", "admitted", false, nil],
             [^token, "result", "noncommitted", false, "expired_before_send"]
           ] = history(c, id)

    assert {:ok, %{status: "retryable", token: nil, proof: %{"safe_confirmation" => false}}} =
             Deliveries.get(c.db, id)

    assert {:ok, :current} = Deliveries.expire_claim(c.db, id)
    assert length(history(c, id)) == 2
    assert {:error, :stale_attempt} = Deliveries.before_dispatch(c.db, claim)

    assert {:error, :stale_attempt} =
             Deliveries.record_attempt_outcome(c.db, claim, {:matched, "Observation/late"})

    assert {:ok, retry} = Deliveries.claim_delivery(c.db, id)
    assert {:ok, :ok} = Deliveries.before_dispatch(c.db, retry)
    assert {:error, :invalid_claim_history} = Deliveries.before_dispatch(c.db, retry)

    assert {:ok, "confirmed"} =
             Deliveries.record_attempt_outcome(c.db, retry, {:matched, "Observation/one"})

    assert {:ok, after_retry} = Deliveries.get(c.db, id)
    assert after_retry.resource_bytes == pinned.resource_bytes
    assert after_retry.destination == pinned.destination
    assert after_retry.qualification_ref == pinned.qualification_ref
  end

  test "qualified sent expiry remains unknown until legitimate reconciliation", %{tmp_dir: root} do
    c = F.context(root)
    id = intent(c, true)
    {:ok, claim} = Deliveries.claim_delivery(c.db, id)
    {:ok, :ok} = Deliveries.before_dispatch(c.db, claim)
    expire(c, id)
    assert {:ok, :unresolved} = Deliveries.expire_claim(c.db, id)
    assert [_, _, [_, "result", "unknown", true, "claim_expired"]] = history(c, id)
    assert {:ok, %{proof: %{"safe_confirmation" => false}}} = Deliveries.get(c.db, id)
    assert {:ok, "confirmed"} = Deliveries.reconcile(c.db, id, {:matched, "Observation/one"})
  end

  test "missing, mismatched or terminal claim evidence is refused without historical repair", %{
    tmp_dir: root
  } do
    c = F.context(root)
    id = intent(c, false)
    {:ok, claim} = Deliveries.claim_delivery(c.db, id)

    for field <- ["attempt_id", "claim_token"] do
      AcquisitionSessions.rows(
        c.db,
        "UPDATE outbox_deliveries SET " <> field <> "=$2 WHERE id=$1",
        [
          id,
          "corruption_fixture"
        ]
      )

      expire(c, id)
      assert {:error, :invalid_claim_history} = Deliveries.expire_claim(c.db, id)
      assert length(history(c, id)) == 1
      assert {:error, :stale_attempt} = Deliveries.before_dispatch(c.db, claim)

      AcquisitionSessions.rows(
        c.db,
        "UPDATE outbox_deliveries SET attempt_id=$2,claim_token=$3 WHERE id=$1",
        [id, claim.attempt_id, claim.token]
      )
    end

    AcquisitionSessions.rows(
      c.db,
      "INSERT INTO delivery_attempts(delivery_id,attempt_id,token,stage,outcome,conditional_protected) VALUES($1,$2,$3,'result','unknown',false)",
      [id, claim.attempt_id, claim.token]
    )

    assert {:error, :invalid_claim_history} = Deliveries.expire_claim(c.db, id)
    assert [_, [_, "result", "unknown", false, nil]] = history(c, id)
    assert {:error, :unsafe_dispatch} = Deliveries.claim_delivery(c.db, id)
  end

  test "claim-only settlement cannot erase an older unknown effect in a corruption fixture", %{
    tmp_dir: root
  } do
    c = F.context(root)
    id = intent(c, false)
    {:ok, old} = Deliveries.claim_delivery(c.db, id)
    {:ok, :ok} = Deliveries.before_dispatch(c.db, old)
    {:ok, "unresolved"} = Deliveries.record_attempt_outcome(c.db, old, {:unknown, :timeout})

    # This state cannot be admitted by claim_delivery/2: model an externally
    # corrupted current claim without rewriting the retained old history.
    AcquisitionSessions.rows(
      c.db,
      "UPDATE outbox_deliveries SET status='dispatching',attempt_id='corrupt_current',claim_token='corrupt_token',lease_until=clock_timestamp()-interval '1 second' WHERE id=$1",
      [id]
    )

    AcquisitionSessions.rows(
      c.db,
      "INSERT INTO delivery_attempts(delivery_id,attempt_id,token,stage,outcome,conditional_protected) VALUES($1,'corrupt_current','corrupt_token','claim','admitted',false)",
      [id]
    )

    assert {:ok, :unresolved} = Deliveries.expire_claim(c.db, id)
    assert {:ok, "unresolved"} = Deliveries.reconcile(c.db, id, {:matched, "Observation/one"})
    assert {:error, :unsafe_dispatch} = Deliveries.claim_delivery(c.db, id)
  end

  test "claim-only retries preserve the five-delay scheduling cap", %{tmp_dir: root} do
    c = F.context(root)
    id = intent(c, false)

    for _ <- 1..6 do
      assert {:ok, _} = Deliveries.claim_delivery(c.db, id)
      expire(c, id)
      assert {:ok, :retryable} = Deliveries.expire_claim(c.db, id)
    end

    assert [[5, nil]] =
             AcquisitionSessions.rows(
               c.db,
               "SELECT executions,next_due_at FROM outbox_deliveries WHERE id=$1",
               [id]
             )

    assert length(history(c, id)) == 12
  end

  test "expiry winning the row lock prevents a late dispatch from admitting HTTP", %{
    tmp_dir: root
  } do
    c = F.context(root)
    id = intent(c, false)
    {:ok, claim} = Deliveries.claim_delivery(c.db, id)
    expire(c, id)
    parent = self()

    expiry =
      Task.async(fn ->
        Postgrex.transaction(c.db, fn tx ->
          result = Deliveries.expire_claim(tx, id)
          send(parent, {:expiry_fenced, result})

          receive do
            :commit -> result
          end
        end)
      end)

    assert_receive {:expiry_fenced, {:ok, :retryable}}, 5_000

    sender =
      Task.async(fn ->
        case Deliveries.before_dispatch(c.db, claim) do
          {:ok, :ok} -> send(parent, :http_admitted)
          error -> error
        end
      end)

    send(expiry.pid, :commit)
    assert {:ok, {:ok, :retryable}} = Task.await(expiry)
    assert {:error, :stale_attempt} = Task.await(sender)
    refute_received :http_admitted
    assert [_, [_, "result", "noncommitted", false, "expired_before_send"]] = history(c, id)
  end

  test "a committed send winning the row lock remains a possible late HTTP effect", %{
    tmp_dir: root
  } do
    c = F.context(root)
    id = intent(c, false)
    {:ok, claim} = Deliveries.claim_delivery(c.db, id)
    parent = self()

    sender =
      Task.async(fn ->
        Postgrex.transaction(c.db, fn tx ->
          assert {:ok, :ok} = Deliveries.before_dispatch(tx, claim)
          expire(%{c | db: tx}, id)
          send(parent, :send_recorded)

          receive do
            :commit -> :ok
          end
        end)
      end)

    assert_receive :send_recorded, 5_000
    expiry = Task.async(fn -> Deliveries.expire_claim(c.db, id) end)
    send(sender.pid, :commit)
    assert {:ok, :ok} = Task.await(sender)
    assert {:ok, :unresolved} = Task.await(expiry)
    assert [_, _, [_, "result", "unknown", false, "claim_expired"]] = history(c, id)
    assert {:ok, "unresolved"} = Deliveries.reconcile(c.db, id, {:matched, "Observation/one"})
  end

  defp expire(c, id) do
    AcquisitionSessions.rows(
      c.db,
      "UPDATE outbox_deliveries SET lease_until=clock_timestamp()-interval '1 second' WHERE id=$1",
      [id]
    )
  end

  defp history(c, id) do
    AcquisitionSessions.rows(
      c.db,
      "SELECT token,stage,outcome,conditional_protected,evidence_ref FROM delivery_attempts WHERE delivery_id=$1 ORDER BY ordinal",
      [id]
    )
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

    assert {:ok, :ok} = DeliveryWorker.run(c, id)
    assert {:ok, %{status: "blocked", resource: nil}} = Deliveries.get(c.db, id)
    assert [[1]] = AcquisitionSessions.rows(c.db, "SELECT count(*) FROM reviews", [])
    assert [[1]] = AcquisitionSessions.rows(c.db, "SELECT count(*) FROM observations", [])
  end
end
