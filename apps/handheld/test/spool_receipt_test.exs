defmodule MedExHandheld.SpoolReceiptTest do
  use ExUnit.Case, async: true

  setup context do
    if dir = context[:tmp_dir], do: on_exit(fn -> File.rm_rf!(dir) end)
    :ok
  end

  alias MedEx.Wire.FrameV1
  alias MedExHandheld.{Paired, Spool}

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

  @tag :tmp_dir
  test "restart recovery advances past reclaimed prefix using validated receipt and recovers gap plus frame tail",
       %{tmp_dir: dir} do
    pid = start_spool(dir, :before_reclaimed_restart)
    assert :ok = Spool.put_and_advance(pid, "audio", 0, frame(0, 0), 1, 1)
    assert :ok = Spool.put_and_advance(pid, "audio", 1, frame(1, 1), 2, 2)
    assert :ok = Spool.activate(pid, "audio", 1, spec(), receipt(0, 1))
    assert :ok = Spool.ack(pid, "audio", 1, receipt(2, 2))
    assert :absent = Spool.get(pid, "audio", 0)
    assert :absent = Spool.get(pid, "audio", 1)

    # source.json was never written (stale at 0/0), while 0..1 were reclaimed.
    refute File.exists?(Path.join([dir, "audio", "source.json"]))

    # Producer writes a multi-sequence gap [2..4) samples [2..5) and then frame 4 at sample 5.
    gap =
      JSON.encode!(%{
        "id" => "gap-2",
        "irreversible" => true,
        "first" => "2",
        "end" => "5",
        "first_sequence" => "2",
        "next_sequence" => "4"
      })

    assert :ok = Spool.put_and_advance(pid, "audio", 2, gap, 4, 5)
    assert :ok = Spool.put_and_advance(pid, "audio", 4, frame(4, 5), 5, 6)
    kill_spool(pid)

    pid = start_spool(dir, :after_reclaimed_restart)

    source =
      Map.merge(spec(), %{
        encoding: :s16le,
        channels: [%{id: "one"}],
        capabilities: %{max_frame_samples: 960}
      })

    config = %{"spool" => dir}
    assert :ok = Paired.interrupt_after_restart(config, pid, "audio", source)

    assert Spool.watermark(pid, "audio") == %{
             "sequence" => 5,
             "sample" => 6,
             "done" => true,
             "interruption" => "source_reset"
           }

    assert Paired.cursor(config, "audio") == Spool.watermark(pid, "audio")
  end

  @tag :tmp_dir
  test "restart recovery fails closed on foreign receipt identity", %{tmp_dir: dir} do
    pid = start_spool(dir, :foreign_receipt_restart)
    foreign = Map.put(receipt(2, 2), "descriptor_ref", String.duplicate("f", 64))
    {:ok, parsed} = MedEx.Serialization.receipt(foreign)

    Spool.write!(
      Path.join([dir, "audio", "receipt.json"]),
      parsed |> MedEx.Serialization.to_map() |> JSON.encode!()
    )

    source =
      Map.merge(spec(), %{
        encoding: :s16le,
        channels: [%{id: "one"}],
        capabilities: %{max_frame_samples: 960}
      })

    assert_raise RuntimeError, "invalid persisted receipt", fn ->
      Paired.interrupt_after_restart(%{"spool" => dir}, pid, "audio", source)
    end
  end

  @tag :tmp_dir
  test "sequence-range ack reclaims only covered prefix under backlog", %{tmp_dir: dir} do
    pid = start_supervised!({Spool, root: dir, limit: 1_048_576})

    for q <- 0..199 do
      assert :ok = Spool.put_and_advance(pid, "audio", q, frame(q, q), q + 1, q + 1)
    end

    assert :ok = Spool.activate(pid, "audio", 1, spec(), receipt(0, 1))
    assert :ok = Spool.ack(pid, "audio", 1, receipt(0, 1))
    assert :ok = Spool.ack(pid, "audio", 1, receipt(15, 2))
    assert :absent = Spool.get(pid, "audio", 0)
    assert :absent = Spool.get(pid, "audio", 14)
    assert {:ok, _} = Spool.get(pid, "audio", 15)
    assert {:ok, _} = Spool.get(pid, "audio", 199)
  end

  @tag :tmp_dir
  test "staged put_and_advance commits atomically and cleans up temp files on rejection", %{
    tmp_dir: dir
  } do
    pid =
      start_supervised!(
        Supervisor.child_spec({Spool, root: dir, limit: 120}, id: :staged, restart: :temporary)
      )

    first = frame(0, 0)
    assert :ok = Spool.put_and_advance(pid, dir, "audio", 0, first, 1, 1)
    assert {:ok, ^first} = Spool.get(pid, "audio", 0)
    assert %{"sequence" => 1, "sample" => 1, "done" => false} = Spool.watermark(pid, "audio")

    # Identical retry is idempotent and leaves no temp file.
    assert :ok = Spool.put_and_advance(pid, dir, "audio", 0, first, 1, 1)

    # Conflicting retry is refused and leaves no temp file.
    assert {:error, :spool_conflict} =
             Spool.put_and_advance(pid, dir, "audio", 0, frame(0, 99), 1, 1)

    # Budget overflow is refused and leaves no temp file.
    assert {:error, :spool_full} =
             Spool.put_and_advance(pid, dir, "audio", 1, :binary.copy(<<0>>, 200), 2, 2)

    assert Path.wildcard(Path.join([dir, "audio", "*.tmp.*"])) == []
  end

  @tag :tmp_dir
  test "batch staging commits multiple frames atomically and startup sweeps crash-leftover temps",
       %{tmp_dir: dir} do
    audio_dir = Path.join(dir, "audio")
    File.mkdir_p!(audio_dir)
    orphan = Path.join(audio_dir, "99.rec.tmp.crashed")
    File.write!(orphan, "partial-uncommitted-bytes")

    pid = start_spool(dir, :batch_restart)
    refute File.exists?(orphan)
    assert %{bytes: 0} = Spool.stats(pid)

    items = for q <- 0..4, do: {q, frame(q, q), q + 1, q + 1}
    assert :ok = Spool.put_batch_and_advance(pid, dir, "audio", items)
    assert %{"sequence" => 5, "sample" => 5, "done" => false} = Spool.watermark(pid, "audio")
    assert Path.wildcard(Path.join([dir, "audio", "*.tmp.*"])) == []

    for q <- 0..4 do
      assert {:ok, bytes} = Spool.get(pid, "audio", q)
      assert bytes == frame(q, q)
    end
  end

  @tag :tmp_dir
  test "a queued batch keeps its staging files after the caller times out", %{tmp_dir: dir} do
    pid = start_spool(dir, :queued_batch)
    items = for q <- 0..1, do: {q, frame(q, q), q + 1, q + 1}
    temps = Path.join([dir, "audio", "*.tmp.*"])

    :ok = :sys.suspend(pid)

    try do
      assert {:timeout, {GenServer, :call, _}} =
               catch_exit(Spool.put_batch_and_advance(pid, dir, "audio", items, 0))

      assert length(Path.wildcard(temps)) == 2
    after
      :ok = :sys.resume(pid)
    end

    assert %{"sequence" => 2, "sample" => 2, "done" => false} = Spool.watermark(pid, "audio")
    assert %{bytes: bytes} = Spool.stats(pid)
    assert bytes == 2 * (byte_size(frame(0, 0)) + 32)
    assert {:ok, raw} = Spool.get(pid, "audio", 1)
    assert raw == frame(1, 1)
    assert :absent = Spool.get(pid, "audio", 2)
    assert Path.wildcard(temps) == []
  end

  @tag :tmp_dir
  test "partial batch spool_full preserves committed prefix and cleans up remaining temps", %{
    tmp_dir: dir
  } do
    # Each encoded 1-sample frame is 50 bytes + 32-byte sha256 = 82 bytes; 2 frames = 164 <= 200 < 246.
    pid =
      start_supervised!(
        Supervisor.child_spec({Spool, root: dir, limit: 200},
          id: :partial_full,
          restart: :temporary
        )
      )

    items = for q <- 0..4, do: {q, frame(q, q), q + 1, q + 1}
    assert {:error, :spool_full} = Spool.put_batch_and_advance(pid, dir, "audio", items)

    assert %{"sequence" => 2, "sample" => 2, "done" => false} = Spool.watermark(pid, "audio")
    assert {:ok, b0} = Spool.get(pid, "audio", 0)
    assert {:ok, b1} = Spool.get(pid, "audio", 1)
    assert {b0, b1} == {frame(0, 0), frame(1, 1)}
    assert :absent = Spool.get(pid, "audio", 2)
    assert Path.wildcard(Path.join([dir, "audio", "*.tmp.*"])) == []
  end

  @tag :tmp_dir
  test "restart after partial batch rename recovers contiguous prefix and marks interruption", %{
    tmp_dir: dir
  } do
    pid = start_spool(dir, :before_crash)
    watermark(dir, 0)

    # Commit the first two frames of a 5-frame batch, then leave 2..4 as staged temp files
    # as if Handheld were killed mid-batch before rename/sync_dir!.
    assert :ok =
             Spool.put_batch_and_advance(
               pid,
               dir,
               "audio",
               for(q <- 0..1, do: {q, frame(q, q), q + 1, q + 1})
             )

    audio_dir = Path.join(dir, "audio")

    for q <- 2..4 do
      bytes = frame(q, q)

      File.write!(
        Path.join(audio_dir, "#{q}.rec.tmp.killed"),
        :crypto.hash(:sha256, bytes) <> bytes
      )
    end

    kill_spool(pid)

    restarted = start_spool(dir, :after_crash)
    assert Path.wildcard(Path.join(audio_dir, "*.tmp.*")) == []
    assert %{bytes: bytes} = Spool.stats(restarted)
    assert bytes == 2 * (byte_size(frame(0, 0)) + 32)

    audio_spec =
      Map.merge(spec(), %{
        encoding: :s16le,
        channels: [%{id: "1"}],
        capabilities: %{max_frame_samples: 960}
      })

    assert :ok =
             MedExHandheld.Paired.interrupt_after_restart(
               %{"spool" => dir},
               restarted,
               "audio",
               audio_spec
             )

    assert %{
             "sequence" => 2,
             "sample" => 2,
             "done" => true,
             "interruption" => "source_reset"
           } = Spool.watermark(restarted, "audio")

    assert :absent = Spool.get(restarted, "audio", 2)
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
