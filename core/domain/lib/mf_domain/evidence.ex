defmodule MedFabric.Domain.Evidence do
  @moduledoc "Validates the two clinical evidence inputs supported by the exam."

  def recording(
        %{
          acquisition_id: id,
          kind: :audio_pcm16_wav,
          artifact_key: key,
          file_sha256: file,
          pcm_sha256: pcm,
          sample_rate_hz: 48_000,
          first_sample: 0,
          end_sample: count,
          sample_count: count,
          continuity: :observed_continuous
        },
        actor,
        settings,
        %DateTime{} = effective_at
      )
      when is_integer(count) and count > 0 and is_binary(actor) and byte_size(actor) > 0 and
             is_map(settings) and is_binary(id) do
    if Regex.match?(~r/\A[A-Za-z0-9_-]{1,64}\z/, id) and digest?(file) and digest?(pcm) and
         key == file <> ".wav" do
      {:ok,
       %{
         "kind" => "audio_pcm16_wav",
         "effective_at" => DateTime.to_iso8601(effective_at),
         "artifact_key" => id <> "/" <> key,
         "file_sha256" => file,
         "pcm_sha256" => pcm,
         "sample_count" => count,
         "sample_rate_hz" => 48_000,
         "continuity" => "observed_continuous",
         "provenance" => %{
           "kind" => "browser_capture",
           "actor" => actor,
           "time_basis" => "server_first_frame",
           "input" =>
             Map.take(
               settings,
               ~w(label sampleRate channelCount contextSampleRate echoCancellation noiseSuppression autoGainControl)
             )
         }
       }}
    else
      {:error, :invalid_recording}
    end
  end

  def recording(_, _, _, _), do: {:error, :invalid_recording}

  def pulse_rate(value, %DateTime{} = effective_at, actor)
      when is_integer(value) and value > 0 and is_binary(actor) and byte_size(actor) > 0 do
    {:ok,
     %{
       "kind" => "pulse_rate",
       "effective_at" => DateTime.to_iso8601(effective_at),
       "value" => value,
       "unit" => "/min",
       "provenance" => %{"kind" => "manual", "actor" => actor}
     }}
  end

  def pulse_rate(_, _, _), do: {:error, :invalid_pulse_rate}

  defp digest?(value), do: is_binary(value) and Regex.match?(~r/\A[0-9a-f]{64}\z/, value)
end
