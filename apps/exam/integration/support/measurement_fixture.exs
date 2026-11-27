defmodule MedFabric.Exam.TestMeasurement do
  import Bitwise

  def event(acquisition \\ "collection", gateway \\ "gateway", boot \\ "boot", pulse \\ 721) do
    raw =
      <<7, 0xF3CC::little-16, 0xF000 ||| (pulse &&& 0xFFF)::little-16, 2020::little-16, 1, 2, 3,
        4, 5, 0x0500::little-16, 0::little-24>>

    {:ok, at, _} = DateTime.from_iso8601("2020-01-02T03:04:05Z")

    facts = [
      {"source", :observed, "synthetic-plx"},
      {"simulated", :observed, true},
      {"phase", :observed, "completed"},
      {"features_raw", :observed,
       Base.encode64(<<15::little-16, 0xFFFF::little-16, 0xFFFF::little-24>>)},
      {"decoder", :claimed, "plxs-1.0.1"},
      {"time_basis", :claimed, "qualified_fixture_utc"},
      {"peripheral_redelivery", :observed, "ambiguous_without_record_id"}
    ]

    %MedEx.MeasurementEvent{
      event_id: "event_one",
      acquisition_id: acquisition,
      source_ref: gateway,
      boot_id: boot,
      stream_id: "plx",
      source_epoch: 0,
      gateway_sequence: 0,
      descriptor_ref: MedFabric.Domain.DeviceMeasurement.descriptor_ref(),
      metrics: %{"spo2" => {:value, 972, -1, "%"}, "pulse_rate" => {:value, pulse, -1, "/min"}},
      raw: {:bytes, raw},
      device_status: %{"measurement" => "1280", "device" => "0"},
      device_time: %{
        clock_id: "unix_us",
        boot_id: "fixture",
        ticks: DateTime.to_unix(at, :microsecond),
        uncertainty_ticks: 0
      },
      provenance:
        Enum.map(facts, fn {name, origin, value} ->
          %{name: name, origin: origin, value: value}
        end)
    }
    |> MedEx.Serialization.to_map()
  end
end
