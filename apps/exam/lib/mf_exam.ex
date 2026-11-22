defmodule MedFabric.Exam do
  @moduledoc "Composition of one authorized fixture exam."
  alias MedFabric.Exam.CaptureRunner
  alias MedFabric.Interop.FhirClient
  alias MedFabric.Store.Postgres

  def lab, do: Application.fetch_env!(:mf_exam, :lab)
  def key(config), do: {config.encounter_id, "circor-1"}
  def session_id(enc), do: "preview-" <> enc

  def announce(config),
    do:
      Phoenix.PubSub.broadcast(
        MedFabric.Exam.PubSub,
        "exam:" <> config.encounter_id,
        :exam_changed
      )

  def snapshot(config) do
    {active, failed} = CaptureRunner.status()

    case Postgres.fetch(Postgres, key(config)) do
      {:ok, row} -> %{capture: active, error: failed, row: row}
      {:error, _} -> %{capture: active, error: true, row: nil}
    end
  end

  def accept(config, digest) do
    with {:ok, :ok} <-
           Postgres.accept(Postgres, key(config), config.artifact_dir, digest, "lab-clinician") do
      announce(config)
    end
  end

  def deliver(config) do
    case Postgres.fetch(Postgres, key(config)) do
      {:ok, %{remote_ref: ref}} when is_binary(ref) ->
        :ok

      {:ok, %{conflict: false, accepted_by: actor} = row} when is_binary(actor) ->
        result = export(config, row)
        status = Postgres.delivery_result(Postgres, key(config), result)
        announce(config)
        status

      {:ok, _} ->
        {:error, :review_required}

      error ->
        error
    end
  end

  defp export(config, row) do
    {enc, acq} = key(config)
    m = row.metadata
    opts = [base_url: config.fhir_base_url]

    refs = m["delivery"]

    if refs == config.refs do
      observation = %{
        interval_ms: {m["start_ms"], m["end_ms"]},
        artifact_sha256: m["artifact_sha256"],
        continuity: m["continuity"],
        accepted_by: row.accepted_by
      }

      resource =
        FhirClient.build_observation(
          observation,
          %{external_id: "urn:med_fabric:observation:obs:#{enc}:#{acq}"},
          %{
            source_kind: :physionet_circor,
            source_ref: m["source_ref"],
            sample_rate_hz: m["sample_rate_hz"]
          },
          patient_ref: refs["patient_ref"],
          encounter_ref: refs["encounter_ref"]
        )

      FhirClient.deliver(resource, opts)
    else
      {:error, :destination_changed}
    end
  end
end
