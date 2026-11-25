defmodule MedExHandheld.Spool do
  @moduledoc "Single device budget. Sync exact bytes before acknowledging local ingestion, persist receipts before reclaiming."
  use GenServer
  alias MedEx.Wire.FrameV1

  def start_link(opts), do: GenServer.start_link(__MODULE__, opts)

  def init(opts) do
    root = opts[:root]
    File.mkdir_p!(root)
    owner = lock!(root)
    # Files carry their own checksum, including retained control/event identity.
    names = Path.wildcard(Path.join(root, "*/*.rec"))
    size = Enum.reduce(names, 0, fn f, n -> n + File.stat!(f).size end)
    for f <- names, do: read_record!(f)

    {:ok,
     %{root: root, bytes: size, maximum: size, limit: opts[:limit], active: %{}, owner: owner}}
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
  def get(p, stream, seq), do: GenServer.call(p, {:get, stream, seq})

  def activate(p, stream, gen, spec, receipt),
    do: GenServer.call(p, {:activate, stream, gen, spec, receipt})

  def ack(p, stream, gen, receipt), do: GenServer.call(p, {:ack, stream, gen, receipt}, 30_000)
  def stats(p), do: GenServer.call(p, :stats)

  def handle_call({:put, name, seq, bytes}, _, s) do
    f = record(s, name, seq)
    total = s.bytes + byte_size(bytes) + 32

    cond do
      File.exists?(f) ->
        {:reply, if(read_record!(f) == bytes, do: :ok, else: {:error, :spool_conflict}), s}

      total > s.limit ->
        {:reply, {:error, :spool_full}, s}

      true ->
        write!(f, :crypto.hash(:sha256, bytes) <> bytes)
        {:reply, :ok, %{s | bytes: total, maximum: max(s.maximum, total)}}
    end
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
         :ok <- verify_coverage(s, name, last, r) do
      write!(receipt, JSON.encode!(MedEx.Serialization.to_map(r)))
      # Also reap any covered files left by a crash after the receipt was synced.
      bytes = reap_covered_records(s, name, r.durable_sequence)

      sync_dir!(Path.dirname(receipt))
      {:reply, :ok, %{s | bytes: bytes}}
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

  defp verify_progress(last, r) do
    cond do
      r.accepted_sequence != r.durable_sequence or r.accepted_sample != r.durable_sample ->
        {:error, :not_durable_receipt}

      r.durable_sequence < last.durable_sequence or r.durable_sample < last.durable_sample ->
        {:error, :receipt_rollback}

      Map.has_key?(last, :descriptor_ref) and
          {last.stream_id, last.source_epoch, last.descriptor_ref} !=
            {r.stream_id, r.source_epoch, r.descriptor_ref} ->
        {:error, :receipt_identity}

      Map.get(last, :fence) == r.fence ->
        verify_journal_progress(last, r)

      true ->
        :ok
    end
  end

  defp verify_journal_progress(last, r) do
    cond do
      r.journal_id != last.journal_id or r.journal_generation < last.journal_generation ->
        {:error, :receipt_rollback}

      r.journal_generation == last.journal_generation and
          {r.journal_digest, r.durable_sequence, r.durable_sample} !=
            {last.journal_digest, last.durable_sequence, last.durable_sample} ->
        {:error, :receipt_conflict}

      r.journal_generation > last.journal_generation and r.journal_digest == last.journal_digest ->
        {:error, :receipt_conflict}

      true ->
        :ok
    end
  end

  defp verify_coverage(s, name, last, r) do
    source =
      read_json(Path.join([s.root, name, "source.json"]), %{"sequence" => 0, "sample" => 0})

    first = last.durable_sequence
    next = r.durable_sequence

    with true <- is_integer(source["sequence"]) and is_integer(source["sample"]),
         true <- next <= source["sequence"] and r.durable_sample <= source["sample"] do
      stream_number = if name == "audio", do: 1, else: 2
      expected_end = {next, r.durable_sample}

      covered_end =
        covered_range(s, name, {first, last.durable_sample}, next, stream_number, r.source_epoch)

      if covered_end == expected_end, do: :ok, else: {:error, :uncovered_receipt}
    else
      _ -> {:error, :uncovered_receipt}
    end
  catch
    :hole -> {:error, :uncovered_receipt}
  end

  defp covered_range(s, name, {first, sample}, next, stream_number, epoch) do
    stream_records(s, name)
    |> Enum.filter(fn {q, _} -> q >= first and q < next end)
    |> Enum.sort()
    |> Enum.reduce({first, sample}, fn {q, path}, {expected, left} ->
      if q != expected, do: throw(:hole)
      advance_coverage(read_record!(path), q, left, stream_number, epoch)
    end)
  end

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
    File.mkdir_p!(dir)
    tmp = path <> ".tmp." <> Base.url_encode64(:crypto.strong_rand_bytes(9))

    try do
      File.open!(tmp, [:write, :binary, :exclusive], fn f ->
        :ok = IO.binwrite(f, bytes)
        :ok = :file.sync(f)
      end)

      File.chmod!(tmp, 0o600)
      File.rename!(tmp, path)
      sync_dir!(dir)
    after
      File.rm(tmp)
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
