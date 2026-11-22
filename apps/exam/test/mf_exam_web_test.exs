defmodule MedFabric.ExamWebTest do
  use ExUnit.Case, async: false

  import Phoenix.ChannelTest
  import Phoenix.ConnTest, only: [build_conn: 0, get: 2]
  import Phoenix.LiveViewTest, only: [live: 2, element: 3, render: 1, render_click: 1]

  alias MedCore.StreamSpec
  alias MedFabric.Exam
  alias MedFabric.ExamWeb.Endpoint
  alias MedFabric.ExamWeb.SignalingChannel
  alias MedFabric.ExamWeb.UserSocket
  alias MedFabric.Store.OutboxStore
  alias MedRTC.SessionServer

  @endpoint Endpoint

  setup_all do
    start_supervised!({Phoenix.PubSub, name: MedFabric.Exam.PubSub})
    start_supervised!(Endpoint)
    :ok
  end

  test "endpoint serves the Welded :med_ex browser RTCPeerConnection hook JS asset" do
    conn = get(build_conn(), "/med_ex/session_hook.js")
    assert conn.status == 200
    assert conn.resp_body =~ "RTCPeerConnection"
  end

  test "SignalingChannel authorizes encounter_ref, relays SDP/ICE, and preserves session across reconnect" do
    stream = %StreamSpec{
      id: "auscultation",
      archetype: :diagnostic_audio,
      modality: :stethoscope,
      codec_profile: {:pcm_s16le, 4_000},
      priority: 2,
      integrity_policy: %{
        require_dsp_disabled: true,
        max_packet_loss_pct: 0.05,
        max_jitter_ms: 40,
        allow_plc: false,
        sample_rate_hz: 4_000
      }
    }

    session = Exam.start_session("enc_web_1", "sess_web_1", streams: [stream])
    {:ok, server} = start_supervised({SessionServer, session: session})
    :ok = SignalingChannel.register_session("enc_web_1", server)

    # Unauthorized connection without clinician/encounter fails
    assert :error = connect(UserSocket, %{})

    # Authorized clinician for enc_web_1 cannot join enc_other
    {:ok, socket} =
      connect(UserSocket, %{"clinician_id" => "clin_1", "encounter_ref" => "enc_web_1"})

    assert {:error, %{reason: "unauthorized_encounter"}} =
             subscribe_and_join(socket, "signaling:enc_other", %{"connection_id" => "conn_bad"})

    # Authorized join on conn_a relays SDP offer + ICE candidate
    {:ok, %{session_id: "sess_web_1", connection_id: "conn_a"}, chan_a} =
      subscribe_and_join(socket, "signaling:enc_web_1", %{
        "connection_id" => "conn_a",
        "t_ms" => 100
      })

    ref_offer = push(chan_a, "sdp_offer", %{"sdp" => "v=0\r\ns=med_ex"})
    assert_reply ref_offer, :ok, %{relayed: :sdp_offer, session_id: "sess_web_1"}

    ref_ice = push(chan_a, "ice_candidate", %{"candidate" => "candidate:1 1 UDP 123"})
    assert_reply ref_ice, :ok, %{relayed: :ice_candidate}

    # Start capture, drop conn_a, complete capture independently, rejoin on conn_b
    SessionServer.dispatch(
      server,
      {:acquisition_started, %{acquisition_id: "acq_1", stream_id: "auscultation", t_ms: 200}}
    )

    Process.unlink(chan_a.channel_pid)
    ref_close = leave(chan_a)
    assert_reply ref_close, :ok

    SessionServer.dispatch(
      server,
      {:capture_completed,
       %{
         acquisition_id: "acq_1",
         artifact_sha256: "sha_web_1",
         interval_ms: {200, 1_200},
         continuity: :observed_continuous,
         delivery_id: "deliv_web_1",
         t_ms: 1_250
       }}
    )

    {:ok, %{session_id: "sess_web_1", connection_id: "conn_b"}, _chan_b} =
      subscribe_and_join(socket, "signaling:enc_web_1", %{
        "connection_id" => "conn_b",
        "t_ms" => 1_400
      })

    snap = SessionServer.snapshot(server)
    assert snap.id == "sess_web_1"
    assert snap.integrity_reports[{:recording_artifact, "acq_1"}].continuity == :observed_continuous
    assert length(snap.preview_interruptions) == 1
  end

  test "ExamLive preserves MedExSessionHook across updates, separates preview vs recording continuity, and commits acceptance" do
    {:ok, store} = start_supervised(OutboxStore)
    Application.put_env(:mf_exam, :outbox_store, store)
    on_exit(fn -> Application.delete_env(:mf_exam, :outbox_store) end)

    {:ok, view, html} = live(build_conn(), "/encounters/enc_live_1")
    assert html =~ ~s(phx-hook="MedExSessionHook")
    assert html =~ ~s(phx-update="ignore")
    assert html =~ ~s(data-hook-src="/med_ex/session_hook.js")

    # Simulate preview drop + independent continuous recording completion (redelivered twice)
    effects = [
      {:emit_fact, :integrity_reported,
       %{
         subject: {:preview_stream, "auscultation"},
         interval_ms: {400, 400},
         continuity: :unknown,
         reasons: [:preview_disconnected]
       }},
      {:emit_fact, :capture_completed,
       %{
         encounter_ref: "enc_live_1",
         session_id: "sess_enc_live_1",
         acquisition_id: "acq_1",
         artifact_sha256: "sha_live_1",
         interval_ms: {200, 1_200},
         continuity: :observed_continuous
       }}
    ]

    send(view.pid, {:med_ex_effects, effects})
    send(view.pid, {:med_ex_effects, effects})

    rendered = render(view)
    assert rendered =~ "Preview (auscultation): unknown"
    assert rendered =~ "Recording acq_1: observed_continuous (ready_for_review)"
    assert rendered =~ ~s(phx-hook="MedExSessionHook")

    # Explicit clinician click commits atomically to OutboxStore
    view |> element("button", "Accept Recording") |> render_click()
    assert render(view) =~ "Accepted: obs:enc_live_1:acq_1"
    assert length(OutboxStore.list_observations(store)) == 1
    assert length(OutboxStore.list_outbox(store)) == 1
  end
end
