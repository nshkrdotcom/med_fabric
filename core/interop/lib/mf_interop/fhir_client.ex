defmodule MedFabric.Interop.FhirClient do
  @moduledoc """
  HL7 FHIR R4 `Observation` projection and idempotent delivery client.

  Uses a stable business identifier (`system|value`) together with FHIR
  conditional create (`If-None-Exist`) so retrying after a lost HTTP response
  or transient failure never creates duplicate remote `Observation` resources
  on a HAPI FHIR R4 server.

  Keeps synthetic patient references strictly separate from recording dataset
  provenance (stored under `note` / `meta.tag`).
  """

  @identifier_system "urn:med_fabric:observation"
  @default_base_url "http://localhost:8080/fhir"

  @type delivery_result ::
          {:ok, %{remote_ref: String.t(), resource: map(), created?: boolean()}}
          | {:error, term()}

  @doc """
  Builds an HL7 FHIR R4 `Observation` JSON map from an accepted observation,
  outbox entry, and recording provenance.

  Options:
  - `:patient_ref` (required synthetic patient ref, e.g. `"Patient/synth-001"`)
  """
  @spec build_observation(map(), map(), map(), keyword()) :: map()
  def build_observation(observation, outbox, provenance, opts)
      when is_map(observation) and is_map(outbox) and is_map(provenance) do
    patient_ref = Keyword.fetch!(opts, :patient_ref)
    {start_ms, end_ms} = observation.interval_ms

    %{
      "resourceType" => "Observation",
      "identifier" => [
        %{
          "system" => @identifier_system,
          "value" => outbox.external_id
        }
      ],
      "status" => "final",
      "category" => [
        %{
          "coding" => [
            %{
              "system" => "http://terminology.hl7.org/CodeSystem/observation-category",
              "code" => "exam",
              "display" => "Exam"
            }
          ]
        }
      ],
      "code" => %{
        "coding" => [
          %{
            "system" => "http://loinc.org",
            "code" => "8867-4",
            "display" => "Heart auscultation recording"
          }
        ],
        "text" => "Clinical auscultation acquisition #{observation.acquisition_id}"
      },
      "subject" => %{"reference" => patient_ref},
      "encounter" => %{"reference" => "Encounter/#{observation.encounter_id}"},
      "performer" => [%{"display" => observation.accepted_by}],
      "valueString" =>
        "sha256:#{observation.artifact_sha256} continuity:#{observation.continuity}",
      "note" => [
        %{
          "text" =>
            "provenance=#{Map.get(provenance, :source_kind, :unknown)}:" <>
              "#{Map.get(provenance, :source_ref, "unspecified")} " <>
              "interval_ms=#{start_ms}..#{end_ms} " <>
              "sample_rate_hz=#{Map.get(provenance, :sample_rate_hz, 0)}"
        }
      ]
    }
  end

  @doc """
  Delivers a FHIR R4 `Observation` using conditional create (`If-None-Exist`)
  keyed on the stable business identifier.

  Options:
  - `:base_url` (default `"http://localhost:8080/fhir"`)
  - `:adapter` (optional `Req` adapter function for offline tests; defaults to Finch)
  """
  @spec deliver(map(), keyword()) :: delivery_result()
  def deliver(%{"resourceType" => "Observation"} = resource, opts \\ []) do
    [%{"system" => system, "value" => value} | _] = Map.fetch!(resource, "identifier")
    if_none_exist = "identifier=#{URI.encode_www_form("#{system}|#{value}")}"

    req =
      build_request(opts)
      |> Req.merge(
        method: :post,
        url: "/Observation",
        headers: [
          {"content-type", "application/fhir+json"},
          {"accept", "application/fhir+json"},
          {"if-none-exist", if_none_exist}
        ],
        json: resource,
        retry: false
      )

    case Req.request(req) do
      {:ok, %Req.Response{status: status, body: %{"id" => id} = body}}
      when status in [200, 201] ->
        {:ok, %{remote_ref: "Observation/#{id}", resource: body, created?: status == 201}}

      {:ok, %Req.Response{status: status, body: body}} ->
        {:error, {:http_error, status, body}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  @doc """
  Reads back matching `Observation` resources from the FHIR server by stable
  business identifier.
  """
  @spec fetch_by_identifier(String.t(), keyword()) :: {:ok, [map()]} | {:error, term()}
  def fetch_by_identifier(external_id, opts \\ []) when is_binary(external_id) do
    req =
      build_request(opts)
      |> Req.merge(
        method: :get,
        url: "/Observation",
        params: [identifier: "#{@identifier_system}|#{external_id}"],
        headers: [{"accept", "application/fhir+json"}],
        retry: false
      )

    case Req.request(req) do
      {:ok, %Req.Response{status: 200, body: %{"resourceType" => "Bundle"} = bundle}} ->
        entries =
          bundle
          |> Map.get("entry", [])
          |> Enum.map(&Map.fetch!(&1, "resource"))

        {:ok, entries}

      {:ok, %Req.Response{status: status, body: body}} ->
        {:error, {:http_error, status, body}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp build_request(opts) do
    base_url = Keyword.get(opts, :base_url, @default_base_url)

    req =
      [base_url: base_url]
      |> maybe_put(:adapter, Keyword.get(opts, :adapter))
      |> Req.new()

    opts
    |> Keyword.get(:private, %{})
    |> Enum.reduce(req, fn {k, v}, acc -> Req.Request.put_private(acc, k, v) end)
  end

  defp maybe_put(opts, _key, nil), do: opts
  defp maybe_put(opts, key, value), do: Keyword.put(opts, key, value)
end
