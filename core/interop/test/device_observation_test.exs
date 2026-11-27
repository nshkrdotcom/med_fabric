defmodule MedFabric.Interop.FhirTransportTest do
  use ExUnit.Case, async: true
  alias MedFabric.Interop.{FhirClient, JSON, Observation}
  @base "http://fhir.invalid/fhir"
  defp resource do
    native = %{
      "kind" => "device_spo2_v1",
      "value" => %{"mantissa" => "972", "exponent" => "-1"},
      "unit" => "%",
      "effective_at" => "2020-01-02T03:04:05Z",
      "issued" => "2026-11-24T12:00:00Z",
      "actor" => "clinician",
      "source_digest" => String.duplicate("a", 64),
      "source_device" => "synthetic-plx",
      "source_event_id" => "event_one",
      "parent_acquisition_id" => "collection",
      "provenance" => %{
        "kind" => "simulated_plxs",
        "simulated" => true,
        "time_basis" => "qualified_fixture_utc",
        "gateway" => "gateway"
      }
    }

    {:ok, r} =
      FhirClient.resource_checked(
        native,
        %{"system" => "urn:uuid:00000000-0000-4000-8000-000000000001", "value" => "native_one"},
        %{"patient_ref" => "Patient/one", "encounter_ref" => "Encounter/one"}
      )

    r
  end

  defp adapter(status, body),
    do: fn request -> {request, Req.Response.new(status: status, body: JSON.encode!(body))} end

  test "conditional creation sends exact decimal JSON and simulation remains clinically visible" do
    r = resource()
    assert Decimal.equal?(r["valueQuantity"]["value"], Decimal.new("97.2"))
    assert hd(r["note"])["text"] =~ "Simulated"
    assert Observation.matches?(r, JSON.decode!(JSON.encode!(r)))
    parent = self()

    adapter = fn request ->
      send(parent, {:request, request.headers, IO.iodata_to_binary(request.body)})
      {request, Req.Response.new(status: 201, body: JSON.encode!(Map.put(r, "id", "remote-one")))}
    end

    assert {:matched, "Observation/remote-one"} =
             FhirClient.deliver(r, base_url: @base, adapter: adapter)

    assert_receive {:request, headers, bytes}

    assert headers["if-none-exist"] == [
             URI.encode_query(
               identifier: "urn:uuid:00000000-0000-4000-8000-000000000001|native_one"
             )
           ]

    assert bytes == FhirClient.canonical_bytes(r)
    assert bytes =~ "97.2"
  end

  test "remote uncertainty and an empty eventually-consistent search never prove noncommit" do
    r = resource()

    assert {:unknown, _} =
             FhirClient.deliver(r,
               base_url: @base,
               adapter: fn request -> {request, %Req.TransportError{reason: :timeout}} end
             )

    assert {:unknown, :empty_search} =
             FhirClient.reconcile(r,
               base_url: @base,
               adapter: adapter(200, %{"resourceType" => "Bundle", "entry" => []})
             )

    assert {:conflict, :ambiguous_search} =
             FhirClient.reconcile(r,
               base_url: @base,
               adapter: adapter(200, %{"resourceType" => "Bundle", "entry" => [%{}, %{}]})
             )

    assert {:conflict, _} = FhirClient.deliver(r, base_url: @base, adapter: adapter(409, %{}))
  end

  test "exact JSON rejects duplicated keys and nonfinite decimals" do
    assert {:error, _} = JSON.decode(~s({"value":1,"value":2}))
    assert {:error, _} = JSON.decode("{} {}")
    assert_raise ArgumentError, fn -> JSON.encode!(%{"value" => Decimal.new("NaN")}) end
    number = Decimal.new("9007199254740993.0001")
    assert %{"value" => decoded} = JSON.decode!(JSON.encode!(%{"value" => number}))
    assert Decimal.equal?(number, decoded)
  end
end
