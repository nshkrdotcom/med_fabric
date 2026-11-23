defmodule MedFabric.Exam do
  @moduledoc "Composes evidence intake, clinician review and durable export."

  alias MedFabric.Domain.Evidence
  alias MedFabric.Interop.FhirClient
  alias MedFabric.Store.{Postgres, Records}

  def lab, do: Application.fetch_env!(:mf_exam, :lab)
  def session_id(enc), do: "preview-" <> enc

  def announce(config) do
    Phoenix.PubSub.broadcast(MedFabric.Exam.PubSub, "exam:" <> config.encounter_id, :exam_changed)
  end

  def pulse(encounter, actor, value) do
    with true <- Records.member?(Postgres, encounter, actor, :clinician),
         {:ok, evidence} <- Evidence.pulse_rate(value, DateTime.utc_now(), actor),
         :ok <- Records.ready(Postgres, encounter, id(), evidence) do
      announce(lab())
    else
      false -> {:error, :unauthorized}
      error -> error
    end
  end

  def accept(encounter, acquisition, actor) do
    config = lab()

    with true <- Records.member?(Postgres, encounter, actor, :clinician),
         {:ok, rows} <- Records.list(Postgres, encounter),
         %{evidence: evidence} <- Enum.find(rows, &(&1.id == acquisition)),
         :ok <- verify_evidence(config, evidence),
         external = "#{encounter}:#{acquisition}",
         resource = FhirClient.resource(evidence, external, actor, config.refs),
         {:ok, :ok} <-
           Records.accept(
             Postgres,
             encounter,
             acquisition,
             actor,
             evidence,
             config.fhir_base_url,
             external,
             resource
           ) do
      announce(config)
    else
      nil -> {:error, :not_found}
      false -> {:error, :unauthorized}
      error -> error
    end
  end

  def deliver(encounter, acquisition, actor) do
    with true <- Records.member?(Postgres, encounter, actor, :clinician),
         {:ok, url, resource, nil} <- Records.delivery(Postgres, encounter, acquisition) do
      result = FhirClient.deliver(resource, base_url: url)
      status = Records.delivery_result(Postgres, encounter, acquisition, result)
      announce(lab())
      status
    else
      {:ok, _, _, remote} when is_binary(remote) -> :ok
      false -> {:error, :unauthorized}
      error -> error
    end
  end

  def artifact(dir, %{"artifact_key" => key, "file_sha256" => digest}) do
    with true <- Regex.match?(~r/\A[0-9a-f]{64}\z/, digest) and key == digest <> ".wav",
         {:ok, bytes} <- File.read(Path.join(dir, key)),
         true <- Base.encode16(:crypto.hash(:sha256, bytes), case: :lower) == digest do
      {:ok, bytes}
    else
      _ -> {:error, :recording_changed}
    end
  end

  def artifact(_, _), do: {:error, :invalid_recording}

  defp verify_evidence(config, %{"kind" => "audio_pcm16_wav"} = evidence) do
    case artifact(config.artifact_dir, evidence) do
      {:ok, _} -> :ok
      error -> error
    end
  end

  defp verify_evidence(_, %{"kind" => "pulse_rate"}), do: :ok

  defp id, do: Base.url_encode64(:crypto.strong_rand_bytes(18), padding: false)
end
