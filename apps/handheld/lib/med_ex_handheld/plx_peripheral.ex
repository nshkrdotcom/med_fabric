defmodule MedExHandheld.PLXPeripheral do
  @moduledoc "PLXS characteristic reads and a simulated RACP procedure port. No BLE radio."
  def new do
    # Time qualification is explicit for this fixed UTC fixture, never inferred from PLXS.
    time = <<2025::little-16, 1, 2, 3, 4, 5>>

    poor =
      <<7, 0x07FF::little-16, 84::little-16, time::binary, 0x8400::little-16, 0x800::little-24>>

    good = <<7, 98::little-16, 72::little-16, time::binary, 0x0500::little-16, 0::little-24>>
    %{subscribed: false, procedure: nil, records: [poor, good]}
  end

  def discover, do: %{service: 0x1822, features: 0x2A60, spot: 0x2A5E, racp: 0x2A52}

  def provisional_notification(%{subscribed: true}),
    do: <<4, 0x7FF::little-16, 0x7FF::little-16, 32::little-16>>

  def read_features, do: <<15::little-16, 0xFFFF::little-16, 0xFFFF::little-24>>
  def subscribe(p), do: %{p | subscribed: true}
  def racp(%{subscribed: false} = p, _), do: {p, {:error, :cccd_improperly_configured}}
  def racp(%{procedure: :report} = p, <<3, 0>>), do: {%{p | procedure: nil}, <<6, 0, 3, 1>>}
  def racp(%{procedure: :report} = p, _), do: {p, {:error, :procedure_in_progress}}
  def racp(p, <<4, 1>>), do: {p, <<5, 0, length(p.records)::little-16>>}
  def racp(p, <<1, 1>>), do: {%{p | procedure: :report}, {:indications, p.records}}
  def racp(p, <<3, 0>>), do: {p, <<6, 0, 3, 7>>}
  def racp(p, <<op, _operator, _::binary>>) when op in [1, 4], do: {p, <<6, 0, op, 4>>}
  def racp(p, <<op, _operator>>), do: {p, <<6, 0, op, 2>>}
  def racp(p, _), do: {p, {:error, :invalid_operand}}
  def complete(%{procedure: :report} = p), do: {%{p | procedure: nil}, <<6, 0, 1, 1>>}
  def timeout(p), do: {%{p | procedure: nil}, :outcome_unknown}

  def event(raw, id, seq, repeat_of, time_policy \\ :unknown) do
    {:ok, e} = MedExHandheld.PLXAdapter.spot_check(raw)

    {at, basis} =
      case e.source_time do
        {:device_local, {y, m, d, h, min, s}} when time_policy == :fixed_fixture_utc ->
          {:ok, date} = Date.new(y, m, d)
          {:ok, time} = Time.new(h, min, s)
          {DateTime.new!(date, time, "Etc/UTC") |> DateTime.to_iso8601(), "qualified_fixture_utc"}

        _ ->
          {nil, "unknown"}
      end

    %{
      "event_id" => id,
      "gateway_sequence" => to_string(seq),
      "raw" => Base.encode64(raw),
      "phase" => "completed",
      "metrics" => %{"spo2" => metric(e.spo2), "pulse_rate" => metric(e.pulse_rate)},
      "source_status" => %{
        "measurement" => status(e.measurement_status),
        "device" => status(e.device_status)
      },
      "measured_at" => at,
      "time_basis" => basis,
      "source" => "synthetic-plx",
      "simulated" => true,
      "repeat_of" => repeat_of,
      "features_raw" => Base.encode64(read_features()),
      "decoder" => "plxs-1.0.1",
      "source_record_id" => nil,
      "peripheral_redelivery" => "ambiguous_without_record_id"
    }
  end

  @doc "Check the synthetic PLXS adapter mapping against the SDK serialization contract."
  def validate_sdk(e, c) do
    metrics = Map.new(e["metrics"], fn {name, value} -> {name, sdk_metric(name, value)} end)

    event = %MedEx.MeasurementEvent{
      event_id: e["event_id"],
      acquisition_id: c["acquisition"],
      source_ref: e["source"],
      boot_id: c["boot"],
      stream_id: "plx",
      source_epoch: 0,
      gateway_sequence: String.to_integer(e["gateway_sequence"]),
      descriptor_ref:
        MedEx.Serialization.digest(%{
          "schema" => "plxs-1.0.1",
          "features" => e["features_raw"],
          "source" => e["source"]
        }),
      metrics: metrics,
      raw: {:bytes, Base.decode64!(e["raw"])},
      device_status: Map.reject(e["source_status"], fn {_, v} -> is_nil(v) end),
      provenance: [%{name: "simulated", origin: :observed, value: true}]
    }

    with :ok <- MedEx.MeasurementEvent.validate(event),
         {:ok, ^event} <- MedEx.Serialization.measurement(MedEx.Serialization.to_map(event)) do
      :ok
    end
  end

  defp sdk_metric(name, value) do
    case value do
      %{"missing" => reason} ->
        {:missing, reason}

      %{"mantissa" => mantissa, "exponent" => exponent} ->
        unit = if name == "spo2", do: "%", else: "/min"
        {:value, String.to_integer(mantissa), String.to_integer(exponent), unit}
    end
  end

  defp metric({:finite, m, e}), do: %{"mantissa" => to_string(m), "exponent" => to_string(e)}
  defp metric({:special, r}), do: %{"missing" => to_string(r)}
  defp status(nil), do: nil
  defp status(%{raw: r}), do: to_string(r)
end
