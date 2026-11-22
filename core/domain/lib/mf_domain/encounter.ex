defmodule MedFabric.Domain.Encounter do
  @moduledoc "Clinical recording intake and review rules."

  def metadata(
        session,
        %{
          interval_ms: {start_ms, end_ms},
          file_sha256: _,
          artifact_sha256: _,
          sample_count: _,
          sample_rate_hz: _,
          continuity: _
        } = capture,
        source
      ) do
    if valid_identity?(session, source) and
         Enum.all?([capture.file_sha256, capture.artifact_sha256], &digest?/1) and
         valid_interval?(start_ms, end_ms) and
         positive?(capture.sample_count) and positive?(capture.sample_rate_hz) and
         end_ms - start_ms == round(1000 * capture.sample_count / capture.sample_rate_hz) and
         capture.continuity in [:observed_continuous, :unknown] do
      {:ok,
       %{
         "session_id" => session,
         "source_ref" => source,
         "file_sha256" => capture.file_sha256,
         "artifact_sha256" => capture.artifact_sha256,
         "start_ms" => start_ms,
         "end_ms" => end_ms,
         "continuity" => Atom.to_string(capture.continuity),
         "sample_count" => capture.sample_count,
         "sample_rate_hz" => capture.sample_rate_hz
       }}
    else
      {:error, :invalid_recording}
    end
  end

  def metadata(_, _, _), do: {:error, :invalid_recording}

  defp valid_identity?(session, source), do: identity?(session) and identity?(source)

  defp valid_interval?(start_ms, end_ms),
    do: is_integer(start_ms) and start_ms >= 0 and is_integer(end_ms)

  defp identity?(value), do: is_binary(value) and String.trim(value) != ""

  def review(%{"file_sha256" => digest}, digest, false), do: :ok
  def review(_, _, true), do: {:error, :conflicting_recording}
  def review(_, _, false), do: {:error, :recording_changed}

  defp positive?(value), do: is_integer(value) and value > 0

  defp digest?(value), do: is_binary(value) and Regex.match?(~r/\A[0-9a-f]{64}\z/, value)
end
