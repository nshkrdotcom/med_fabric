defmodule MedFabric.Domain.DeviceMeasurement do
  @moduledoc "Clinical selection from a completed synthetic PLXS indication with preserved source bits."
  import Bitwise
  @codes %{"spo2" => {"device_spo2_v1", "%"}, "pulse_rate" => {"device_pulse_rate_v1", "/min"}}
  @special [0x7FE, 0x7FF, 0x800, 0x801, 0x802]

  def validate(
        %{
          "raw" => raw,
          "event_id" => id,
          "gateway_sequence" => seq,
          "source" => "synthetic-plx",
          "simulated" => true,
          "phase" => "completed",
          "metrics" => metrics,
          "source_status" => status
        } = e
      ) do
    with true <- is_binary(raw) and byte_size(raw) in 4..128,
         true <- is_binary(id) and Regex.match?(~r/\A[A-Za-z0-9_-]{1,96}\z/, id),
         true <- is_binary(seq) and Regex.match?(~r/\A(0|[1-9][0-9]{0,3})\z/, seq),
         {:ok, <<flags, s::little-16, p::little-16, rest::binary>>} <- Base.decode64(raw),
         {:ok, t, r1} <- optional(rest, flags, 0, 7),
         {:ok, ms, r2} <- optional(r1, flags, 1, 2),
         {:ok, ds, r3} <- optional(r2, flags, 2, 3),
         {:ok, _, <<>>} <- optional(r3, flags, 3, 2),
         true <- metrics == %{"spo2" => metric(s), "pulse_rate" => metric(p)},
         true <- status == %{"measurement" => bits(ms), "device" => bits(ds)},
         true <- valid_time?(e, t, flags) do
      :ok
    else
      _ -> {:error, :invalid_indication}
    end
  end

  def validate(_), do: {:error, :invalid_indication}

  def derived(event, code, collection, device, issued) do
    with :ok <- validate(event),
         {kind, unit} <- @codes[code],
         %{"mantissa" => _, "exponent" => _} = value <- event["metrics"][code],
         true <- usable?(event),
         "qualified_fixture_utc" <- event["time_basis"] do
      {:ok,
       %{
         "kind" => kind,
         "value" => value,
         "unit" => unit,
         "effective_at" => event["measured_at"],
         "issued" => issued,
         "device_ref" => "Device/" <> event["source"],
         "source_event_id" => event["event_id"],
         "parent_acquisition_id" => collection,
         "provenance" => %{
           "kind" => "simulated_plxs",
           "simulated" => true,
           "time_basis" => event["time_basis"],
           "gateway" => device
         }
       }}
    else
      _ -> {:error, :ineligible_metric}
    end
  end

  def usable?(%{"source_status" => %{"measurement" => ms, "device" => ds}}) do
    # Explicit lab policy requires source status. Demonstration bit is retained.
    is_binary(ms) and is_binary(ds) and Regex.match?(~r/\A[0-9]{1,5}\z/, ms) and
      Regex.match?(~r/\A[0-9]{1,8}\z/, ds) and
      (String.to_integer(ms) &&& 0xF860) == 0 and (String.to_integer(ds) &&& 0xFFFE) == 0
  end

  def usable?(_), do: false

  defp optional(data, flags, bit, _) when (flags &&& 1 <<< bit) == 0, do: {:ok, nil, data}

  defp optional(data, _, _, size) when byte_size(data) >= size do
    <<v::binary-size(^size), r::binary>> = data
    {:ok, v, r}
  end

  defp optional(_, _, _, _), do: :error
  defp bits(nil), do: nil
  defp bits(b), do: Integer.to_string(:binary.decode_unsigned(b, :little))

  defp metric(w) when w in @special,
    do: %{
      "missing" =>
        Enum.at(~w(positive_infinity nan not_at_resolution reserved negative_infinity), w - 0x7FE)
    }

  defp metric(w),
    do: %{
      "mantissa" => to_string(signed(w &&& 4095, 2048)),
      "exponent" => to_string(signed(w >>> 12, 8))
    }

  defp signed(n, limit) when n >= limit, do: n - 2 * limit
  defp signed(n, _), do: n
  defp valid_time?(%{"measured_at" => nil, "time_basis" => "unknown"}, _, _), do: true

  defp valid_time?(
         %{"measured_at" => at, "time_basis" => "qualified_fixture_utc"},
         <<y::little-16, m, d, h, min, s>>,
         flags
       )
       when (flags &&& 16) == 0 and is_binary(at) do
    case DateTime.from_iso8601(at) do
      {:ok, t, 0} ->
        {t.year, t.month, t.day, t.hour, t.minute, t.second, t.microsecond} ==
          {y, m, d, h, min, s, {0, 0}}

      _ ->
        false
    end
  end

  defp valid_time?(_, _, _), do: false
end
