defmodule MedFabric.ExamTest do
  use ExUnit.Case, async: true

  alias MedCore.StreamSpec
  alias MedFabric.Domain.Encounter
  alias MedFabric.Exam
  alias MedRTC.PeerLoopback
  alias MedRTC.SessionServer
  alias MedWeb.Signaling

  test "consumes Welded :med_ex SDK (ExWebRTC loopback + shipped JS hook) and accepts one deduplicated capture" do
    # 1. Verify the Welded :med_ex SDK ships its browser RTCPeerConnection hook asset
    hook_path = Signaling.hook_asset_full_path()
    assert File.regular?(hook_path)
    assert String.contains?(File.read!(hook_path), "RTCPeerConnection")

    # 2. Initialize encounter in pure MedFabric.Domain and live session in Welded :med_ex
    {:ok, encounter} = Encounter.new("enc_42") |> Encounter.request_acquisition("acq_1")

    stream = %StreamSpec{
      id: "exam_audio",
      archetype: :diagnostic_audio,
      modality: :stethoscope,
      codec_profile: {:opus, bitrate: 32_000, fec: true},
      priority: 2,
      integrity_policy: %{
        require_dsp_disabled: false,
        max_packet_loss_pct: 1.0,
        max_jitter_ms: 80,
        allow_plc: true,
        sample_rate_hz: 48_000
      }
    }

    session = Exam.start_session("enc_42", "sess_9", streams: [stream])
    {:ok, server} = SessionServer.start_link(session: session)

    # 3. Establish real ExWebRTC peer connection #1 (conn_a)
    {:ok, pair_a} = PeerLoopback.connect_pair("conn_a")

    {_, e1} =
      SessionServer.dispatch(
        server,
        Signaling.to_session_event({:join, "clin_1", "conn_a", :clinician, 100})
      )

    encounter = Exam.ingest_effects(encounter, e1)

    # 4. Start simulated capture
    {_, e2} =
      SessionServer.dispatch(
        server,
        {:acquisition_started, %{acquisition_id: "acq_1", stream_id: "exam_audio", t_ms: 200}}
      )

    encounter = Exam.ingest_effects(encounter, e2)

    # 5. Drop real ExWebRTC preview connection #1 while capture continues
    :ok = PeerLoopback.close_pair(pair_a)

    {_, e3} =
      SessionServer.dispatch(
        server,
        Signaling.to_session_event({:leave, "clin_1", "conn_a", 400})
      )

    encounter = Exam.ingest_effects(encounter, e3)

    # 6. Capture finishes independently on the device
    complete_event =
      {:capture_completed,
       %{
         acquisition_id: "acq_1",
         artifact_sha256: "sha_exam_1",
         interval_ms: {200, 1_200},
         continuity: :observed_continuous,
         delivery_id: "deliv_1",
         t_ms: 1_250
       }}

    {_, e4} = SessionServer.dispatch(server, complete_event)
    encounter = Exam.ingest_effects(encounter, e4)

    # 7. Browser rejoins same session with a new real ExWebRTC connection (conn_b)
    {:ok, pair_b} = PeerLoopback.connect_pair("conn_b")

    {_, e5} =
      SessionServer.dispatch(
        server,
        Signaling.to_session_event({:join, "clin_1", "conn_b", :clinician, 1_400})
      )

    encounter = Exam.ingest_effects(encounter, e5)
    :ok = PeerLoopback.close_pair(pair_b)

    # 8. Feed the SDK's actual emitted capture_completed fact a second time (redelivery)
    encounter = Exam.ingest_effects(encounter, e4)

    # 9. Preview interruption stays transient; recording continuity intact; one candidate
    assert encounter.transient_preview_state[{:preview_stream, "exam_audio"}].continuity ==
             :unknown

    assert map_size(encounter.review_candidates) == 1
    assert encounter.review_candidates["acq_1"].status == :ready_for_review
    assert encounter.review_candidates["acq_1"].continuity == :observed_continuous
    assert encounter.accepted_observations == %{}

    # 10. Explicit clinician acceptance yields one observation + one FHIR export intent
    {:ok, encounter_accepted, acceptance} =
      Encounter.accept_acquisition(encounter, "acq_1", "sha_exam_1", "clin_1")

    assert acceptance.observation.observation_id == "obs:enc_42:acq_1"
    assert acceptance.observation.continuity == :observed_continuous
    assert acceptance.export_intent.target == :fhir_r4
    assert map_size(encounter_accepted.accepted_observations) == 1
  end
end
