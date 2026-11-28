defmodule MedFabric.Handheld.PLXAdapterTest do
  use ExUnit.Case, async: true
  alias MedEx.Wire.Control
  alias MedFabric.Handheld.PLXAdapter, as: PLX
  alias MedFabric.Handheld.PLXPeripheral

  test "zero is finite, absent optional values and NaN stay distinct" do
    bytes = <<0, 0, 0, 0xFF, 0x07>>
    assert {:ok, result} = PLX.spot_check(bytes)
    assert result.spo2 == {:finite, 0, 0}
    assert result.pulse_rate == {:special, :nan}
    assert result.pulse_amplitude_index == nil
    assert result.source_time == :unknown
    assert result.raw == bytes
    refute Map.has_key?(result, :event_id)
  end

  test "SFLOAT preserves signed decimal resolution and all five special words" do
    for {word, expected} <- [
          {0x07FE, :positive_infinity},
          {0x07FF, :nan},
          {0x0800, :not_at_resolution},
          {0x0801, :reserved},
          {0x0802, :negative_infinity}
        ] do
      assert {:ok, %{spo2: {:special, ^expected}}} = PLX.spot_check(<<0, word::little-16, 0::16>>)
    end

    assert {:ok, result} = PLX.spot_check(<<0, 0xE0, 0xFF, 0xFF, 0xF7>>)
    assert result.spo2 == {:finite, -32, -1}
    assert result.pulse_rate == {:finite, 2047, -1}
  end

  test "optional fields retain source-local time and reported status" do
    time = <<2026::little-16, 11, 24, 9, 30, 15>>
    tail = <<time::binary, 0x00, 0x0A, 0x00, 0x88, 0x00, 0, 0>>
    assert {:ok, result} = PLX.spot_check(<<0x0F, 98, 0, 70, 0, tail::binary>>)
    assert result.source_time == {:device_local, {2026, 11, 24, 9, 30, 15}}
    assert result.measurement_status.set == [:stored, :testing]
    assert result.device_status.set == [:sensor_off_user, :sensor_disconnected]
    assert result.pulse_amplitude_index == {:finite, 0, 0}
    assert {:ok, %{source_time: :unknown}} = PLX.spot_check(<<0x11, 98, 0, 70, 0, time::binary>>)
    assert {:ok, %{source_time: :unknown}} = PLX.spot_check(<<1, 98, 0, 70, 0, 0::56>>)
  end

  test "features and RFU bits are retained without inventing supported statuses" do
    assert {:ok, f} = PLX.features(<<0x8F, 0x80, 0, 0x0A, 0, 0x88, 0x80>>)

    assert f.supported == [
             :measurement_status,
             :device_status,
             :storage,
             :timestamp,
             :multiple_bonds
           ]

    assert f.device_status.set == [:sensor_off_user, :sensor_disconnected]
    assert f.device_status.raw == 0x808800
    assert {:ok, %{spo2: {:finite, 98, 0}}} = PLX.spot_check(<<0xE0, 98, 0, 70, 0>>)
  end

  test "truncated optional fields and trailing bytes cannot produce measurements" do
    full = <<0x0F, 98, 0, 70, 0, 2026::little-16, 11, 24, 9, 30, 15, 0::56>>

    for size <- 0..(byte_size(full) - 1),
        do: assert(PLX.spot_check(binary_part(full, 0, size)) == {:error, :invalid_length})

    assert {:error, :invalid_length} = PLX.spot_check(<<0, 98, 0, 70, 0, 0>>)
    assert {:error, :invalid_length} = PLX.features(<<3, 0, 0, 0, 0, 0>>)
  end

  test "the PLX wire body is the canonical SDK event with exact source bytes and explicit time qualification" do
    config = %{"device" => "gateway", "acquisition" => "collection", "boot" => "boot"}
    raw = List.last(PLXPeripheral.new().records)

    wire =
      PLXPeripheral.event(
        raw,
        "event",
        1,
        "previous",
        config,
        :fixed_fixture_utc
      )

    assert {:ok, event} = MedEx.Serialization.measurement(wire)
    assert event.acquisition_id == "collection" and event.source_ref == "gateway"
    assert event.raw == {:bytes, raw}
    assert event.metrics["spo2"] == {:value, 98, 0, "%"}
    assert event.device_time.clock_id == "unix_us" and event.device_time.uncertainty_ticks == 0
    assert %{name: "repeat_of", origin: :observed, value: "previous"} in event.provenance

    binding = %{
      "acquisition" => "collection",
      "profile" => "plx_spot_check",
      "generation" => "1",
      "connection" => "connection"
    }

    assert {:ok, bytes} =
             Control.encode("measurement", %{
               "binding" => binding,
               "operation_id" => "put-event",
               "event" => wire
             })

    assert {:ok, %{"event" => ^wire}} = Control.decode(bytes, ["measurement"])
    unknown = PLXPeripheral.event(raw, "unknown-time", 2, nil, config)
    assert {:ok, %{device_time: :unknown}} = MedEx.Serialization.measurement(unknown)
  end
end
