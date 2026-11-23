<p align="center"><img src="assets/interop.svg" width="200" alt="Healthcare record exchange" /></p>

<h1 align="center">Healthcare record exchange</h1>

<p align="center">
  <a href="https://github.com/nshkrdotcom/med_fabric"><img src="https://img.shields.io/badge/GitHub-med_fabric-345366" alt="GitHub repository" /></a>
  <a href="LICENSE"><img src="https://img.shields.io/badge/license-MIT-458f8b" alt="MIT license" /></a>
</p>

`mf_interop` is the single authoritative healthcare record exchange package across both `med_fabric` and `med_ex`. It maps accepted observations into HL7 FHIR R4 `Observation` resources and delivers them idempotently over HTTP using `Req`.

---

## Delivery

`MedFabric.Interop.FhirClient` maps reviewed recording digests and manually entered pulse rate into distinct FHIR R4 Observation payloads. It uses conditional create and confirms remote identity and clinical values. Use `FHIR_BASE_URL` and `mix test integration` to exercise retry against native HAPI. See the [native runbook](../../guides/browser_to_record.md).
