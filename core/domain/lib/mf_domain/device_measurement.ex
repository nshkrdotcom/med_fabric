defmodule MedFabric.Domain.DeviceMeasurement do
  @moduledoc "Clinical eligibility from one canonical SDK measurement event and its preserved synthetic PLXS bytes."
  import Bitwise
  alias MedEx.{MeasurementEvent, Serialization}
  alias MedFabric.Domain.NativeValue
  @codes %{"spo2" => {"device_spo2_v1", "%"}, "pulse_rate" => {"device_pulse_rate_v1", "/min"}}
  @special [0x7FE, 0x7FF, 0x800, 0x801, 0x802]

  def descriptor_ref do
    Serialization.digest(%{
      "schema" => "plxs-1.0.1",
      "features" => Base.encode64(<<15::little-16, 0xFFFF::little-16, 0xFFFF::little-24>>),
      "source" => "synthetic-plx"
    })
  end

  def validate(wire) when is_map(wire) do
    with {:ok, event} <- Serialization.measurement(wire),
         true <-
           event.stream_id == "plx" and event.source_epoch == 0 and
             event.gateway_sequence < 10_000,
         true <- event.descriptor_ref == descriptor_ref() and is_nil(event.source_record_id),
         {:bytes, <<flags, saturation::little-16, pulse::little-16, rest::binary>>} <- event.raw,
         true <- (flags &&& 0xE0) == 0,
         {:ok, time, rest} <- optional(rest, flags, 0, 7),
         {:ok, measurement, rest} <- optional(rest, flags, 1, 2),
         {:ok, device, rest} <- optional(rest, flags, 2, 3),
         {:ok, _, <<>>} <- optional(rest, flags, 3, 2),
         true <-
           event.metrics == %{
             "spo2" => metric(saturation, "%"),
             "pulse_rate" => metric(pulse, "/min")
           },
         true <-
           event.device_status == %{"measurement" => bits(measurement), "device" => bits(device)},
         {:ok, facts} <- provenance(event.provenance),
         true <-
           facts["source"] == "synthetic-plx" and facts["simulated"] == true and
             facts["phase"] == "completed",
         true <-
           facts["decoder"] == "plxs-1.0.1" and
             facts["features_raw"] ==
               Base.encode64(<<15::little-16, 0xFFFF::little-16, 0xFFFF::little-24>>),
         true <- valid_time?(event, facts, time, flags) do
      :ok
    else
      _ -> {:error, :invalid_indication}
    end
  end

  def validate(_), do: {:error, :invalid_indication}

  def derived(wire, code, collection, gateway, issued) do
    with :ok <- validate(wire),
         {:ok, event} <- Serialization.measurement(wire),
         true <- event.acquisition_id == collection and event.source_ref == gateway,
         {kind, unit} <- @codes[code],
         {:value, mantissa, exponent, ^unit} <- event.metrics[code],
         value = %{"mantissa" => to_string(mantissa), "exponent" => to_string(exponent)},
         true <- NativeValue.eligible?(code, value) and usable?(event),
         %{clock_id: "unix_us", boot_id: "fixture", ticks: ticks, uncertainty_ticks: 0} <-
           event.device_time,
         {:ok, effective} <- DateTime.from_unix(ticks, :microsecond),
         {:ok, issued_at, _} <- DateTime.from_iso8601(issued),
         true <- DateTime.compare(effective, issued_at) != :gt do
      {:ok,
       %{
         "kind" => kind,
         "value" => value,
         "unit" => unit,
         "effective_at" => DateTime.to_iso8601(effective),
         "issued" => issued,
         "source_device" => "synthetic-plx",
         "source_event_id" => event.event_id,
         "parent_acquisition_id" => collection,
         "provenance" => %{
           "kind" => "simulated_plxs",
           "simulated" => true,
           "time_basis" => "qualified_fixture_utc",
           "gateway" => gateway
         }
       }}
    else
      _ -> {:error, :ineligible_metric}
    end
  end

  def usable?(%MeasurementEvent{device_status: %{"measurement" => ms, "device" => ds}}) do
    is_binary(ms) and is_binary(ds) and Regex.match?(~r/\A(?:0|[1-9][0-9]{0,4})\z/, ms) and
      Regex.match?(~r/\A(?:0|[1-9][0-9]{0,7})\z/, ds) and
      (String.to_integer(ms) &&& 0xF860) == 0 and (String.to_integer(ds) &&& 0xFFFE) == 0
  end

  def usable?(wire) when is_map(wire) do
    case Serialization.measurement(wire) do
      {:ok, event} -> usable?(event)
      _ -> false
    end
  end

  def usable?(_), do: false

  defp provenance(facts) do
    if length(facts) == length(Enum.uniq_by(facts, & &1.name)),
      do: {:ok, Map.new(facts, &{&1.name, &1.value})},
      else: {:error, :duplicate_provenance}
  end

  defp optional(data, flags, bit, _) when (flags &&& 1 <<< bit) == 0, do: {:ok, nil, data}

  defp optional(data, _, _, size) when byte_size(data) >= size do
    <<value::binary-size(^size), rest::binary>> = data
    {:ok, value, rest}
  end

  defp optional(_, _, _, _), do: :error
  defp bits(nil), do: :unknown
  defp bits(bytes), do: Integer.to_string(:binary.decode_unsigned(bytes, :little))

  defp metric(word, _) when word in @special,
    do:
      {:missing,
       Enum.at(
         ~w(positive_infinity nan not_at_resolution reserved negative_infinity),
         word - 0x7FE
       )}

  defp metric(word, unit), do: {:value, signed(word &&& 4095, 2048), signed(word >>> 12, 8), unit}
  defp signed(n, limit) when n >= limit, do: n - 2 * limit
  defp signed(n, _), do: n
  defp valid_time?(%{device_time: :unknown}, %{"time_basis" => "unknown"}, _, _), do: true

  defp valid_time?(
         %{
           device_time: %{
             clock_id: "unix_us",
             boot_id: "fixture",
             ticks: ticks,
             uncertainty_ticks: 0
           }
         },
         %{"time_basis" => "qualified_fixture_utc"},
         <<year::little-16, month, day, hour, minute, second>>,
         flags
       )
       when (flags &&& 16) == 0 do
    case DateTime.from_unix(ticks, :microsecond) do
      {:ok, time} ->
        {time.year, time.month, time.day, time.hour, time.minute, time.second,
         elem(time.microsecond, 0)} == {year, month, day, hour, minute, second, 0}

      _ ->
        false
    end
  end

  defp valid_time?(_, _, _, _), do: false
end
