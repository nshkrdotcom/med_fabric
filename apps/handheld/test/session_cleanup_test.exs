defmodule MedExHandheld.SessionCleanupTest do
  use ExUnit.Case, async: true
  alias MedExHandheld.{Session, Spool}

  @tag :tmp_dir
  test "failed initial admission releases all local owners while the caller survives", %{tmp_dir: dir} do
    config = %{"device" => "fixture", "encounter" => "exam", "acquisition" => "fresh",
      "spool_root" => dir, "server" => "wss://localhost:443", "ca_file" => Path.join(dir, "unused-ca.pem"),
      "credential_file" => Path.join(dir, "missing-device-credential")}
    links = caller_links()
    assert_raise File.Error, fn -> Session.run(config, "plx_spot_check") end
    assert caller_links() == links
    pid = start_supervised!({Spool, [root: Path.join(dir, "fresh"), limit: 1000]})
    assert Spool.stats(pid).bytes == 0
  end

  @tag :tmp_dir
  test "local PLX ingestion failure releases the recovered spool and preserves its outcome", %{tmp_dir: dir} do
    root = Path.join(dir, "resuming")
    File.mkdir_p!(root)
    identity = %{"device" => "fixture", "encounter" => "exam", "acquisition" => "resuming",
      "boot" => "boot", "profile" => "plx_spot_check", "origin_us" => 0}
    Spool.write!(Path.join(root, "identity.json"), JSON.encode!(identity))
    Spool.write!(Path.join(root, "source_started.json"), JSON.encode!(Map.take(identity, ["boot","acquisition"])))
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
    producer = Task.Supervisor.async(pool, fn ->
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

  defp caller_links do
    {:links, links} = Process.info(self(), :links)
    MapSet.new(links)
  end
end
