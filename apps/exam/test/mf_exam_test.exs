defmodule MedFabric.ExamTest do
  use ExUnit.Case, async: true

  alias MedCore.StreamSpec
  alias MedFabric.Domain.Encounter
  alias MedFabric.Exam
  alias MedFabric.Interop.FhirClient
  alias MedFabric.Store.OutboxStore
  alias MedRTC.PeerLoopback
  alias MedRTC.SessionServer
  alias MedRTC.WavCapture
  alias MedWeb.Signaling

  defmodule ExamFhirAdapter do
    @moduledoc false

    def start do
      Agent.start_link(fn -> %{next_id: 1, by_identifier: %{}, dropped_once?: false} end)
    end

    def run(%Req.Request{} = request) do
      agent = request.private[:hapi_agent]

      case {request.method, request.url.path} do
        {:post, "/fhir/Observation"} -> handle_post(agent, request)
        {:get, "/fhir/Observation"} -> handle_get(agent, request)
      end
    end

    defp handle_post(agent, request) do
      body = Jason.decode!(IO.iodata_to_binary(request.body))
      "identifier=" <> encoded_id = Req.Request.get_header(request, "if-none-exist") |> List.first()
      ident_key = URI.decode_www_form(encoded_id)

      case Agent.get_and_update(agent, &upsert(&1, ident_key, body)) do
        {:ok, status, payload} ->
          {request,
           %Req.Response{
             status: status,
             headers: %{"content-type" => ["application/fhir+json"]},
             body: Jason.encode!(payload)
           }}

        {:error, reason} ->
          {request, %RuntimeError{message: "lost response: #{inspect(reason)}"}}
      end
    end

    defp upsert(state, ident_key, body) do
      case Map.get(state.by_identifier, ident_key) do
        nil ->
          stored = Map.put(body, "id", "exam-hapi-#{state.next_id}")

          next = %{
            state
            | next_id: state.next_id + 1,
              by_identifier: Map.put(state.by_identifier, ident_key, stored)
          }

          if state.dropped_once? do
            {{:ok, 201, stored}, next}
          else
            {{:error, :closed_after_write}, %{next | dropped_once?: true}}
          end

        existing ->
          {{:ok, 200, existing}, state}
      end
    end

    defp handle_get(agent, request) do
      %{"identifier" => ident_key} = URI.decode_query(request.url.query || "")
      matches = Agent.get(agent, fn s -> s.by_identifier |> Map.get(ident_key) |> List.wrap() end)

      bundle = %{
        "resourceType" => "Bundle",
        "type" => "searchset",
        "total" => length(matches),
        "entry" => Enum.map(matches, &%{"resource" => &1})
      }

      {request,
       %Req.Response{
         status: 200,
         headers: %{"content-type" => ["application/fhir+json"]},
         body: Jason.encode!(bundle)
       }}
    end
  end

  test "end-to-end Welded :med_ex WAV replay + ExWebRTC reconnect -> Encounter acceptance -> atomic OutboxStore -> idempotent FHIR delivery" do
    # 1. Verify the Welded :med_ex SDK ships its browser RTCPeerConnection hook asset
    hook_path = Signaling.hook_asset_full_path()
    assert File.regular?(hook_path)
    assert String.contains?(File.read!(hook_path), "RTCPeerConnection")

    # 2. Parse a 4 kHz 16-bit mono PCM WAV via Welded :med_ex MedRTC.WavCapture
    pcm = for i <- 0..3_999, into: <<>>, do: <<rem(i * 23, 30_000)::little-signed-16>>
    {:ok, wav} = pcm |> WavCapture.encode_pcm16_wav(4_000) |> WavCapture.parse_wav()
    expected_sha = :crypto.hash(:sha256, pcm) |> Base.encode16(case: :lower)

    # 3. Initialize encounter in pure MedFabric.Domain and live session in Welded :med_ex
    {:ok, encounter} = Encounter.new("enc_42") |> Encounter.request_acquisition("acq_1")

    stream = %StreamSpec{
      id: "exam_audio",
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

    session = Exam.start_session("enc_42", "sess_9", streams: [stream])
    {:ok, server} = SessionServer.start_link(session: session)

    # 4. Establish real ExWebRTC peer connection #1 (conn_a) and start acquisition
    {:ok, pair_a} = PeerLoopback.connect_pair("conn_a")

    {_, e1} =
      SessionServer.dispatch(
        server,
        Signaling.to_session_event({:join, "clin_1", "conn_a", :clinician, 100})
      )

    encounter = Exam.ingest_effects(encounter, e1)

    {_, e2} =
      SessionServer.dispatch(
        server,
        {:acquisition_started, %{acquisition_id: "acq_1", stream_id: "exam_audio", t_ms: 200}}
      )

    encounter = Exam.ingest_effects(encounter, e2)

    # 5. Replay WAV: drop real ExWebRTC preview mid-capture while lossless capture completes intact
    {summary, disconnect_effects} =
      replay_with_preview_drop(wav, pair_a, server)

    encounter = Exam.ingest_effects(encounter, disconnect_effects)
    assert summary.preview_chunks_dropped == 15
    assert summary.artifact_sha256 == expected_sha
    assert summary.continuity == :observed_continuous

    # 6. Capture finishes independently on the device; browser rejoins on conn_b
    complete_event =
      {:capture_completed,
       %{
         acquisition_id: "acq_1",
         artifact_sha256: summary.artifact_sha256,
         interval_ms: summary.interval_ms,
         continuity: summary.continuity,
         delivery_id: "deliv_1",
         t_ms: 1_250
       }}

    {_, e4} = SessionServer.dispatch(server, complete_event)
    encounter = Exam.ingest_effects(encounter, e4)

    {:ok, pair_b} = PeerLoopback.connect_pair("conn_b")

    {_, e5} =
      SessionServer.dispatch(
        server,
        Signaling.to_session_event({:join, "clin_1", "conn_b", :clinician, 1_400})
      )

    encounter = Exam.ingest_effects(encounter, e5)
    :ok = PeerLoopback.close_pair(pair_b)

    # 7. Redeliver the SDK's emitted capture_completed fact -> still 1 candidate, 0 accepted
    encounter = Exam.ingest_effects(encounter, e4)
    assert map_size(encounter.review_candidates) == 1
    assert encounter.review_candidates["acq_1"].continuity == :observed_continuous
    assert encounter.accepted_observations == %{}

    # 8. Explicit clinician acceptance -> atomic OutboxStore commit + crash-retry idempotency
    {:ok, encounter_accepted, acceptance} =
      Encounter.accept_acquisition(encounter, "acq_1", expected_sha, "clin_1")

    assert map_size(encounter_accepted.accepted_observations) == 1

    {:ok, store} = OutboxStore.start_link()

    provenance = %{
      source_kind: :synthetic_wav,
      source_ref: "exam_4khz_test.wav",
      sample_rate_hz: wav.sample_rate_hz,
      sample_count: summary.sample_count
    }

    assert_raise RuntimeError, "lost_reply", fn ->
      OutboxStore.commit_acceptance(store, acceptance, provenance,
        after_commit: fn _rec -> raise "lost_reply" end
      )
    end

    {:ok, :already_committed, record} =
      OutboxStore.commit_acceptance(store, acceptance, provenance)

    assert length(OutboxStore.list_observations(store)) == 1
    assert length(OutboxStore.list_outbox(store)) == 1

    # 9. Deliver to simulated HAPI FHIR: lost HTTP response -> retry -> exactly 1 remote resource
    {:ok, hapi_agent} = ExamFhirAdapter.start()

    fhir_opts = [
      base_url: "http://localhost:8080/fhir",
      adapter: ExamFhirAdapter,
      private: %{hapi_agent: hapi_agent}
    ]

    resource =
      FhirClient.build_observation(record.observation, record.outbox, record.provenance,
        patient_ref: "Patient/synth-42"
      )

    assert {:error, %RuntimeError{message: "lost response: :closed_after_write"}} =
             FhirClient.deliver(resource, fhir_opts)

    {:ok, _retry_entry} =
      OutboxStore.mark_delivery_failed(store, record.outbox.intent_id, :closed_after_write, 2_000)

    assert {:ok, %{remote_ref: "Observation/exam-hapi-1", created?: false}} =
             FhirClient.deliver(resource, fhir_opts)

    {:ok, delivered} =
      OutboxStore.mark_delivered(store, record.outbox.intent_id, "Observation/exam-hapi-1")

    assert delivered.status == :delivered

    assert {:ok, [remote]} = FhirClient.fetch_by_identifier(record.outbox.external_id, fhir_opts)
    assert remote["id"] == "exam-hapi-1"
    assert remote["subject"] == %{"reference" => "Patient/synth-42"}
    assert remote["valueString"] =~ expected_sha
  end

  defp replay_with_preview_drop(wav, pair_a, server) do
    {:ok, agent} = Agent.start_link(fn -> [] end)

    summary =
      WavCapture.replay(wav,
        acquisition_id: "acq_1",
        started_at_ms: 200,
        chunk_ms: 20,
        on_preview_chunk: fn idx, _chunk ->
          cond do
            idx == 5 ->
              :ok = PeerLoopback.close_pair(pair_a)

              {_, effects} =
                SessionServer.dispatch(
                  server,
                  Signaling.to_session_event({:leave, "clin_1", "conn_a", 400})
                )

              Agent.update(agent, fn _ -> effects end)
              {:error, :preview_disconnected}

            idx > 5 and idx < 20 ->
              {:error, :preview_disconnected}

            true ->
              :ok
          end
        end
      )

    effects = Agent.get(agent, & &1)
    Agent.stop(agent)
    {summary, effects}
  end
end
