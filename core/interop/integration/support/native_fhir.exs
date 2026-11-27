defmodule MedFabric.Interop.NativeFHIRFixture do
  @moduledoc false
  alias MedFabric.Interop.JSON

  def create! do
    url = System.fetch_env!("FHIR_BASE_URL") |> String.trim_trailing("/")
    prefix = "mfqc-" <> Base.encode16(:crypto.strong_rand_bytes(8), case: :lower)
    namespace = uuid()
    external = hash(prefix)
    identifier = %{"system" => "urn:uuid:" <> namespace, "value" => external}
    refs = %{"patient_ref" => "Patient/" <> prefix, "encounter_ref" => "Encounter/" <> prefix}
    fixtures = [
      {"Patient", %{"resourceType" => "Patient", "id" => prefix,
        "name" => [%{"text" => "Synthetic Med Fabric qualification"}]}},
      {"Encounter", %{"resourceType" => "Encounter", "id" => prefix, "status" => "in-progress",
        "class" => %{"system" => "http://terminology.hl7.org/CodeSystem/v3-ActCode", "code" => "AMB"},
        "subject" => %{"reference" => refs["patient_ref"]}}},
      {"Device", %{"resourceType" => "Device", "id" => prefix, "status" => "active",
        "identifier" => [%{"system" => "urn:medfabric:source-device", "value" => prefix}],
        "deviceName" => [%{"name" => "PLXS engineering simulator", "type" => "user-friendly-name"}]}}
    ]
    %{status: 200, body: %{"fhirVersion" => "4.0.1"}} =
      Req.get!(url <> "/metadata", retry: false, receive_timeout: 5_000)
    Enum.each(fixtures, fn {type, resource} ->
      %{status: status} = Req.put!(url <> "/#{type}/#{prefix}", json: resource,
        retry: false, receive_timeout: 5_000)
      unless status in [200, 201], do: raise("FHIR fixture creation failed")
    end)
    %{url: url, prefix: prefix, identifier: identifier, refs: refs, fixtures: fixtures}
  end

  def native(ctx, kind, value) do
    %{"id" => ctx.identifier["value"], "kind" => kind, "value" => value,
      "unit" => if(kind == "device_spo2_v1", do: "%", else: "/min"),
      "actor" => "synthetic-reviewer", "source_digest" => hash(ctx.prefix <> "evidence"),
      "effective_at" => "2026-11-26T12:00:00Z", "issued" => "2026-11-26T12:00:01Z",
      "source_device" => ctx.prefix, "source_event_id" => ctx.prefix <> "-event",
      "parent_acquisition_id" => ctx.prefix <> "-collection",
      "provenance" => if(kind == "pulse_rate",
        do: %{"kind" => "manual", "actor" => "synthetic-reviewer",
          "recorded_at" => "2026-11-26T12:00:00Z"},
        else: %{"kind" => "simulated_plxs", "simulated" => true,
          "time_basis" => "qualified_fixture_utc", "gateway" => "synthetic-gateway"})}
  end

  # Independent HTTP oracle; it does not call production reconcile/verify.
  def observations(ctx) do
    %{status: 200, body: bytes} = Req.get!(ctx.url <> "/Observation",
      params: [identifier: ctx.identifier["system"] <> "|" <> ctx.identifier["value"], "_count": 20],
      retry: false, decode_body: false, receive_timeout: 5_000)
    %{"resourceType" => "Bundle"} = bundle = JSON.decode!(bytes)
    if Enum.any?(bundle["link"] || [], &(&1["relation"] == "next")),
      do: raise("Unexpected extra fixture observations")
    Enum.map(bundle["entry"] || [], &Map.fetch!(&1, "resource"))
  end

  def cleanup(ctx) do
    for row <- observations(ctx) do
      Req.delete!(ctx.url <> "/Observation/" <> row["id"], retry: false, receive_timeout: 5_000)
    end
    for {type, _} <- Enum.reverse(ctx.fixtures) do
      Req.delete!(ctx.url <> "/#{type}/#{ctx.prefix}", retry: false, receive_timeout: 5_000)
    end
  end

  defp hash(bytes), do: Base.encode16(:crypto.hash(:sha256, bytes), case: :lower)
  defp uuid do
    <<a::32, b::16, _::4, c::12, _::2, d::14, e::48>> = :crypto.strong_rand_bytes(16)
    <<first::binary-size(8), second::binary-size(4), third::binary-size(4),
      fourth::binary-size(4), fifth::binary-size(12)>> =
      Base.encode16(<<a::32, b::16, 4::4, c::12, 2::2, d::14, e::48>>, case: :lower)
    Enum.join([first, second, third, fourth, fifth], "-")
  end
end
