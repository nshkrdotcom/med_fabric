defmodule FabricHexSmoke.PublishedPackagesTest do
  use ExUnit.Case

  import Plug.Conn, only: [put_req_header: 3]
  alias ExWebRTC.{PeerConnection, SessionDescription}
  alias MedEx.Wire.FrameV1
  alias MedExHandheld.PLXPeripheral
  alias MedFabric.ExamWeb.Endpoint, as: Exam
  alias MedFabric.Preview.Endpoint, as: Preview

  test "Exam serves its own and the SDK's packaged browser assets" do
    for path <- ["/assets/exam.js", "/med_ex/pcm_worklet.js"] do
      response = Exam.call(Plug.Test.conn(:get, path), Exam.init([]))
      assert response.status == 200
      assert byte_size(response.resp_body) > 0
    end
  end

  test "Handheld reads a synthetic spot check that round-trips through MedEx" do
    peripheral = PLXPeripheral.new() |> PLXPeripheral.subscribe()
    {peripheral, {:indications, [_, reading]}} = PLXPeripheral.racp(peripheral, <<1, 1>>)
    {_, <<6, 0, 1, 1>>} = PLXPeripheral.complete(peripheral)
    event = PLXPeripheral.event(reading, "fixture-reading", 0, nil, :fixed_fixture_utc)
    assert event["metrics"]["spo2"] == %{"mantissa" => "98", "exponent" => "0"}

    assert :ok =
             PLXPeripheral.validate_sdk(event, %{"acquisition" => "hex-smoke", "boot" => "boot"})
  end

  test "Preview encodes an SDK PCM frame and sends Opus over WebRTC" do
    {:ok, receiver} = PeerConnection.start_link(ice_servers: [], audio_codecs: [:opus])

    try do
      {:ok, _} = PeerConnection.add_transceiver(receiver, :audio, direction: :recvonly)
      {:ok, offer} = PeerConnection.create_offer(receiver)
      :ok = PeerConnection.set_local_description(receiver, offer)
      assert_receive {:ex_webrtc, ^receiver, {:ice_gathering_state_change, :complete}}, 5_000

      {secret, token} = preview_credentials()
      %{sdp: offer_sdp} = PeerConnection.get_local_description(receiver)

      %{"sdp" => answer} =
        post_preview(
          "/offer",
          secret,
          JSON.encode!(%{"token" => token, "sdp" => offer_sdp, "ice" => %{"iceServers" => []}})
        )

      :ok =
        PeerConnection.set_remote_description(receiver, %SessionDescription{
          type: :answer,
          sdp: answer
        })

      assert_receive {:ex_webrtc, ^receiver, {:connection_state_change, :connected}}, 5_000

      for sequence <- 0..9 do
        assert %{"credit" => 1} = post_preview("/feed", secret, monitor_frame(sequence))
        Process.sleep(20)
      end

      assert_receive {:ex_webrtc, ^receiver, {:rtp, _track, _rid, %{payload: packet}}}, 2_000
      assert byte_size(packet) > 0

      assert %{"state" => "closed"} =
               post_preview("/close", secret, JSON.encode!(%{"token" => token}))
    after
      PeerConnection.stop(receiver)
    end
  end

  defp monitor_frame(sequence) do
    pcm = for i <- 0..959, into: <<>>, do: <<trunc(4000 * :math.sin(i / 20))::little-signed-16>>

    {:ok, bytes} =
      FrameV1.encode(%FrameV1{
        stream_number: 3,
        source_epoch: 0,
        config_epoch: 0,
        sequence: sequence,
        first_sample: sequence * 960,
        sample_count: 960,
        payload: pcm
      })

    bytes
  end

  defp preview_credentials do
    secret = Application.fetch_env!(:mf_preview, :listen)[:secret]

    payload =
      JSON.encode!(%{
        "acquisition" => "hex-smoke",
        "viewer" => "example",
        "exp" => System.system_time(:second) + 60
      })

    encode = &Base.url_encode64(&1, padding: false)
    token = encode.(payload) <> "." <> encode.(:crypto.mac(:hmac, :sha256, secret, payload))
    {secret, token}
  end

  defp post_preview(path, secret, body) do
    response =
      Plug.Test.conn(:post, path, body)
      |> put_req_header("authorization", "Bearer " <> secret)
      |> put_req_header("x-acquisition", "hex-smoke")
      |> Preview.call(Preview.init([]))

    assert response.status == 200
    JSON.decode!(response.resp_body)
  end
end
