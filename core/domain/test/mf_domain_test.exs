defmodule MedFabric.DomainTest do
  use ExUnit.Case, async: true

  alias MedFabric.Domain.Encounter

  test "closed encounter rejects new acquisitions" do
    enc = Encounter.new("enc_closed") |> Encounter.close()
    assert Encounter.request_acquisition(enc, "acq_1", "s1") == {:error, :encounter_closed}
  end

  test "preview drop stays transient, duplicate capture yields one review candidate, and acceptance is idempotent" do
    {:ok, enc0} = Encounter.new("enc_1") |> Encounter.request_acquisition("acq_1", "s1")

    enc1 =
      enc0
      |> Encounter.apply_fact(
        {:peer_connection_changed,
         %{peer_id: "clin_1", connection_id: "conn_a", state: :disconnected, t_ms: 14_200}}
      )
      |> Encounter.apply_fact(
        {:integrity_reported,
         %{
           subject: {:preview_stream, "auscultation"},
           interval_ms: {14_200, 14_200},
           continuity: :unknown,
           reasons: [:preview_disconnected]
         }}
      )

    capture_fact =
      {:capture_completed,
       %{
         encounter_ref: "enc_1",
         session_id: "s1",
         acquisition_id: "acq_1",
         artifact_sha256: "sha_ok_1",
         interval_ms: {10_000, 20_000},
         continuity: :observed_continuous,
         delivery_id: "d1",
         t_ms: 20_050
       }}

    # Deliver capture_completed twice (simulating redelivery)
    enc2 =
      enc1
      |> Encounter.apply_fact(capture_fact)
      |> Encounter.apply_fact(capture_fact)

    assert map_size(enc2.review_candidates) == 1
    assert enc2.review_candidates["acq_1"].status == :ready_for_review
    assert enc2.review_candidates["acq_1"].continuity == :observed_continuous
    assert enc2.accepted_observations == %{}

    # Explicit clinician acceptance emits one observation and one export intent
    {:ok, enc3, result1} = Encounter.accept_acquisition(enc2, "acq_1", "sha_ok_1", "clin_1")
    assert result1.observation.continuity == :observed_continuous
    assert result1.export_intent.target == :fhir_r4
    assert map_size(enc3.accepted_observations) == 1

    # Retrying acceptance with same digest is idempotent
    {:ok, enc4, result2} = Encounter.accept_acquisition(enc3, "acq_1", "sha_ok_1", "clin_1")
    assert result2 == result1
    assert map_size(enc4.accepted_observations) == 1
  end

  test "unknown recording continuity is preserved faithfully and conflicting digests block acceptance" do
    {:ok, enc0} = Encounter.new("enc_2") |> Encounter.request_acquisition("acq_u", "s2")

    enc1 =
      Encounter.apply_fact(
        enc0,
        {:capture_completed,
         %{
           encounter_ref: "enc_2",
           session_id: "s2",
           acquisition_id: "acq_u",
           artifact_sha256: "sha_u1",
           interval_ms: {0, 5_000},
           continuity: :unknown,
           delivery_id: "d1",
           t_ms: 5_010
         }}
      )

    assert enc1.review_candidates["acq_u"].continuity == :unknown

    # Conflicting digest arrives for the same acquisition -> blocks acceptance
    enc2 =
      Encounter.apply_fact(
        enc1,
        {:capture_completed,
         %{
           encounter_ref: "enc_2",
           session_id: "s2",
           acquisition_id: "acq_u",
           artifact_sha256: "sha_u2_conflict",
           interval_ms: {0, 5_000},
           continuity: :observed_continuous,
           delivery_id: "d2",
           t_ms: 5_020
         }}
      )

    assert enc2.review_candidates["acq_u"].status == :conflict

    assert Encounter.accept_acquisition(enc2, "acq_u", "sha_u1", "clin_1") ==
             {:error, :conflict_blocks_acceptance}
  end

  test "review candidates require the requested encounter, session, and acquisition" do
    {:ok, encounter} = Encounter.new("enc") |> Encounter.request_acquisition("acq", "session")

    capture = %{
      encounter_ref: "enc",
      session_id: "session",
      acquisition_id: "acq",
      artifact_sha256: "digest",
      interval_ms: {0, 5_000},
      continuity: :observed_continuous
    }

    for key <- [:encounter_ref, :session_id, :acquisition_id] do
      assert ^encounter =
               Encounter.apply_fact(
                 encounter,
                 {:capture_completed, %{capture | key => "unrelated"}}
               )
    end

    assert {:error, :acquisition_already_bound} =
             Encounter.request_acquisition(encounter, "acq", "new-session")

    ready = Encounter.apply_fact(encounter, {:capture_completed, capture})
    closed = Encounter.close(ready)

    assert {:error, :encounter_closed} =
             Encounter.accept_acquisition(closed, "acq", "digest", "reviewer")

    conflict = %{
      encounter_ref: "enc",
      session_id: "session",
      acquisition_id: "acq",
      incoming_sha256: "conflict"
    }

    held =
      encounter
      |> Encounter.apply_fact({:capture_conflict, conflict})
      |> Encounter.apply_fact({:capture_completed, capture})

    assert {:error, :conflict_blocks_acceptance} =
             Encounter.accept_acquisition(held, "acq", "digest", "reviewer")

    {:ok, accepted, original} = Encounter.accept_acquisition(ready, "acq", "digest", "reviewer")
    accepted = Encounter.apply_fact(accepted, {:capture_conflict, conflict})

    assert {:ok, _, ^original} =
             Encounter.accept_acquisition(Encounter.close(accepted), "acq", "digest", "reviewer")
  end
end
