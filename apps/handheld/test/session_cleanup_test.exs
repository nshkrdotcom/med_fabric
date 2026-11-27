defmodule MedExHandheld.SessionCleanupTest do
  use ExUnit.Case, async: true
  alias MedExHandheld.{Session, Transport}

  setup do
    root = Path.join(System.tmp_dir!(), "mf-session-" <> Base.url_encode64(:crypto.strong_rand_bytes(12), padding: false))
    File.mkdir!(root)
    File.chmod!(root, 0o700)
    on_exit(fn -> File.rm_rf!(root) end)
    %{tmp_dir: root}
  end

  test "session dimensions reject clean completion before drain and invalidate authority on disconnect" do
    initial = %{phase: :disconnected, binding: nil, authority_deadline: nil, stopped: false}
    assert {:ok, resuming} = Session.transition(initial, :resume, 0)
    assert {:error, _} = Session.transition(resuming, {:admitted, %{}, 0}, 1)

    assert {:ok, active} =
             Session.transition(resuming, {:admitted, %{"connection" => "current"}, 100}, 1)

    assert {:error, _} = Session.transition(active, {:sealed, String.duplicate("a", 64)}, 2)
    assert {:ok, lost} = Session.transition(active, :transport_lost, 2)
    assert lost.phase == :disconnected and lost.binding == nil and lost.authority_deadline == nil
    assert {:ok, draining} = Session.transition(active, :source_stopped, 2)
    assert {:ok, finalizing} = Session.transition(draining, :durably_drained, 3)

    assert {:ok, complete} =
             Session.transition(finalizing, {:sealed, String.duplicate("a", 64)}, 4)

    assert complete.phase == :complete
  end

  test "invalid credential configuration creates no owners or spool evidence", %{tmp_dir: root} do
    config = %{
      "device" => "device",
      "encounter" => "exam",
      "acquisition" => "acq",
      "spool_root" => root,
      "server" => "wss://localhost:443",
      "credential_file" => Path.join(root, "absent")
    }

    before = links()

    assert_raise ArgumentError, "invalid Handheld configuration", fn ->
      Session.run(config, "plx_spot_check")
    end

    assert links() == before
    refute File.exists?(Path.join(root, "acq"))

    assert {:error, :invalid_transport_configuration} =
             Transport.validate_config(%{config | "server" => "ws://localhost"})
  end

  test "namespace incompatibility is refused without network or mutation", %{tmp_dir: root} do
    credential = Path.join(root, "credential")
    File.write!(credential, String.duplicate("x", 32))
    spool = Path.join(root, "acq")
    File.mkdir_p!(spool)
    bytes = "{\"revision\":1}"
    File.write!(Path.join(spool, "identity.json"), bytes)

    config = %{
      "device" => "device",
      "encounter" => "exam",
      "acquisition" => "acq",
      "spool_root" => root,
      "server" => "wss://localhost:443",
      "credential_file" => credential
    }

    assert_raise ArgumentError, "incompatible spool namespace", fn ->
      Session.run(config, "plx_spot_check")
    end

    assert File.read!(Path.join(spool, "identity.json")) == bytes
  end

  test "teardown of partially started sources leaves no linked worker" do
    parent = self()
    {:ok, resources} = Supervisor.start_link([], strategy: :one_for_one)
    {:ok, pool} = Supervisor.start_child(resources, {Task.Supervisor, []})

    producer =
      Task.Supervisor.async(pool, fn ->
        send(parent, {:started, self()})

        receive do
          :finish -> :ok
        end
      end)

    assert_receive {:started, pid}
    assert pid == producer.pid
    assert :ok = Session.stop_resources(resources)
    refute Process.alive?(pid)
    refute Process.alive?(resources)
  end

  defp links do
    {:links, links} = Process.info(self(), :links)
    MapSet.new(links)
  end
end
