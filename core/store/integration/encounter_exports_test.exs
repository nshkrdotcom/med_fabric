Code.require_file("support/fixture.exs", __DIR__)

defmodule MedFabric.Store.EncounterExportsTest do
  use ExUnit.Case, async: false
  alias MedFabric.Domain.Review
  alias MedFabric.Store.{AcquisitionSessions, Deliveries, Encounters, Records}
  alias MedFabric.Store.IntegrationFixture, as: F

  setup do
    F.database()
  end

  test "two live encounters retain distinct membership, browser sessions and export references", c do
    entries = for id <- ["one", "two"] do
      entry = %{"exam" => id, "patient_actor" => "patient_#{id}", "clinician_actor" => "clinician_#{id}",
        "destination" => "https://#{id}.example.invalid/fhir", "patient_ref" => "Patient/#{id}", "encounter_ref" => "Encounter/#{id}"}
      assert {:ok, :ok} = Encounters.open(c.db, entry)
      assert {:ok, :ok} = Encounters.browser_session(c.db, "session_#{id}", id, entry["clinician_actor"], :clinician)
      entry
    end
    for {own, other} <- [{hd(entries), List.last(entries)}, {List.last(entries), hd(entries)}] do
      assert {:ok, %{destination: destination, refs: refs, qualified: false}} = Encounters.export(c.db, own["exam"])
      assert destination == own["destination"] and refs == Map.take(own, ~w(patient_ref encounter_ref))
      assert Records.member?(c.db, own["exam"], own["clinician_actor"], :clinician)
      refute Records.member?(c.db, own["exam"], other["clinician_actor"], :clinician)
      assert Encounters.session_authorized?(c.db, "session_#{own["exam"]}", own["exam"], own["clinician_actor"], :clinician)
      refute Encounters.session_authorized?(c.db, "session_#{other["exam"]}", own["exam"], own["clinician_actor"], :clinician)
      assert {:error, :unauthorized} = Encounters.browser_session(c.db, "wrong_#{own["exam"]}", own["exam"], other["clinician_actor"], :clinician)
    end
    [one, _] = entries
    assert {:error, :encounter_conflict} = Encounters.open(c.db, %{one | "patient_actor" => "changed_patient"})
  end

  test "missing export configuration leaves native entry available and qualification requires an explicit reference", c do
    F.encounter(c.db)
    assert {:error, :destination_missing} = Encounters.export(c.db, "encounter")
    assert %{kind: :manual, verified: true} = F.manual(c.db)
    entry = %{"exam" => "encounter", "patient_actor" => "patient", "clinician_actor" => "clinician",
      "destination" => "https://example.invalid/fhir", "patient_ref" => "Patient/one", "encounter_ref" => "Encounter/one",
      "conditional_create_qualified" => true, "qualification_ref" => "native-hapi-qualification"}
    assert {:ok, :ok} = Encounters.open(c.db, entry)
    assert {:ok, %{qualified: true, qualification_ref: "native-hapi-qualification"}} = Encounters.export(c.db, "encounter")
    assert_raise Postgrex.Error, fn -> AcquisitionSessions.rows(c.db,
      "UPDATE encounter_exports SET conditional_create_qualified=true,qualification_ref=NULL WHERE encounter_id=$1", ["encounter"]) end
  end

  test "revoked or expired browser sessions and encounter closure cannot renew authority", c do
    F.encounter(c.db)
    assert {:ok, :ok} = Encounters.browser_session(c.db, "viewer", "encounter", "clinician", :clinician)
    assert {:ok, remaining} = Encounters.authority_remaining(c.db, "viewer", "encounter", "clinician", :clinician)
    assert remaining in 1..30_000
    AcquisitionSessions.rows(c.db, "UPDATE browser_sessions SET expires_at=clock_timestamp()+interval '2 seconds' WHERE id='viewer'", [])
    assert {:ok, short} = Encounters.authority_remaining(c.db, "viewer", "encounter", "clinician", :clinician)
    assert short in 1..2000
    AcquisitionSessions.rows(c.db, "UPDATE browser_sessions SET revoked=true WHERE id='viewer'", [])
    refute Encounters.session_authorized?(c.db, "viewer", "encounter", "clinician", :clinician)
    assert {:error, :session_expired} = Encounters.authority_remaining(c.db, "viewer", "encounter", "clinician", :clinician)
    assert {:ok, :ok} = Encounters.browser_session(c.db, "another_viewer", "encounter", "clinician", :clinician)
    assert {:ok, :ok} = Encounters.close(c.db, "encounter", "clinician")
    refute Encounters.session_authorized?(c.db, "another_viewer", "encounter", "clinician", :clinician)
    assert Encounters.session_authorized?(c.db, "another_viewer", "encounter", "clinician", :clinician, :read)
    assert {:error, :unauthorized} = Encounters.authority_remaining(c.db, "another_viewer", "encounter", "clinician", :clinician)
  end

  test "authorized configuration repair after closure prepares only unpinned intents and never redirects existing pins", c do
    F.encounter(c.db)
    original = %{"destination" => "https://first.example.invalid/fhir", "patient_ref" => "Patient/one", "encounter_ref" => "Encounter/one"}
    assert {:ok, :ok} = Encounters.configure_export(c.db, "encounter", "clinician", original)
    source = F.manual(c.db)
    {:ok, plan} = Review.plan(source, "clinician", "pin_request", %{"decision" => "accept"}, ~U[2026-11-24 12:00:01Z])
    {:ok, %{observations: [pinned_id]}} = Records.accept_plan(c.db, plan)
    {:ok, intent} = Deliveries.get(c.db, pinned_id)
    # This Store-only fixture checks immutable pin persistence. External FHIR
    # representation/readback is exercised by the separate real Interop lane.
    resource = %{"resourceType" => "Observation", "identifier" => [%{"system" => intent.identifier_system, "value" => intent.identifier_value}]}
    bytes = MedEx.CanonicalJSON.encode(resource)
    assert {:ok, :ok} = Deliveries.save_mapping(c.db, pinned_id, %{destination: original["destination"],
      refs: Map.take(original, ~w(patient_ref encounter_ref)), version: "store-pin-fixture-v2", resource: resource,
      bytes: bytes, fingerprint: AcquisitionSessions.hash(bytes), qualified: false, qualification_ref: nil})
    {:ok, pinned} = Deliveries.get(c.db, pinned_id)
    another = F.manual(c.db, "second_manual", 72)
    {:ok, plan} = Review.plan(another, "clinician", "blocked_request", %{"decision" => "accept"}, ~U[2026-11-24 12:00:01Z])
    {:ok, %{observations: [blocked_id]}} = Records.accept_plan(c.db, plan)
    assert {:ok, :ok} = Deliveries.block_preparation(c.db, blocked_id, :reference_missing)
    assert {:ok, :ok} = Encounters.close(c.db, "encounter", "clinician")
    repaired = %{"destination" => "https://second.example.invalid/fhir", "patient_ref" => "Patient/two", "encounter_ref" => "Encounter/two",
      "conditional_create_qualified" => true, "qualification_ref" => "qualified-fixture-contract"}
    assert {:error, :unauthorized} = Encounters.configure_export(c.db, "encounter", "patient", repaired)
    assert {:ok, :ok} = Encounters.configure_export(c.db, "encounter", "clinician", repaired)
    assert {:ok, %{destination: "https://second.example.invalid/fhir", qualified: true}} = Encounters.export(c.db, "encounter")
    assert {:ok, ^pinned} = Deliveries.get(c.db, pinned_id)
    assert {:ok, "pending"} = Deliveries.remediate(c.db, blocked_id, "clinician")
    assert {:ok, %{status: "pending", resource: nil, destination: nil}} = Deliveries.get(c.db, blocked_id)
  end

  test "configuration repair validates every bounded field and cannot bypass restore blocking", c do
    F.encounter(c.db)
    valid = %{"destination" => "https://example.invalid/fhir", "patient_ref" => "Patient/one", "encounter_ref" => "Encounter/one"}
    invalid = [nil, [], %{}, Map.put(valid, "extra", "unrecognized"), Map.put(valid, "destination", "file:///tmp/fhir"),
      Map.put(valid, "destination", "https://user:secret@example.invalid/fhir"), Map.put(valid, "destination", "https://example.invalid/fhir?token=secret"),
      Map.put(valid, "destination", "https://example.invalid/fhir#fragment"), Map.put(valid, "destination", String.duplicate("a", 2049)),
      Map.put(valid, "patient_ref", "Encounter/one"), Map.put(valid, "encounter_ref", "Encounter/../other"),
      Map.put(valid, "conditional_create_qualified", "true"), Map.put(valid, "conditional_create_qualified", true),
      Map.put(valid, "qualification_ref", ""), Map.put(valid, "qualification_ref", String.duplicate("x", 257))]
    for config <- invalid do
      assert {:error, :invalid_export_configuration} = Encounters.configure_export(c.db, "encounter", "clinician", config)
    end
    assert {:error, :destination_missing} = Encounters.export(c.db, "encounter")
    AcquisitionSessions.rows(c.db, "UPDATE deployment_identity SET recovery_state='blocked' WHERE singleton", [])
    assert {:error, :restore_reconciliation_required} = Encounters.configure_export(c.db, "encounter", "clinician", valid)
  end
end
