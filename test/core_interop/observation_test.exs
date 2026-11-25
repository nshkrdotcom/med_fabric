defmodule MedFabric.Interop.ObservationTest do
  use ExUnit.Case, async: true
  alias MedFabric.Interop.{FhirClient, Observation}

  test "an exact pulse retains its meaning after server enrichment" do
    pulse = %{"kind" => "pulse_rate", "value" => 70, "effective_at" => "2026-11-22T12:00:00Z"}
    refs = %{"patient_ref" => "Patient/a", "encounter_ref" => "Encounter/b"}
    expected = FhirClient.resource(pulse, "a:b", "clinician", refs)
    [coding] = expected["code"]["coding"]
    remote = put_in(expected, ["code", "coding"], [Map.put(coding, "display", "Heart rate")])

    assert Observation.matches?(expected, remote)
    refute Observation.matches?(expected, put_in(remote, ["valueQuantity", "comparator"], "<"))
    refute Observation.matches?(expected, put_in(remote, ["subject", "reference"], "Patient/c"))
    refute Observation.matches?(expected, Map.put(remote, "component", []))
  end
end
