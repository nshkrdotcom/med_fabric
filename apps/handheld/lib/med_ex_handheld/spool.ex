defmodule MedExHandheld.Spool do
  @moduledoc "Single device budget. Sync exact bytes before acknowledging local ingestion, persist receipts before reclaiming."
  use GenServer
  alias MedEx.Wire.FrameV1

  def start_link(opts), do: GenServer.start_link(__MODULE__, opts)

  def init(opts) do
    root = opts[:root]
    File.mkdir_p!(root)
    owner = lock!(root)
    # Remove any uncommitted temp files left behind by a prior hard crash.
    for tmp <- Path.wildcard(Path.join(root, "*/*.tmp.*")), do: File.rm(tmp)
    # Files carry their own checksum, including retained control/event identity.
    names = Path.wildcard(Path.join(root, "*/*.rec"))
    size = Enum.reduce(names, 0, fn f, n -> n + File.stat!(f).size end)
    for f <- names, do: read_record!(f)

    {:ok,
     %{
       root: root,
       bytes: size,
       maximum: size,
       limit: opts[:limit],
       active: %{},
       watermarks: %{},
       needs_sweep: %{"audio" => true, "ecg" => true},
       owner: owner
     }}
  end

  defp lock!(root) do
    bin =
      System.find_executable("flock") || raise "POSIX flock is required to own this device spool"

    opts =
      Enum.map(
        [
          "-n",
          "--no-fork",
          Path.join(root, "spool.lock"),
          "sh",
          "-c",
          "echo locked && exec cat >/dev/null"
        ],
        &String.to_charlist/1
      )

    acquire_lock!(bin, opts, 50)
  end

  defp acquire_lock!(bin, opts, retries) do
    port =
      Port.open({:spawn_executable, String.to_charlist(bin)}, [
        :binary,
        :exit_status,
        :use_stdio,
        {:args, opts}
      ])

    receive do
      {^port, {:data, "locked\n"}} ->
        port

      {^port, {:exit_status, _}} when retries > 0 ->
        # Closing the prior owner's port lets its OS child exit asynchronously.
        # Every retry still needs the real OS lock; this never removes/steals it.
        Process.sleep(20)
        acquire_lock!(bin, opts, retries - 1)

      {^port, {:exit_status, _}} ->
        raise "spool already owned"
    after
      5000 ->
        Port.close(port)
        raise "spool lock timeout"
    end
  end

  def handle_info({port, {:exit_status, _}}, %{owner: port} = s), do: {:stop, :spool_lock_lost, s}

  def put(p, stream, seq, bytes), do: GenServer.call(p, {:put, stream, seq, bytes}, 30_000)

  def put_and_advance(p, stream, seq, bytes, next_seq, next_sample),
    do:
      GenServer.call(
        p,
        {:put_and_advance, stream, seq, bytes, next_seq, next_sample},
        30_000
      )

  def put_and_advance(p, root, stream, seq, bytes, next_seq, next_sample)
      when is_binary(root) and stream in ["audio", "ecg", "events"] and is_integer(seq) and
             seq >= 0 do
    put_batch_and_advance(p, root, stream, [{seq, bytes, next_seq, next_sample}])
  end

  def put_batch_and_advance(p, root, stream, items, timeout \\ 30_000)

  def put_batch_and_advance(_p, _root, _stream, [], _timeout), do: :ok

  def put_batch_and_advance(p, root, stream, items, timeout)
      when is_binary(root) and stream in ["audio", "ecg", "events"] and is_list(items) do
    dir = Path.join(root, stream)
    File.mkdir_p!(dir)

    staged =
      case items do
        [{seq, bytes, next_seq, next_sample}] ->
          [stage_batch_item!(dir, seq, bytes, next_seq, next_sample)]

        many ->
          many
          |> Enum.map(&stage_batch_item_async(dir, &1))
          |> Task.await_many(30_000)
      end

    # A timed-out call can still commit. Only the spool may unlink the staged
    # files after transfer. Startup reclaims them if the spool exits first.
    GenServer.call(p, {:commit_batch_and_advance, stream, staged}, timeout)
  end

  defp stage_batch_item_async(dir, {seq, bytes, next_seq, next_sample}) do
    Task.async(fn -> stage_batch_item!(dir, seq, bytes, next_seq, next_sample) end)
  end

  defp stage_batch_item!(dir, seq, bytes, next_seq, next_sample) do
    path = Path.join(dir, to_string(seq) <> ".rec")
    framed = :crypto.hash(:sha256, bytes) <> bytes
    tmp = stage_tmp!(dir, path, framed)

    %{
      seq: seq,
      bytes: bytes,
      tmp: tmp,
      framed_size: byte_size(framed),
      next_seq: next_seq,
      next_sample: next_sample
    }
  end

  def watermark(p, stream), do: GenServer.call(p, {:watermark, stream})

  def persist_watermark(p, stream), do: GenServer.call(p, {:persist_watermark, stream}, 30_000)

  def finish_source(p, stream, seq, sample, interruption),
    do: GenServer.call(p, {:finish_source, stream, seq, sample, interruption}, 30_000)

  def get(p, stream, seq), do: GenServer.call(p, {:get, stream, seq})

  def activate(p, stream, gen, spec, receipt),
    do: GenServer.call(p, {:activate, stream, gen, spec, receipt})

  def ack(p, stream, gen, receipt), do: GenServer.call(p, {:ack, stream, gen, receipt}, 30_000)
  def stats(p), do: GenServer.call(p, :stats)

  def handle_call({:put, name, seq, bytes}, _, s) do
    case put_record(s, name, seq, bytes) do
      {:ok, next} -> {:reply, :ok, next}
      {:error, reason} -> {:reply, {:error, reason}, s}
    end
  end

  def handle_call({:put_and_advance, name, seq, bytes, next_seq, next_sample}, _, s) do
    case put_record(s, name, seq, bytes) do
      {:ok, next} ->
        mark = %{"sequence" => next_seq, "sample" => next_sample, "done" => false}
        {:reply, :ok, %{next | watermarks: Map.put(next.watermarks, name, mark)}}

      {:error, reason} ->
        {:reply, {:error, reason}, s}
    end
  end

  def handle_call({:commit_batch_and_advance, name, staged}, _, s) do
    case commit_staged_batch(s, name, staged) do
      {:ok, next} -> {:reply, :ok, next}
      {:error, reason, next} -> {:reply, {:error, reason}, next}
    end
  after
    dir = Path.join(s.root, name)
    for %{tmp: tmp} <- staged, Path.dirname(tmp) == dir, do: File.rm(tmp)
  end

  def handle_call({:watermark, name}, _, s), do: {:reply, current_watermark(s, name), s}

  def handle_call({:persist_watermark, name}, _, s) do
    mark = current_watermark(s, name)
    write!(Path.join([s.root, name, "source.json"]), JSON.encode!(mark))
    {:reply, :ok, s}
  end

  def handle_call({:finish_source, name, seq, sample, interruption}, _, s) do
    mark = %{
      "sequence" => seq,
      "sample" => sample,
      "done" => true,
      "interruption" => interruption
    }

    write!(Path.join([s.root, name, "source.json"]), JSON.encode!(mark))
    {:reply, :ok, %{s | watermarks: Map.put(s.watermarks, name, mark)}}
  end

  def handle_call({:get, name, seq}, _, s) do
    file = record(s, name, seq)
    {:reply, if(File.exists?(file), do: {:ok, read_record!(file)}, else: :absent), s}
  end

  def handle_call(
        {:activate, name, gen,
         %{stream_id: name, descriptor_ref: descriptor, source_epoch: epoch}, wire},
        _,
        s
      )
      when name in ["audio", "ecg"] and is_integer(gen) and gen > 0 do
    with {:ok, r} <- parse_receipt(wire),
         true <-
           r.stream_id == name and r.descriptor_ref == descriptor and r.source_epoch == epoch do
      binding = %{
        "generation" => gen,
        "fence" => r.fence,
        "journal_id" => r.journal_id,
        "descriptor_ref" => descriptor,
        "source_epoch" => epoch
      }

      path = Path.join([s.root, name, "activation.json"])
      previous = read_json(path, nil)

      if previous &&
           (previous["generation"] > gen or
              (previous["generation"] == gen and previous != binding)) do
        {:reply, {:error, :stale_generation}, s}
      else
        # Persist transport ownership before accepting a receipt that can reclaim bytes.
        write!(path, JSON.encode!(binding))
        {:reply, :ok, %{s | active: Map.put(s.active, name, binding)}}
      end
    else
      _ -> {:reply, {:error, :receipt_identity}, s}
    end
  end

  def handle_call({:activate, _, _, _, _}, _, s), do: {:reply, {:error, :invalid_activation}, s}

  def handle_call({:ack, name, gen, wire}, _, s) when name in ["audio", "ecg"] do
    with %{"generation" => ^gen} = binding <- s.active[name],
         {:ok, r} <- parse_receipt(wire),
         true <- identity?(r, name, binding),
         receipt = Path.join([s.root, name, "receipt.json"]),
         {:ok, last} <- previous_receipt(receipt),
         :ok <- verify_progress(last, r),
         {:ok, visited} <- verify_coverage(s, name, last, r) do
      write!(receipt, JSON.encode!(MedEx.Serialization.to_map(r)))

      {bytes, needs_sweep} =
        if Map.get(s.needs_sweep, name, true) do
          # One-time sweep after start/restart to reap any covered files left by a crash after receipt sync.
          {reap_covered_records(s, name, r.durable_sequence), Map.put(s.needs_sweep, name, false)}
        else
          {reap_paths(s.bytes, visited), s.needs_sweep}
        end

      if bytes != s.bytes, do: sync_dir!(Path.dirname(receipt))
      {:reply, :ok, %{s | bytes: bytes, needs_sweep: needs_sweep}}
    else
      {:error, _} = error -> {:reply, error, s}
      _ -> {:reply, {:error, :stale_fence}, s}
    end
  end

  def handle_call({:ack, _, _, _}, _, s), do: {:reply, {:error, :invalid_receipt}, s}

  def handle_call({:event_ack, seq, id, digest}, _, s) do
    path = record(s, "events", seq)
    event = read_record!(path) |> JSON.decode!()

    if event["event_id"] == id and MedEx.Serialization.digest(event) == digest do
      write!(path <> ".receipt", JSON.encode!([id, digest]))
      {:reply, :ok, s}
    else
      {:reply, {:error, :event_conflict}, s}
    end
  end

  def handle_call({:event_seal, inventory}, _, s) do
    remaining =
      Enum.reduce(Enum.with_index(inventory), s.bytes, fn {entry, seq}, total ->
        path = record(s, "events", seq)

        if File.exists?(path) and read_json(path <> ".receipt", nil) == entry do
          size = File.stat!(path).size
          File.rm!(path)
          total - size
        else
          total
        end
      end)

    sync_dir!(Path.join(s.root, "events"))
    {:reply, :ok, %{s | bytes: remaining}}
  end

  def handle_call(:stats, _, s), do: {:reply, Map.take(s, [:bytes, :maximum, :limit]), s}

  defp put_record(s, name, seq, bytes) do
    f = record(s, name, seq)
    total = s.bytes + byte_size(bytes) + 32

    cond do
      File.exists?(f) ->
        if read_record!(f) == bytes, do: {:ok, s}, else: {:error, :spool_conflict}

      total > s.limit ->
        {:error, :spool_full}

      true ->
        write!(f, :crypto.hash(:sha256, bytes) <> bytes)
        {:ok, %{s | bytes: total, maximum: max(s.maximum, total)}}
    end
  end

  defp reconcile_batch_item(file, item, state, name, renamed?) do
    if read_record!(file) == item.bytes do
      mark = %{"sequence" => item.next_seq, "sample" => item.next_sample, "done" => false}
      {:cont, {:ok, %{state | watermarks: Map.put(state.watermarks, name, mark)}, renamed?}}
    else
      {:halt, {{:error, :spool_conflict}, state, renamed?}}
    end
  end

  defp commit_staged_batch(s, name, staged) do
    dir = Path.join(s.root, name)

    {status, state, synced?} =
      Enum.reduce_while(staged, {:ok, s, false}, fn item, {:ok, acc, renamed?} ->
        f = record(acc, name, item.seq)
        total = acc.bytes + item.framed_size

        cond do
          Path.dirname(item.tmp) != dir ->
            {:halt, {{:error, :invalid_stage_path}, acc, renamed?}}

          File.exists?(f) ->
            reconcile_batch_item(f, item, acc, name, renamed?)

          total > acc.limit ->
            {:halt, {{:error, :spool_full}, acc, renamed?}}

          true ->
            File.rename!(item.tmp, f)
            mark = %{"sequence" => item.next_seq, "sample" => item.next_sample, "done" => false}

            next = %{
              acc
              | bytes: total,
                maximum: max(acc.maximum, total),
                watermarks: Map.put(acc.watermarks, name, mark)
            }

            {:cont, {:ok, next, true}}
        end
      end)

    if synced?, do: sync_dir!(dir)

    case status do
      :ok -> {:ok, state}
      {:error, reason} -> {:error, reason, state}
    end
  end

  defp current_watermark(s, name) do
    case Map.fetch(s.watermarks, name) do
      {:ok, mark} ->
        mark

      :error ->
        read_json(Path.join([s.root, name, "source.json"]), %{
          "sequence" => 0,
          "sample" => 0,
          "done" => false
        })
    end
  end

  defp reap_paths(bytes, paths) do
    Enum.reduce(paths, bytes, fn path, total ->
      if File.exists?(path) do
        size = File.stat!(path).size
        File.rm!(path)
        total - size
      else
        total
      end
    end)
  end

  defp reap_covered_records(s, name, sequence) do
    Enum.reduce(stream_records(s, name), s.bytes, fn {q, path}, bytes ->
      if q < sequence do
        size = File.stat!(path).size
        File.rm!(path)
        bytes - size
      else
        bytes
      end
    end)
  end

  defp stream_records(s, name) do
    Path.wildcard(Path.join([s.root, name, "*.rec"]))
    |> Stream.map(fn path -> {path |> Path.basename(".rec") |> String.to_integer(), path} end)
  end

  defp parse_receipt(wire) when is_map(wire) do
    if Map.get(wire, "type", "durable") in ["durable", "stream_finished"] and
         Map.get(wire, "schema", "medex.device.v1") == "medex.device.v1" do
      MedEx.Serialization.receipt(Map.drop(wire, ["type", "schema"]))
    else
      {:error, :invalid_receipt}
    end
  end

  defp parse_receipt(_), do: {:error, :invalid_receipt}

  defp identity?(r, name, b),
    do:
      r.stream_id == name and r.fence == b["fence"] and
        r.journal_id == b["journal_id"] and r.descriptor_ref == b["descriptor_ref"] and
        r.source_epoch == b["source_epoch"]

  defp previous_receipt(path) do
    case read_json(path, nil) do
      nil -> {:ok, %{durable_sequence: 0, durable_sample: 0}}
      wire -> MedEx.Serialization.receipt(wire)
    end
  end

  defp verify_progress(%{fence: fence} = last, %{fence: fence} = receipt),
    do: MedEx.Serialization.receipt_progress(last, receipt)

  # The active generation pins the successor journal and fence before this comparison.
  defp verify_progress(%{fence: _} = last, receipt),
    do: MedEx.Serialization.receipt_progress(last, receipt, :verified_handoff)

  defp verify_progress(_empty, receipt) do
    if MedEx.Serialization.durable_prefix(receipt) == receipt,
      do: :ok,
      else: {:error, :not_durable_receipt}
  end

  defp verify_coverage(s, name, last, r) do
    source = current_watermark(s, name)
    first = last.durable_sequence
    next = r.durable_sequence

    with true <- is_integer(source["sequence"]) and is_integer(source["sample"]),
         true <- next <= source["sequence"] and r.durable_sample <= source["sample"] do
      stream_number = if name == "audio", do: 1, else: 2
      expected_end = {next, r.durable_sample}

      {covered_end, visited} =
        covered_range(
          s,
          name,
          {first, last.durable_sample},
          next,
          stream_number,
          r.source_epoch,
          []
        )

      if covered_end == expected_end, do: {:ok, visited}, else: {:error, :uncovered_receipt}
    else
      _ -> {:error, :uncovered_receipt}
    end
  catch
    :hole -> {:error, :uncovered_receipt}
  end

  defp covered_range(s, name, {q, sample}, next, stream_number, epoch, visited) when q < next do
    path = record(s, name, q)
    unless File.exists?(path), do: throw(:hole)

    {next_q, next_sample} =
      advance_coverage(read_record!(path), q, sample, stream_number, epoch)

    if next_q > next, do: throw(:hole)

    covered_range(
      s,
      name,
      {next_q, next_sample},
      next,
      stream_number,
      epoch,
      [path | visited]
    )
  end

  defp covered_range(_s, _name, pos, _next, _stream_number, _epoch, visited), do: {pos, visited}

  defp advance_coverage(<<"MEX1", _::binary>> = wire, q, left, stream_number, epoch) do
    {:ok, frame} = FrameV1.decode(wire)

    if frame.sequence != q or frame.first_sample != left or frame.source_epoch != epoch or
         frame.stream_number != stream_number do
      throw(:hole)
    end

    {q + 1, left + frame.sample_count}
  end

  defp advance_coverage(wire, q, left, _, _) do
    first = to_string(left)
    first_sequence = to_string(q)

    with %{
           "irreversible" => true,
           "first" => ^first,
           "end" => ending,
           "first_sequence" => ^first_sequence,
           "next_sequence" => next
         }
         when is_binary(next) and is_binary(ending) <- JSON.decode!(wire),
         {right_seq, ""} <- Integer.parse(next),
         {right_sample, ""} <- Integer.parse(ending),
         true <- right_seq > q and right_sample > left do
      {right_seq, right_sample}
    else
      _ -> throw(:hole)
    end
  end

  def terminate(_, s) do
    if Port.info(s.owner), do: Port.close(s.owner)
    :ok
  end

  defp record(s, name, seq)
       when name in ["audio", "ecg", "events"] and is_integer(seq) and seq >= 0,
       do: Path.join([s.root, name, to_string(seq) <> ".rec"])

  defp read_record!(path) do
    <<sha::binary-size(32), body::binary>> = File.read!(path)
    unless :crypto.hash(:sha256, body) == sha, do: raise("spool checksum mismatch")
    body
  end

  def read_json(path, default) do
    case File.read(path) do
      {:ok, b} -> JSON.decode!(b)
      {:error, :enoent} -> default
      {:error, r} -> raise File.Error, reason: r, action: "read", path: path
    end
  end

  def write!(path, bytes) do
    dir = Path.dirname(path)
    tmp = stage_tmp!(dir, path, bytes)

    try do
      File.rename!(tmp, path)
      sync_dir!(dir)
    after
      File.rm(tmp)
    end
  end

  defp stage_tmp!(dir, path, bytes) do
    File.mkdir_p!(dir)
    tmp = path <> ".tmp." <> Base.url_encode64(:crypto.strong_rand_bytes(9))

    try do
      {:ok, fd} = :file.open(String.to_charlist(tmp), [:write, :raw, :binary, :exclusive])

      try do
        File.chmod!(tmp, 0o600)
        :ok = :file.write(fd, bytes)
        :ok = :file.sync(fd)
      after
        :file.close(fd)
      end

      tmp
    rescue
      e ->
        File.rm(tmp)
        reraise e, __STACKTRACE__
    end
  end

  defp sync_dir!(dir) do
    {:ok, fd} = :file.open(String.to_charlist(dir), [:read, :raw, :directory])

    try do
      :ok = :file.sync(fd)
    after
      :file.close(fd)
    end
  end
end
