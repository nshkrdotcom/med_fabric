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
      loop(c, spool, monitor, hub, n, p, spec)
    end
  end

  defp loop(c, spool, monitor, hub, n, p, spec) do
    {rn, rd} = spec.sample_rate
    target = div((c["seconds"] || 60) * rn, rd)
    stop = Agent.get(hub, & &1.stop)

    reset = source_reset?(c, n, p)

    if p.first >= target or stop or reset do
      {_, res, []} = ReferencePeripheral.transact(p, "stop")

      :ok =
        Spool.finish_source(
          spool,
          n,
          String.to_integer(res["sequence"]),
          String.to_integer(res["sample"]),
          if(reset, do: "source_reset", else: nil)
        )
    else
      capture_frame(c, spool, monitor, hub, n, p, spec, target)
    end
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

  defp capture_frame(c, spool, monitor, hub, n, p, spec, target) do
    {rn, rd} = spec.sample_rate
    wait_for_sample(c, n, p.first, spec.sample_rate)
    step = frame_step(c, n)
    gap = n == "audio" and c["gap"] in [true, 3] and p.seq == 2
    count = min(if(gap, do: 100, else: step), target - p.first)
    tick = 8_640_000 + div(p.first * 48_000_000 * rd, rn)
    {next, packet} = ReferencePeripheral.emit(p, count, tick, c["seed"])
    frame = decode_frame(p, packet, count)
    {:ok, raw} = FrameV1.encode(frame)

    {next, record} =
      if gap, do: lost_frame(c, p, next, step, target, spec.sample_rate), else: {next, raw}

    case Spool.put_and_advance(spool, c["spool"], n, p.seq, record, next.seq, next.first) do
      :ok ->
        if not gap and {n, spec.encoding} == {"audio", :s16le} do
          publish_monitor_frame(c, monitor, hub, frame)
        end

        persist_stride = if n == "audio", do: 50, else: 10

        if rem(next.seq, persist_stride) == 0 do
          :ok = Spool.persist_watermark(spool, n)
        end

        loop(c, spool, monitor, hub, n, next, spec)

      {:error, :spool_full} ->
        Agent.update(hub, &Map.put(&1, :stop, true))
        :ok = Spool.finish_source(spool, n, p.seq, p.first, "spool_full")
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
        with {:ok, r} <- Serialization.receipt(wire),
             true <-
               r.stream_id == spec.stream_id and r.source_epoch == spec.source_epoch and
                 r.descriptor_ref == spec.descriptor_ref and
                 r.accepted_sequence == r.durable_sequence and
                 r.accepted_sample == r.durable_sample do
          cond do
            r.durable_sequence > saved["sequence"] and r.durable_sample >= saved["sample"] ->
              {r.durable_sequence, r.durable_sample}

            r.durable_sequence == saved["sequence"] and r.durable_sample == saved["sample"] ->
              {saved["sequence"], saved["sample"]}

            r.durable_sequence < saved["sequence"] and r.durable_sample <= saved["sample"] ->
              {saved["sequence"], saved["sample"]}

            true ->
              raise "persisted receipt conflicts with source cursor"
          end
        else
          _ -> raise "invalid persisted receipt"
        end
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

      cond do
        r["type"] == "stream_finished" ->
          state = Spool.watermark(spool, n)

          if state["done"] and r["durable_sequence"] == to_string(state["sequence"]) and
               r["durable_sample"] == to_string(state["sample"]),
             do: :ok,
             else: {:interrupted, :premature_terminal}

        r["type"] == "durable" ->
          durable_seq = String.to_integer(r["durable_sequence"])
          drain(c, spool, s, n, gen, credit, durable_seq, durable_seq, [])
      end
    after
      Transport.close(s)
    end
  end

  defp drain(c, spool, s, n, gen, credit, durable_seq, sent_seq, in_flight) do
    case drain_replies(spool, s, n, gen, durable_seq, in_flight) do
      {:interrupted, :premature_terminal} ->
        {:interrupted, :premature_terminal}

      {:ok, durable_seq, in_flight} ->
        state = Spool.watermark(spool, n)
        step_drain(c, spool, s, n, gen, credit, durable_seq, sent_seq, in_flight, state)
    end
  end

  defp step_drain(c, spool, s, n, gen, credit, durable_seq, sent_seq, in_flight, state) do
    cond do
      durable_seq > state["sequence"] ->
        raise "remote receipt exceeds stored source watermark"

      sent_seq < state["sequence"] and length(in_flight) < credit ->
        {:ok, raw} = Spool.get(spool, n, sent_seq)

        next_sequence =
          if String.starts_with?(raw, "MEX1") do
            :ok = Transport.send_frame(s, {:binary, raw})
            sent_seq + 1
          else
            gap = JSON.decode!(raw)
            {next, _sample} = gap_endpoint(gap, sent_seq, String.to_integer(gap["first"]))
            :ok = Transport.send_json(s, "gap", gap)
            next
          end

        drain(
          c,
          spool,
          s,
          n,
          gen,
          credit,
          durable_seq,
          next_sequence,
          in_flight ++ [{sent_seq, next_sequence}]
        )

      in_flight != [] ->
        wait_ms = if length(in_flight) >= credit or state["done"], do: 35_000, else: 10

        case Transport.recv(s, wait_ms) do
          {:error, :timeout} when wait_ms < 35_000 ->
            drain(c, spool, s, n, gen, credit, durable_seq, sent_seq, in_flight)

          reply ->
            case handle_reply(spool, n, gen, durable_seq, in_flight, reply) do
              {:interrupted, :premature_terminal} ->
                {:interrupted, :premature_terminal}

              {:ok, durable_seq, in_flight} ->
                drain(c, spool, s, n, gen, credit, durable_seq, sent_seq, in_flight)
            end
        end

      sent_seq == state["sequence"] and state["done"] ->
        true = durable_seq == sent_seq

        {:ok, %{"type" => "stream_finished"}} =
          Transport.request(
            s,
            "finish",
            %{
              "sequence" => to_string(durable_seq),
              "sample" => to_string(state["sample"]),
              "interruption" => state["interruption"]
            },
            35_000
          )

        :ok

      sent_seq == state["sequence"] ->
        Process.sleep(10)
        drain(c, spool, s, n, gen, credit, durable_seq, sent_seq, in_flight)

      true ->
        raise "remote receipt exceeds stored source watermark"
    end
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
