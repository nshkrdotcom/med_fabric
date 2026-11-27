Code.require_file("support/native_fhir.exs", __DIR__)

defmodule MedFabric.Interop.HapiIntegrationTest do
  use ExUnit.Case, async: false
  alias MedFabric.Interop.{FhirClient, NativeFHIRFixture, JSON}
  @moduletag timeout: 60_000

  defmodule DropCreatedResponse do
    @moduledoc false
    def run(request) do
      {request, %Req.Response{status: 201}} = Req.Finch.run(request)
      {request, %RuntimeError{message: "synthetic response loss after remote commit"}}
    end
  end

  setup do
    ctx = NativeFHIRFixture.create!()
    on_exit(fn -> NativeFHIRFixture.cleanup(ctx) end)
    %{fixture: ctx}
  end

  test "lost actual HAPI response remains unknown until exact readback", %{fixture: ctx} do
    native = NativeFHIRFixture.native(ctx, "pulse_rate", %{"mantissa" => "70", "exponent" => "0"})
    assert {:ok, resource} = FhirClient.resource_checked(native, ctx.identifier, ctx.refs)
    assert {:unknown, :possible_remote_effect} = FhirClient.deliver(resource,
      base_url: ctx.url, adapter: DropCreatedResponse)
    [remote] = NativeFHIRFixture.observations(ctx)
    reference = "Observation/" <> remote["id"]
    assert remote["identifier"] == [ctx.identifier]
    assert remote["subject"]["reference"] == ctx.refs["patient_ref"]
    assert remote["encounter"]["reference"] == ctx.refs["encounter_ref"]
    assert Decimal.equal?(remote["valueQuantity"]["value"], Decimal.new(70))
    assert {:matched, ^reference} = FhirClient.reconcile(resource, base_url: ctx.url)

    # Qualifies the remote conditional-create behavior only. Store still needs
    # its independent dispatch/confirmation proof before authorizing any retry.
    assert {:matched, ^reference} = FhirClient.deliver(resource, base_url: ctx.url)
    assert [_] = NativeFHIRFixture.observations(ctx)

    [coding] = remote["code"]["coding"]
    enriched = put_in(remote, ["code", "coding"], [Map.put(coding, "display", "Heart rate")])
    assert %{status: 200} = Req.put!(ctx.url <> "/" <> reference,
      body: JSON.encode!(enriched), headers: [{"content-type", "application/fhir+json"}],
      retry: false, receive_timeout: 5_000)
    assert {:matched, ^reference} = FhirClient.reconcile(resource, base_url: ctx.url)

    changed = put_in(resource, ["valueQuantity", "value"], Decimal.new(71))
    assert {:conflict, :conflicting_remote_record} = FhirClient.deliver(changed, base_url: ctx.url)
    assert [unchanged] = NativeFHIRFixture.observations(ctx)
    assert Decimal.equal?(unchanged["valueQuantity"]["value"], Decimal.new(70))
  end

  test "multiple actual remote matches are conflict, never arbitrary confirmation", %{fixture: ctx} do
    native = NativeFHIRFixture.native(ctx, "pulse_rate", %{"mantissa" => "80", "exponent" => "0"})
    assert {:ok, resource} = FhirClient.resource_checked(native, ctx.identifier, ctx.refs)
    for _ <- 1..2 do
      assert %{status: 201} = Req.post!(ctx.url <> "/Observation",
        headers: [{"content-type", "application/fhir+json"}], body: JSON.encode!(resource),
        retry: false, receive_timeout: 5_000)
    end
    assert [_, _] = NativeFHIRFixture.observations(ctx)
    assert {:conflict, :ambiguous_search} = FhirClient.reconcile(resource, base_url: ctx.url)
  end

  test "empty real search cannot prove noncommit", %{fixture: ctx} do
    native = NativeFHIRFixture.native(ctx, "pulse_rate", %{"mantissa" => "90", "exponent" => "0"})
    assert {:ok, resource} = FhirClient.resource_checked(native, ctx.identifier, ctx.refs)
    assert [] = NativeFHIRFixture.observations(ctx)
    assert {:unknown, :empty_search} = FhirClient.reconcile(resource, base_url: ctx.url)
  end
end
