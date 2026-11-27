defmodule MedExHandheld.MonitorTest do
  use ExUnit.Case, async: true
  alias MedExHandheld.Monitor
  alias MedEx.Wire.FrameV1
  @moduletag :tmp_dir

  setup %{tmp_dir: dir} do
    table = :ets.new(:monitor_test, [:set, :public])
    :ets.insert(table, {:authority, test_binding(), System.monotonic_time(:millisecond) + 60_000})
    {:ok, root: dir, table: table}
  end

  test "corrupt valid JSON shapes fail as optional startup errors and preserve exact bytes", c do
    for value <- [
          nil,
          [],
          1,
          true,
          "value",
          %{},
          %{"boot" => "boot", "epoch" => "00", "gain" => "unity", "cache" => %{}},
          %{"boot" => "other", "epoch" => "0", "gain" => "unity", "cache" => %{}}
        ] do
      bytes = JSON.encode!(value)
      File.write!(Path.join(c.root, "monitor.json"), bytes)

      assert {:error, :invalid_monitor_ledger} =
               Monitor.start_link({%{"spool" => c.root}, "boot", c.table})

      assert File.read!(Path.join(c.root, "monitor.json")) == bytes
    end
  end

  test "a suspended monitor admits one control and never applies it after deadline", c do
    monitor = start_supervised!({Monitor, {%{"spool" => c.root}, "boot", c.table}})
    :ok = :sys.suspend(monitor)
    authority = authority(20)
    assert {:ok, ticket} = Monitor.control(monitor, c.table, :apply, command(), authority)

    for _ <- 1..100,
        do:
          assert(
            {:error, :busy} = Monitor.control(monitor, c.table, :apply, command(), authority)
          )

    Process.sleep(30)
    :ok = Monitor.offer(monitor, c.table, [frame(0, 0)])
    :ok = :sys.resume(monitor)

    assert_receive {:med_ex_monitor, ^ticket, %{"status" => "rejected", "reason" => "expired"}},
                   1_000

    ledger = MedExHandheld.Spool.read_json(Path.join(c.root, "monitor.json"), nil)
    assert ledger["gain"] == "unity" and ledger["epoch"] == "0"
    assert {:message_queue_len, size} = Process.info(monitor, :message_queue_len)
    assert size < 5
  end

  test "actual asynchronous offer applies one persisted result and exact readback survives restart",
       c do
    monitor = start_supervised!({Monitor, {%{"spool" => c.root}, "boot", c.table}})
    assert {:ok, ticket} = Monitor.control(monitor, c.table, :apply, command(), authority(5_000))
    assert :ok = Monitor.offer(monitor, c.table, [frame(3, 2_880)])
    assert_receive {:med_ex_monitor, ^ticket, %{"status" => "applied"} = result}, 1_000
    assert result["application"]["first_sample"] == "2880"
    assert result["epoch"] == "1"
    assert [{:latest, _, _, [raw]}] = :ets.lookup(c.table, :latest)
    assert {:ok, %{payload: <<2, 0>>, stream_number: 3}} = FrameV1.decode(raw)
    stop_supervised!(Monitor)
    monitor = start_supervised!({Monitor, {%{"spool" => c.root}, "boot", c.table}})

    assert {:ok, query} =
             Monitor.control(monitor, c.table, :readback, command(), authority(5_000))

    assert_receive {:med_ex_monitor, ^query, ^result}, 1_000

    assert {:ok, other} =
             Monitor.control(
               monitor,
               c.table,
               :readback,
               Map.put(command(), "id", "unknown"),
               authority(5_000)
             )

    assert_receive {:med_ex_monitor, ^other, %{"status" => "outcome_unknown"}}, 1_000
  end

  test "dead monitor deleted ETS and trace errors do not fail raw producer offers", c do
    config = %{"spool" => c.root, "trace_monitor" => true, "trace_limit_bytes" => 1}
    monitor = start_supervised!({Monitor, {config, "boot", c.table}})
    for _ <- 1..1000, do: assert(:ok = Monitor.offer(monitor, c.table, [frame(0, 0)]))
    assert :sys.get_state(monitor).pending == nil
    assert Process.alive?(monitor)
    :ets.delete(c.table)
    assert :ok = Monitor.offer(monitor, c.table, [frame(0, 0)])
    stop_supervised!(Monitor)
    assert :ok = Monitor.offer(monitor, c.table, [frame(0, 0)])
  end

  test "replacement connection at the same generation cannot revive a pending command", c do
    monitor = start_supervised!({Monitor, {%{"spool" => c.root}, "boot", c.table}})
    assert {:ok, ticket} = Monitor.control(monitor, c.table, :apply, command(), authority(5_000))
    :sys.get_state(monitor)

    :ets.insert(
      c.table,
      {:authority, Map.put(test_binding(), "connection", "replacement"),
       System.monotonic_time(:millisecond) + 5_000}
    )

    assert :ok = Monitor.offer(monitor, c.table, [frame(0, 0)])

    assert_receive {:med_ex_monitor, ^ticket, %{"status" => "rejected", "reason" => "expired"}},
                   1_000

    assert :sys.get_state(monitor).ledger["gain"] == "unity"
    assert :sys.get_state(monitor).ledger["epoch"] == "0"
  end

  test "an oversized trace budget cannot turn an existing symlink into a writable trace", c do
    target = Path.join(c.root, "preserve.txt")
    File.write!(target, "preserve\n")
    File.ln_s!(target, Path.join(c.root, "monitor-truth.jsonl"))
    config = %{"spool" => c.root, "trace_monitor" => true, "trace_limit_bytes" => 10_000_000}
    monitor = start_supervised!({Monitor, {config, "boot", c.table}})
    assert {:ok, ticket} = Monitor.control(monitor, c.table, :apply, command(), authority(5_000))
    assert :ok = Monitor.offer(monitor, c.table, [frame(0, 0)])
    assert_receive {:med_ex_monitor, ^ticket, %{"status" => "applied"}}, 1_000
    assert :sys.get_state(monitor).config["trace_monitor"] == false
    assert File.read!(target) == "preserve\n"
  end

  test "duplicate ledger keys and invalid nested history preserve the original file", c do
    file = Path.join(c.root, "monitor.json")

    for bytes <- [
          ~s({"boot":"boot","boot":"other","epoch":"0","gain":"unity","cache":{}}),
          JSON.encode!(%{
            "boot" => "boot",
            "epoch" => "0",
            "gain" => "unity",
            "cache" => %{"command" => %{"command" => command(), "result" => []}}
          })
        ] do
      File.write!(file, bytes)
      assert {:error, :invalid_monitor_ledger} = Monitor.load_ledger(file, "boot")
      assert File.read!(file) == bytes
    end
  end

  defp command,
    do: %{
      "id" => "command",
      "fingerprint" => String.duplicate("a", 64),
      "boot" => "boot",
      "target" => "handheld_monitor",
      "generation" => "1",
      "expected_epoch" => "0",
      "gain" => "half",
      "op" => "set_monitor_gain"
    }

  defp authority(ms),
    do: %{
      nonce: "nonce",
      generation: "1",
      boot: "boot",
      binding: test_binding(),
      deadline: System.monotonic_time(:millisecond) + ms
    }

  defp test_binding,
    do: %{
      "acquisition" => "acq",
      "profile" => "paired_exam",
      "generation" => "1",
      "connection" => "control"
    }

  defp frame(q, sample) do
    {:ok, raw} =
      FrameV1.encode(%FrameV1{
        stream_number: 1,
        source_epoch: 0,
        config_epoch: 0,
        sequence: q,
        first_sample: sample,
        sample_count: 1,
        payload: <<4, 0>>
      })

    {q, raw, q + 1, sample + 1}
  end
end
