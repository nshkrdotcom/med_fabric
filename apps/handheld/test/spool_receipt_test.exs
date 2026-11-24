defmodule MedExHandheld.SpoolReceiptTest do
  use ExUnit.Case, async: true
  alias MedExHandheld.{Paired, Spool}
  alias MedEx.Wire.FrameV1

  @tag :tmp_dir
  test "initial out-of-range receipt cannot retire even locally present unsaved source data", %{
    tmp_dir: dir
  } do
    pid = start_supervised!({Spool, root: dir, limit: 4096})
    raw = frame(0, 0)
    assert :ok = Spool.put(pid, "audio", 0, raw)
    candidate = receipt(1, 2)
    assert :ok = Spool.activate(pid, "audio", 1, spec(), candidate)
    assert {:error, :uncovered_receipt} = Spool.ack(pid, "audio", 1, candidate)
    assert {:ok, ^raw} = Spool.get(pid, "audio", 0)
    refute File.exists?(Path.join([dir, "audio", "receipt.json"]))
    watermark(dir, 1)
    assert :ok = Spool.ack(pid, "audio", 1, candidate)
    assert :absent = Spool.get(pid, "audio", 0)
  end

  @tag :tmp_dir
  test "foreign identity, journal rollback and conflicting same-generation digest preserve remaining bytes",
       %{tmp_dir: dir} do
    pid = start_supervised!({Spool, root: dir, limit: 4096})
    raw0 = frame(0, 0)
    raw1 = frame(1, 1)
    assert :ok = Spool.put(pid, "audio", 0, raw0)
    assert :ok = Spool.put(pid, "audio", 1, raw1)
    watermark(dir, 2)
    initial = receipt(0, 1)
    assert :ok = Spool.activate(pid, "audio", 3, spec(), initial)
    assert :ok = Spool.ack(pid, "audio", 3, initial)
    receipt_path = Path.join([dir, "audio", "receipt.json"])
    persisted = File.read!(receipt_path)

    for changed <- [
          Map.put(receipt(1, 2), "stream_id", "ecg"),
          Map.put(receipt(1, 2), "descriptor_ref", String.duplicate("f", 64)),
          Map.put(receipt(1, 2), "source_epoch", "1"),
          Map.put(receipt(1, 2), "journal_id", "different-journal"),
          Map.put(receipt(1, 2), "fence", "old-fence")
        ] do
      assert {:error, :stale_fence} = Spool.ack(pid, "audio", 3, changed)
      assert {:ok, ^raw0} = Spool.get(pid, "audio", 0)
      assert File.read!(receipt_path) == persisted
    end

    assert :ok = Spool.ack(pid, "audio", 3, receipt(1, 2))
    persisted = File.read!(receipt_path)
    assert {:error, :receipt_rollback} = Spool.ack(pid, "audio", 3, receipt(2, 1))
    assert {:error, :receipt_conflict} = Spool.ack(pid, "audio", 3, receipt(2, 2))

    assert {:error, :invalid_receipt} =
             Spool.ack(pid, "audio", 3, Map.put(receipt(2, 3), "type", "accepted"))

    assert {:ok, ^raw1} = Spool.get(pid, "audio", 1)
    assert File.read!(receipt_path) == persisted
    assert :ok = Spool.ack(pid, "audio", 3, receipt(2, 3))
    assert :absent = Spool.get(pid, "audio", 1)
    assert :ok = Spool.ack(pid, "audio", 3, receipt(2, 3))
  end

  @tag :tmp_dir
  test "persisted activation rejects same-generation rebinding and predecessor generations", %{
    tmp_dir: dir
  } do
    pid = start_supervised!({Spool, root: dir, limit: 4096})
    first = receipt(0, 1)
    assert :ok = Spool.activate(pid, "audio", 5, spec(), first)
    changed = %{first | "fence" => "successor", "journal_id" => "successor-journal"}
    assert {:error, :stale_generation} = Spool.activate(pid, "audio", 4, spec(), first)
    assert {:error, :stale_generation} = Spool.activate(pid, "audio", 5, spec(), changed)
    assert :ok = Spool.activate(pid, "audio", 6, spec(), changed)
    assert {:error, :stale_fence} = Spool.ack(pid, "audio", 5, first)
    assert :ok = Spool.ack(pid, "audio", 6, changed)
    persisted = Spool.read_json(Path.join([dir, "audio", "activation.json"]), nil)
    assert persisted["generation"] == 6 and persisted["fence"] == "successor"
  end

  @tag :tmp_dir
  test "restarted owners recover activation and a synced receipt left before reclamation", %{
    tmp_dir: dir
  } do
    initial = receipt(0, 1)
    durable = receipt(1, 2)
    bytes = frame(0, 0)
    pid = start_spool(dir, :before_activation_cut)
    assert :ok = Spool.put(pid, "audio", 0, bytes)
    watermark(dir, 1)
    assert :ok = Spool.activate(pid, "audio", 3, spec(), initial)
    assert {_, 1} = System.cmd("flock", ["-n", Path.join(dir, "spool.lock"), "true"])
    kill_spool(pid)

    pid = start_spool(dir, :before_receipt_cut)
    assert {:error, :stale_generation} = Spool.activate(pid, "audio", 2, spec(), initial)
    assert {:error, :stale_fence} = Spool.ack(pid, "audio", 3, durable)
    assert :ok = Spool.activate(pid, "audio", 3, spec(), initial)

    # Leave exactly the files present if the process dies between receipt sync
    # and record deletion. Recovery must still check the persisted activation.
    {:ok, parsed} = MedEx.Serialization.receipt(durable)
    expected = parsed |> MedEx.Serialization.to_map() |> JSON.encode!()
    receipt_path = Path.join([dir, "audio", "receipt.json"])
    Spool.write!(receipt_path, expected)
    kill_spool(pid)

    pid = start_spool(dir, :after_receipt_cut)
    assert {:ok, ^bytes} = Spool.get(pid, "audio", 0)
    assert {:error, :stale_fence} = Spool.ack(pid, "audio", 3, durable)
    assert :ok = Spool.activate(pid, "audio", 3, spec(), initial)
    assert {:error, :receipt_rollback} = Spool.ack(pid, "audio", 3, initial)
    assert File.read!(receipt_path) == expected
    assert {:ok, ^bytes} = Spool.get(pid, "audio", 0)
    assert :ok = Spool.ack(pid, "audio", 3, durable)
    assert :absent = Spool.get(pid, "audio", 0)
    assert Spool.stats(pid).bytes == 0
  end

  @tag :tmp_dir
  test "a gap can retire only its exact declared sequence and sample interval", %{tmp_dir: dir} do
    pid = start_supervised!({Spool, root: dir, limit: 4096})

    gap =
      JSON.encode!(%{
        "id" => "missing",
        "irreversible" => true,
        "first" => "0",
        "end" => "3",
        "first_sequence" => "0",
        "next_sequence" => "2"
      })

    assert :ok = Spool.put(pid, "audio", 0, gap)

    Spool.write!(
      Path.join([dir, "audio", "source.json"]),
      JSON.encode!(%{"sequence" => 2, "sample" => 3, "done" => true})
    )

    assert :ok = Spool.activate(pid, "audio", 1, spec(), receipt(0, 1))
    assert {:error, :uncovered_receipt} = Spool.ack(pid, "audio", 1, receipt(2, 2))
    assert {:ok, ^gap} = Spool.get(pid, "audio", 0)
    exact = %{receipt(2, 2) | "accepted_sample" => "3", "durable_sample" => "3"}
    assert :ok = Spool.ack(pid, "audio", 1, exact)
    assert :absent = Spool.get(pid, "audio", 0)
  end

  @tag :tmp_dir
  test "unfinished device restart retains synchronized tail and interrupts instead of synthesizing continuity",
       %{tmp_dir: dir} do
    pid = start_spool(dir, :before_source_cursor_cut)
    raw = frame(0, 0)
    assert :ok = Spool.put(pid, "audio", 0, raw)
    refute File.exists?(Path.join([dir, "audio", "source.json"]))
    kill_spool(pid)
    pid = start_spool(dir, :after_source_cursor_cut)

    source =
      Map.merge(spec(), %{
        encoding: :s16le,
        channels: [%{id: "one"}],
        capabilities: %{max_frame_samples: 960}
      })

    config = %{"spool" => dir}
    assert :ok = Paired.interrupt_after_restart(config, pid, "audio", source)

    assert Paired.cursor(config, "audio") == %{
             "sequence" => 1,
             "sample" => 1,
             "done" => true,
             "interruption" => "source_reset"
           }

    assert {:ok, ^raw} = Spool.get(pid, "audio", 0)
    assert :absent = Spool.get(pid, "audio", 1)
    assert :ok = Paired.interrupt_after_restart(config, pid, "audio", source)
    assert Paired.cursor(config, "audio")["sample"] == 1
  end

  defp start_spool(dir, id) do
    start_supervised!(
      Supervisor.child_spec({Spool, root: dir, limit: 4096}, id: id, restart: :temporary)
    )
  end

  defp kill_spool(pid) do
    monitor = Process.monitor(pid)
    Process.exit(pid, :kill)
    assert_receive {:DOWN, ^monitor, :process, ^pid, :killed}
  end

  defp spec, do: %{stream_id: "audio", source_epoch: 0, descriptor_ref: String.duplicate("a", 64)}

  defp frame(sequence, first) do
    {:ok, bytes} =
      FrameV1.encode(%FrameV1{
        stream_number: 1,
        source_epoch: 0,
        config_epoch: 0,
        sequence: sequence,
        first_sample: first,
        sample_count: 1,
        payload: <<1, 2>>
      })

    bytes
  end

  defp watermark(dir, next) do
    Spool.write!(
      Path.join([dir, "audio", "source.json"]),
      JSON.encode!(%{"sequence" => next, "sample" => next, "done" => false})
    )
  end

  defp receipt(next, generation) do
    %{
      "fence" => "current",
      "stream_id" => "audio",
      "source_epoch" => "0",
      "descriptor_ref" => String.duplicate("a", 64),
      "journal_id" => "journal",
      "journal_generation" => to_string(generation),
      "journal_digest" =>
        :crypto.hash(:sha256, to_string(generation)) |> Base.encode16(case: :lower),
      "accepted_sequence" => to_string(next),
      "accepted_sample" => to_string(next),
      "durable_sequence" => to_string(next),
      "durable_sample" => to_string(next)
    }
  end
end
