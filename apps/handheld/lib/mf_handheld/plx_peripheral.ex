defmodule MedFabric.Handheld.PLXPeripheral do
  @moduledoc "PLXS characteristic reads and a simulated RACP procedure port. No BLE radio."
  alias MedFabric.Handheld.PLXAdapter

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

  @doc "Build the single canonical SDK event; only the declared fixture policy qualifies source-local time."
  def event(raw, id, sequence, repeat_of, config, time_policy \\ :unknown) do
    {:ok, indication} = PLXAdapter.spot_check(raw)
    {device_time, basis} = source_time(indication.source_time, time_policy)
    features = Base.encode64(read_features())

    facts = [
      %{name: "source", origin: :observed, value: "synthetic-plx"},
      %{name: "simulated", origin: :observed, value: true},
      %{name: "phase", origin: :observed, value: "completed"},
      %{name: "features_raw", origin: :observed, value: features},
      %{name: "decoder", origin: :claimed, value: "plxs-1.0.1"},
      %{name: "time_basis", origin: :claimed, value: basis},
      %{name: "peripheral_redelivery", origin: :observed, value: "ambiguous_without_record_id"}
    ]

    facts =
      if repeat_of == nil,
        do: facts,
        else: facts ++ [%{name: "repeat_of", origin: :observed, value: repeat_of}]

    event = %MedEx.MeasurementEvent{
      event_id: id,
      acquisition_id: config["acquisition"],
      source_ref: config["device"],
      boot_id: config["boot"],
      stream_id: "plx",
      source_epoch: 0,
      gateway_sequence: sequence,
      descriptor_ref:
        MedEx.Serialization.digest(%{
          "schema" => "plxs-1.0.1",
          "features" => features,
          "source" => "synthetic-plx"
        }),
      metrics: %{
        "spo2" => metric(indication.spo2, "%"),
        "pulse_rate" => metric(indication.pulse_rate, "/min")
      },
      raw: {:bytes, raw},
      source_record_id: nil,
      device_status: %{
        "measurement" => status(indication.measurement_status),
        "device" => status(indication.device_status)
      },
      device_time: device_time,
      receipt_time: :unknown,
      provenance: facts
    }

    :ok = MedEx.MeasurementEvent.validate(event)
    wire = MedEx.Serialization.to_map(event)
    {:ok, ^event} = MedEx.Serialization.measurement(wire)
    wire
  end

  defp source_time({:device_local, {y, m, d, h, min, s}}, :fixed_fixture_utc) do
    {:ok, date} = Date.new(y, m, d)
    {:ok, time} = Time.new(h, min, s)
    at = DateTime.new!(date, time, "Etc/UTC")

    {%{
       clock_id: "unix_us",
       boot_id: "fixture",
       ticks: DateTime.to_unix(at, :microsecond),
       uncertainty_ticks: 0
     }, "qualified_fixture_utc"}
  end

  defp source_time(_, _), do: {:unknown, "unknown"}
  defp metric({:finite, m, e}, unit), do: {:value, m, e, unit}
  defp metric({:special, reason}, _), do: {:missing, to_string(reason)}
  defp status(nil), do: :unknown
  defp status(%{raw: raw}), do: to_string(raw)
end
