defmodule MedExHandheld.ReferencePeripheral do
  @moduledoc "RDP1 fixture instrument with its own counters, command cache and bounded packet retention."
  alias MedExHandheld.RDP1

  def new(source, boot, variant \\ false) do
    audio = source == 1

    caps = %{
      "protocol" => "RDP1",
      "source" => if(audio, do: "audio", else: "ecg"),
      "encoding" => if(variant, do: "s24le", else: "s16le"),
      "channels" => if(variant, do: 2, else: 1),
      "sample_rate" => if(variant, do: [30000, 1001], else: [if(audio, do: 48000, else: 250), 1]),
      "tick_rate" => 48_000_000,
      "calibration" => if(audio, do: "unknown", else: "synthetic_adc_1uV"),
      "replay_capacity_frames" => 16
    }

    %{
      source: source,
      boot: boot,
      caps: caps,
      seq: 0,
      first: 0,
      running: false,
      history: %{},
      commands: %{}
    }
  end

  def request(p, bytes) do
    with {:ok, <<>>,
          [
            %{
              kind: 16,
              source: source,
              boot: boot,
              body:
                %{"schema" => "rdp1.control.v1", "request_id" => id, "op" => op, "args" => args} =
                  body
            }
          ]} <- RDP1.decode(<<>>, bytes),
         true <- source == p.source and is_binary(id) and byte_size(id) in 1..96 and is_map(args) do
      case p.commands[id] do
        {^body, resp} ->
          {p, resp}

        nil when map_size(p.commands) < 4096 ->
          {p, status, res, extra} =
            if boot == p.boot or (boot == 0 and op == "capabilities"),
              do: operation(p, op, args),
              else: {p, "error", "wrong_boot", []}

          reply = answer(p, id, status, res) ++ extra
          {%{p | commands: Map.put(p.commands, id, {body, reply})}, reply}

        nil ->
          {p, answer(p, id, "error", "command_cache_full")}

        _ ->
          {p, answer(p, id, "error", "request_conflict")}
      end
    else
      _ -> {:error, :invalid_request}
    end
  end

  defp answer(p, id, status, res) do
    body = %{
      "request_id" => id,
      "status" => status,
      if(status == "ok", do: "result", else: "error") => res
    }

    [RDP1.packet(17, p.source, p.boot, 0, 0, 0, 0, JSON.encode!(body))]
  end

  defp operation(p, "capabilities", _), do: {p, "ok", p.caps, []}

  defp operation(p, "start", %{"profile" => "reference", "acquisition" => a})
       when is_binary(a) and not p.running,
       do: {%{p | running: true}, "ok", state(%{p | running: true}), []}

  defp operation(p, "stop", _),
    do: {%{p | running: false}, "ok", state(%{p | running: false}), []}

  defp operation(p, "state", _), do: {p, "ok", state(p), []}

  defp operation(p, "replay", %{"first" => a, "next" => b})
       when is_integer(a) and is_integer(b) and a >= 0 and b > a and b - a <= 16 do
    packets = Enum.map(a..(b - 1), &p.history[&1])

    if Enum.all?(packets, &is_binary/1),
      do: {p, "ok", %{"state" => "available"}, packets},
      else: {p, "ok", %{"state" => "unavailable", "oldest" => max(p.seq - 16, 0)}, []}
  end

  defp operation(p, _, _), do: {p, "error", "unsupported_or_busy", []}

  defp state(p),
    do: %{
      "boot" => to_string(p.boot),
      "running" => p.running,
      "sequence" => to_string(p.seq),
      "sample" => to_string(p.first),
      "config_epoch" => "0",
      "oldest" => max(p.seq - 16, 0)
    }

  def emit(%{running: true} = p, count, tick, seed) when p.seq < 0xFFFFFFFF do
    bits = if p.caps["encoding"] == "s24le", do: 24, else: 16

    pcm =
      for index <- p.first..(p.first + count - 1), channel <- 1..p.caps["channels"], into: <<>> do
        raw = rem(index * 37 + seed * 17 + channel * 13 + p.source * 101, 65536) - 32768
        <<raw::little-signed-size(bits)>>
      end

    packet =
      RDP1.packet(1, p.source, p.boot, p.seq, p.first, count, 0, <<tick::little-64, pcm::binary>>)

    history = p.history |> Map.put(p.seq, packet) |> Map.delete(p.seq - 16)
    {%{p | first: p.first + count, seq: p.seq + 1, history: history}, packet}
  end

  def emit(_, _, _, _), do: {:error, :counter_exhausted}

  def transact(p, op, args \\ %{}) do
    id = Base.url_encode64(:crypto.strong_rand_bytes(12))

    req =
      RDP1.packet(
        16,
        p.source,
        if(op == "capabilities", do: 0, else: p.boot),
        0,
        0,
        0,
        0,
        JSON.encode!(%{
          "schema" => "rdp1.control.v1",
          "request_id" => id,
          "op" => op,
          "args" => args
        })
      )

    {next, [reply | extra]} = request(p, req)
    %{body: %{"status" => "ok", "result" => res}} = fragmented(reply)
    {next, res, extra}
  end

  def fragmented(packet) do
    <<a::binary-size(5), b::binary-size(19), c::binary>> = packet
    {:ok, r, []} = RDP1.decode(<<>>, a)
    {:ok, r, []} = RDP1.decode(r, b)
    {:ok, <<>>, [v]} = RDP1.decode(r, c)
    v
  end
end
