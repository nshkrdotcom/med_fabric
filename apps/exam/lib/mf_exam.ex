defmodule MedFabric.Exam do
  @moduledoc "Composes evidence intake, clinician review and durable export."

  alias MedFabric.Domain.Evidence
  alias MedFabric.Exam.{Artifact, Context}
  alias MedFabric.Interop.FhirClient
  alias MedFabric.Store.{Encounters, Postgres, Records}

  def lab, do: Application.fetch_env!(:mf_exam, :lab)
  def session_id(enc), do: "preview-" <> enc

  def context do
    lab = Application.get_env(:mf_exam, :lab, %{})

    %Context{
      artifact_dir: lab[:artifact_dir],
      encounter_ids: Map.keys(lab[:encounters] || %{})
    }
  end

  def member?(encounter, actor, role, db \\ Postgres)

  def member?(encounter, actor, role, db) when role in [:patient, "patient"],
    do: Records.member?(db, encounter, actor, :patient)

  def member?(encounter, actor, role, db) when role in [:clinician, "clinician"],
    do: Records.member?(db, encounter, actor, :clinician)

  def member?(_, _, _, _), do: false

  def announce(encounter, context \\ context()) do
    Phoenix.PubSub.broadcast(context.pubsub, "exam:" <> encounter, :exam_changed)
  end

  def pulse(encounter, actor, value, context \\ context()) do
    with true <- member?(encounter, actor, :clinician, context.db),
         {:ok, evidence} <- Evidence.pulse_rate(value, DateTime.utc_now(), actor),
         :ok <- Records.ready(context.db, encounter, id(), evidence) do
      announce(encounter, context)
    else
      false -> {:error, :unauthorized}
      error -> error
    end
  end

  def accept(encounter, acquisition, actor, context \\ context()) do
    with {:ok, url, refs} <- Encounters.export(context.db, encounter, actor),
         {:ok, %{evidence: evidence}} <- Records.get(context.db, encounter, acquisition),
         :ok <- verify_evidence(context.artifact_dir, acquisition, evidence),
         external = "#{encounter}:#{acquisition}",
         resource = FhirClient.resource(evidence, external, actor, refs),
         {:ok, :ok} <-
           Records.accept(
             context.db,
             encounter,
             acquisition,
             actor,
             evidence,
             url,
             external,
             resource
           ) do
      announce(encounter, context)
    end
  end

  def deliver(encounter, acquisition, actor, context \\ context()) do
    with true <- member?(encounter, actor, :clinician, context.db),
         {:ok, url, resource, nil} <- Records.delivery(context.db, encounter, acquisition) do
      result = FhirClient.deliver(resource, base_url: url)
      status = Records.delivery_result(context.db, encounter, acquisition, result)
      announce(encounter, context)
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
