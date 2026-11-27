defmodule MedFabric.Preview.FeedTest do
  use ExUnit.Case, async: false
  alias MedEx.Wire.FrameV1
  alias MedFabric.Preview.{Application, Capability, Endpoint, Feed, Peer}
  @secret "synthetic-preview-test-credential-32"

  setup do
    {:ok, config} =
      Application.validate_config(Elixir.Application.fetch_env!(:mf_preview, :listen))

    {:ok, config: config}
  end

  test "private monitor frames require all source identities and never retain listenerless frames",
       %{config: config} do
    {:ok, bytes} =
      FrameV1.encode(%FrameV1{
        stream_number: 3,
        source_epoch: 0,
        config_epoch: 1,
        sequence: 0,
        first_sample: 0,
        sample_count: 960,
        payload: :binary.copy(<<0>>, 1920)
      })

    request =
      Plug.Test.conn(:post, "/feed", bytes) |> Plug.Conn.put_req_header("x-acquisition", "acq")

    assert Endpoint.call(request, config).status == 403

    signed =
      request
      |> Plug.Conn.put_req_header("authorization", "Bearer " <> @secret)
      |> Plug.Conn.put_req_header("x-generation", "1")
      |> Plug.Conn.put_req_header("x-source-epoch", "0")
      |> Plug.Conn.put_req_header("x-descriptor-ref", String.duplicate("a", 64))

    assert Endpoint.call(signed, config).status == 200
    assert :ets.match_object(:mf_preview_feed, {{:frame, :_}, :_, :_, :_}) == []

    assert Endpoint.call(Plug.Conn.put_req_header(signed, "x-generation", "01"), config).status ==
             403
  end

  test "owner resource reservations are finite and crash cleanup removes slots", %{config: config} do
    grant = grant("viewer", "session")
    {:reserved, ticket} = Feed.reserve(grant, true)

    {:ok, peer} =
      DynamicSupervisor.start_child(
        MedFabric.Preview.Peers,
        {Peer, %{grant: grant, ticket: ticket, config: config}}
      )

    assert :ok = Feed.attach(Capability.key(grant), ticket, peer)
    assert {:ok, ^peer} = Feed.reserve(grant, true)
    other = grant("other", "session")
    assert {:reserved, second} = Feed.reserve(other, true)
    assert {:error, :capacity} = Feed.reserve(grant("third", "session"), true)
    Feed.release(Capability.key(other), second)
    ref = Process.monitor(peer)
    Process.exit(peer, :kill)
    assert_receive {:DOWN, ^ref, :process, ^peer, :killed}
    # The Feed owner consumes the same DOWN before its next synchronous request.
    eventually(fn -> Feed.reserve(grant, false) == :absent end)
    assert :ets.lookup(:mf_preview_feed, {:peer, Capability.key(grant)}) == []
  end

  test "suspended peer resumes past authority expiry without allocating native media", %{
    config: config
  } do
    grant = %{grant("expired", "session") | deadline: System.monotonic_time(:millisecond) + 30}
    {:reserved, ticket} = Feed.reserve(grant, true)

    {:ok, peer} =
      DynamicSupervisor.start_child(
        MedFabric.Preview.Peers,
        {Peer, %{grant: grant, ticket: ticket, config: config}}
      )

    assert :ok = Feed.attach(Capability.key(grant), ticket, peer)
    :ok = :sys.suspend(peer)
    ref = Process.monitor(peer)
    Process.sleep(40)
    :ok = :sys.resume(peer)
    assert_receive {:DOWN, ^ref, :process, ^peer, :normal}, 1000
  end

  test "untrusted clock and invalid listener configuration fail before child startup" do
    assert {:error, :invalid_preview_configuration} =
             Application.validate_config(port: 0, secret: @secret)

    assert {:error, _} =
             Application.validate_config(port: 0, secret: "short", trusted_clock: true)

    assert {:error, _} = Application.validate_config([:invalid])

    assert {:error, _} =
             Application.validate_config(
               port: 0,
               secret: @secret,
               secret: @secret,
               trusted_clock: true
             )

    assert {:error, _} =
             Application.validate_config(
               port: 0,
               secret: @secret,
               trusted_clock: true,
               ice_servers: [%{"urls" => ["https://remote.invalid"]}]
             )

    assert {:error, _} =
             Application.validate_config(
               port: 0,
               secret: @secret,
               trusted_clock: true,
               ice_transport_policy: :relay,
               ice_servers: []
             )
  end

  test "one request slot per viewer and finite global budget are released exactly once", %{
    config: config
  } do
    token = make_ref()
    key = {"budget", "viewer", "session"}
    assert Feed.enter(key, token)
    refute Feed.enter(key, make_ref())
    before = :ets.lookup_element(:mf_preview_feed, :requests, 2)
    assert :ok = Feed.leave(key, make_ref())
    assert :ets.lookup_element(:mf_preview_feed, :requests, 2) == before
    assert :ok = Feed.leave(key, token)
    assert :ok = Feed.leave(key, token)
    assert :ets.lookup_element(:mf_preview_feed, :requests, 2) == before - 1

    slots =
      for n <- 1..(config[:max_peers] * 2), do: {{"global", "viewer-#{n}", "session"}, make_ref()}

    try do
      for {id, ref} <- slots, do: assert(Feed.enter(id, ref))
      refute Feed.enter({"global", "overflow", "session"}, make_ref())
    after
      for {id, ref} <- slots, do: Feed.leave(id, ref)
    end
  end

  test "latest slots retain full source identity across peer replacement", %{config: config} do
    grant = grant("generation", "session")
    {:reserved, ticket} = Feed.reserve(grant, true)

    {:ok, peer} =
      DynamicSupervisor.start_child(
        MedFabric.Preview.Peers,
        {Peer, %{grant: grant, ticket: ticket, config: config}}
      )

    :ok = Feed.attach(Capability.key(grant), ticket, peer)
    :ok = :sys.suspend(peer)
    source = Capability.source(grant)

    frame = %FrameV1{
      stream_number: 3,
      source_epoch: 0,
      config_epoch: 0,
      sequence: 0,
      first_sample: 0,
      sample_count: 960,
      payload: :binary.copy(<<0>>, 1920)
    }

    assert :ok = Feed.offer(source, frame)
    assert {:ok, _, ^source, ^frame} = Feed.take(Capability.key(grant))
    assert :ok = Feed.offer(Map.put(source, "generation", "2"), frame)
    assert :empty = Feed.take(Capability.key(grant))
    Process.exit(peer, :kill)
  end

  defp grant(viewer, session) do
    now = System.system_time(:millisecond)

    claims = %{
      "purpose" => "monitor",
      "acquisition" => "acq",
      "source_kind" => "device",
      "profile" => "paired_exam",
      "generation" => "1",
      "source_epoch" => "0",
      "descriptor_ref" => String.duplicate("a", 64),
      "viewer" => viewer,
      "viewer_session" => session,
      "issued_at_ms" => to_string(now),
      "expires_at_ms" => to_string(now + 25_000),
      "nonce" => "nonce"
    }

    payload = MedEx.CanonicalJSON.encode(claims)

    token =
      Base.url_encode64(payload, padding: false) <>
        "." <> Base.url_encode64(:crypto.mac(:hmac, :sha256, @secret, payload), padding: false)

    {:ok, grant} =
      Capability.verify(token, "acq", @secret,
        now_ms: now,
        mono_ms: System.monotonic_time(:millisecond),
        clock_error_ms: 2_000
      )

    grant
  end

  defp eventually(check, remaining \\ 100)

  defp eventually(check, remaining) when remaining > 0 do
    if check.(),
      do: :ok,
      else:
        (
          Process.sleep(10)
          eventually(check, remaining - 1)
        )
  end

  defp eventually(_, 0), do: flunk("peer cleanup did not complete")
end
