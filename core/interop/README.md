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
values on read-back.

Use `FHIR_BASE_URL` and `mix test integration` to exercise retry against native
HAPI. See the [browser-to-record guide](../../guides/browser_to_record.md).
