defmodule MedExHandheld.SessionCleanupTest do
  use ExUnit.Case, async: true

  setup context do
    if dir = context[:tmp_dir], do: on_exit(fn -> File.rm_rf!(dir) end)
    :ok
  end

  alias MedExHandheld.{Session, Spool}

  @tag :tmp_dir
  test "failed initial admission releases all local owners while the caller survives", %{
    tmp_dir: dir
  } do
    config = %{
      "device" => "fixture",
      "encounter" => "exam",
      "acquisition" => "fresh",
      "spool_root" => dir,
      "server" => "wss://localhost:443",
      "ca_file" => Path.join(dir, "unused-ca.pem"),
      "credential_file" => Path.join(dir, "missing-device-credential")
    }

    links = caller_links()
    assert_raise File.Error, fn -> Session.run(config, "plx_spot_check") end
    assert caller_links() == links
    pid = start_supervised!({Spool, [root: Path.join(dir, "fresh"), limit: 1000]})
    assert Spool.stats(pid).bytes == 0
  end

  @tag :tmp_dir
  test "a mismatched durable identity survives rejection and its spool lock is released", %{
    tmp_dir: dir
  } do
    root = Path.join(dir, "exam")
    persisted = Path.join(root, "identity.json")
    identity = Map.put(identity(), "device", "other-device")
    bytes = JSON.encode!(identity)
    Spool.write!(persisted, bytes)

    links = caller_links()

    assert_raise RuntimeError, "spool identity mismatch", fn ->
      Session.run(Map.put(identity(), "spool_root", dir), "plx_spot_check")
    end

    assert caller_links() == links
    assert File.read!(persisted) == bytes
    pid = start_supervised!({Spool, root: root, limit: 1000})
    assert Spool.stats(pid).bytes == 0
  end

  @tag :tmp_dir
  test "monitor initialization reports its error and leaves its durable state intact", %{
    tmp_dir: dir
  } do
    root = Path.join(dir, "exam")
    Spool.write!(Path.join(root, "identity.json"), JSON.encode!(identity()))
    monitor_file = Path.join(root, "monitor.json")
    bytes = JSON.encode!(%{"boot" => "other-boot"})
    Spool.write!(monitor_file, bytes)

    links = caller_links()

    error =
      assert_raise MatchError, fn ->
        Session.run(Map.put(identity(), "spool_root", dir), "plx_spot_check")
      end

    assert {:error, {{%RuntimeError{message: "monitor boot domain changed"}, _}, _}} = error.term
    assert caller_links() == links
    assert File.read!(monitor_file) == bytes
    pid = start_supervised!({Spool, root: root, limit: 1000})
    assert Spool.stats(pid).bytes == 0
  end

  @tag :tmp_dir
  test "peer-verified WSS admission refusal closes the connection and releases local owners", %{
    tmp_dir: dir
  } do
    cert = Path.join(dir, "cert.pem")
    key = Path.join(dir, "key.pem")
    credential = Path.join(dir, "credential")
    Spool.write!(credential, "wrong-fixture-token")

    ca = Path.join(dir, "ca.pem")
    ca_key = Path.join(dir, "ca.key")

    certificate!([
      "-subj",
      "/CN=Session cleanup test CA",
      "-addext",
      "basicConstraints=critical,CA:TRUE",
      "-addext",
      "keyUsage=critical,keyCertSign,cRLSign",
      "-keyout",
      ca_key,
      "-out",
      ca
    ])

    certificate!([
      "-CA",
      ca,
      "-CAkey",
      ca_key,
      "-subj",
      "/CN=localhost",
      "-addext",
      "subjectAltName=DNS:localhost",
      "-addext",
      "basicConstraints=critical,CA:FALSE",
      "-addext",
      "extendedKeyUsage=serverAuth",
      "-keyout",
      key,
      "-out",
      cert
    ])

    File.rm!(ca_key)

    {:ok, listener} =
      :ssl.listen(0,
        ip: {127, 0, 0, 1},
        active: false,
        packet: :http_bin,
        certfile: String.to_charlist(cert),
        keyfile: String.to_charlist(key)
      )

    on_exit(fn -> :ssl.close(listener) end)
    {:ok, {{127, 0, 0, 1}, port}} = :ssl.sockname(listener)

    links = caller_links()

    peer =
      Task.async(fn ->
        {:ok, socket} = :ssl.transport_accept(listener, 5000)
        {:ok, socket} = :ssl.handshake(socket, 5000)

        try do
          {:ok, {:http_request, :GET, {:abs_path, "/api/device/v1/control"}, {1, 1}}} =
            :ssl.recv(socket, 0, 5000)

          receive_refusal_request(socket, nil)
        after
          :ssl.close(socket)
        end
      end)

    peer_pid = peer.pid
    peer_exit = Process.monitor(peer_pid)

    config =
      Map.merge(identity(), %{
        "spool_root" => dir,
        "server" => "wss://localhost:#{port}",
        "ca_file" => ca,
        "credential_file" => credential
      })

    error = assert_raise MatchError, fn -> Session.run(config, "plx_spot_check") end
    assert error.term == {:error, :upgrade_failed}
    # Only the test-owned peer may still be linked at this point.
    assert MapSet.delete(caller_links(), peer_pid) == links
    assert Task.await(peer) == "Bearer wrong-fixture-token"
    assert_receive {:DOWN, ^peer_exit, :process, ^peer_pid, :normal}, 5_000
    refute Process.alive?(peer_pid)
    assert caller_links() == links

    root = Path.join(dir, "exam")
    refute File.exists?(Path.join(root, "source_started.json"))
    pid = start_supervised!({Spool, root: root, limit: 1000})
    assert Spool.stats(pid).bytes == 0
  end

  @tag :tmp_dir
  test "local PLX ingestion failure releases the recovered spool and preserves its outcome", %{
    tmp_dir: dir
  } do
    root = Path.join(dir, "resuming")
    File.mkdir_p!(root)

    identity = %{
      "device" => "fixture",
      "encounter" => "exam",
      "acquisition" => "resuming",
      "boot" => "boot",
      "profile" => "plx_spot_check",
      "origin_us" => 0
    }

    Spool.write!(Path.join(root, "identity.json"), JSON.encode!(identity))

    Spool.write!(
      Path.join(root, "source_started.json"),
      JSON.encode!(Map.take(identity, ["boot", "acquisition"]))
    )

    config = Map.merge(identity, %{"spool_root" => dir, "spool_limit" => 1})
    links = caller_links()
    error = assert_raise MatchError, fn -> Session.run(config, "plx_spot_check") end
    assert error.term == {:error, :spool_full}
    assert caller_links() == links
    pid = start_supervised!({Spool, [root: root, limit: 1000]})
    assert Spool.stats(pid).bytes == 0
    refute File.exists?(Path.join(root, "inventory.json"))
  end

  test "teardown of a partially started paired capture preserves the caller's failure" do
    parent = self()
    {:ok, resources} = Supervisor.start_link([], strategy: :one_for_one)
    {:ok, pool} = Supervisor.start_child(resources, {Task.Supervisor, []})

    producer =
      Task.Supervisor.async(pool, fn ->
        send(parent, {:collecting, self()})

        receive do
          :finish -> :ok
        end
      end)

    pid = producer.pid
    assert_receive {:collecting, ^pid}
    assert MapSet.member?(caller_links(), pid)

    assert_raise RuntimeError, "second source failed to start", fn ->
      try do
        raise "second source failed to start"
      after
        Session.stop_resources(resources)
      end
    end

    refute Process.alive?(pid)
    refute Process.alive?(resources)
  end

  defp identity do
    %{
      "device" => "fixture",
      "encounter" => "one",
      "acquisition" => "exam",
      "boot" => "boot",
      "profile" => "plx_spot_check",
      "origin_us" => 0
    }
  end

  defp certificate!(extensions) do
    args = ["req", "-x509", "-newkey", "rsa:2048", "-nodes", "-days", "1"]
    assert {_, 0} = System.cmd("openssl", args ++ extensions, stderr_to_stdout: true)
  end

  defp receive_refusal_request(socket, authorization) do
    case :ssl.recv(socket, 0, 5000) do
      {:ok, {:http_header, _, :Authorization, _, value}} ->
        receive_refusal_request(socket, value)

      {:ok, {:http_header, _, _, _, _}} ->
        receive_refusal_request(socket, authorization)

      {:ok, :http_eoh} ->
        :ok = :ssl.send(socket, "HTTP/1.1 401 Unauthorized\r\nContent-Length: 0\r\n\r\n")
        assert {:error, :closed} = :ssl.recv(socket, 0, 5000)
        authorization
    end
  end

  defp caller_links do
    {:links, links} = Process.info(self(), :links)
    MapSet.new(links)
  end
end
