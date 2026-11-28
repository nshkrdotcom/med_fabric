defmodule MedFabric.Handheld.SourceAdapter do
  @moduledoc "Contract for incremental source decoders."
  @callback decode(binary(), binary()) :: {:ok, binary(), [map()]} | {:error, atom(), binary()}
end

defmodule MedFabric.Handheld.RDP1 do
  @moduledoc "Bounded incremental decoder of the little-endian synthetic peripheral byte stream."
  @behaviour MedFabric.Handheld.SourceAdapter
  def packet(kind, source, boot, seq, first, count, config, payload)
      when byte_size(payload) <= 2012 do
    body =
      <<0xA5, 0x5A, 1, kind, source, 0, byte_size(payload)::little-16, boot::little-64,
        seq::little-32, first::little-64, count::little-16, config::little-16, payload::binary>>

    <<body::binary, :erlang.crc32(body)::little-32>>
  end

  def decode(buffer, bytes) when byte_size(buffer) <= 2048 and byte_size(bytes) <= 65_536,
    do: parse(buffer <> bytes, [], 0)

  def decode(_, _), do: {:error, :input_limit, <<>>}

  defp parse(
         <<0xA5, 0x5A, 1, k, s, 0, len::little-16, boot::little-64, q::little-32, i::little-64,
           n::little-16, c::little-16, rest::binary>> = all,
         events,
         searched
       ) do
    cond do
      len > 2012 or k not in [1, 2, 3, 16, 17] or s not in [1, 2] ->
        {:error, :invalid_header, <<>>}

      byte_size(rest) < len + 4 ->
        {:ok, all, Enum.reverse(events)}

      true ->
        base = %{
          kind: k,
          source: s,
          boot: boot,
          sequence: q,
          first_sample: i,
          sample_count: n,
          config_epoch: if(c == 65_535, do: :unknown, else: c)
        }

        parse_payload(all, rest, len, base, events, searched)
    end
  end

  defp parse(<<0xA5, 0x5A, _::binary>> = b, acc, _) when byte_size(b) < 32,
    do: {:ok, b, Enum.reverse(acc)}

  defp parse(<<0xA5, 0x5A, _::binary>>, _, _), do: {:error, :invalid_header, <<>>}
  defp parse(b, acc, _) when b in [<<>>, <<0xA5>>], do: {:ok, b, Enum.reverse(acc)}

  defp parse(<<_, tail::binary>>, acc, searched) when searched < 4096,
    do: parse(tail, acc, searched + 1)

  defp parse(_, _, _), do: {:error, :framing_limit, <<>>}

  defp parse_payload(all, rest, len, base, events, searched) do
    <<payload::binary-size(^len), crc::little-32, tail::binary>> = rest

    with true <- :erlang.crc32(binary_part(all, 0, 32 + len)) == crc,
         {:ok, event} <- unpack(base.kind, payload, base) do
      parse(tail, [event | events], searched)
    else
      false -> {:error, :bad_crc, <<>>}
      _ -> {:error, :invalid_payload, <<>>}
    end
  end

  defp unpack(1, <<t::little-64, pcm::binary>>, b) when b.sample_count > 0 and byte_size(pcm) > 0,
    do: {:ok, Map.merge(b, %{tick: t, payload: pcm})}

  defp unpack(k, payload, %{sequence: 0, first_sample: 0, sample_count: 0} = b)
       when k in [2, 3, 16, 17] do
    with {:ok, v} when is_map(v) <- JSON.decode(payload), do: {:ok, Map.put(b, :body, v)}
  end

  defp unpack(_, _, _), do: :error
end
