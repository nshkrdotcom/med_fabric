defmodule MedFabric.Exam.ClockObservationsTest do
  use ExUnit.Case, async: true

  alias MedEx.{Serialization, StreamSpec}
  alias MedFabric.Exam.ClockObservations

  test "freeze bounds clock alignment for peripherals with more than one hour of uptime" do
    ClockObservations.initialize_host_generation()
    host_gen = ClockObservations.host_generation()

    spec = %StreamSpec{
      source_ref: "bench-device",
      acquisition_id: "uptime-test",
      boot_id: "boot-long",
      stream_id: "ecg",
      source_epoch: 2,
      descriptor_ref: String.duplicate("0", 64),
      modality: "medex:ecg",
      encoding: :s16le,
      channels: [%{id: "1", label: "ecg 1", unit: "uV", calibration: :unknown}],
      sample_rate: {250, 1},
      clock: %{
        domain_id: "ecg",
        boot_id: "boot-long",
        generation: 0,
        tick_rate: {48_000_000, 1},
        uncertainty_ticks: 48
      },
      source_processing: :unknown,
      capabilities: %{
        encodings: [:s16le],
        max_frame_samples: 960,
        max_payload_bytes: 2012,
        replay: :durable_spool,
        commands: []
      }
    }

    spec = %{spec | descriptor_ref: Serialization.descriptor_ref(spec)}

    # Simulate a peripheral powered on for > 11 hours (40_000 seconds).
    device_base_us = 40_000_000_000
    host_now = ClockObservations.now()

    facts = [
      %{"type" => "clock_freeze", "body" => ClockObservations.wall_mapping()},
      %{
        "type" => "anchor",
        "body" => %{
          "stream" => "ecg",
          "method" => "fixture_acquisition_tick",
          "sample_index" => "0",
          "tick" => to_string(device_base_us * 48),
          "error_us" => "2"
        }
      },
      %{
        "type" => "probe",
        "body" => %{
          "stream" => "ecg",
          "host_generation" => host_gen,
          "h1" => to_string(host_now - 2_000_000),
          "h4" => to_string(host_now - 1_999_000),
          "d2" => to_string(device_base_us),
          "d3" => to_string(device_base_us + 200)
        }
      },
      %{
        "type" => "probe",
        "body" => %{
          "stream" => "ecg",
          "host_generation" => host_gen,
          "h1" => to_string(host_now - 1_000_000),
          "h4" => to_string(host_now - 999_000),
          "d2" => to_string(device_base_us + 1_000_000),
          "d3" => to_string(device_base_us + 1_000_200)
        }
      }
    ]

    frozen = ClockObservations.freeze("ecg", spec, facts)
    assert frozen["state"] == "bounded"
    assert {:ok, {earliest, latest}} = ClockObservations.interval(frozen, 250)
    assert earliest <= latest
  end
end
