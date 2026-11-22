defmodule MedFabric.Interop.FhirClientTest do
  use ExUnit.Case, async: true

  alias MedFabric.Domain.Encounter
  alias MedFabric.Interop.FhirClient

  defmodule SimulatedHapiAdapter do
    @moduledoc false

    def start(drop_first_response?) do
      Agent.start_link(fn ->
        %{next_id: 1, by_identifier: %{}, dropped_once?: false, drop_first?: drop_first_response?}
      end)
    end

    def run(%Req.Request{} = request) do
      agent = request.private[:hapi_agent]

      case {request.method, request.url.path} do
        {:post, "/fhir/Observation"} -> handle_post(agent, request)
        {:get, "/fhir/Observation"} -> handle_get(agent, request)
      end
    end

    defp handle_post(agent, request) do
      body = Jason.decode!(IO.iodata_to_binary(request.body))
      if_none_exist = Req.Request.get_header(request, "if-none-exist") |> List.first()
      "identifier=" <> encoded_id = if_none_exist
      ident_key = URI.decode_www_form(encoded_id)

      case Agent.get_and_update(agent, &upsert_observation(&1, ident_key, body)) do
        {:ok, status, payload} ->
          {request,
           %Req.Response{
             status: status,
             headers: %{"content-type" => ["application/fhir+json"]},
             body: Jason.encode!(payload)
           }}

        {:error, reason} ->
          {request, %RuntimeError{message: "simulated network error: #{inspect(reason)}"}}
      end
    end

    defp upsert_observation(state, ident_key, body) do
      case Map.get(state.by_identifier, ident_key) do
        nil ->
          id = "hapi-#{state.next_id}"
          stored = Map.put(body, "id", id)

          next_state = %{
            state
            | next_id: state.next_id + 1,
              by_identifier: Map.put(state.by_identifier, ident_key, stored)
          }

          if state.drop_first? and not state.dropped_once? do
            {{:error, :closed_after_write}, %{next_state | dropped_once?: true}}
          else
            {{:ok, 201, stored}, next_state}
          end

        existing ->
          {{:ok, 200, existing}, state}
      end
    end

    defp handle_get(agent, request) do
      %{"identifier" => ident_key} = URI.decode_query(request.url.query || "")

      matches =
        Agent.get(agent, fn state ->
          case Map.get(state.by_identifier, ident_key) do
            nil -> []
            resource -> [resource]
          end
        end)

      bundle = %{
        "resourceType" => "Bundle",
        "type" => "searchset",
        "total" => length(matches),
        "entry" => Enum.map(matches, &%{"resource" => &1})
      }

      {request,
       %Req.Response{
         status: 200,
         headers: %{"content-type" => ["application/fhir+json"]},
         body: Jason.encode!(bundle)
       }}
    end
  end

  test "lost HTTP response after remote write followed by conditional-create retry produces exactly one FHIR Observation" do
    {:ok, enc} = Encounter.new("enc_fhir_1") |> Encounter.request_acquisition("acq_1")

    enc =
      Encounter.apply_fact(
        enc,
        {:capture_completed,
         %{
           acquisition_id: "acq_1",
           session_id: "sess_fhir_1",
           artifact_sha256: "7c8c93ee4602072aa5c0e4c81a5a9e28d926b278f701218ea588bde9644efc66",
           interval_ms: {200, 23_800},
           continuity: :observed_continuous
         }}
      )

    {:ok, _enc, %{observation: obs, export_intent: intent}} =
      Encounter.accept_acquisition(
        enc,
        "acq_1",
        "7c8c93ee4602072aa5c0e4c81a5a9e28d926b278f701218ea588bde9644efc66",
        "clin_7"
      )

    outbox = Map.put(intent, :external_id, "urn:med_fabric:observation:#{obs.observation_id}")

    provenance = %{
      source_kind: :physionet_circor,
      source_ref: "2530_AV.wav",
      sample_rate_hz: 4_000
    }

    resource =
      FhirClient.build_observation(obs, outbox, provenance, patient_ref: "Patient/synth-001")

    assert resource["subject"] == %{"reference" => "Patient/synth-001"}
    assert hd(resource["note"])["text"] =~ "physionet_circor:2530_AV.wav"

    {:ok, agent} = SimulatedHapiAdapter.start(true)

    opts = [
      base_url: "http://localhost:8080/fhir",
      adapter: SimulatedHapiAdapter,
      private: %{hapi_agent: agent}
    ]

    # First delivery writes on HAPI FHIR but drops the HTTP response in flight
    assert {:error, %RuntimeError{message: "simulated network error: :closed_after_write"}} =
             FhirClient.deliver(resource, opts)

    # Retry with identical conditional create If-None-Exist converges on the existing resource
    assert {:ok, %{remote_ref: "Observation/hapi-1", created?: false}} =
             FhirClient.deliver(resource, opts)

    # Read-back proves exactly one remote FHIR R4 Observation exists
    assert {:ok, [remote]} = FhirClient.fetch_by_identifier(outbox.external_id, opts)
    assert remote["id"] == "hapi-1"
    assert remote["subject"] == %{"reference" => "Patient/synth-001"}
    assert remote["valueString"] =~ "continuity:observed_continuous"
  end
end
