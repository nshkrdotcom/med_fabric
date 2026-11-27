defmodule MedFabric.Interop.FhirClient do
  @moduledoc "Checked FHIR R4 mapping after native acceptance and bounded exact-identifier transport. Remote matching is separate from the outbox safety predicate."
  alias MedFabric.Interop.{JSON, Observation}
  @headers [{"content-type", "application/fhir+json"}, {"accept", "application/fhir+json"}]
  @max_body 1_048_576

  def resource_checked(native, %{"system" => system, "value" => external}, refs)
      when is_map(native) and is_map(refs) do
    with true <-
           is_binary(system) and
             Regex.match?(
               ~r/\Aurn:uuid:[0-9a-f]{8}-[0-9a-f]{4}-[1-5][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}\z/,
               system
             ),
         true <-
           text?(external) and text?(native["actor"]) and is_binary(native["source_digest"]) and
             Regex.match?(~r/\A[0-9a-f]{64}\z/, native["source_digest"]),
         true <-
           reference?(refs["patient_ref"], "Patient") and
             reference?(refs["encounter_ref"], "Encounter"),
         {:ok, kind, unit, label} <- mapping(native["kind"]),
         true <- native["unit"] == unit,
         {:ok, value} <- represent_decimal(native["value"]),
         {:ok, at, _} <- DateTime.from_iso8601(native["effective_at"]),
         {:ok, issued, _} <- DateTime.from_iso8601(native["issued"]),
         true <- DateTime.compare(at, issued) != :gt do
      resource = %{
        "resourceType" => "Observation",
        "identifier" => [%{"system" => system, "value" => external}],
        "status" => "final",
        "category" => [
          %{
            "coding" => [
              %{
                "system" => "http://terminology.hl7.org/CodeSystem/observation-category",
                "code" => "vital-signs"
              }
            ]
          }
        ],
        "meta" => %{"profile" => ["http://hl7.org/fhir/StructureDefinition/vitalsigns"]},
        "code" => %{"coding" => [%{"system" => "http://loinc.org", "code" => kind}]},
        "subject" => %{"reference" => refs["patient_ref"]},
        "encounter" => %{"reference" => refs["encounter_ref"]},
        "effectiveDateTime" => DateTime.to_iso8601(at),
        "issued" => DateTime.to_iso8601(issued),
        "performer" => [%{"display" => native["actor"]}],
        "valueQuantity" => %{
          "value" => value,
          "unit" => label,
          "system" => "http://unitsofmeasure.org",
          "code" => unit
        },
        "derivedFrom" => [
          %{
            "identifier" => %{
              "system" => "urn:medfabric:native-evidence:sha256",
              "value" => native["source_digest"]
            }
          }
        ]
      }

      qualify_provenance(resource, native)
    else
      _ -> {:error, :representation_unavailable}
    end
  rescue
    _ in [ArgumentError, FunctionClauseError] -> {:error, :representation_unavailable}
  end

  def resource_checked(_, _, _), do: {:error, :representation_unavailable}

  defp qualify_provenance(resource, native) do
    resource =
      case native["provenance"] do
        %{"kind" => "manual"} ->
          Map.put(resource, "method", %{"text" => "Manually entered measurement"})

        %{
          "kind" => "simulated_plxs",
          "simulated" => true,
          "time_basis" => "qualified_fixture_utc"
        } ->
          Map.merge(resource, %{
            "method" => %{"text" => "Synthetic PLXS fixture"},
            "note" => [%{"text" => "Simulated source; not a physical device measurement."}],
            "meta" =>
              Map.put(resource["meta"], "tag", [
                %{"system" => "urn:medfabric:source", "code" => "simulated"}
              ])
          })
          |> device_lineage(native)

        _ ->
          nil
      end

    if resource, do: {:ok, resource}, else: {:error, :unqualified_native_provenance}
  end

  def mapping_version, do: "medfabric.fhir-r4.v2"
  def canonical_bytes(resource), do: JSON.encode_to_iodata!(resource) |> IO.iodata_to_binary()

  def deliver(resource, opts) do
    with %{
           "resourceType" => "Observation",
           "identifier" => [%{"system" => system, "value" => value} = identifier]
         } <- resource,
         bytes = Keyword.get(opts, :pinned_bytes, canonical_bytes(resource)),
         true <- is_binary(bytes) and valid_pinned?(JSON.decode(bytes), resource) do
      condition = URI.encode_query(identifier: system <> "|" <> value)

      case request(opts,
             method: :post,
             url: "/Observation",
             headers: [
               {"if-none-exist", condition},
               {"prefer", "return=representation"} | @headers
             ],
             body: bytes
           ) do
        {:ok, %{status: status, body: remote}} when status in [200, 201] ->
          confirm_delivery(resource, remote, identifier, opts)

        {:ok, %{status: status}} when status in [409, 412] ->
          {:conflict, :conditional_conflict}

        {:error, :destination_invalid} ->
          {:noncommitted, :before_http}

        _ ->
          {:unknown, :possible_remote_effect}
      end
    else
      _ -> {:permanent_noncommit, :before_http}
    end
  end

  defp confirm_delivery(resource, remote, identifier, opts) do
    case verify(resource, remote, identifier) do
      {:matched, _} = matched -> matched
      {:conflict, _} = conflict -> conflict
      _ -> reconcile(resource, opts)
    end
  end

  defp valid_pinned?({:ok, decoded}, resource),
    do:
      Observation.matches?(resource, decoded) and decoded["identifier"] == resource["identifier"]

  defp valid_pinned?(_, _), do: false

  def reconcile(
        %{"identifier" => [%{"system" => system, "value" => value} = identifier]} = resource,
        opts
      ) do
    case request(opts,
           method: :get,
           url: "/Observation",
           headers: @headers,
           params: [identifier: system <> "|" <> value, _count: 2]
         ) do
      {:ok, %{status: 200, body: %{"resourceType" => "Bundle"} = bundle}} ->
        reconcile_bundle(resource, identifier, bundle)

      _ ->
        {:unknown, :reconciliation_unavailable}
    end
  end

  defp reconcile_bundle(resource, identifier, bundle) do
    links = Map.get(bundle, "link", [])
    entries = Map.get(bundle, "entry", [])

    cond do
      not is_list(links) or not is_list(entries) ->
        {:unknown, :unconfirmed_remote_record}

      Enum.any?(links, &next_link?/1) or length(entries) > 1 ->
        {:conflict, :ambiguous_search}

      entries == [] ->
        {:unknown, :empty_search}

      true ->
        verify_entry(resource, hd(entries), identifier)
    end
  end

  defp next_link?(link), do: is_map(link) and link["relation"] == "next"

  defp verify_entry(resource, %{"resource" => remote}, identifier),
    do: verify(resource, remote, identifier)

  defp verify_entry(_, _, _), do: {:unknown, :unconfirmed_remote_record}

  def verify(
        expected,
        %{"resourceType" => "Observation", "id" => id, "identifier" => identifiers} = remote,
        identifier
      )
      when is_binary(id) and is_list(identifiers) do
    if Regex.match?(~r/\A[A-Za-z0-9.-]{1,64}\z/, id) and identifier in identifiers and
         Observation.matches?(expected, remote),
       do: {:matched, "Observation/" <> id},
       else: {:conflict, :conflicting_remote_record}
  end

  def verify(_, _, _), do: {:unknown, :unconfirmed_remote_record}

  defp request(opts, request_opts) do
    with {:ok, uri} <- URI.new(Keyword.fetch!(opts, :base_url)),
         true <- uri.scheme in ["http", "https"] and is_binary(uri.host) and is_nil(uri.userinfo) do
      Req.new(
        base_url: URI.to_string(uri),
        retry: false,
        redirect: false,
        receive_timeout: 5_000,
        decode_body: false,
        into: &bounded_body/2
      )
      |> Req.merge(Keyword.take(opts, [:adapter, :receive_timeout]))
      |> Req.request(request_opts)
      |> decode_response()
    else
      _ -> {:error, :destination_invalid}
    end
  rescue
    _ in [ArgumentError, KeyError] -> {:error, :destination_invalid}
  end

  defp bounded_body({:data, data}, {request, response}) do
    body = response.body || ""

    if byte_size(body) + byte_size(data) <= @max_body,
      do: {:cont, {request, %{response | body: body <> data}}},
      else: {:halt, {request, %{response | status: 502, body: ""}}}
  end

  defp bounded_body(_, pair), do: {:cont, pair}

  defp decode_response({:ok, %{body: bytes} = response})
       when is_binary(bytes) and byte_size(bytes) <= @max_body do
    case JSON.decode(bytes) do
      {:ok, body} -> {:ok, %{response | body: body}}
      _ -> {:error, :malformed_response}
    end
  end

  defp decode_response(_), do: {:error, :transport_unknown}

  defp device_lineage(resource, native) do
    if Enum.all?(~w(source_device source_event_id parent_acquisition_id), &text?(native[&1])) and
         text?(native["provenance"]["gateway"]) do
      lineage =
        resource["derivedFrom"] ++
          [
            %{
              "identifier" => %{
                "system" => "urn:medfabric:acquisition",
                "value" => native["parent_acquisition_id"]
              }
            },
            %{
              "identifier" => %{
                "system" => "urn:medfabric:source-event",
                "value" => native["parent_acquisition_id"] <> ":" <> native["source_event_id"]
              }
            }
          ]

      Map.merge(resource, %{
        "derivedFrom" => lineage,
        "device" => %{
          "identifier" => %{
            "system" => "urn:medfabric:source-device",
            "value" => native["source_device"]
          }
        },
        "extension" => [
          %{
            "url" => "urn:medfabric:provenance:time-basis",
            "valueCode" => native["provenance"]["time_basis"]
          },
          %{
            "url" => "urn:medfabric:provenance:gateway",
            "valueIdentifier" => %{
              "system" => "urn:medfabric:gateway",
              "value" => native["provenance"]["gateway"]
            }
          }
        ]
      })
    end
  end

  defp mapping(kind) when kind in ["pulse_rate", "device_pulse_rate_v1"],
    do: {:ok, "8867-4", "/min", "beats/minute"}

  defp mapping("device_spo2_v1"), do: {:ok, "2708-6", "%", "%"}
  defp mapping(_), do: {:error, :unsupported_representation}

  defp represent_decimal(%{"mantissa" => m, "exponent" => e})
       when is_binary(m) and is_binary(e) and byte_size(m) <= 21 and byte_size(e) <= 3 do
    # This mapper supports up to 18 significant decimal digits. Native values
    # have a larger exact domain; unsupported representation is an outbox block.
    valid = supported_decimal?(m, e)

    case if(valid, do: Decimal.parse(m <> "e" <> e), else: :unsupported) do
      {value, ""} ->
        if Decimal.nan?(value) or Decimal.inf?(value),
          do: {:error, :nonfinite},
          else: {:ok, value}

      _ ->
        {:error, :invalid_decimal}
    end
  end

  defp represent_decimal(_), do: {:error, :invalid_decimal}

  defp supported_decimal?(m, e) do
    Regex.match?(~r/\A(?:0|[1-9][0-9]*|-[1-9][0-9]*)\z/, m) and
      Regex.match?(~r/\A(?:0|[1-9][0-9]*|-[1-9][0-9]*)\z/, e) and
      String.length(String.trim_leading(m, "-")) <= 18 and String.to_integer(e) in -18..18
  end

  defp reference?(s, type),
    do: is_binary(s) and Regex.match?(~r/\A#{type}\/[A-Za-z0-9.-]{1,64}\z/, s)

  defp text?(s), do: is_binary(s) and byte_size(s) in 1..256 and String.valid?(s)
end
