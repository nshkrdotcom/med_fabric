defmodule MedExHandheld.Paired do
  @moduledoc "Reference peripheral acquisition runs independently of server connectivity."
  alias MedEx.{Receipt, Serialization, StreamCursor, StreamSpec}
  alias MedEx.Wire.{Control, Credit, FrameV1}
  alias MedExHandheld.{Monitor, ReferencePeripheral, Spool, Transport}
  alias MedExHandheld.Spool.Plan

  def sources(c) do
    for {n, s} <- [{"audio", 1}, {"ecg", 2}], into: %{} do
      p = ReferencePeripheral.new(s, c["seed"] + s, c["variant"] == true)
      {p, cap, []} = ReferencePeripheral.transact(p, "capabilities")
      encoding = if cap["encoding"] == "s24le", do: :s24le, else: :s16le

      channels =
        for i <- 1..cap["channels"],
            do: %{
              id: to_string(i),
              label: n <> " " <> to_string(i),
              unit: if(s == 2, do: "uV", else: :unknown),
              calibration:
                if(s == 2,
                  do: %{zero: 0, scale_num: 1, scale_den: 1, reference: "synthetic_adc_1uV"},
                  else: :unknown
                )
            }

      spec = %StreamSpec{
        source_ref: c["device"],
        acquisition_id: c["acquisition"],
        boot_id: Map.fetch!(c, "boot"),
        stream_id: n,
        source_epoch: 0,
        descriptor_ref: String.duplicate("0", 64),
        modality: if(s == 1, do: "medex:diagnostic_audio", else: "medex:ecg"),
        encoding: encoding,
        channels: channels,
        sample_rate: List.to_tuple(cap["sample_rate"]),
        clock: %{
          domain_id: n,
          boot_id: "rdp-" <> to_string(p.boot),
          generation: 0,
          tick_rate: {cap["tick_rate"], 1},
          uncertainty_ticks: 48
        },
        source_processing: [%{name: "simulated_rdp1", origin: :claimed, value: true}],
        capabilities: %{
          encodings: [encoding],
          max_frame_samples: 960,
          max_payload_bytes: 2012,
          replay: :durable_spool,
          commands: []
        }
      }

      spec = %{spec | descriptor_ref: Serialization.descriptor_ref(spec)}
      :ok = StreamSpec.validate(spec)
      {n, {p, spec}}
    end
  end

  def produce(c, spool, monitor, hub, n, {peripheral, spec}) do
    cursor = cursor(c, n)

    if !cursor["done"] do
      {p, _res, []} =
        ReferencePeripheral.transact(peripheral, "start", %{
          "profile" => "reference",
          "acquisition" => c["acquisition"]
        })

      p = %{p | first: cursor["sample"], seq: cursor["sequence"]}
      source = %{config: c, spool: spool, monitor: monitor, hub: hub, name: n, spec: spec}
      loop(source, p, [])
    end
  end

  defp loop(%{config: c, hub: hub, name: name, spec: spec} = source, peripheral, pending) do
    {rn, rd} = spec.sample_rate
    target = div((c["seconds"] || 60) * rn, rd)
    stop = :ets.member(hub, :stop)
    reset = source_reset?(c, name, peripheral)

    if peripheral.first >= target or stop or reset do
      stop_source(source, peripheral, pending, reset)
    else
      capture_frame(source, peripheral, target, pending)
    end
  end

  defp stop_source(%{spool: spool, name: name} = source, peripheral, pending, reset) do
    case flush_pending(source, pending) do
      :ok ->
        {_, result, []} = ReferencePeripheral.transact(peripheral, "stop")

        :ok =
          Spool.finish_source(
            spool,
            name,
            String.to_integer(result["sequence"]),
            String.to_integer(result["sample"]),
            if(reset, do: "source_reset", else: nil)
          )

      {:error, :spool_full} ->
        stop_on_full_spool(source)
    end
  end

  defp stop_on_full_spool(%{spool: spool, hub: hub, name: name}) do
    mark = Spool.watermark(spool, name)
    :ets.insert(hub, {:stop, true})
    :ok = Spool.finish_source(spool, name, mark["sequence"], mark["sample"], "spool_full")
  end

  defp source_reset?(c, n, p) do
    if c["reset"] == true and n == "ecg" and p.seq == 3 do
      rebooted = ReferencePeripheral.new(p.source, p.boot + 1)
      {_, discovery, []} = ReferencePeripheral.transact(rebooted, "state")
      discovery["boot"] != to_string(p.boot) and discovery["sequence"] == "0"
    else
      false
    end
  end

  defp capture_frame(source, peripheral, target, pending) do
    %{config: c, name: name, spec: spec} = source
    {rn, rd} = spec.sample_rate
    wait_for_sample(c, name, peripheral.first, spec.sample_rate)
    step = frame_step(c, name)
    gap = name == "audio" and c["gap"] in [true, 3] and peripheral.seq == 2
    count = min(if(gap, do: 100, else: step), target - peripheral.first)
    tick = 8_640_000 + div(peripheral.first * 48_000_000 * rd, rn)
    {next, packet} = ReferencePeripheral.emit(peripheral, count, tick, c["seed"])
    frame = decode_frame(peripheral, packet, count)
    {:ok, raw} = FrameV1.encode(frame)

    {next, record} =
      if gap,
        do: lost_frame(c, peripheral, next, step, target, spec.sample_rate),
        else: {next, raw}

    pending = [{peripheral.seq, record, next.seq, next.first} | pending]
    buffer_frames(source, next, pending, gap, target)
  end

  defp buffer_frames(%{config: c, name: name} = source, next, pending, gap, target) do
    batch_size = if name == "audio" and c["variant"] != true, do: 5, else: 1
    persist_stride = if name == "audio", do: 50, else: 10
    persist = rem(next.seq, persist_stride) == 0

    if gap or next.first >= target or length(pending) >= batch_size or persist do
      flush_frames(source, next, pending, persist)
    else
      loop(source, next, pending)
    end
  end

  defp flush_frames(%{spool: spool, name: name} = source, next, pending, persist) do
    case flush_pending(source, pending) do
      :ok ->
        if persist, do: :ok = Spool.persist_watermark(spool, name)
        loop(source, next, [])

      {:error, :spool_full} ->
        stop_on_full_spool(source)
    end
  end

  defp flush_pending(_, []), do: :ok

  defp flush_pending(source, pending) do
    batch = Enum.reverse(pending)

    with :ok <-
           Spool.put_batch_and_advance(source.spool, source.config["spool"], source.name, batch) do
      if source.name == "audio" and source.spec.encoding == :s16le do
        Monitor.offer(source.monitor, source.hub, batch)
      end

      :ok
    end
  end

  defp wait_for_sample(c, n, first, {rn, rd}) do
    delta = div(first * 1_000_000 * rd, rn)

    # The fixture oscillator has an explicit origin, fixed rate perturbation and acquisition ticks.
    planned = c["origin_us"] + div(delta * (1_000_000 + ppm(n)), 1_000_000)
    delay = planned - System.system_time(:microsecond)
    if delay > 0, do: Process.sleep(div(delay, 1000))
  end

  defp frame_step(c, n) do
    cond do
      c["variant"] -> 4
      n == "audio" -> 960
      true -> 25
    end
  end

  defp decode_frame(p, packet, count) do
    event = ReferencePeripheral.fragmented(packet)

    true =
      event.boot == p.boot and event.source == p.source and event.sequence == p.seq and
        event.sample_count == count and event.first_sample == p.first

    %FrameV1{
      stream_number: p.source,
      source_epoch: 0,
      config_epoch: event.config_epoch,
      sequence: event.sequence,
      first_sample: event.first_sample,
      sample_count: count,
      payload: event.payload
    }
  end

  defp lost_frame(c, p, next, step, target, {rn, rd}) do
    # Evict the unavailable packets, then use a CRC-verified packet to
    # establish the first sample and sequence after the loss.
    count = if c["gap"] == 3, do: 3, else: 1

    lost =
      Enum.reduce(2..count//1, next, fn _, peripheral ->
        tick = 8_640_000 + div(peripheral.first * 48_000_000 * rd, rn)
        {advanced, _} = ReferencePeripheral.emit(peripheral, 100, tick, c["seed"])
        advanced
      end)

    history = Map.drop(lost.history, Enum.to_list(p.seq..(lost.seq - 1)))
    lost = %{lost | history: history}

    {lost, %{"state" => "unavailable"}, []} =
      ReferencePeripheral.transact(lost, "replay", %{"first" => p.seq, "next" => lost.seq})

    next_tick = 8_640_000 + div(lost.first * 48_000_000 * rd, rn)

    {_, witness} =
      ReferencePeripheral.emit(lost, min(step, target - lost.first), next_tick, c["seed"])

    boundary = ReferencePeripheral.fragmented(witness)
    true = boundary.boot == p.boot and boundary.sequence == lost.seq

    {lost,
     MedEx.CanonicalJSON.encode(%{
       "id" => "loss-" <> to_string(p.seq),
       "irreversible" => true,
       "cause" => "reference_buffer_exhausted",
       "first" => to_string(p.first),
       "end" => to_string(boundary.first_sample),
       "first_sequence" => to_string(p.seq),
       "next_sequence" => to_string(boundary.sequence)
     })}
  end

  def device_us(c, n),
    do:
      max(
        0,
        180_000 +
          div((System.system_time(:microsecond) - c["origin_us"]) * 1_000_000, 1_000_000 + ppm(n))
      )

  defp ppm("audio"), do: 35
  defp ppm("ecg"), do: -40

  def cursor(c, n),
    do:
      Spool.read_json(Path.join([c["spool"], n, "source.json"]), %{
        "sequence" => 0,
        "sample" => 0,
        "done" => false
      })

  @doc "Retain the actual verified local tail; a restarted physical source cannot establish continuous capture."
  def interrupt_after_restart(_config, spool, name, spec) do
    with :ok <- Spool.register(spool, spec),
         %{"sequence" => sequence, "sample" => sample, "done" => done} <-
           Spool.watermark(spool, name) do
      if done, do: :ok, else: Spool.finish_source(spool, name, sequence, sample, "source_reset")
    end
  end

  def upload(config, spool, admission, name, spec) do
    with {:ok, socket} <- Transport.connect(config, "stream") do
      try do
        fields = %{
          "binding" => admission["binding"],
          "lease" => admission["lease"],
          "acquisition" => admission["binding"]["acquisition"],
          "generation" => admission["binding"]["generation"],
          "stream" => name,
          "descriptor_ref" => spec.descriptor_ref,
          "max_credit_frames" => admission["credit_frames"],
          "max_credit_bytes" => admission["credit_bytes"]
        }

        authority = %{hub: config["hub"], control_binding: admission["binding"]}

        with {:ok, reply} <- Transport.request(socket, "open_stream", fields),
             :ok <- authority(authority),
             true <-
               is_map(reply["binding"]) and
                 Map.take(reply["binding"], ~w(acquisition profile generation)) ==
                   Map.take(admission["binding"], ~w(acquisition profile generation)),
             {:ok, receipt} <- Spool.activate(spool, name, spec, reply),
             {:ok, ledger} <-
               Credit.new(reply["binding"], reply["credit_frames"], reply["credit_bytes"]),
             {:ok, cursor} <- StreamCursor.new(spec) do
          stream = %{
            spool: spool,
            socket: socket,
            name: name,
            spec: spec,
            binding: reply["binding"],
            ledger: ledger,
            durable: receipt,
            cursor: %{
              cursor
              | next_sequence: receipt.durable_sequence,
                next_sample: receipt.durable_sample
            },
            hub: config["hub"],
            control_binding: admission["binding"],
            checkpoint: nil,
            checkpoint_at: System.monotonic_time(:millisecond),
            deadline: System.monotonic_time(:millisecond) + 1_800_000
          }

          try do
            if reply["type"] == "stream_finished",
              do: terminal(stream, reply),
              else: drain(stream)
          after
            Spool.invalidate(spool, reply["binding"])
          end
        end
      after
        Transport.close(socket)
      end
    end
  end

  defp drain(stream) do
    with :ok <- authority(stream),
         {:ok, stream} <- replies(stream, 31) do
      mark = Spool.watermark(stream.spool, stream.name)
      sent = {stream.cursor.next_sequence, stream.cursor.next_sample}
      produced = {mark["sequence"], mark["sample"]}

      cond do
        System.monotonic_time(:millisecond) >= stream.deadline ->
          {:error, :upload_deadline}

        ready_to_finish?(stream, mark, sent, produced) ->
          finish_upload(stream, mark)

        sent != produced ->
          drain_record(stream, mark)

        true ->
          wait_reply(stream, mark)
      end
    end
  end

  defp send_record(stream) do
    key = {stream.cursor.next_sequence, stream.cursor.next_sample}

    with {:ok, raw} <- Spool.get(stream.spool, stream.name, key),
         {:ok, metadata} <- Plan.record(raw, stream.spec),
         {:ok, next_cursor} <- Plan.advance(stream.cursor, metadata),
         {:ok, frame, charge} <- outbound_record(metadata, raw, stream.binding),
         operation = %{
           id: metadata.id,
           fingerprint: metadata.fingerprint,
           bytes: charge,
           sequence: next_cursor.next_sequence,
           sample: next_cursor.next_sample
         },
         {:ok, ledger, _} <- Credit.reserve(stream.ledger, stream.binding, operation),
         :ok <- authority(stream),
         :ok <- Transport.send_frame(stream.socket, frame) do
      {:ok, %{stream | ledger: ledger, cursor: next_cursor}}
    else
      :absent -> {:error, :missing_source_record}
      error -> error
    end
  end

  defp outbound_record(%{event: {:frame, _}}, raw, _), do: {:ok, {:binary, raw}, byte_size(raw)}

  defp outbound_record(%{gap: gap, id: id}, _raw, binding) do
    with {:ok, encoded} <-
           Control.encode("gap", Map.merge(gap, %{"binding" => binding, "operation_id" => id})) do
      {:ok, {:text, encoded}, byte_size(encoded)}
    end
  end

  defp wait_reply(stream, mark) do
    pending = Credit.stats(stream.ledger).outstanding_frames > 0

    checkpoint_due =
      pending and stream.checkpoint == nil and
        (mark["done"] or System.monotonic_time(:millisecond) - stream.checkpoint_at >= 200)

    timeout = if(pending, do: 250, else: 10)

    with {:ok, stream} <- if(checkpoint_due, do: request_checkpoint(stream), else: {:ok, stream}) do
      case Transport.recv(stream.socket, timeout) do
        {:error, :timeout} -> drain(stream)
        reply -> drain_reply(stream, reply)
      end
    end
  end

  defp request_checkpoint(stream) do
    operation = Transport.operation_id()

    with :ok <- authority(stream),
         :ok <-
           Transport.send_json(stream.socket, "checkpoint", %{
             "binding" => stream.binding,
             "operation_id" => operation
           }) do
      {:ok, %{stream | checkpoint: operation, checkpoint_at: System.monotonic_time(:millisecond)}}
    end
  end

  defp replies(stream, 0), do: {:ok, stream}

  defp replies(stream, budget) do
    case Transport.recv_nowait(stream.socket) do
      {:error, :timeout} -> {:ok, stream}
      reply -> with {:ok, next} <- handle_reply(stream, reply), do: replies(next, budget - 1)
    end
  end

  defp handle_reply(stream, {:ok, reply}) when is_map(reply) do
    cond do
      reply["binding"] != stream.binding ->
        {:ok, stream}

      authority(stream) != :ok ->
        {:error, :authority_expired}

      reply["type"] == "accepted" ->
        accept_reply(stream, reply)

      reply["type"] in ["durable", "stream_finished"] ->
        durable_response(stream, reply)

      reply["type"] == "refused" ->
        with {:ok, operation} <-
               Credit.lookup(stream.ledger, stream.binding, reply["operation_id"]),
             {:ok, _ledger} <-
               Credit.refuse(
                 stream.ledger,
                 stream.binding,
                 operation.id,
                 operation_fingerprint(reply, operation.id)
               ),
             do: {:error, :known_refusal}

      true ->
        {:error, :unexpected_reply}
    end
  end

  defp handle_reply(_, error), do: error

  defp operation_fingerprint(reply, "frame-" <> _), do: reply["transport_sha256"]
  defp operation_fingerprint(reply, "gap-" <> _), do: reply["fingerprint"]
  defp operation_fingerprint(_, _), do: nil

  defp receipt_operation?(stream, operation) do
    operation == stream.checkpoint or
      match?({:ok, _}, Credit.lookup(stream.ledger, stream.binding, operation)) or
      (is_binary(operation) and byte_size(operation) <= 96 and
         Regex.match?(~r/\Acheckpoint-[A-Za-z0-9_-]+\z/, operation))
  end

  defp finish_upload(stream, mark) do
    with true <-
           {stream.durable.durable_sequence, stream.durable.durable_sample} ==
             {mark["sequence"], mark["sample"]},
         :ok <- authority(stream),
         {:ok, reply} <-
           Transport.request(
             stream.socket,
             "finish",
             %{
               "binding" => stream.binding,
               "sequence" => to_string(mark["sequence"]),
               "sample" => to_string(mark["sample"]),
               "interruption" => mark["interruption"]
             },
             35_000
           ),
         true <- reply["binding"] == stream.binding,
         :ok <- authority(stream),
         :ok <- Spool.ack(stream.spool, stream.name, stream.binding, reply["receipt"]) do
      terminal(stream, reply)
    else
      false -> {:error, :incomplete_source_drain}
      error -> error
    end
  end

  defp terminal(stream, reply) do
    mark = Spool.watermark(stream.spool, stream.name)

    with true <-
           reply["type"] == "stream_finished" and
             MedEx.ContractRules.digest?(reply["index_digest"]),
         {:ok, receipt} <- Receipt.parse(reply["receipt"]),
         true <- Receipt.durable?(receipt),
         true <-
           mark["done"] and
             {receipt.durable_sequence, receipt.durable_sample} ==
               {mark["sequence"], mark["sample"]} do
      :ok
    else
      _ -> {:interrupted, :premature_terminal}
    end
  end

  defp authority(stream) do
    now = System.monotonic_time(:millisecond)
    expected_binding = stream.control_binding

    case :ets.lookup(stream.hub, :authority) do
      [{:authority, ^expected_binding, deadline}] when is_integer(deadline) ->
        if now < deadline, do: :ok, else: {:error, :authority_expired}

      _ ->
        {:error, :authority_expired}
    end
  rescue
    ArgumentError -> {:error, :authority_expired}
  end

  defp drain_record(stream, mark) do
    case send_record(stream) do
      {:ok, next} ->
        drain(next)

      {:error, :credit_exhausted} ->
        if Credit.stats(stream.ledger).outstanding_frames == 0,
          do: {:error, :insufficient_negotiated_credit},
          else: wait_reply(stream, mark)

      error ->
        error
    end
  end

  defp ready_to_finish?(stream, mark, sent, produced),
    do: sent == produced and mark["done"] and Credit.stats(stream.ledger).outstanding_frames == 0

  defp drain_reply(stream, reply) do
    with {:ok, next} <- handle_reply(stream, reply), do: drain(next)
  end

  defp accept_reply(stream, reply) do
    with {:ok, operation} <-
           Credit.lookup(stream.ledger, stream.binding, reply["operation_id"]),
         true <- operation_fingerprint(reply, operation.id) == operation.fingerprint,
         {:ok, accepted} <- Receipt.parse(reply["receipt"]),
         :ok <- Receipt.validate_identity(accepted, stream.durable),
         true <-
           accepted.accepted_sequence >= operation.sequence and
             accepted.accepted_sample >= operation.sample,
         true <-
           accepted.accepted_sequence <= stream.cursor.next_sequence and
             accepted.accepted_sample <= stream.cursor.next_sample do
      {:ok, stream}
    else
      false -> {:error, :invalid_acceptance}
      error -> error
    end
  end

  defp advance_durable_reply(stream, reply, receipt, ledger) do
    next = %{
      stream
      | durable: receipt,
        ledger: ledger,
        checkpoint:
          if(
            reply["operation_id"] == stream.checkpoint or
              Credit.stats(ledger).outstanding_frames == 0,
            do: nil,
            else: stream.checkpoint
          )
    }

    if reply["type"] == "stream_finished",
      do: {:interrupted, :premature_terminal},
      else: {:ok, next}
  end

  defp durable_response(stream, reply) do
    with {:ok, receipt} <- Receipt.parse(reply["receipt"]),
         true <-
           receipt_operation?(stream, reply["operation_id"]) or
             Receipt.exact_prefix?(stream.durable, receipt),
         true <-
           receipt.durable_sequence <= stream.cursor.next_sequence and
             receipt.durable_sample <= stream.cursor.next_sample,
         :ok <- Spool.ack(stream.spool, stream.name, stream.binding, receipt),
         {:ok, ledger, _released} <-
           Credit.acknowledge(stream.ledger, stream.binding, receipt) do
      advance_durable_reply(stream, reply, receipt, ledger)
    else
      false -> {:error, :uncovered_receipt}
      error -> error
    end
  end
end
