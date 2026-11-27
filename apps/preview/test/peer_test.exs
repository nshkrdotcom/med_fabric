defmodule MedFabric.Preview.PeerTest do
  use ExUnit.Case, async: false
  alias ExWebRTC.{PeerConnection, SessionDescription}
  alias MedEx.Wire.FrameV1
  alias MedFabric.Preview.{Capability, Feed, Peer}
  @secret "synthetic-preview-test-credential-32"

  test "real PCM encoder and independent receiver preserve emitted sequence and dropped sample time" do
    {receiver, peer, grant, config} = connect()
    first = 9_600
    feed(grant, first)
    assert_receive {:ex_webrtc, ^receiver, {:rtp, _, _, packet}}, 2_000
    assert packet.sequence_number == 0 and packet.timestamp == 0
    assert byte_size(packet.payload) in 1..1275
    feed(grant, first + 2_880)
    assert_receive {:ex_webrtc, ^receiver, {:rtp, _, _, packet}}, 2_000
    assert packet.sequence_number == 1 and packet.timestamp == 2_880
    %{encoder: encoder} = :sys.get_state(peer)
    ref = Process.monitor(peer)
    Process.exit(encoder, :kill)
    assert_receive {:DOWN, ^ref, :process, ^peer, _}, 2_000
    eventually(fn -> Registry.lookup(MedFabric.Preview.Registry, Capability.key(grant)) == [] end)
    assert Peer.action(grant, "status", %{}, config) == {:error, :disconnected}
  end

  test "suspended established peer cannot resume encoding or sending beyond authority" do
    {receiver, peer, grant, _} = connect()
    feed(grant, 0)
    assert_receive {:ex_webrtc, ^receiver, {:rtp, _, _, _}}, 2_000
    :ok = :sys.suspend(peer)
    feed(grant, 960)
    Process.sleep(max(0, grant.deadline - System.monotonic_time(:millisecond) + 25))
    ref = Process.monitor(peer)
    :ok = :sys.resume(peer)
    assert_receive {:DOWN, ^ref, :process, ^peer, :normal}, 2_000
    refute_receive {:ex_webrtc, ^receiver, {:rtp, _, _, _}}, 250
    assert Feed.take(Capability.key(grant)) == :empty
  end

  defp connect do
    {:ok, config} = MedFabric.Preview.Application.validate_config(Application.fetch_env!(:mf_preview, :listen))
    {:ok, receiver} = PeerConnection.start_link(ice_servers: [])
    on_exit(fn -> if Process.alive?(receiver), do: PeerConnection.stop(receiver) end)
    {:ok, _} = PeerConnection.add_transceiver(receiver, :audio, direction: :recvonly)
    {:ok, offer} = PeerConnection.create_offer(receiver)
    :ok = PeerConnection.set_local_description(receiver, offer)
    assert_receive {:ex_webrtc, ^receiver, {:ice_gathering_state_change, :complete}}, 5_000
    grant = grant()
    assert {:ok, %{"sdp" => answer}} = Peer.action(grant, "offer", %{"sdp" => PeerConnection.get_local_description(receiver).sdp}, config)
    :ok = PeerConnection.set_remote_description(receiver, %SessionDescription{type: :answer, sdp: answer})
    assert_receive {:ex_webrtc, ^receiver, {:connection_state_change, :connected}}, 5_000
    [{peer, _}] = Registry.lookup(MedFabric.Preview.Registry, Capability.key(grant))
    on_exit(fn -> if Process.alive?(peer), do: Process.exit(peer, :kill) end)
    eventually(fn -> match?({:ok, %{"state" => "connected"}}, Peer.action(grant, "status", %{}, config)) end)
    {receiver, peer, grant, config}
  end
  defp feed(grant, sample) do
    pcm = for n <- 0..959, into: <<>>, do: <<trunc(4_000 * :math.sin(2 * :math.pi() * 440 * n / 48_000))::little-signed-16>>
    frame = %FrameV1{stream_number: 3, source_epoch: 0, config_epoch: 0, sequence: div(sample, 960), first_sample: sample, sample_count: 960, payload: pcm}
    assert :ok = Feed.offer(Capability.source(grant), frame)
  end
  defp grant do
    now = System.system_time(:millisecond)
    claims = %{"purpose" => "monitor", "acquisition" => "real-#{System.unique_integer([:positive])}", "source_kind" => "device", "profile" => "paired_exam", "generation" => "1", "source_epoch" => "0", "descriptor_ref" => String.duplicate("a", 64), "viewer" => "viewer", "viewer_session" => "session", "issued_at_ms" => to_string(now), "expires_at_ms" => to_string(now + 25_000), "nonce" => "nonce"}
    bytes = MedEx.CanonicalJSON.encode(claims)
    token = Base.url_encode64(bytes, padding: false) <> "." <> Base.url_encode64(:crypto.mac(:hmac, :sha256, @secret, bytes), padding: false)
    {:ok, grant} = Capability.verify(token, claims["acquisition"], @secret, now_ms: now, mono_ms: System.monotonic_time(:millisecond), clock_error_ms: 2_000)
    grant
  end
  defp eventually(check, remaining \\ 100)
  defp eventually(check, remaining) when remaining > 0, do: if(check.(), do: :ok, else: (Process.sleep(20); eventually(check, remaining - 1)))
  defp eventually(_, 0), do: flunk("native media peer did not reach expected state")
end
