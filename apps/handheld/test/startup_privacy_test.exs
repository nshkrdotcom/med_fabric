defmodule MedExHandheld.StartupPrivacyTest do
  use ExUnit.Case, async: false
  import ExUnit.CaptureLog
  alias MedExHandheld.{Monitor, Spool}

  setup do
    root =
      Path.join(
        System.tmp_dir!(),
        "mf-refusal-" <> Base.url_encode64(:crypto.strong_rand_bytes(12), padding: false)
      )

    File.mkdir!(root)
    File.chmod!(root, 0o700)
    on_exit(fn -> File.rm_rf!(root) end)
    %{root: root}
  end

  test "spool and monitor expected refusals preserve caller, shape and private diagnostics", %{
    root: root
  } do
    sentinel = "synthetic-startup-secret-591ea884"
    File.write!(Path.join(root, "monitor.json"), JSON.encode!(%{"secret" => sentinel}))
    table = :ets.new(:refusal_table, [:set, :public])
    before_links = links()
    before_ports = MapSet.new(Port.list())

    log =
      capture_log(fn ->
        assert {:error, :invalid_monitor_ledger} =
                 Monitor.start_link({%{"spool" => root}, "boot", table})

        assert {:error, :invalid_spool_options} = Spool.start_link(root: nil, secret: sentinel)

        assert {:error, :invalid_monitor_options} =
                 Monitor.start_link({%{"secret" => sentinel}, "boot", table})

        require Logger
        Logger.warning("handheld_expected_refusal_test")
      end)

    assert Process.alive?(self())
    assert links() == before_links
    assert MapSet.new(Port.list()) == before_ports
    assert log =~ "handheld_expected_refusal_test"
    refute log =~ sentinel
    refute log =~ "crasher"
    refute log =~ "CRASH REPORT"
  end

  test "failed spool initialization closes its acquired lock and success stays linked", %{
    root: root
  } do
    namespace = Path.join(root, "namespace.json")
    File.write!(namespace, "{\"revision\":1}")
    assert {:error, _} = Spool.start_link(root: root)
    File.rm!(namespace)
    # Failed init acquired flock before checking the namespace. A fresh owner
    # must be able to acquire that lock and remain linked to its caller.
    spool = await_owner(root)
    assert MapSet.member?(links(), spool)
    assert :ok = GenServer.stop(spool)
  end

  test "spool ownership is rechecked before operations after root replacement", %{root: root} do
    assert {:ok, spool} = Spool.start_link(root: root)
    moved = root <> "-moved"
    File.rename!(root, moved)
    on_exit(fn -> File.rm_rf!(moved) end)
    File.mkdir!(root)
    File.chmod!(root, 0o700)
    ref = Process.monitor(spool)
    assert {:error, :unsafe_spool_root} = Spool.stats(spool)
    assert_receive {:DOWN, ^ref, :process, ^spool, :normal}
    assert File.ls!(root) == []
  end

  test "startup cannot accept a replacement root after locking the original directory", %{
    root: root
  } do
    fixture = root <> "-fixture"
    moved = root <> "-moved"
    File.mkdir!(fixture)
    File.chmod!(fixture, 0o700)
    real_flock = System.find_executable("flock") || flunk("flock is required")
    ready = Path.join(fixture, "ready")
    release = Path.join(fixture, "release")
    keys = ~w(PATH MF_TEST_LOCK_READY_FILE MF_TEST_LOCK_RELEASE_FILE)
    previous = Map.new(keys, &{&1, System.get_env(&1)})

    on_exit(fn ->
      Enum.each(previous, fn {key, value} ->
        if value, do: System.put_env(key, value), else: System.delete_env(key)
      end)

      File.rm_rf!(fixture)
      File.rm_rf!(moved)
    end)

    # The test executable still acquires the actual OS lock. Its handshake is
    # held so replacement occurs at the exact pre-initialization boundary.
    quoted_flock = "'" <> String.replace(real_flock, "'", "'\\''") <> "'"

    File.write!(Path.join(fixture, "flock"), """
    #!/bin/sh
    exec #{quoted_flock} "$1" "$2" "$3" /bin/sh -c '
      printf ready > "$MF_TEST_LOCK_READY_FILE"
      while [ ! -e "$MF_TEST_LOCK_RELEASE_FILE" ]; do sleep 0.01; done
      echo locked
      exec cat >/dev/null
    '
    """)

    File.chmod!(Path.join(fixture, "flock"), 0o700)

    System.put_env(%{
      "PATH" => fixture <> ":" <> (previous["PATH"] || ""),
      "MF_TEST_LOCK_READY_FILE" => ready,
      "MF_TEST_LOCK_RELEASE_FILE" => release
    })

    starter = Task.async(fn -> Spool.start_link(root: root) end)
    await_file(ready)
    File.rename!(root, moved)
    File.mkdir!(root)
    File.chmod!(root, 0o700)
    File.write!(release, "release")

    assert {:error, :unsafe_spool_root} = Task.await(starter, 6_000)
    assert File.ls!(root) == []
    assert {_, 0} = System.cmd(real_flock, ["-w", "1", Path.join(moved, "spool.lock"), "true"])
  end

  defp links do
    {:links, values} = Process.info(self(), :links)
    MapSet.new(values)
  end

  defp await_owner(root, attempts \\ 100)
  defp await_owner(_, 0), do: flunk("failed initialization did not release the spool lock")

  defp await_owner(root, attempts) do
    case Spool.start_link(root: root) do
      {:ok, spool} ->
        spool

      {:error, :spool_already_owned} ->
        Process.sleep(10)
        await_owner(root, attempts - 1)

      error ->
        flunk("unexpected spool ownership result: #{inspect(error)}")
    end
  end

  defp await_file(path, attempts \\ 100)
  defp await_file(_, 0), do: flunk("spool startup did not reach the lock boundary")

  defp await_file(path, attempts) do
    if File.exists?(path) do
      :ok
    else
      Process.sleep(10)
      await_file(path, attempts - 1)
    end
  end
end
