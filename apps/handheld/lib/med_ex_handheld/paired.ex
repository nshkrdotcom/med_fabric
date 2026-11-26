defmodule MedExHandheld.Paired do
  unless Code.ensure_loaded?(MedEx.Wire.FrameV1),
    do: raise("Select the MedEx stream-v1 source checkout in .mix_sources.json")

  @moduledoc "Reference peripheral acquisition runs independently of server connectivity."
  alias MedEx.{Serialization, StreamSpec}
  alias MedEx.Wire.FrameV1
  alias MedExHandheld.{ReferencePeripheral, Spool, Transport}

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
        boot_id: "rdp-" <> to_string(p.boot),
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
    stop = Agent.get(hub, & &1.stop)
    reset = source_reset?(c, name, peripheral)

    if peripheral.first >= target or stop or reset do
      stop_source(source, peripheral, pending, reset)
    else
      capture_frame(source, peripheral, target, pending)
    end
  end

  defp stop_source(%{config: c, spool: spool, name: name} = source, peripheral, pending, reset) do
    case flush_pending(c, spool, name, pending) do
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
    Agent.update(hub, &Map.put(&1, :stop, true))
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
    %{config: c, monitor: monitor, hub: hub, name: name, spec: spec} = source
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

    if not gap and {name, spec.encoding} == {"audio", :s16le} do
      publish_monitor_frame(c, monitor, hub, frame)
    end

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

  defp flush_frames(%{config: c, spool: spool, name: name} = source, next, pending, persist) do
    case flush_pending(c, spool, name, pending) do
      :ok ->
        if persist, do: :ok = Spool.persist_watermark(spool, name)
        loop(source, next, [])

      {:error, :spool_full} ->
        stop_on_full_spool(source)
    end
  end

  defp flush_pending(_c, _spool, _n, []), do: :ok

  defp flush_pending(c, spool, n, pending) do
    Spool.put_batch_and_advance(spool, c["spool"], n, Enum.reverse(pending))
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
     JSON.encode!(%{
       "id" => "loss-" <> to_string(p.seq),
       "irreversible" => true,
       "cause" => "reference_buffer_exhausted",
       "first" => to_string(p.first),
       "end" => to_string(boundary.first_sample),
       "first_sequence" => to_string(p.seq),
       "next_sequence" => to_string(boundary.sequence)
     })}
  end

  defp publish_monitor_frame(c, monitor, hub, frame) do
    {epoch, pcm} = GenServer.call(monitor, {:frame, frame.first_sample, frame.payload})

    trace_monitor(c, frame, epoch, pcm)

    {:ok, derived} =
      FrameV1.encode(%{
        frame
        | stream_number: 3,
          config_epoch: String.to_integer(epoch),
          payload: pcm
      })

    Agent.update(
      hub,
      &Map.put(&1, :latest, {System.monotonic_time(:millisecond), derived})
    )
  end

  defp trace_monitor(c, frame, epoch, pcm) do
    if c["trace_monitor"] do
      trace = %{
        "first" => frame.first_sample,
        "count" => frame.sample_count,
        "epoch" => epoch,
        "sha256" => Serialization.sha256(pcm)
      }

      File.write!(
        Path.join(c["spool"], "monitor-truth.jsonl"),
        [JSON.encode!(trace), "\n"],
        [:append]
      )
    end
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

  @doc "Recover only synchronized local bytes after a device VM restart; never regenerate an unobserved acquisition interval."
  def interrupt_after_restart(c, spool, n, spec) do
    saved = cursor(c, n)

    unless is_integer(saved["sequence"]) and saved["sequence"] >= 0 and
             is_integer(saved["sample"]) and saved["sample"] >= 0 and is_boolean(saved["done"]),
           do: raise("invalid persisted source cursor")

    unless saved["done"] do
      {base_seq, base_sample} = recovery_base(c, n, spec, saved)
      {sequence, sample} = recover_local_tail(spool, n, spec, base_seq, base_sample)
      :ok = Spool.finish_source(spool, n, sequence, sample, "source_reset")
    end

    :ok
  end

  defp recovery_base(c, n, spec, saved) do
    case Spool.read_json(Path.join([c["spool"], n, "receipt.json"]), nil) do
      nil ->
        {saved["sequence"], saved["sample"]}

      wire ->
        receipt_cursor(wire, spec, saved)
    end
  end

  defp receipt_cursor(wire, spec, saved) do
    with {:ok, r} <- Serialization.receipt(wire),
         true <- comparable_receipt?(r, spec) do
      recovery_cursor(r, saved)
    else
      _ -> raise "invalid persisted receipt"
    end
  end

  defp comparable_receipt?(r, spec) do
    r.stream_id == spec.stream_id and r.source_epoch == spec.source_epoch and
      r.descriptor_ref == spec.descriptor_ref and r.accepted_sequence == r.durable_sequence and
      r.accepted_sample == r.durable_sample
  end

  defp recovery_cursor(receipt, %{"sequence" => sequence, "sample" => sample}) do
    cond do
      receipt.durable_sequence > sequence and receipt.durable_sample >= sample ->
        {receipt.durable_sequence, receipt.durable_sample}

      receipt.durable_sequence == sequence and receipt.durable_sample == sample ->
        {sequence, sample}

      receipt.durable_sequence < sequence and receipt.durable_sample <= sample ->
        {sequence, sample}

      true ->
        raise "persisted receipt conflicts with source cursor"
    end
  end

  defp recover_local_tail(spool, n, spec, sequence, sample) do
    case Spool.get(spool, n, sequence) do
      :absent ->
        {sequence, sample}

      {:ok, wire} ->
        {next, right} = advance_source_tail(wire, n, spec, sequence, sample)
        recover_local_tail(spool, n, spec, next, right)
    end
  end

  defp advance_source_tail(<<"MEX1", _::binary>> = wire, n, spec, sequence, sample) do
    number = if n == "audio", do: 1, else: 2

    with {:ok, f} <- FrameV1.decode(wire),
         true <-
           {f.stream_number, f.source_epoch, f.sequence, f.first_sample} ==
             {number, spec.source_epoch, sequence, sample},
         true <- f.sample_count <= spec.capabilities.max_frame_samples,
         true <-
           byte_size(f.payload) ==
             f.sample_count * length(spec.channels) * StreamSpec.bytes_per_value(spec.encoding) do
      {sequence + 1, sample + f.sample_count}
    else
      _ -> raise "invalid durable source tail"
    end
  end

  defp advance_source_tail(wire, _, _, sequence, sample),
    do: gap_endpoint(JSON.decode!(wire), sequence, sample)

  defp gap_endpoint(gap, sequence, sample) do
    first = to_string(sample)
    first_sequence = to_string(sequence)

    with %{
           "irreversible" => true,
           "first" => ^first,
           "end" => ending,
           "first_sequence" => ^first_sequence,
           "next_sequence" => next_sequence
         } <- gap,
         {next, ""} <- Integer.parse(next_sequence),
         {right, ""} <- Integer.parse(ending),
         true <- next > sequence and right > sample do
      {next, right}
    else
      _ -> raise "invalid durable source gap"
    end
  end

  def upload(c, spool, b, n, spec) do
    credit =
      case b["credit_frames"] do
        v when is_integer(v) and v in 1..15 -> v
        _ -> 1
      end

    {:ok, s} = Transport.connect(c, "stream")

    try do
      {:ok, r} =
        Transport.request(
          s,
          "open_stream",
          Map.merge(b, %{
            "stream" => n,
            "descriptor_ref" => spec.descriptor_ref,
            "credit_frames" => credit
          })
        )

      true = r["type"] in ["durable", "stream_finished"]
      gen = String.to_integer(b["generation"])
      :ok = Spool.activate(spool, n, gen, spec, r)
      :ok = Spool.ack(spool, n, gen, r)

      stream = %{spool: spool, socket: s, name: n, generation: gen, credit: credit}
      continue_upload(r, stream)
    after
      Transport.close(s)
    end
  end

  defp continue_upload(%{"type" => "stream_finished"} = receipt, %{spool: spool, name: name}) do
    state = Spool.watermark(spool, name)

    if state["done"] and receipt["durable_sequence"] == to_string(state["sequence"]) and
         receipt["durable_sample"] == to_string(state["sample"]),
       do: :ok,
       else: {:interrupted, :premature_terminal}
  end

  defp continue_upload(%{"type" => "durable", "durable_sequence" => sequence}, stream) do
    durable_seq = String.to_integer(sequence)
    drain(stream, durable_seq, durable_seq, [])
  end

  defp drain(stream, durable_seq, sent_seq, in_flight) do
    %{spool: spool, socket: socket, name: name, generation: generation} = stream

    case drain_replies(spool, socket, name, generation, durable_seq, in_flight) do
      {:interrupted, :premature_terminal} ->
        {:interrupted, :premature_terminal}

      {:ok, durable_seq, in_flight} ->
        watermark = Spool.watermark(spool, name)
        step_drain(stream, durable_seq, sent_seq, in_flight, watermark)
    end
  end

  defp step_drain(stream, durable_seq, sent_seq, in_flight, watermark) do
    cond do
      durable_seq > watermark["sequence"] ->
        raise "remote receipt exceeds stored source watermark"

      sent_seq < watermark["sequence"] and length(in_flight) < stream.credit ->
        next_sequence = send_spooled(stream, sent_seq)
        drain(stream, durable_seq, next_sequence, in_flight ++ [{sent_seq, next_sequence}])

      in_flight != [] ->
        wait_for_drain_reply(stream, durable_seq, sent_seq, in_flight, watermark["done"])

      sent_seq == watermark["sequence"] and watermark["done"] ->
        true = durable_seq == sent_seq
        finish_upload(stream.socket, durable_seq, watermark)

      sent_seq == watermark["sequence"] ->
        Process.sleep(10)
        drain(stream, durable_seq, sent_seq, in_flight)

      true ->
        raise "remote receipt exceeds stored source watermark"
    end
  end

  defp send_spooled(%{spool: spool, socket: socket, name: name}, sequence) do
    {:ok, raw} = Spool.get(spool, name, sequence)

    if String.starts_with?(raw, "MEX1") do
      :ok = Transport.send_frame(socket, {:binary, raw})
      sequence + 1
    else
      gap = JSON.decode!(raw)
      {next, _sample} = gap_endpoint(gap, sequence, String.to_integer(gap["first"]))
      :ok = Transport.send_json(socket, "gap", gap)
      next
    end
  end

  defp wait_for_drain_reply(stream, durable_seq, sent_seq, in_flight, source_done) do
    %{spool: spool, socket: socket, name: name, generation: generation, credit: credit} = stream
    wait_ms = if length(in_flight) >= credit or source_done, do: 35_000, else: 10

    case Transport.recv(socket, wait_ms) do
      {:error, :timeout} when wait_ms < 35_000 ->
        drain(stream, durable_seq, sent_seq, in_flight)

      reply ->
        with {:ok, durable_seq, in_flight} <-
               handle_reply(spool, name, generation, durable_seq, in_flight, reply) do
          drain(stream, durable_seq, sent_seq, in_flight)
        end
    end
  end

  defp finish_upload(socket, durable_seq, watermark) do
    {:ok, %{"type" => "stream_finished"}} =
      Transport.request(
        socket,
        "finish",
        %{
          "sequence" => to_string(durable_seq),
          "sample" => to_string(watermark["sample"]),
          "interruption" => watermark["interruption"]
        },
        35_000
      )

    :ok
  end

  defp drain_replies(spool, s, n, gen, durable_seq, in_flight) do
    case Transport.recv_nowait(s) do
      {:error, :timeout} ->
        {:ok, durable_seq, in_flight}

      reply ->
        case handle_reply(spool, n, gen, durable_seq, in_flight, reply) do
          {:interrupted, :premature_terminal} ->
            {:interrupted, :premature_terminal}

          {:ok, next_durable, next_in_flight} ->
            drain_replies(spool, s, n, gen, next_durable, next_in_flight)
        end
    end
  end

  defp handle_reply(spool, n, gen, durable_seq, in_flight, reply) do
    case reply do
      {:ok, %{"type" => "accepted"}} ->
        {:ok, durable_seq, in_flight}

      {:ok, %{"type" => "durable"} = r} ->
        next_durable = String.to_integer(r["durable_sequence"])

        true =
          next_durable == durable_seq or Enum.any?(in_flight, fn {_, q} -> q == next_durable end)

        :ok = Spool.ack(spool, n, gen, r)
        remaining = Enum.drop_while(in_flight, fn {_q, next_q} -> next_q <= next_durable end)
        {:ok, next_durable, remaining}

      {:ok, %{"type" => "stream_finished"} = r} ->
        :ok = Spool.ack(spool, n, gen, r)
        {:interrupted, :premature_terminal}

      other ->
        raise MatchError, term: other
    end
  end
end
