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

    resource =
      FhirClient.resource(
        %{
          "kind" => "audio_pcm16_wav",
          "file_sha256" => String.duplicate("a", 64),
          "effective_at" => DateTime.utc_now() |> DateTime.to_iso8601()
        },
        fixture_id,
        "Integration test reviewer",
        %{"patient_ref" => patient, "encounter_ref" => encounter}
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

    [coding] = remote["code"]["coding"]
    enriched = put_in(remote, ["code", "coding"], [Map.put(coding, "display", "Reviewed audio")])

    assert %{status: 200} =
             Req.put!("#{base_url}/#{remote_ref}",
               headers: [{"content-type", "application/fhir+json"}],
               json: enriched
             )

    assert {:ok, %{created?: false, remote_ref: ^remote_ref}} = FhirClient.deliver(resource, opts)

    assert {:error, :conflicting_remote_record} =
             FhirClient.deliver(Map.put(resource, "valueString", String.duplicate("b", 64)), opts)

    different_recording = Map.put(resource, "status", "entered-in-error")
    assert {:error, :conflicting_remote_record} = FhirClient.deliver(different_recording, opts)
    assert {:ok, [confirmed]} = FhirClient.fetch_by_identifier(fixture_id, opts)
    assert confirmed["code"] == enriched["code"]
  end
end
