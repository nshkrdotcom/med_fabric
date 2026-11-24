<p align="center"><img src="assets/interop.svg" width="200" alt="Healthcare record exchange" /></p>

<h1 align="center">Healthcare record exchange</h1>

<p align="center">
  <a href="https://github.com/nshkrdotcom/med_fabric"><img src="https://img.shields.io/badge/GitHub-med_fabric-345366" alt="GitHub repository" /></a>
  <a href="LICENSE"><img src="https://img.shields.io/badge/license-MIT-458f8b" alt="MIT license" /></a>
</p>

`mf_interop` (`core/interop`) is the single authoritative healthcare record
exchange library for [Med Fabric](../../README.md) (kept outside
[MedEx](https://github.com/nshkrdotcom/med_ex)). It maps accepted observations
into HL7 FHIR R4 `Observation` resources and delivers them idempotently over
HTTP using `Req`.

---

## Delivery

`MedFabric.Interop.FhirClient` maps reviewed recording digests
(`reviewed-auscultation-recording`) and manually entered pulse rates (LOINC
`8867-4`, UCUM `/min`) into distinct FHIR R4 `Observation` payloads. It uses
conditional create (`If-None-Exist`) and confirms remote identity and clinical
values on read-back, including the presence or absence of a quantity comparator.

Use `FHIR_BASE_URL` and `mix test integration` to exercise retry against native
HAPI. See the [browser-to-record guide](../../guides/browser_to_record.md).

## Accepted device metrics

`FhirClient.resource_checked/4` validates `device_spo2_v1` and
`device_pulse_rate_v1` evidence before an outbox intent is written. It requires
a qualified measurement timestamp, later availability time, the measuring
peripheral's `Device/...` reference, immutable event/collection lineage and
explicit simulation provenance. A gateway receipt timestamp cannot substitute
for an unknown measurement timestamp. Manual pulse retains its existing method.

The oxygen-saturation resource uses the R4 oxygen-saturation profile, LOINC
`2708-6`, and UCUM `%`; device pulse uses the heart-rate profile, LOINC `8867-4`
and UCUM `/min`. The originating exact mantissa/exponent remains in evidence.
Decimal values are encoded as JSON numbers using `MedFabric.Interop.JSON`,
and decoded without binary floating-point rounding. The Postgrex JSON codec
must be `MedFabric.Store.JSON` at compile time so outbox JSONB round trips
preserve the same numeric values. Recompile Postgrex after changing that setting.

Read-back comparison requires the selected profiles and exact clinical fields,
including method, measurement time, device, source-event lineage and simulation
note. Server-generated IDs, version metadata, narrative and reference display
labels may be enriched; a changed quantity type, comparator, unit, subject,
method or time remains a conflict. A failed response leaves delivery retryable
under the same external identifier; it never authorizes a new observation ID.

Unit tests cover exact fractional JSON and typed confirmation. They do not
replace the actual HAPI conditional-create, lost-response and read-back suite.

References: [FHIR R4 oxygen saturation](https://hl7.org/fhir/R4/oxygensat.html),
[FHIR R4 Observation](https://hl7.org/fhir/R4/observation.html),
[Elixir JSON callbacks](https://hexdocs.pm/elixir/JSON.html),
[Decimal numeric JSON encoding](https://hexdocs.pm/decimal/Decimal.html),
[Postgrex JSON configuration](https://hexdocs.pm/postgrex/readme.html).

Run the real response-loss regression against an isolated local HTTP HAPI R4 instance:

```bash
FHIR_BASE_URL=http://127.0.0.1:18080/fhir mix test integration
```

It creates uniquely named synthetic Patient, Encounter and Device fixtures, forwards
a real conditional POST through a TCP proxy that discards HAPI's response, then
retries directly and checks that exactly one typed observation exists. Fixtures
are cleaned up afterward. Required service absence is a failure, not a passing skip.
