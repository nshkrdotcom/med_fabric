<p align="center"><img src="assets/interop.svg" width="200" alt="Healthcare record exchange" /></p>

<h1 align="center">Healthcare record exchange</h1>

<p align="center">
  <a href="https://github.com/nshkrdotcom/med_fabric"><img src="https://img.shields.io/badge/GitHub-med_fabric-345366" alt="GitHub repository" /></a>
  <a href="LICENSE"><img src="https://img.shields.io/badge/license-MIT-458f8b" alt="MIT license" /></a>
</p>

`mf_interop` is the single authoritative healthcare record exchange package across both `med_fabric` and `med_ex`. It maps accepted observations into HL7 FHIR R4 `Observation` resources and delivers them idempotently over HTTP using `Req`.

---

## Delivery

`MedFabric.Interop.FhirClient` maps reviewed auscultation recordings to FHIR R4 and uses conditional create with a stable observation identifier. It confirms the remote identity, including the subject, encounter, and recording value.

Use `FHIR_BASE_URL` for a dedicated HAPI R4 test server. Run `mix test integration` from this directory to exercise real delivery after losing a successful response. See the [native runbook](../../guides/browser_to_record.md).
