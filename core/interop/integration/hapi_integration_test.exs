defmodule MedFabric.Interop.HapiIntegrationTest do
  use ExUnit.Case, async: false

  alias MedFabric.Interop.FhirClient


  defmodule DropCreatedResponse do
    @moduledoc false

    def run(request) do
      {request, %Req.Response{status: 201}} = Req.Finch.run(request)
      {request, %RuntimeError{message: "discarded response after HAPI accepted the write"}}
    end
  end

  test "R4 HAPI conditional create survives a response lost after the actual write" do
    base_url = System.fetch_env!("FHIR_BASE_URL")
    opts = [base_url: base_url]
    fixture_id = "record-test-" <> Base.encode16(:crypto.strong_rand_bytes(8), case: :lower)

    assert %{status: 200, body: %{"fhirVersion" => "4.0.1"}} =
             Req.get!("#{base_url}/metadata", headers: [{"accept", "application/fhir+json"}])

    assert {:ok, %{patient_ref: patient, encounter_ref: encounter} = refs} =
             FhirClient.seed_exam(fixture_id, opts)

    assert {:ok, ^refs} = FhirClient.seed_exam(fixture_id, opts)

    observation = %{
      artifact_sha256: "recording-digest",
      interval_ms: {0, 1_000},
      continuity: :observed_continuous,
      accepted_by: "Integration test reviewer"
    }

    resource =
      FhirClient.build_observation(
        observation,
        %{external_id: fixture_id},
        %{source_kind: :fixture, source_ref: "clip.wav"},
        patient_ref: patient,
        encounter_ref: encounter
      )

    assert {:error, %RuntimeError{message: "discarded response after HAPI accepted the write"}} =
             FhirClient.deliver(resource, Keyword.put(opts, :adapter, DropCreatedResponse))

    assert {:ok, %{created?: false, remote_ref: remote_ref}} = FhirClient.deliver(resource, opts)
    assert {:ok, [remote]} = FhirClient.fetch_by_identifier(fixture_id, opts)
    assert "Observation/" <> remote["id"] == remote_ref
    assert remote["subject"]["reference"] == patient
    assert remote["encounter"]["reference"] == encounter
    assert remote["valueString"] == resource["valueString"]
    assert hd(remote["code"]["coding"])["code"] == "reviewed-auscultation-recording"

    different_recording = Map.put(resource, "valueString", "different recording")
    assert {:error, :conflicting_remote_record} = FhirClient.deliver(different_recording, opts)
    assert {:ok, [^remote]} = FhirClient.fetch_by_identifier(fixture_id, opts)
  end
end
