defmodule MedFabric.Domain.DeviceMeasurementTest do
  use ExUnit.Case, async: true
  alias MedFabric.Domain.DeviceMeasurement, as: D
  alias MedFabric.TestMeasurement, as: F

  test "canonical SDK event preserves exact SFLOAT, time, raw bits and synthetic provenance" do
    event = F.event()
    assert :ok = D.validate(event)
    assert {:ok, typed} = MedEx.Serialization.measurement(event)
    assert typed.metrics["spo2"] == {:value, 972, -1, "%"}

    assert {:ok, native} =
             D.derived(event, "spo2", "collection", "gateway", "2026-11-24T12:00:00Z")

    assert native["value"] == %{"mantissa" => "972", "exponent" => "-1"}
    assert native["provenance"]["simulated"]
    assert native["effective_at"] =~ "2020-01-02T03:04:05"
  end

  test "negative finite SFLOAT remains evidence but is clinically ineligible" do
    event = F.event("collection", "gateway", "boot", -1)
    assert :ok = D.validate(event)

    assert {:error, :ineligible_metric} =
             D.derived(event, "pulse_rate", "collection", "gateway", "2026-11-24T12:00:00Z")

    assert {:ok, _} = D.derived(event, "spo2", "collection", "gateway", "2026-11-24T12:00:00Z")
  end

  test "metric spoofing, wrong raw/status, unknown source time and wrong source identity cannot become clinical truth" do
    event = F.event()

    assert {:error, _} =
             D.validate(put_in(event, ["metrics", "spo2"], ["value", "980", "-1", "%"]))

    assert {:error, _} = D.validate(Map.put(event, "raw", 42))
    assert {:error, _} = D.validate(put_in(event, ["device_status", "measurement"], "0"))
    assert {:error, _} = D.derived(event, "spo2", "other", "gateway", "2026-11-24T12:00:00Z")

    unknown =
      event
      |> Map.put("device_time", "unknown")
      |> Map.update!("provenance", fn facts ->
        Enum.map(facts, fn f ->
          if f["name"] == "time_basis", do: Map.put(f, "value", "unknown"), else: f
        end)
      end)

    assert :ok = D.validate(unknown)

    assert {:error, :ineligible_metric} =
             D.derived(unknown, "spo2", "collection", "gateway", "2026-11-24T12:00:00Z")
  end
end
