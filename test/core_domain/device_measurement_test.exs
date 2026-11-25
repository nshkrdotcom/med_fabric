defmodule MedFabric.Domain.DeviceMeasurementTest do
  use ExUnit.Case, async: true
  alias MedFabric.Domain.DeviceMeasurement, as: D

  test "malformed status/bytes return errors and unknown numbers never become zero" do
    base = %{
      "raw" => 42,
      "event_id" => "evt",
      "gateway_sequence" => "0",
      "source" => "synthetic-plx",
      "simulated" => true,
      "phase" => "completed",
      "metrics" => %{},
      "source_status" => %{}
    }

    assert {:error, :invalid_indication} = D.validate(base)
    refute D.usable?(%{"source_status" => %{"measurement" => "bad", "device" => "0"}})
    refute D.usable?(%{"source_status" => %{"measurement" => "32768", "device" => "0"}})
    assert D.usable?(%{"source_status" => %{"measurement" => "1280", "device" => "0"}})
  end
end
