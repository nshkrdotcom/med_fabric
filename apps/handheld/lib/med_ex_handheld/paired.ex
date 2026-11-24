defmodule MedExHandheld.Paired do
  unless Code.ensure_loaded?(MedEx.Wire.FrameV1),
    do: raise("Select the MedEx stream-v1 source checkout in .mix_sources.json")

  @moduledoc "Reference peripheral acquisition runs independently of server connectivity."
  alias MedExHandheld.{ReferencePeripheral, Spool, Transport}
  alias MedEx.{StreamSpec, Serialization}
  alias MedEx.Wire.FrameV1

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

    reset =
      if c["reset"] == true and n == "ecg" and p.seq == 3 do
        rebooted = ReferencePeripheral.new(p.source, p.boot + 1)
        {_, discovery, []} = ReferencePeripheral.transact(rebooted, "state")
        discovery["boot"] != to_string(p.boot) and discovery["sequence"] == "0"
      else
        false
      end

    if p.first >= target or stop or reset do
      {_, res, []} = ReferencePeripheral.transact(p, "stop")

      save_cursor(c, n, %{
        "sequence" => String.to_integer(res["sequence"]),
        "sample" => String.to_integer(res["sample"]),
        "done" => true,
        "interruption" => if(reset, do: "source_reset", else: nil)
      })
    else
      delta = div(p.first * 1_000_000 * rd, rn)

      # The fixture oscillator has an explicit origin, fixed rate perturbation and acquisition ticks.
      planned = c["origin_us"] + div(delta * (1_000_000 + ppm(n)), 1_000_000)
      delay = planned - System.system_time(:microsecond)
      if delay > 0, do: Process.sleep(div(delay, 1000))

      step =
        cond do
          c["variant"] -> 4
          n == "audio" -> 960
          true -> 25
        end

      gap = n == "audio" and c["gap"] == true and p.seq == 2
      count = min(if(gap, do: 100, else: step), target - p.first)
      tick = 8_640_000 + div(p.first * 48_000_000 * rd, rn)
      {next, packet} = ReferencePeripheral.emit(p, count, tick, c["seed"])
      event = ReferencePeripheral.fragmented(packet)

      true =
        event.boot == p.boot and event.source == p.source and event.sequence == p.seq and
          event.sample_count == count and event.first_sample == p.first

      frame = %FrameV1{
        stream_number: p.source,
        source_epoch: 0,
        config_epoch: event.config_epoch,
        sequence: event.sequence,
        first_sample: event.first_sample,
        sample_count: count,
        payload: event.payload
      }

      {:ok, raw} = FrameV1.encode(frame)

      {next, record} =
        if gap do
          # Evict the missing source packet, request its original bytes, then use
          # the next CRC-verified hardware counter to establish the right boundary.
          lost = %{next | history: Map.delete(next.history, p.seq)}

          {lost, %{"state" => "unavailable"}, []} =
            ReferencePeripheral.transact(lost, "replay", %{"first" => p.seq, "next" => p.seq + 1})

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
        else
          {next, raw}
        end

      case Spool.put(spool, n, p.seq, record) do
        :ok ->
          if n == "audio" and spec.encoding == :s16le and not gap do
            {epoch, pcm} = GenServer.call(monitor, {:frame, p.first, event.payload})

            if c["trace_monitor"] do
              trace = %{
                "first" => p.first,
                "count" => count,
                "epoch" => epoch,
                "sha256" => Serialization.sha256(pcm)
              }

              File.write!(
                Path.join(c["spool"], "monitor-truth.jsonl"),
                [JSON.encode!(trace), "\n"],
                [:append]
              )
            end

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

          save_cursor(c, n, %{"sequence" => next.seq, "sample" => next.first, "done" => false})
          loop(c, spool, monitor, hub, n, next, spec)

        {:error, :spool_full} ->
          Agent.update(hub, &Map.put(&1, :stop, true))

          save_cursor(c, n, %{
            "sequence" => p.seq,
            "sample" => p.first,
            "done" => true,
            "interruption" => "spool_full"
          })
      end
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

  defp save_cursor(c, n, map),
    do: Spool.write!(Path.join([c["spool"], n, "source.json"]), JSON.encode!(map))

  @doc "Recover only synchronized local bytes after a device VM restart; never regenerate an unobserved acquisition interval."
  def interrupt_after_restart(c, spool, n, spec) do
    saved = cursor(c, n)

    unless is_integer(saved["sequence"]) and saved["sequence"] >= 0 and
             is_integer(saved["sample"]) and saved["sample"] >= 0 and is_boolean(saved["done"]),
           do: raise("invalid persisted source cursor")

    unless saved["done"] do
      {sequence, sample} = recover_local_tail(spool, n, spec, saved["sequence"], saved["sample"])

      save_cursor(c, n, %{
        "sequence" => sequence,
        "sample" => sample,
        "done" => true,
        "interruption" => "source_reset"
      })
    end

    :ok
  end

  defp recover_local_tail(spool, n, spec, sequence, sample) do
    case Spool.get(spool, n, sequence) do
      :absent ->
        {sequence, sample}

      {:ok, <<"MEX1", _::binary>> = wire} ->
        number = if n == "audio", do: 1, else: 2

        with {:ok, f} <- FrameV1.decode(wire),
             true <-
               f.stream_number == number and f.source_epoch == spec.source_epoch and
                 f.sequence == sequence and f.first_sample == sample and
                 f.sample_count <= spec.capabilities.max_frame_samples and
                 byte_size(f.payload) ==
                   f.sample_count * length(spec.channels) *
                     StreamSpec.bytes_per_value(spec.encoding) do
          recover_local_tail(spool, n, spec, sequence + 1, sample + f.sample_count)
        else
          _ -> raise "invalid durable source tail"
        end

      {:ok, wire} ->
        with {:ok,
              %{
                "irreversible" => true,
                "first" => a,
                "end" => b,
                "first_sequence" => q,
                "next_sequence" => r
              }} <- JSON.decode(wire),
             true <- a == to_string(sample) and q == to_string(sequence),
             {next, ""} <- Integer.parse(r),
             {right, ""} <- Integer.parse(b),
             true <- next > sequence and right > sample do
          recover_local_tail(spool, n, spec, next, right)
        else
          _ -> raise "invalid durable source gap"
        end
    end
  end

  def upload(c, spool, b, n, spec) do
    {:ok, s} = Transport.connect(c, "stream")

    try do
      {:ok, r} =
        Transport.request(
          s,
          "open_stream",
          Map.merge(b, %{"stream" => n, "descriptor_ref" => spec.descriptor_ref})
        )

      true = r["type"] in ["durable", "stream_finished"]
      gen = String.to_integer(b["generation"])
      :ok = Spool.activate(spool, n, gen, spec, r)
      :ok = Spool.ack(spool, n, gen, r)

      cond do
        r["type"] == "stream_finished" ->
          :ok

        r["type"] == "durable" ->
          drain(c, spool, s, n, gen, String.to_integer(r["durable_sequence"]))
      end
    after
      Transport.close(s)
    end
  end

  defp drain(c, spool, s, n, gen, q) do
    state = cursor(c, n)

    cond do
      q < state["sequence"] ->
        {:ok, raw} = Spool.get(spool, n, q)

        if String.starts_with?(raw, "MEX1"),
          do: Transport.send_frame(s, {:binary, raw}),
          else: Transport.send_json(s, "gap", JSON.decode!(raw))

        {:ok, %{"type" => "accepted"}} = Transport.recv(s)
        {:ok, %{"type" => "durable"} = r} = Transport.recv(s, 35_000)
        true = String.to_integer(r["durable_sequence"]) == q + 1
        :ok = Spool.ack(spool, n, gen, r)
        drain(c, spool, s, n, gen, q + 1)

      q == state["sequence"] and state["done"] ->
        {:ok, %{"type" => "stream_finished"}} =
          Transport.request(s, "finish", %{
            "sequence" => to_string(q),
            "sample" => to_string(state["sample"]),
            "interruption" => state["interruption"]
          })

        :ok

      q == state["sequence"] ->
        Process.sleep(10)
        drain(c, spool, s, n, gen, q)

      true ->
        raise "remote receipt exceeds stored source watermark"
    end
  end
end
