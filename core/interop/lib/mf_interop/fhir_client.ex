defmodule MedFabric.Interop.FhirClient do
  @moduledoc """
  Maps accepted clinical observations (reviewed audio, manual pulse and typed
  device spot-check metrics) to HL7 FHIR R4 `Observation` resources and
  delivers them idempotently via conditional create (`If-None-Exist`) with
  strict typed read-back confirmation.
  """

  alias MedFabric.Interop.Observation
  alias MedFabric.Interop.DeviceObservation
  alias MedFabric.Interop.JSON, as: FHIRJSON

  @identifier_system "urn:med-fabric:observation"
  @default_base_url "http://127.0.0.1:18080/fhir"
  @headers [{"content-type", "application/fhir+json"}, {"accept", "application/fhir+json"}]

  def resource(%{"kind" => kind} = evidence, external, actor, refs)
      when kind in ["device_spo2_v1", "device_pulse_rate_v1"] do
    case DeviceObservation.resource(evidence, external, actor, refs) do
      {:ok, resource} -> resource
      {:error, reason} -> raise ArgumentError, "device export refused: #{reason}"
    end
  end

  def resource(evidence, external, actor, refs) do
    base = %{
      "resourceType" => "Observation",
      "identifier" => identifier(@identifier_system, external),
      "status" => "final",
      "subject" => %{"reference" => refs["patient_ref"]},
      "encounter" => %{"reference" => refs["encounter_ref"]},
      "effectiveDateTime" => evidence["effective_at"],
      "performer" => [%{"display" => actor}]
    }

    Map.merge(base, observation_value(evidence))
  end

  @doc "Validate device export eligibility before writing an outbox intent."
  def resource_checked(%{"kind" => kind} = evidence, external, actor, refs)
      when kind in ["device_spo2_v1", "device_pulse_rate_v1"],
      do: DeviceObservation.resource(evidence, external, actor, refs)
  def resource_checked(evidence, external, actor, refs) do
    {:ok, resource(evidence, external, actor, refs)}
  rescue
    _ in [ArgumentError, FunctionClauseError] -> {:error, :unsupported_evidence}
  end

  defp observation_value(%{"kind" => "pulse_rate", "value" => value}) do
    %{
      "code" => %{"coding" => [%{"system" => "http://loinc.org", "code" => "8867-4"}]},
      "valueQuantity" => %{
        "value" => value,
        "unit" => "beats/minute",
        "system" => "http://unitsofmeasure.org",
        "code" => "/min"
      },
      "method" => %{"text" => "Manually entered measurement"}
    }
  end

  defp observation_value(%{"kind" => "audio_pcm16_wav"} = evidence) do
    %{
      "code" => %{
        "coding" => [
          %{
            "system" => "https://med-fabric.local/fhir/CodeSystem/exam-observation",
            "code" => "reviewed-auscultation-recording"
          }
        ]
      },
      "valueString" => evidence["file_sha256"],
      "method" => %{"text" => "Reviewed diagnostic audio recording"}
    }
  end

  @spec deliver(map(), keyword()) :: {:ok, map()} | {:error, term()}
  def deliver(%{"resourceType" => "Observation"} = resource, opts \\ []) do
    conditional_create(resource, opts)
  end

  @spec fetch_by_identifier(String.t(), keyword()) :: {:ok, [map()]} | {:error, term()}
  def fetch_by_identifier(external_id, opts \\ []) do
    search("Observation", @identifier_system, external_id, opts)
  end

  def conditional_create(%{"resourceType" => type, "identifier" => [first | _]} = resource, opts) do
    %{"system" => system, "value" => value} = first
    condition = URI.encode_query(identifier: "#{system}|#{value}")

    case request(opts,
           method: :post,
           url: "/#{type}",
           headers: [{"if-none-exist", condition}, {"prefer", "return=representation"} | @headers],
           body: FHIRJSON.encode_to_iodata!(resource)
         ) do
      {:ok, %{status: status, body: %{"id" => _} = remote}} when status in [200, 201] ->
        confirmed(resource, remote, first, status == 201)

      {:ok, %{status: status}} when status in [200, 201] ->
        case search(type, system, value, opts) do
          {:ok, [remote]} -> confirmed(resource, remote, first, status == 201)
          {:ok, _} -> {:error, :unconfirmed_remote_record}
          {:error, _} = error -> error
        end

      result ->
        response_error(result)
    end
  end

  defp confirmed(expected, %{"id" => id} = actual, identifier, created?)
       when is_binary(id) and byte_size(id) > 0 do
    fields = Map.drop(expected, ["identifier"])
    remote_identifiers = List.wrap(actual["identifier"])

    if Regex.match?(~r/\A[A-Za-z0-9.-]{1,64}\z/, id) and clinical_fields_match?(fields, actual) and
         Enum.any?(remote_identifiers, &matches?(identifier, &1)) do
      {:ok,
       %{remote_ref: "#{actual["resourceType"]}/#{id}", resource: actual, created?: created?}}
    else
      {:error, :conflicting_remote_record}
    end
  end

  defp confirmed(_expected, _actual, _identifier, _created?),
    do: {:error, :unconfirmed_remote_record}

  defp clinical_fields_match?(%{"resourceType" => "Observation"} = expected, actual),
    do: Observation.matches?(expected, actual)

  defp clinical_fields_match?(expected, actual), do: matches?(expected, actual)

  # HAPI can enrich reference objects and reorder repeated elements.
  defp matches?(expected, actual) when is_map(expected) and is_map(actual),
    do: Enum.all?(expected, fn {k, v} -> matches?(v, Map.get(actual, k)) end)

  defp matches?(expected, actual) when is_list(expected) and is_list(actual),
    do: Enum.sort(expected) == Enum.sort(actual)

  defp matches?(expected, actual), do: expected == actual

  defp search(type, system, value, opts) do
    case request(opts,
           method: :get,
           url: "/#{type}",
           params: [identifier: "#{system}|#{value}"],
           headers: @headers
         ) do
      {:ok, %{status: 200, body: %{"resourceType" => "Bundle"} = bundle}} ->
        search_results(bundle)

      result ->
        response_error(result)
    end
  end

  defp search_results(bundle) do
    links = Map.get(bundle, "link", [])
    entries = Map.get(bundle, "entry", [])

    cond do
      not is_list(links) or not Enum.all?(links, &is_map/1) or
          not is_list(entries) or not Enum.all?(entries, &valid_search_entry?/1) ->
        {:error, :invalid_search_response}

      Enum.any?(links, &(&1["relation"] == "next")) ->
        {:error, :ambiguous_search}

      true ->
        {:ok, for(%{"resource" => resource} = entry <- entries,
          get_in(entry, ["search", "mode"]) in [nil, "match"], do: resource)}
    end
  end

  defp valid_search_entry?(%{"resource" => resource} = entry) when is_map(resource),
    do: is_nil(entry["search"]) or is_map(entry["search"])
  defp valid_search_entry?(_), do: false

  defp request(opts, request_opts) do
    defaults = [base_url: Keyword.get(opts, :base_url, @default_base_url), retry: false,
      redirect: false, receive_timeout: 5_000,
      decoders: [json: FHIRJSON, json_api: FHIRJSON]]
    defaults = Keyword.merge(defaults, Keyword.take(opts, [:adapter, :receive_timeout]))

    defaults
    |> Req.new()
    |> Req.request(request_opts)
  end

  defp response_error({:ok, %{status: status, body: body}}),
    do: {:error, {:http_error, status, body}}

  defp response_error({:error, _} = error), do: error

  defp identifier(system, value), do: [%{"system" => system, "value" => value}]
end
