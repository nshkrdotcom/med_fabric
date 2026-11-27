defmodule MedFabric.LabFHIR do
  @moduledoc false
  alias MedFabric.Interop.FhirClient

  def seed_exam(fixture_id, opts \\ []) do
    patient = %{
      "resourceType" => "Patient",
      "identifier" => [%{"system" => "urn:med-fabric:fixture", "value" => fixture_id}],
      "active" => true,
      "name" => [%{"family" => "Fixture", "given" => ["Exam"]}]
    }

    with {:ok, %{remote_ref: patient_ref}} <-
           FhirClient.conditional_create(patient, opts) do
      encounter = %{
        "resourceType" => "Encounter",
        "identifier" => [%{"system" => "urn:med-fabric:fixture", "value" => fixture_id}],
        "status" => "in-progress",
        "class" => %{
          "system" => "http://terminology.hl7.org/CodeSystem/v3-ActCode",
          "code" => "AMB"
        },
        "subject" => %{"reference" => patient_ref}
      }

      with {:ok, %{remote_ref: encounter_ref}} <-
             FhirClient.conditional_create(encounter, opts) do
        {:ok, %{patient_ref: patient_ref, encounter_ref: encounter_ref}}
      end
    end
  end
end
