defmodule MedFabric.Domain.EncounterTest do
  use ExUnit.Case, async: true
  alias MedFabric.Domain.Encounter

  test "replay metadata requires identified input and a valid sample interval" do
    digest = String.duplicate("a", 64)

    capture = %{
      file_sha256: digest,
      artifact_sha256: digest,
      sample_count: 4000,
      sample_rate_hz: 4000,
      interval_ms: {0, 1000},
      continuity: :observed_continuous
    }

    assert {:ok, _} = Encounter.metadata("session", capture, "fixture")
    assert {:error, :invalid_recording} = Encounter.metadata("", capture, nil)

    assert {:error, :invalid_recording} =
             Encounter.metadata("session", %{capture | interval_ms: nil}, "fixture")

    assert {:error, :invalid_recording} =
             Encounter.metadata("session", %{capture | continuity: :observed_gap}, "fixture")
  end

  test "review binds the complete file and blocks conflicting evidence" do
    m = %{"file_sha256" => "first"}
    assert :ok = Encounter.review(m, "first", false)
    assert {:error, :recording_changed} = Encounter.review(m, "different", false)
    assert {:error, :conflicting_recording} = Encounter.review(m, "first", true)
  end
end
