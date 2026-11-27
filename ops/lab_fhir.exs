defmodule MedFabric.LabFHIR do
  @moduledoc false

  def seed_exam(fixture_id, opts \\ []) do
    base_url = Keyword.fetch!(opts, :base_url) |> String.trim_trailing("/")
    true = is_binary(fixture_id) and Regex.match?(~r/\A[A-Za-z0-9.-]{1,64}\z/, fixture_id)
    patient_id = "patient-" <> fixture_id
    encounter_id = "encounter-" <> fixture_id

    patient = %{
      "resourceType" => "Patient",
      "id" => patient_id,
      "identifier" => [%{"system" => "urn:med-fabric:fixture", "value" => fixture_id}],
      "active" => true,
      "name" => [%{"family" => "Fixture", "given" => ["Exam"]}]
    }

    patient_ref = "Patient/" <> patient_id
    encounter_ref = "Encounter/" <> encounter_id

    encounter = %{
      "resourceType" => "Encounter",
      "id" => encounter_id,
      "identifier" => [%{"system" => "urn:med-fabric:fixture", "value" => fixture_id}],
      "status" => "in-progress",
      "class" => %{
        "system" => "http://terminology.hl7.org/CodeSystem/v3-ActCode",
        "code" => "AMB"
      },
      "subject" => %{"reference" => patient_ref}
    }

    with :ok <- put_resource(base_url, "Patient", patient_id, patient),
         :ok <- put_resource(base_url, "Encounter", encounter_id, encounter) do
      {:ok, %{patient_ref: patient_ref, encounter_ref: encounter_ref}}
    end
  end

  defp put_resource(base_url, type, id, resource) do
    case Req.put(base_url <> "/" <> type <> "/" <> id,
           json: resource,
           retry: false,
           receive_timeout: 5_000
         ) do
      {:ok, %{status: status, body: %{"id" => ^id, "resourceType" => ^type}}}
      when status in [200, 201] ->
        :ok

      _ ->
        {:error, {:fixture_write_failed, type}}
    end
  end
end
