defmodule MedFabric.Interop.ObservationTest do
  use ExUnit.Case, async: true
  alias MedFabric.Interop.{FhirClient, Observation}

  defp native do
    %{
      "kind" => "pulse_rate",
      "value" => %{"mantissa" => "76", "exponent" => "0"},
      "unit" => "/min",
      "effective_at" => "2026-11-24T12:00:00Z",
      "issued" => "2026-11-24T12:00:01Z",
      "actor" => "clinician",
      "source_digest" => String.duplicate("a", 64),
      "provenance" => %{"kind" => "manual"}
    }
  end

  defp identifier,
    do: %{"system" => "urn:uuid:00000000-0000-4000-8000-000000000001", "value" => "native_one"}

  defp refs, do: %{"patient_ref" => "Patient/one", "encounter_ref" => "Encounter/one"}

  test "checked mapping and exact remote verification permit only server enrichment" do
    assert {:ok, expected} = FhirClient.resource_checked(native(), identifier(), refs())

    remote =
      expected |> Map.put("id", "remote-1") |> put_in(["subject", "display"], "Patient display")

    assert Observation.matches?(expected, remote)
    assert {:matched, "Observation/remote-1"} = FhirClient.verify(expected, remote, identifier())

    for changed <- [
          put_in(remote, ["valueQuantity", "value"], "76"),
          put_in(remote, ["valueQuantity", "comparator"], "<"),
          put_in(remote, ["subject", "reference"], "Patient/other"),
          Map.put(remote, "component", [])
        ] do
      refute Observation.matches?(expected, changed)
      assert {:conflict, _} = FhirClient.verify(expected, changed, identifier())
    end
  end

  test "native-valid but unsupported numeric representation blocks mapping without clinical revalidation" do
    native = put_in(native(), ["value", "mantissa"], "9223372036854775807")
    assert {:error, _} = FhirClient.resource_checked(native, identifier(), refs())
    assert {:error, _} = FhirClient.resource_checked(native(), identifier(), %{})
  end

  test "full timestamp equivalence is accepted, partial or changed source time is not" do
    {:ok, expected} = FhirClient.resource_checked(native(), identifier(), refs())

    assert Observation.matches?(
             expected,
             Map.put(expected, "effectiveDateTime", "2026-11-24T12:00:00.000+00:00")
           )

    refute Observation.matches?(expected, Map.put(expected, "effectiveDateTime", "2026-11-24"))

    refute Observation.matches?(
             expected,
             Map.put(expected, "effectiveDateTime", "2026-11-24T12:00:00.000001Z")
           )
  end
end
