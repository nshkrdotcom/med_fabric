defmodule MedFabric.Domain.EvidenceTest do
  use ExUnit.Case, async: true
  alias MedFabric.Domain.Evidence

  test "manual pulse evidence has a measurement and provenance independent of any file" do
    at = ~U[2026-11-22 12:00:00Z]

    assert {:ok, %{"value" => 70, "unit" => "/min", "provenance" => %{"actor" => "clinician"}}} =
             Evidence.pulse_rate(70, at, "clinician")

    assert {:error, :invalid_pulse_rate} = Evidence.pulse_rate(0, at, "clinician")
  end

  test "recording evidence binds the artifact key and sample interval" do
    digest = String.duplicate("a", 64)
    at = ~U[2026-11-22 12:00:00Z]

    capture = %{
      acquisition_id: "attempt-1", kind: :audio_pcm16_wav,
      artifact_key: digest <> ".wav",
      file_sha256: digest,
      pcm_sha256: digest,
      sample_rate_hz: 48_000,
      first_sample: 0,
      end_sample: 960,
      sample_count: 960,
      continuity: :observed_continuous
    }

    assert {:ok, %{"file_sha256" => ^digest}} = Evidence.recording(capture, "patient", %{"label" => "USB input"}, at)

    assert {:error, :invalid_recording} =
             Evidence.recording(%{capture | artifact_key: "other.wav"}, "patient", %{"label" => "USB input"}, at)

    assert {:error, :invalid_recording} =
             Evidence.recording(%{capture | end_sample: 961}, "patient", %{"label" => "USB input"}, at)
  end
end
