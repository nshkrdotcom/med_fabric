defmodule MedFabric.Exam do
  @moduledoc "Composes evidence intake, clinician review and durable export."

  alias MedFabric.Domain.Evidence
  alias MedFabric.Interop.FhirClient
  alias MedFabric.Store.{Encounters, Postgres, Records}
  alias MedFabric.Exam.Artifact

  def lab, do: Application.fetch_env!(:mf_exam, :lab)
  def session_id(enc), do: "preview-" <> enc

  def announce(encounter) do
    Phoenix.PubSub.broadcast(MedFabric.Exam.PubSub, "exam:" <> encounter, :exam_changed)
  end

  def pulse(encounter, actor, value) do
    with true <- Records.member?(Postgres, encounter, actor, :clinician),
         {:ok, evidence} <- Evidence.pulse_rate(value, DateTime.utc_now(), actor),
         :ok <- Records.ready(Postgres, encounter, id(), evidence) do
      announce(encounter)
    else
      false -> {:error, :unauthorized}
      error -> error
    end
  end

  def accept(encounter, acquisition, actor) do
    config = lab()

    with {:ok, url, refs} <- Encounters.export(Postgres, encounter, actor),
         {:ok, %{evidence: evidence}} <- Records.get(Postgres, encounter, acquisition),
         :ok <- verify_evidence(config.artifact_dir, acquisition, evidence),
         external = "#{encounter}:#{acquisition}",
         resource = FhirClient.resource(evidence, external, actor, refs),
         {:ok, :ok} <-
           Records.accept(
             Postgres,
             encounter,
             acquisition,
             actor,
             evidence,
             url,
             external,
             resource
           ) do
      announce(encounter)
    end
  end

  def deliver(encounter, acquisition, actor) do
    with true <- Records.member?(Postgres, encounter, actor, :clinician),
         {:ok, url, resource, nil} <- Records.delivery(Postgres, encounter, acquisition) do
      result = FhirClient.deliver(resource, base_url: url)
      status = Records.delivery_result(Postgres, encounter, acquisition, result)
      announce(encounter)
      status
    else
      {:ok, _, _, remote} when is_binary(remote) -> :ok
      false -> {:error, :unauthorized}
      error -> error
    end
  end

  defp verify_evidence(dir, id, %{"kind" => "audio_pcm16_wav"} = evidence),
    do: Artifact.verify(dir, id, evidence)

  defp verify_evidence(_, _, %{"kind" => "pulse_rate"}), do: :ok

  defp id, do: Base.url_encode64(:crypto.strong_rand_bytes(18), padding: false)
end
