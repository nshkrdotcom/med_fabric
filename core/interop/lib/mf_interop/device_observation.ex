defmodule MedFabric.Interop.DeviceObservation do
  @moduledoc "Typed device metric export after clinical acceptance; collection/status events are not observations."
  @identifier_system "urn:med-fabric:observation"
  @time_bases ["qualified_fixture_utc", "qualified_device_utc"]

  @spec resource(map(), String.t(), String.t(), map()) :: {:ok, map()} | {:error, atom()}
  def resource(%{"kind" => kind} = evidence, external, actor, refs)
      when kind in ["device_spo2_v1", "device_pulse_rate_v1"] and is_map(refs) do
    with true <- text?(external) and text?(actor),
         true <- reference?(refs["patient_ref"], "Patient") and reference?(refs["encounter_ref"], "Encounter"),
         true <- reference?(evidence["device_ref"], "Device"),
         true <- text?(evidence["source_event_id"]) and text?(evidence["parent_acquisition_id"]),
         {:ok, measured} <- timestamp(evidence["effective_at"]),
         {:ok, issued} <- timestamp(evidence["issued"]),
         true <- DateTime.compare(measured, issued) in [:lt, :eq],
         :ok <- provenance(evidence["provenance"]),
         {:ok, value} <- decimal(evidence["value"]),
         true <- valid_value?(kind, value),
         true <- valid_unit?(kind, evidence["unit"]) do
      {code, unit, label, profile} = mapping(kind)
      simulated? = evidence["provenance"]["simulated"]
      prefix = if simulated?, do: "Simulated engineering measurement. ", else: "Device-reported measurement. "

      {:ok, %{
        "resourceType" => "Observation",
        "meta" => %{"profile" => [profile]},
        "identifier" => [%{"system" => @identifier_system, "value" => external}],
        "status" => "final",
        "category" => [%{"coding" => [%{"system" => "http://terminology.hl7.org/CodeSystem/observation-category",
          "code" => "vital-signs"}]}],
        "code" => %{"coding" => [%{"system" => "http://loinc.org", "code" => code}]},
        "subject" => %{"reference" => refs["patient_ref"]},
        "encounter" => %{"reference" => refs["encounter_ref"]},
        "effectiveDateTime" => DateTime.to_iso8601(measured),
        "issued" => DateTime.to_iso8601(issued),
        "performer" => [%{"display" => actor}],
        "device" => %{"reference" => evidence["device_ref"]},
        "valueQuantity" => %{"value" => value, "unit" => label,
          "system" => "http://unitsofmeasure.org", "code" => unit},
        "method" => %{"text" => "Pulse oximeter device measurement"},
        "derivedFrom" => [%{"identifier" => %{"system" => "urn:med-fabric:measurement-event",
          "value" => evidence["source_event_id"]}}],
        "note" => [%{"text" => prefix <> "Collection " <> evidence["parent_acquisition_id"] <>
          "; source event " <> evidence["source_event_id"] <> "."}]
      }}
    else
      _ -> {:error, :device_measurement_export_ineligible}
    end
  end
  def resource(_, _, _, _), do: {:error, :unsupported_device_evidence}

  defp mapping("device_spo2_v1"),
    do: {"2708-6", "%", "%", "http://hl7.org/fhir/StructureDefinition/oxygensat"}
  defp mapping("device_pulse_rate_v1"),
    do: {"8867-4", "/min", "beats/minute", "http://hl7.org/fhir/StructureDefinition/heartrate"}

  defp valid_unit?(_kind, nil), do: true
  defp valid_unit?(kind, unit), do: elem(mapping(kind), 1) == unit
  defp valid_value?(kind, value) do
    Decimal.compare(value, 0) in [:eq, :gt] and
      (kind  !=  "device_spo2_v1" or Decimal.compare(value, 100) in [:lt, :eq])
  end

  defp decimal(%{"mantissa" => mantissa, "exponent" => exponent}) do
    with true <- is_binary(mantissa) and byte_size(mantissa) <= 21,
         true <- is_binary(exponent) and byte_size(exponent) <= 3,
         true <- Regex.match?(~r/\A-?(0|[1-9][0-9]*)\z/, mantissa),
         true <- Regex.match?(~r/\A-?(0|[1-9][0-9]*)\z/, exponent),
         {m, ""} <- Integer.parse(mantissa), {e, ""} <- Integer.parse(exponent),
         true <- abs(m) <= 0xFFFFFFFFFFFFFFFF and e in -18..18 do
      {:ok, Decimal.new(if(m < 0, do: -1, else: 1), abs(m), e)}
    else
      _ -> {:error, :invalid_decimal}
    end
  end
  defp decimal(_), do: {:error, :invalid_decimal}

  defp provenance(%{"kind" => kind, "simulated" => simulated, "time_basis" => basis,
      "gateway" => gateway}) when is_boolean(simulated) do
    if text?(kind) and text?(gateway) and basis in @time_bases and
      (basis  !=  "qualified_fixture_utc" or simulated), do: :ok, else: {:error, :unqualified_time}
  end
  defp provenance(_), do: {:error, :unqualified_time}

  defp timestamp(value) when is_binary(value) and byte_size(value) <= 64 do
    with true <- Regex.match?(~r/\A[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}(?:\.[0-9]{1,6})?(?:Z|[+-][0-9]{2}:[0-9]{2})\z/, value),
         {:ok, datetime, _offset} <- DateTime.from_iso8601(value) do
      {:ok, datetime}
    else
      _ -> {:error, :unqualified_time}
    end
  end
  defp timestamp(_), do: {:error, :unqualified_time}
  defp text?(value), do: is_binary(value) and byte_size(value) in 1..256 and String.valid?(value)
  defp reference?(value, type) when is_binary(value),
    do: Regex.match?(~r/\A#{type}\/[A-Za-z0-9.-]{1,64}\z/, value)
  defp reference?(_, _), do: false
end
