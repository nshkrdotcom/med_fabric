defmodule MedFabric.Handheld.Spool do
  @moduledoc "One OS-locked spool: synchronized source records and canonical durable receipts precede reclamation."
  use GenServer, restart: :temporary
  import Bitwise, only: [band: 2]
  alias MedEx.{Receipt, Serialization, StreamCursor, StreamSpec}
  alias MedEx.Wire.Control
  alias MedFabric.Handheld.EffectiveUID
  alias MedFabric.Handheld.Spool.Plan
  @namespace %{"schema" => "mf_handheld.spool", "revision" => 2}
  @max_records 100_000

  def start_link(opts) do
    case GenServer.start_link(__MODULE__, {self(), opts}) do
      {:error, {:shutdown, reason}} -> {:error, reason}
      result -> result
    end
  end

  def register(pid, spec), do: GenServer.call(pid, {:register, spec}, 30_000)

  def put(pid, "events", sequence, bytes),
    do: GenServer.call(pid, {:event, sequence, bytes}, 30_000)

  def put_batch_and_advance(pid, root, stream, items, timeout \\ 30_000),
    do: GenServer.call(pid, {:batch, root, stream, items}, timeout)

  def watermark(pid, stream), do: GenServer.call(pid, {:watermark, stream})

  def persist_watermark(pid, stream),
    do: GenServer.call(pid, {:persist_watermark, stream}, 30_000)

  def finish_source(pid, stream, sequence, sample, interruption),
    do: GenServer.call(pid, {:finish_source, stream, sequence, sample, interruption}, 30_000)

  def get(pid, stream, position), do: GenServer.call(pid, {:get, stream, position})

  def activate(pid, stream, spec, reply),
    do: GenServer.call(pid, {:activate, stream, spec, reply}, 30_000)

  def ack(pid, stream, binding, receipt),
    do: GenServer.call(pid, {:ack, stream, binding, receipt}, 30_000)

  def invalidate(pid, binding), do: GenServer.call(pid, {:invalidate, binding})
  def event_activate(pid, binding), do: GenServer.call(pid, {:event_activate, binding})

  def event_ack(pid, binding, sequence, id, digest),
    do: GenServer.call(pid, {:event_ack, binding, sequence, id, digest}, 30_000)

  def event_seal(pid, binding, inventory),
    do: GenServer.call(pid, {:event_seal, binding, inventory}, 30_000)

  def stats(pid), do: GenServer.call(pid, :stats)

  def init({caller, opts}) do
    case initialize(opts) do
      {:stop, reason} ->
        Process.unlink(caller)
        {:stop, {:shutdown, reason}}

      success ->
        success
    end
  end

  defp initialize(opts) do
    with root when is_binary(root) <- opts[:root],
         limit when is_integer(limit) and limit > 0 and limit <= 536_870_912 <-
           opts[:limit] || 67_108_864,
         {:ok, uid} <- EffectiveUID.resolve(),
         :ok <- check_existing_namespace(root),
         :ok <- prepare_root(root, uid),
         {:ok, %{major_device: device, inode: inode}} <- File.lstat(root),
         {:ok, owner} <- lock(root) do
      ownership = %{
        root: Path.expand(root),
        root_identity: {device, inode},
        owner: owner,
        uid: uid
      }

      result =
        if owned_root?(ownership),
          do: initialize(ownership, limit),
          else: {:error, :unsafe_spool_root}

      case result do
        {:ok, state} ->
          {:ok, state}

        {:error, reason} ->
          close_port(owner)
          {:stop, reason}
      end
    else
      {:error, reason} -> {:stop, reason}
      _ -> {:stop, :invalid_spool_options}
    end
  end

  def handle_call(request, from, state) do
    if owned_root?(state),
      do: handle_owned_call(request, from, state),
      else: {:stop, :normal, {:error, :unsafe_spool_root}, state}
  end

  defp owned_root?(state) do
    with true <- Port.info(state.owner) != nil,
         {:ok, uid} <- EffectiveUID.resolve(),
         true <- uid == state.uid,
         {:ok, %{type: :directory, uid: ^uid, mode: mode, major_device: device, inode: inode}} <-
           File.lstat(state.root),
         true <- band(mode, 0o022) == 0 and {device, inode} == state.root_identity,
         :ok <- trusted_ancestors(state.root, uid) do
      true
    else
      _ -> false
    end
  end

  defp handle_owned_call({:register, %StreamSpec{stream_id: name} = spec}, _, state)
       when name in ["audio", "ecg"] do
    case register_stream(state, spec) do
      {:ok, stream} -> {:reply, :ok, %{state | streams: Map.put(state.streams, name, stream)}}
      error -> {:reply, error, state}
    end
  end

  defp handle_owned_call({:register, _}, _, state), do: {:reply, {:error, :invalid_stream}, state}

  defp handle_owned_call({:batch, root, name, items}, _, state)
       when is_list(items) and length(items) <= 5 do
    with true <- Path.expand(root) == state.root,
         {:ok, stream} <- Map.fetch(state.streams, name),
         true <- not stream.done do
      case install_batch(state, name, stream, items) do
        {:ok, next} -> {:reply, :ok, next}
        {:error, reason, next} -> {:reply, {:error, reason}, next}
      end
    else
      _ -> {:reply, {:error, :invalid_source_batch}, state}
    end
  rescue
    _ in [File.Error, MatchError, ArgumentError] ->
      {:stop, :local_outcome_unknown, {:error, :outcome_unknown}, state}
  end

  defp handle_owned_call({:batch, _, _, _}, _, state),
    do: {:reply, {:error, :invalid_source_batch}, state}

  defp handle_owned_call({:watermark, name}, _, state),
    do: {:reply, mark(state.streams[name]), state}

  defp handle_owned_call({:persist_watermark, name}, _, state) do
    case state.streams[name] do
      nil ->
        {:reply, {:error, :unknown_stream}, state}

      stream ->
        write!(Path.join([state.root, name, "source.json"]), JSON.encode!(mark(stream)))
        {:reply, :ok, state}
    end
  end

  defp handle_owned_call({:finish_source, name, q, sample, interruption}, _, state) do
    case state.streams[name] do
      %{cursor: %{next_sequence: ^q, next_sample: ^sample}} = stream
      when is_nil(interruption) or is_binary(interruption) ->
        if interruption == nil or
             (byte_size(interruption) <= 96 and MedEx.ContractRules.id?(interruption)) do
          next = %{stream | done: true, interruption: interruption}
          write!(Path.join([state.root, name, "source.json"]), JSON.encode!(mark(next)))
          {:reply, :ok, %{state | streams: Map.put(state.streams, name, next)}}
        else
          {:reply, {:error, :invalid_interruption}, state}
        end

      _ ->
        {:reply, {:error, :source_cursor_conflict}, state}
    end
  end

  defp handle_owned_call({:get, name, key}, _, state) do
    case state.files[{name, key}] do
      nil -> {:reply, :absent, state}
      file -> {:reply, {:ok, read_record!(file.path)}, state}
    end
  end

  defp handle_owned_call({:activate, name, spec, reply}, _, state) when is_map(reply) do
    with {:ok, stream} <- Map.fetch(state.streams, name),
         true <- stream.spec == spec,
         true <- reply["type"] in ["durable", "stream_finished"],
         false <- Map.has_key?(reply, "event_id") or Map.has_key?(reply, "fingerprint"),
         {:ok, receipt} <- Receipt.parse(reply["receipt"]),
         true <- Receipt.durable?(receipt),
         :ok <- binding_valid(reply["binding"], spec, receipt),
         :ok <- activation_progress(stream.ack, reply["binding"], receipt, reply["handoff"]),
         {:ok, keys} <- covered(stream, receipt) do
      next = persist_ack(state, name, stream, reply["binding"], receipt, keys)
      {:reply, {:ok, receipt}, %{next | active: Map.put(next.active, name, reply["binding"])}}
    else
      {:error, _} = error -> {:reply, error, state}
      _ -> {:reply, {:error, :invalid_activation}, state}
    end
  end

  defp handle_owned_call({:activate, _, _, _}, _, state),
    do: {:reply, {:error, :invalid_activation}, state}

  defp handle_owned_call({:ack, name, binding, wire}, _, state) do
    with ^binding <- state.active[name],
         true <- is_map(binding),
         {:ok, stream} <- Map.fetch(state.streams, name),
         {:ok, receipt} <- Receipt.parse(wire),
         true <- Receipt.durable?(receipt),
         :ok <- binding_valid(binding, stream.spec, receipt),
         :ok <- Receipt.observe(stream.ack.receipt, receipt),
         {:ok, keys} <- covered(stream, receipt) do
      {:reply, :ok, persist_ack(state, name, stream, binding, receipt, keys)}
    else
      {:error, _} = error -> {:reply, error, state}
      _ -> {:reply, {:error, :stale_binding}, state}
    end
  end

  defp handle_owned_call({:invalidate, binding}, _, state) do
    base? =
      is_map(binding) and
        Enum.sort(Map.keys(binding)) == Enum.sort(~w(acquisition profile generation connection))

    active =
      Map.reject(state.active, fn {_, value} ->
        value == binding or
          (base? and
             Map.take(value, ~w(acquisition profile generation)) ==
               Map.take(binding, ~w(acquisition profile generation)))
      end)

    {:reply, :ok,
     %{
       state
       | active: active,
         events_binding: if(state.events_binding == binding, do: nil, else: state.events_binding)
     }}
  end

  defp handle_owned_call({:event, sequence, bytes}, _, state)
       when is_integer(sequence) and sequence >= 0 and is_binary(bytes) and
              byte_size(bytes) <= 16_384 do
    key = {"events", sequence}

    cond do
      not valid_event?(bytes, sequence, state.root) ->
        {:reply, {:error, :invalid_source_event}, state}

      state.files[key] != nil ->
        {:reply,
         if(read_record!(state.files[key].path) == bytes,
           do: :ok,
           else: {:error, :event_conflict}
         ), state}

      event_capacity_exceeded?(state, bytes) ->
        {:reply, {:error, :spool_full}, state}

      true ->
        path = record_path(state.root, "events", sequence)
        install!(path, :crypto.hash(:sha256, bytes) <> bytes)
        size = byte_size(bytes) + 32

        {:reply, :ok,
         %{
           state
           | files: Map.put(state.files, key, %{path: path, raw: bytes, size: size}),
             bytes: state.bytes + size,
             maximum: max(state.maximum, state.bytes + size)
         }}
    end
  end

  defp handle_owned_call({:event_activate, binding}, _, state) do
    history = Path.join([state.root, "events", "binding.json"])
    identity = read_json(Path.join(state.root, "identity.json"), nil)

    with true <- is_map(binding) and is_map(identity),
         true <-
           Enum.sort(Map.keys(binding)) ==
             Enum.sort(~w(acquisition profile generation connection)),
         true <-
           binding["profile"] == "plx_spot_check" and identity["profile"] == "plx_spot_check" and
             binding["acquisition"] == identity["acquisition"],
         true <- MedEx.ContractRules.id?(binding["connection"]),
         {:ok, generation} <- Control.uint64(binding["generation"]),
         true <- generation in 1..0x7FFFFFFFFFFFFFFF,
         previous <- read_json(history, nil),
         :ok <- event_generation(previous, binding, generation) do
      write!(history, JSON.encode!(binding))
      {:reply, :ok, %{state | events_binding: binding}}
    else
      _ -> {:reply, {:error, :invalid_binding}, state}
    end
  end

  defp handle_owned_call({:event_ack, binding, sequence, id, digest}, _, state) do
    with true <- binding == state.events_binding and is_map(binding),
         {:ok, file} <- Map.fetch(state.files, {"events", sequence}),
         raw <- read_record!(file.path),
         true <- valid_event?(raw, sequence, state.root),
         {:ok, event} when is_map(event) <- JSON.decode(raw),
         true <- event["event_id"] == id and Serialization.digest(event) == digest do
      write!(file.path <> ".receipt", JSON.encode!([id, digest]))
      {:reply, :ok, state}
    else
      _ -> {:reply, {:error, :event_conflict}, state}
    end
  end

  defp handle_owned_call({:event_seal, binding, inventory}, _, state) do
    files = Enum.filter(state.files, fn {{name, _}, _} -> name == "events" end)
    seal_path = Path.join([state.root, "events", "seal.json"])
    saved = read_json(seal_path, nil)

    valid = valid_seal?(state, binding, inventory, saved, files)

    if valid do
      # The complete authenticated remote inventory is persisted before any local deletion.
      if saved == nil, do: write!(seal_path, JSON.encode!(inventory))

      next =
        Enum.reduce(files, state, fn {key, file}, acc ->
          File.rm!(file.path)
          File.rm(file.path <> ".receipt")
          %{acc | files: Map.delete(acc.files, key), bytes: acc.bytes - file.size}
        end)

      sync_dir!(Path.join(state.root, "events"))
      {:reply, :ok, next}
    else
      {:reply, {:error, :event_inventory_conflict}, state}
    end
  end

  defp handle_owned_call(:stats, _, state),
    do: {:reply, Map.take(state, [:bytes, :maximum, :limit, :reclamation_visits]), state}

  defp handle_owned_call(_, _, state), do: {:reply, {:error, :invalid_spool_operation}, state}

  defp initialize(%{root: root} = ownership, limit) do
    namespace = Path.join(root, "namespace.json")

    with :ok <- namespace(root, namespace),
         :ok <-
           clean_staging(
             root,
             ~r/\A(?:identity|source_started|result|inventory|monitor)\.json\.tmp\.[A-Za-z0-9_-]{16}\z/
           ),
         {:ok, records, bytes} <- load_records(root),
         true <- map_size(records) <= @max_records and bytes <= limit do
      {:ok,
       Map.merge(ownership, %{
         limit: limit,
         bytes: bytes,
         maximum: bytes,
         files: records,
         streams: %{},
         active: %{},
         events_binding: nil,
         reclamation_visits: 0,
         needs_sweep: MapSet.new(["audio", "ecg"])
       })}
    else
      {:error, reason} -> {:error, reason}
      _ -> {:error, :invalid_spool_inventory}
    end
  rescue
    _ in [File.Error, JSON.DecodeError, ArgumentError, MatchError] -> {:error, :corrupt_spool}
  end

  defp prepare_root(root, uid) do
    with true <- Path.type(root) == :absolute,
         :ok <- trusted_ancestors(root, uid),
         :ok <- File.mkdir_p(root),
         {:ok, stat} <- File.lstat(root),
         true <- stat.type == :directory and stat.uid == uid,
         :ok <- File.chmod(root, 0o700) do
      :ok
    else
      _ -> {:error, :unsafe_spool_root}
    end
  end

  defp trusted_ancestors(root, uid) do
    paths = Path.expand(root) |> Path.split() |> Enum.scan(&Path.join(&2, &1))

    Enum.reduce_while(paths, :ok, fn path, :ok ->
      trusted_ancestor(path, uid)
    end)
  rescue
    _ in [ArgumentError, ErlangError, MatchError] -> {:error, :unsafe_spool_root}
  end

  defp check_existing_namespace(root) do
    case File.lstat(root) do
      {:ok, %{type: :directory}} -> check_nonempty_namespace(root)
      _ -> :ok
    end
  rescue
    _ in [File.Error, JSON.DecodeError, ArgumentError] -> {:error, :corrupt_spool}
  end

  defp check_nonempty_namespace(root) do
    if File.ls!(root) -- ["spool.lock"] == [] do
      :ok
    else
      case read_json(Path.join(root, "namespace.json"), nil) do
        value when value == @namespace -> :ok
        nil -> {:error, :incompatible_spool}
        _ -> {:error, :corrupt_spool}
      end
    end
  end

  defp namespace(root, path) do
    case read_json(path, nil) do
      value when value == @namespace ->
        :ok

      nil ->
        if File.ls!(root) -- ["spool.lock"] == [] do
          write!(path, JSON.encode!(@namespace))
          :ok
        else
          {:error, :incompatible_spool}
        end

      _ ->
        {:error, :corrupt_spool}
    end
  end

  defp load_records(root) do
    Enum.reduce_while(["audio", "ecg", "events"], {:ok, %{}, 0}, fn name, {:ok, all, total} ->
      load_stream_records(root, name, all, total)
    end)
  catch
    :spool_metadata_limit -> {:error, :spool_metadata_limit}
  end

  defp clean_staging(dir, pattern) do
    names = File.ls!(dir)
    if length(names) > @max_records + 64, do: raise(ArgumentError, "spool metadata limit")
    stale = Enum.filter(names, &Regex.match?(pattern, &1))
    Enum.each(stale, &File.rm!(Path.join(dir, &1)))
    if stale != [], do: sync_dir!(dir)
    :ok
  end

  defp file_key("events", file) do
    [_, number] = Regex.run(~r/\A(0|[1-9][0-9]*)\.rec\z/, file)
    {:ok, value} = Control.uint64(number)
    value
  end

  defp file_key(_, file) do
    [_, q, sample] = Regex.run(~r/\A(0|[1-9][0-9]*)-(0|[1-9][0-9]*)\.rec\z/, file)
    {:ok, q} = Control.uint64(q)
    {:ok, sample} = Control.uint64(sample)
    {q, sample}
  end

  defp register_stream(state, spec) do
    name = spec.stream_id
    descriptor_file = Path.join([state.root, name, "descriptor.json"])
    wire = Serialization.to_map(spec)

    with :ok <- StreamSpec.validate(spec),
         true <- spec.descriptor_ref == Serialization.descriptor_ref(spec),
         old <- read_json(descriptor_file, nil),
         true <- old == nil or old == wire,
         {:ok, initial} <- StreamCursor.new(spec),
         {:ok, saved_ack} <- load_ack(state.root, name, spec),
         {:ok, records} <- load_metadata(state, spec),
         base =
           if(saved_ack,
             do: %{
               initial
               | next_sequence: saved_ack.receipt.durable_sequence,
                 next_sample: saved_ack.receipt.durable_sample
             },
             else: initial
           ),
         {:ok, cursor} <- Plan.tail(records, base),
         :ok <- complete_inventory(records, base, cursor),
         saved <- read_json(Path.join([state.root, name, "source.json"]), nil),
         :ok <- validate_watermark(saved, cursor) do
      if old == nil, do: write!(descriptor_file, JSON.encode!(wire))

      {:ok,
       %{
         spec: spec,
         records: records,
         cursor: cursor,
         ack: saved_ack,
         done: saved != nil and saved["done"] == true,
         interruption: if(saved, do: saved["interruption"], else: nil)
       }}
    else
      {:error, _} = error -> error
      _ -> {:error, :source_identity_or_coverage}
    end
  rescue
    _ in [File.Error, JSON.DecodeError, ArgumentError, MatchError] ->
      {:error, :corrupt_source_state}
  end

  defp load_metadata(state, spec) do
    Enum.reduce_while(state.files, {:ok, %{}}, fn
      {{name, key}, file}, {:ok, acc} when name == spec.stream_id ->
        case Plan.record(file.raw, spec) do
          {:ok, %{key: ^key} = metadata} ->
            {:cont, {:ok, Map.put(acc, key, Map.merge(metadata, Map.take(file, [:path, :size])))}}

          _ ->
            {:halt, {:error, :corrupt_source_record}}
        end

      _, acc ->
        {:cont, acc}
    end)
  end

  defp complete_inventory(records, base, cursor) do
    with {:ok, visited} <-
           Plan.coverage(records, base, {cursor.next_sequence, cursor.next_sample}) do
      visited = MapSet.new(visited)

      valid =
        Enum.all?(records, fn {key, metadata} ->
          record_covered?(base, visited, key, metadata)
        end)

      if valid, do: :ok, else: {:error, :source_discontinuity}
    end
  end

  defp load_ack(root, name, spec) do
    case read_json(Path.join([root, name, "ack.json"]), nil) do
      nil ->
        {:ok, nil}

      %{"binding" => binding, "receipt" => wire} = ack when map_size(ack) == 2 ->
        with {:ok, receipt} <- Receipt.parse(wire),
             true <- Receipt.durable?(receipt),
             :ok <- binding_valid(binding, spec, receipt) do
          {:ok, %{binding: binding, receipt: receipt}}
        else
          _ -> {:error, :corrupt_receipt}
        end

      _ ->
        {:error, :corrupt_receipt}
    end
  end

  defp validate_watermark(nil, _), do: :ok

  defp validate_watermark(%{"sequence" => q, "sample" => sample, "done" => done}, cursor)
       when is_integer(q) and q >= 0 and is_integer(sample) and sample >= 0 and is_boolean(done) do
    cond do
      watermark_ahead?(q, sample, cursor) ->
        {:error, :source_watermark_ahead}

      terminal_watermark_conflict?(q, sample, done, cursor) ->
        {:error, :terminal_source_conflict}

      true ->
        :ok
    end
  end

  defp validate_watermark(_, _), do: {:error, :corrupt_source_watermark}

  defp install_batch(state, name, stream, items) do
    Enum.reduce_while(items, {:ok, state}, fn item, {:ok, acc} ->
      current = acc.streams[name] || stream

      case install_one(acc, name, current, item) do
        {:ok, next} -> {:cont, {:ok, next}}
        {:error, reason} -> {:halt, {:error, reason, acc}}
      end
    end)
  end

  defp install_one(state, name, stream, {q, raw, next_q, next_sample}) do
    with {:ok, metadata} <- Plan.record(raw, stream.spec), true <- elem(metadata.key, 0) == q do
      install_record(state, name, stream, metadata, raw, next_q, next_sample)
    else
      false -> {:error, :invalid_source_batch}
      error -> error
    end
  end

  defp install_one(_, _, _, _), do: {:error, :invalid_source_batch}

  defp mark(nil), do: %{"sequence" => 0, "sample" => 0, "done" => false}

  defp mark(stream),
    do: %{
      "sequence" => stream.cursor.next_sequence,
      "sample" => stream.cursor.next_sample,
      "done" => stream.done,
      "interruption" => stream.interruption
    }

  defp binding_valid(binding, spec, receipt) when is_map(binding) do
    with true <-
           Enum.sort(Map.keys(binding)) ==
             Enum.sort(~w(acquisition profile generation connection stream fence journal_id)),
         true <-
           binding["acquisition"] == spec.acquisition_id and binding["profile"] == "paired_exam" and
             binding["stream"] == spec.stream_id,
         {:ok, generation} <- Control.uint64(binding["generation"]),
         true <- generation in 1..0x7FFFFFFFFFFFFFFF,
         true <- Enum.all?(~w(connection fence journal_id), &MedEx.ContractRules.id?(binding[&1])),
         :ok <-
           Receipt.validate_identity(receipt, %{
             stream_id: spec.stream_id,
             source_epoch: spec.source_epoch,
             descriptor_ref: spec.descriptor_ref,
             fence: binding["fence"],
             journal_id: binding["journal_id"]
           }) do
      :ok
    else
      _ -> {:error, :receipt_identity}
    end
  end

  defp binding_valid(_, _, _), do: {:error, :invalid_binding}
  defp activation_progress(nil, _, _, nil), do: :ok

  defp activation_progress(nil, _, receipt, handoff) do
    verify_handoff(nil, receipt, handoff)
  end

  defp activation_progress(old, binding, receipt, handoff) do
    with {:ok, previous_gen} <- Control.uint64(old.binding["generation"]),
         {:ok, generation} <- Control.uint64(binding["generation"]),
         true <- generation >= previous_gen do
      check_activation_progress(old, receipt, handoff, generation, previous_gen)
    else
      _ -> {:error, :stale_generation}
    end
  end

  defp verify_handoff(
         local,
         receipt,
         %{
           "previous" => previous,
           "successor" => successor,
           "imported" => imported,
           "asserted_by" => "authenticated_host"
         } = proof
       )
       when map_size(proof) == 4 do
    with {:ok, host_previous} <- Receipt.parse(previous),
         :ok <- if(is_nil(local), do: :ok, else: Receipt.observe(local, host_previous)) do
      Receipt.handoff(host_previous, receipt, %{
        previous: previous,
        successor: successor,
        imported: imported,
        authenticated: true,
        quiescent: true,
        authority: :authenticated_host
      })
    end
  end

  defp verify_handoff(_, _, _), do: {:error, :unverified_handoff}

  defp covered(stream, receipt) do
    initial = %{stream.cursor | next_sequence: 0, next_sample: 0}

    start =
      if stream.ack,
        do: %{
          initial
          | next_sequence: stream.ack.receipt.durable_sequence,
            next_sample: stream.ack.receipt.durable_sample
        },
        else: initial

    with true <-
           receipt.durable_sequence <= stream.cursor.next_sequence and
             receipt.durable_sample <= stream.cursor.next_sample,
         {:ok, keys} <-
           Plan.coverage(
             stream.records,
             start,
             {receipt.durable_sequence, receipt.durable_sample}
           ),
         :ok <- verify_covered(stream, keys) do
      {:ok, keys}
    else
      false -> {:error, :uncovered_receipt}
      error -> error
    end
  end

  defp verify_covered(stream, keys) do
    Enum.reduce_while(keys, :ok, fn key, :ok ->
      case verify_record(Map.fetch!(stream.records, key), stream.spec) do
        :ok -> {:cont, :ok}
        error -> {:halt, error}
      end
    end)
  end

  defp verify_record(metadata, spec) do
    with raw <- read_record!(metadata.path),
         {:ok, current} <- Plan.record(raw, spec),
         true <- current.key == metadata.key and current.fingerprint == metadata.fingerprint do
      :ok
    else
      _ -> {:error, :source_record_changed}
    end
  rescue
    _ in [File.Error, ArgumentError, MatchError] -> {:error, :source_record_changed}
  end

  defp persist_ack(state, name, stream, binding, receipt, keys) do
    write!(
      Path.join([state.root, name, "ack.json"]),
      JSON.encode!(%{"binding" => binding, "receipt" => Receipt.to_map(receipt)})
    )

    sweep? = MapSet.member?(state.needs_sweep, name)

    keys =
      if sweep?,
        do:
          Enum.filter(Map.keys(stream.records), fn key ->
            metadata = stream.records[key]

            {:ok, next} =
              Plan.advance(
                %{stream.cursor | next_sequence: elem(key, 0), next_sample: elem(key, 1)},
                metadata
              )

            next.next_sequence <= receipt.durable_sequence and
              next.next_sample <= receipt.durable_sample
          end),
        else: keys

    {files, records, bytes} =
      Enum.reduce(keys, {state.files, stream.records, state.bytes}, fn key,
                                                                       {files, records, bytes} ->
        file = Map.fetch!(records, key)

        case File.rm(file.path) do
          :ok ->
            :ok

          {:error, :enoent} ->
            :ok

          {:error, reason} ->
            raise File.Error, reason: reason, action: "reclaim spool record", path: file.path
        end

        {Map.delete(files, {name, key}), Map.delete(records, key), bytes - file.size}
      end)

    if keys != [], do: sync_dir!(Path.join(state.root, name))
    stream = %{stream | records: records, ack: %{binding: binding, receipt: receipt}}

    %{
      state
      | files: files,
        bytes: bytes,
        streams: Map.put(state.streams, name, stream),
        needs_sweep: MapSet.delete(state.needs_sweep, name),
        reclamation_visits:
          state.reclamation_visits +
            if(sweep?, do: map_size(stream.records) + length(keys), else: length(keys))
    }
  end

  def handle_info({port, {:exit_status, _}}, %{owner: port} = state),
    do: {:stop, :spool_lock_lost, state}

  def handle_info(_, state), do: {:noreply, state}

  defp event_generation(nil, _, _), do: :ok

  defp event_generation(previous, binding, generation) when is_map(previous) do
    with true <-
           Enum.sort(Map.keys(previous)) ==
             Enum.sort(~w(acquisition profile generation connection)),
         true <-
           Map.take(previous, ~w(acquisition profile)) ==
             Map.take(binding, ~w(acquisition profile)),
         true <- MedEx.ContractRules.id?(previous["connection"]),
         {:ok, old} <- Control.uint64(previous["generation"]),
         true <- old > 0 and generation >= old do
      :ok
    else
      _ -> {:error, :stale_event_binding}
    end
  end

  defp event_generation(_, _, _), do: {:error, :corrupt_event_binding}

  defp valid_event?(raw, sequence, root) do
    identity = read_json(Path.join(root, "identity.json"), nil)

    with true <- is_map(identity) and identity["profile"] == "plx_spot_check",
         {:ok, wire} <- MedEx.CanonicalJSON.decode(raw),
         {:ok, event} <- Serialization.measurement(wire) do
      event.gateway_sequence == sequence and event.acquisition_id == identity["acquisition"] and
        event.boot_id == identity["boot"] and event.source_ref == identity["device"] and
        event.stream_id == "plx"
    else
      _ -> false
    end
  end

  defp valid_inventory?(inventory)
       when is_list(inventory) and length(inventory) <= @max_records do
    Enum.all?(inventory, fn
      [id, digest] -> MedEx.ContractRules.id?(id) and MedEx.ContractRules.digest?(digest)
      _ -> false
    end) and length(Enum.uniq_by(inventory, &hd/1)) == length(inventory)
  end

  defp valid_inventory?(_), do: false

  defp record_path(root, "events", q), do: Path.join([root, "events", "#{q}.rec"])
  defp record_path(root, name, {q, sample}), do: Path.join([root, name, "#{q}-#{sample}.rec"])

  defp read_record!(path) do
    {:ok, %{type: :regular, size: size}} = File.lstat(path)
    true = size in 33..65_616
    <<digest::binary-size(32), body::binary>> = File.read!(path)
    if :crypto.hash(:sha256, body) != digest, do: raise(ArgumentError, "spool checksum mismatch")
    body
  end

  def read_json(path, default) do
    case File.lstat(path) do
      {:ok, %{type: :regular, size: size}} when size <= 4_194_304 ->
        decode_metadata!(path)

      {:error, :enoent} ->
        default

      {:error, reason} ->
        raise File.Error, reason: reason, action: "read", path: path

      _ ->
        raise ArgumentError, "unsafe metadata path or size"
    end
  end

  def write!(path, bytes) do
    tmp = stage!(path, bytes)

    try do
      File.rename!(tmp, path)
      sync_dir!(Path.dirname(path))
    after
      File.rm(tmp)
    end
  end

  defp install!(path, bytes) do
    tmp = stage!(path, bytes)

    try do
      case File.ln(tmp, path) do
        :ok ->
          sync_dir!(Path.dirname(path))

        {:error, :eexist} ->
          if File.read!(path) != bytes, do: raise(ArgumentError, "immutable spool conflict")

        {:error, reason} ->
          raise File.Error, reason: reason, action: "install spool record", path: path
      end
    after
      File.rm(tmp)
    end
  end

  defp stage!(path, bytes) do
    File.mkdir_p!(Path.dirname(path))
    tmp = path <> ".tmp." <> Base.url_encode64(:crypto.strong_rand_bytes(12), padding: false)
    {:ok, fd} = :file.open(String.to_charlist(tmp), [:write, :raw, :binary, :exclusive])

    try do
      File.chmod!(tmp, 0o600)
      :ok = :file.write(fd, bytes)
      :ok = :file.sync(fd)
      tmp
    after
      :file.close(fd)
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

  defp lock(root) do
    case System.find_executable("flock") do
      nil ->
        {:error, :flock_required}

      executable ->
        args = [
          "-n",
          "--no-fork",
          Path.join(root, "spool.lock"),
          "sh",
          "-c",
          "echo locked && exec cat >/dev/null"
        ]

        port =
          Port.open({:spawn_executable, String.to_charlist(executable)}, [
            :binary,
            :exit_status,
            :use_stdio,
            args: Enum.map(args, &String.to_charlist/1)
          ])

        receive do
          {^port, {:data, "locked\n"}} -> {:ok, port}
          {^port, {:exit_status, _}} -> {:error, :spool_already_owned}
        after
          5_000 ->
            close_port(port)
            {:error, :spool_lock_timeout}
        end
    end
  end

  defp close_port(port) do
    if Port.info(port), do: Port.close(port)
    :ok
  rescue
    ArgumentError -> :ok
  end

  def terminate(_, state), do: close_port(state.owner)

  defp event_capacity_exceeded?(state, bytes),
    do: state.bytes + byte_size(bytes) + 32 > state.limit or map_size(state.files) >= @max_records

  defp valid_seal?(state, binding, inventory, saved, files) do
    binding == state.events_binding and is_map(binding) and valid_inventory?(inventory) and
      (saved == nil or saved == inventory) and
      Enum.all?(Enum.with_index(inventory), fn {entry, q} ->
        seal_entry?(state, inventory, saved, entry, q)
      end) and
      Enum.all?(files, fn {{_, q}, _} -> q < length(inventory) end)
  end

  defp seal_entry?(state, inventory, saved, entry, q) do
    case state.files[{"events", q}] do
      nil ->
        saved == inventory

      file ->
        verified_seal_entry?(state, file, entry, q)
    end
  end

  defp trusted_ancestor(path, uid) do
    case File.lstat(path) do
      {:error, :enoent} ->
        {:cont, :ok}

      {:ok, %{type: :directory, uid: owner, mode: mode}} ->
        # A root-owned sticky system temporary directory cannot rename this user's entries.
        trusted =
          owner in [0, uid] and
            (band(mode, 0o022) == 0 or (owner == 0 and band(mode, 0o1000) != 0))

        if trusted, do: {:cont, :ok}, else: {:halt, {:error, :unsafe_spool_root}}

      _ ->
        {:halt, {:error, :unsafe_spool_root}}
    end
  end

  defp load_record(root, name, dir, file, acc, count) do
    path = Path.join(dir, file)
    {:ok, info} = File.lstat(path)
    true = info.type == :regular and info.size in 33..65_616
    body = read_record!(path)
    key = file_key(name, file)

    if name == "events" and not valid_event?(body, key, root),
      do: raise(ArgumentError, "corrupt source event")

    {Map.put(acc, {name, key}, %{path: path, size: info.size, raw: body}), count + info.size}
  end

  defp load_stream_records(root, name, all, total) do
    dir = Path.join(root, name)

    with :ok <- File.mkdir_p(dir),
         {:ok, stat} <- File.lstat(dir),
         true <- stat.type == :directory do
      files = File.ls!(dir)

      # Only recognizable uncommitted staging files are removable; all installed evidence is retained.
      :ok =
        clean_staging(
          dir,
          ~r/\A(?:(?:descriptor|source|ack|binding|seal)\.json|[0-9]+(?:-[0-9]+)?\.rec(?:\.receipt)?)\.tmp\.[A-Za-z0-9_-]{16}\z/
        )

      entries = Enum.filter(files, &String.ends_with?(&1, ".rec"))
      if map_size(all) + length(entries) > @max_records, do: throw(:spool_metadata_limit)

      {records, bytes} =
        Enum.reduce(entries, {all, total}, fn file, {acc, count} ->
          load_record(root, name, dir, file, acc, count)
        end)

      {:cont, {:ok, records, bytes}}
    else
      _ -> {:halt, {:error, :unsafe_spool_path}}
    end
  end

  defp record_covered?(base, visited, key, metadata) do
    case Plan.advance(
           %{base | next_sequence: elem(key, 0), next_sample: elem(key, 1)},
           metadata
         ) do
      {:ok, ending} ->
        MapSet.member?(visited, key) or
          (ending.next_sequence <= base.next_sequence and
             ending.next_sample <= base.next_sample)

      _ ->
        false
    end
  end

  defp watermark_ahead?(q, sample, cursor),
    do: q > cursor.next_sequence or sample > cursor.next_sample

  defp install_new_record(state, name, stream, metadata, raw, next_q, next_sample) do
    with {:ok, cursor} <- Plan.advance(stream.cursor, metadata),
         true <- {cursor.next_sequence, cursor.next_sample} == {next_q, next_sample},
         true <- state.bytes + byte_size(raw) + 32 <= state.limit,
         true <- map_size(state.files) < @max_records do
      path = record_path(state.root, name, metadata.key)
      install!(path, :crypto.hash(:sha256, raw) <> raw)
      metadata = Map.merge(metadata, %{path: path, size: byte_size(raw) + 32})

      next_stream = %{
        stream
        | cursor: cursor,
          records: Map.put(stream.records, metadata.key, metadata)
      }

      {:ok,
       %{
         state
         | bytes: state.bytes + metadata.size,
           maximum: max(state.maximum, state.bytes + metadata.size),
           files:
             Map.put(state.files, {name, metadata.key}, %{
               path: path,
               size: metadata.size,
               raw: raw
             }),
           streams: Map.put(state.streams, name, next_stream)
       }}
    else
      false -> {:error, :spool_full}
      error -> error
    end
  end

  defp install_record(state, name, stream, metadata, raw, next_q, next_sample) do
    case stream.records[metadata.key] do
      %{fingerprint: fingerprint} when fingerprint == metadata.fingerprint ->
        start = %{
          stream.cursor
          | next_sequence: elem(metadata.key, 0),
            next_sample: elem(metadata.key, 1)
        }

        with {:ok, ending} <- Plan.advance(start, metadata),
             true <- {ending.next_sequence, ending.next_sample} == {next_q, next_sample},
             :ok <- verify_record(stream.records[metadata.key], stream.spec) do
          {:ok, state}
        else
          _ -> {:error, :spool_conflict}
        end

      %{} ->
        {:error, :spool_conflict}

      nil ->
        install_new_record(state, name, stream, metadata, raw, next_q, next_sample)
    end
  end

  defp check_activation_progress(old, receipt, handoff, generation, previous_gen) do
    if old.receipt.fence == receipt.fence do
      Receipt.observe(old.receipt, receipt)
    else
      if generation > previous_gen,
        do: verify_handoff(old.receipt, receipt, handoff),
        else: {:error, :unverified_handoff}
    end
  end

  defp decode_metadata!(path) do
    bytes = File.read!(path)
    if byte_size(bytes) > 4_194_304, do: raise(ArgumentError, "metadata limit")

    decoders = [
      object_start: fn _ -> %{} end,
      object_push: &push_metadata!/3,
      object_finish: fn object, parent -> {object, parent} end
    ]

    case JSON.decode(bytes, nil, decoders) do
      {value, nil, rest} ->
        if String.trim(rest) == "", do: value, else: raise(ArgumentError, "invalid metadata")

      _ ->
        raise ArgumentError, "invalid metadata"
    end
  end

  defp push_metadata!(key, value, object) do
    if Map.has_key?(object, key), do: raise(ArgumentError, "duplicate metadata key")
    Map.put(object, key, value)
  end

  defp terminal_watermark_conflict?(q, sample, done, cursor),
    do: done and {q, sample} != {cursor.next_sequence, cursor.next_sample}

  defp verified_seal_entry?(state, file, entry, q) do
    raw = read_record!(file.path)

    with true <- valid_event?(raw, q, state.root), {:ok, event} <- JSON.decode(raw) do
      entry == [event["event_id"], Serialization.digest(event)]
    else
      _ -> false
    end
  end
end
