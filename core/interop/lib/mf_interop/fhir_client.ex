defmodule MedFabric.Interop.FhirClient do
  @moduledoc """
  Exports a reviewed recording to FHIR R4 using conditional create by identifier.

  The test server receives synthetic clinical references. Fixture origin and
  continuity describe the reviewed artifact independently of those references.
  """

  @identifier_system "urn:med-fabric:observation"
  @fixture_system "urn:med-fabric:fixture"
  @default_base_url "http://127.0.0.1:18080/fhir"
  @headers [{"content-type", "application/fhir+json"}, {"accept", "application/fhir+json"}]

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

  def seed_exam(fixture_id, opts \\ []) do
    patient = %{
      "resourceType" => "Patient",
      "identifier" => identifier(@fixture_system, fixture_id),
      "active" => true,
      "name" => [%{"family" => "Fixture", "given" => ["Exam"]}]
    }

    with {:ok, %{remote_ref: patient_ref}} <- conditional_create(patient, opts) do
      encounter = %{
        "resourceType" => "Encounter",
        "identifier" => identifier(@fixture_system, fixture_id),
        "status" => "finished",
        "class" => %{
          "system" => "http://terminology.hl7.org/CodeSystem/v3-ActCode",
          "code" => "AMB"
        },
        "subject" => %{"reference" => patient_ref}
      }

      with {:ok, %{remote_ref: encounter_ref}} <- conditional_create(encounter, opts) do
        {:ok, %{patient_ref: patient_ref, encounter_ref: encounter_ref}}
      end
    end
  end

  @spec deliver(map(), keyword()) :: {:ok, map()} | {:error, term()}
  def deliver(%{"resourceType" => "Observation"} = resource, opts \\ []) do
    conditional_create(resource, opts)
  end

  @spec fetch_by_identifier(String.t(), keyword()) :: {:ok, [map()]} | {:error, term()}
  def fetch_by_identifier(external_id, opts \\ []) do
    search("Observation", @identifier_system, external_id, opts)
  end

  defp conditional_create(%{"resourceType" => type, "identifier" => [first | _]} = resource, opts) do
    %{"system" => system, "value" => value} = first
    condition = URI.encode_query(identifier: "#{system}|#{value}")

    case request(opts,
           method: :post,
           url: "/#{type}",
           headers: [{"if-none-exist", condition}, {"prefer", "return=representation"} | @headers],
           json: resource
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

    if clinical_fields_match?(fields, actual) and
         Enum.any?(remote_identifiers, &matches?(identifier, &1)) do
      {:ok,
       %{remote_ref: "#{actual["resourceType"]}/#{id}", resource: actual, created?: created?}}
    else
      {:error, :conflicting_remote_record}
    end
  end

  defp confirmed(_expected, _actual, _identifier, _created?),
    do: {:error, :unconfirmed_remote_record}

  defp clinical_fields_match?(%{"resourceType" => "Observation"} = expected, actual) do
    matches?(expected, actual) and
      Enum.all?(Map.keys(actual), fn key ->
        if String.starts_with?(key, "value") or
             key in ~w(component dataAbsentReason interpretation modifierExtension) do
          Map.has_key?(expected, key)
        else
          true
        end
      end)
  end

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
        if Enum.any?(Map.get(bundle, "link", []), &(&1["relation"] == "next")) do
          {:error, :ambiguous_search}
        else
          {:ok,
           for(
             %{"resource" => r} = entry <- Map.get(bundle, "entry", []),
             get_in(entry, ["search", "mode"]) in [nil, "match"],
             do: r
           )}
        end

      result ->
        response_error(result)
    end
  end

  defp request(opts, request_opts) do
    defaults = [base_url: Keyword.get(opts, :base_url, @default_base_url), retry: false]
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
