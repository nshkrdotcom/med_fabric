defmodule MedFabric.Interop.DeviceObservationTest do
  use ExUnit.Case, async: true
  alias MedFabric.Interop.{FhirClient, Observation}
  alias MedFabric.Interop.JSON, as: FHIRJSON

  defp evidence do
    %{"kind" => "device_spo2_v1", "value" => %{"mantissa" => "972", "exponent" => "-1"},
      "effective_at" => "2026-11-24T12:00:00Z", "issued" => "2026-11-24T12:00:10Z",
      "device_ref" => "Device/plx-1", "source_event_id" => "event-1",
      "parent_acquisition_id" => "collection-1",
      "provenance" => %{"kind" => "simulated_plxs", "simulated" => true,
        "time_basis" => "qualified_fixture_utc", "gateway" => "handheld-1"}}
  end

  defp refs, do: %{"patient_ref" => "Patient/p1", "encounter_ref" => "Encounter/e1"}
  defp resource, do: FhirClient.resource(evidence(), "e1:metric1", "clinician-1", refs())

  test "device saturation preserves exact decimal, source time and simulated provenance" do
    r = resource()
    assert Decimal.equal?(r["valueQuantity"]["value"], Decimal.new("97.2"))
    assert r["valueQuantity"]["code"] == "%"
    assert r["code"]["coding"] == [%{"system" => "http://loinc.org", "code" => "2708-6"}]
    assert r["device"] == %{"reference" => "Device/plx-1"}
    assert r["effectiveDateTime"] == evidence()["effective_at"]
    assert r["issued"] == evidence()["issued"]
    assert hd(r["note"])["text"] =~ "Simulated"
    assert FHIRJSON.encode!(r) =~ "97.2"
    refute FHIRJSON.encode!(r) =~ "\"value\":\"97.2\""
    assert Observation.matches?(r, FHIRJSON.decode!(FHIRJSON.encode!(r)))
  end

  test "unknown source time, invalid references and numeric impostors cannot be exported" do
    for invalid <- [Map.put(evidence(), "effective_at", nil),
      Map.put(evidence(), "effective_at", "2026-11-24T12:00:00.0000001Z"),
      put_in(evidence(), ["provenance", "time_basis"], "received_at"),
      Map.put(evidence(), "device_ref", "Device/../patient"),
      Map.put(evidence(), "value", %{"mantissa" => "NaN", "exponent" => "0"}),
      Map.put(evidence(), "value", %{"mantissa" => "97", "exponent" => "999999"}),
      Map.put(evidence(), "value", 97.2)] do
      assert {:error, _} = FhirClient.resource_checked(invalid, "e1:metric1", "c1", refs())
    end
    assert {:error, _} = FhirClient.resource_checked(evidence(), "e1:metric1", "c1", %{})
  end

  test "device pulse never acquires the legacy manually entered method" do
    device = evidence() |> Map.put("kind", "device_pulse_rate_v1")
      |> Map.put("value", %{"mantissa" => "721", "exponent" => "-1"})
    r = FhirClient.resource(device, "e1:pulse", "c1", refs())
    assert r["valueQuantity"]["code"] == "/min"
    refute r["method"]["text"] =~ "Manually"
    manual = FhirClient.resource(%{"kind" => "pulse_rate", "value" => 72,
      "effective_at" => "2026-11-24T12:00:00Z"}, "e1:manual", "c1", refs())
    assert manual["method"]["text"] == "Manually entered measurement"
  end

  test "server display enrichment is allowed but clinical changes are rejected" do
    expected = resource()
    remote = expected |> Map.put("id", "remote-1")
      |> put_in(["device", "display"], "Pulse oximeter")
      |> put_in(["subject", "display"], "Synthetic patient")
      |> put_in(["meta", "versionId"], "1")
    assert Observation.matches?(expected, remote)
    for changed <- [put_in(remote, ["valueQuantity", "value"], "97.2"),
      put_in(remote, ["valueQuantity", "value"], Decimal.new("97.3")),
      put_in(remote, ["valueQuantity", "comparator"], "<"),
      put_in(remote, ["valueQuantity", "code"], "1"),
      put_in(remote, ["method", "text"], "Manually entered measurement"),
      put_in(remote, ["subject", "reference"], "Patient/other"),
      Map.put(remote, "effectiveDateTime", remote["issued"]),
      Map.put(remote, "note", []), Map.put(remote, "meta", %{})] do
      refute Observation.matches?(expected, changed)
    end
  end

  test "conditional create uses typed numeric JSON and verifies its remote result" do
    expected = resource()
    caller = self()
    adapter = fn request ->
      send(caller, {:sent, request.body, request.headers})
      remote = expected |> Map.put("id", "remote-1") |> FHIRJSON.encode!()
      {request, Req.Response.new(status: 201,
        headers: %{"content-type" => ["application/fhir+json"]}, body: remote)}
    end
    assert {:ok, %{remote_ref: "Observation/remote-1", created?: true}} =
      FhirClient.deliver(expected, adapter: adapter)
    assert_receive {:sent, body, headers}
    assert IO.iodata_to_binary(body) == FHIRJSON.encode!(expected)
    assert headers["if-none-exist"] == [URI.encode_query(identifier: "urn:med-fabric:observation|e1:metric1")]
  end

  test "equivalent complete timestamp renderings preserve the accepted instant" do
    expected = resource()
    same = expected |> Map.put("effectiveDateTime", "2026-11-24T12:00:00.000+00:00")
      |> Map.put("issued", "2026-11-24T02:00:10-10:00")
    assert Observation.matches?(expected, same)
    refute Observation.matches?(expected, Map.put(same, "effectiveDateTime", "2026-11-24"))
    refute Observation.matches?(expected, Map.put(same, "effectiveDateTime", "2026-11-24T12:00:00.000001Z"))
    refute Observation.matches?(expected, Map.put(same, "effectiveDateTime", "2026-11-24T12:00:00.0000001Z"))
    refute Observation.matches?(expected, Map.put(same, "issued", "2026-11-24T12:00:10"))
  end

  test "remote identity and search envelopes are validated before confirmation" do
    expected = resource()
    for id <- ["../other", String.duplicate("x", 65)] do
      adapter = json_adapter(201, Map.put(expected, "id", id))
      assert {:error, :conflicting_remote_record} = FhirClient.deliver(expected, adapter: adapter)
    end

    for envelope <- [
      %{"resourceType" => "Bundle", "link" => nil},
      %{"resourceType" => "Bundle", "link" => ["not-an-object"]},
      %{"resourceType" => "Bundle", "entry" => %{}},
      %{"resourceType" => "Bundle", "entry" => [%{"resource" => %{}, "search" => "bad"}]}
    ] do
      assert {:error, :invalid_search_response} =
        FhirClient.fetch_by_identifier("e1:metric1", adapter: json_adapter(200, envelope))
    end
    assert {:error, :ambiguous_search} = FhirClient.fetch_by_identifier("e1:metric1",
      adapter: json_adapter(200, %{"resourceType" => "Bundle", "link" => [%{"relation" => "next"}]}))
  end

  test "JSON rejects duplicate keys, trailing content and nonfinite decimals" do
    assert {:error, _} = FHIRJSON.decode("{\"value\":1,\"value\":2}")
    assert {:error, _} = FHIRJSON.decode("{} {}")
    assert_raise ArgumentError, fn -> FHIRJSON.encode!(%{"value" => Decimal.new("NaN")}) end
    number = Decimal.new("9007199254740993.0001")
    assert %{"value" => decoded} = FHIRJSON.decode!(FHIRJSON.encode!(%{"value" => number}))
    assert Decimal.equal?(number, decoded)
  end

  defp json_adapter(status, body) do
    fn request ->
      {request, Req.Response.new(status: status,
        headers: %{"content-type" => ["application/fhir+json"]}, body: FHIRJSON.encode!(body))}
    end
  end
end
