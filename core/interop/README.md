<p align="center"><img src="assets/interop.svg" width="200" alt="Healthcare record exchange" /></p>

<h1 align="center">Healthcare record exchange</h1>

<p align="center">
  <a href="https://github.com/nshkrdotcom/med_fabric"><img src="https://img.shields.io/badge/GitHub-med_fabric-345366" alt="GitHub repository" /></a>
  <a href="LICENSE"><img src="https://img.shields.io/badge/license-MIT-458f8b" alt="MIT license" /></a>
</p>

`mf_interop` is the single authoritative healthcare record exchange package across both `med_fabric` and `med_ex`. It maps accepted observations into HL7 FHIR R4 `Observation` resources and delivers them idempotently over HTTP using `Req`.

---

## What This Owns (and Does Not Own)

**`mf_interop` owns:**
- `MedFabric.Interop.FhirClient.build_observation/4` — Builds an HL7 FHIR R4 `Observation` JSON map carrying a stable business `identifier`, synthetic `subject` (`Patient/...`) kept strictly separate from public recording provenance (`note`), `encounter` reference, `artifact_sha256`, and `continuity`.
- `MedFabric.Interop.FhirClient.deliver/2` — Delivers the `Observation` with FHIR conditional create (`If-None-Exist: identifier=<system>|<value>`) so retrying after a lost HTTP response never creates duplicate remote resources.
- `MedFabric.Interop.FhirClient.fetch_by_identifier/2` — Reads back matching `Observation` resources from the FHIR server by stable business identifier.

**`mf_interop` does not own:**
- Clinical acceptance logic (`core/domain`) or outbox state persistence (`core/store`). DICOM/DICOMweb export is deferred until an imaging product requires it.

---

## Walkthrough

In `test/mf_interop_test.exs`, an offline `Req` adapter simulates HAPI FHIR R4:
1. First `POST /fhir/Observation` writes `Observation/hapi-1` on the server, then drops the HTTP response in flight.
2. Second `POST /fhir/Observation` sends the identical `If-None-Exist` conditional create header and receives `200 OK` returning `Observation/hapi-1` (`created?: false`) without duplicating the remote resource.
3. `fetch_by_identifier/2` confirms exactly 1 remote FHIR R4 `Observation` exists.

Against a live HAPI FHIR R4 server (see the native runbook), omit `:adapter` and pass `base_url: "http://127.0.0.1:18080/fhir"`.

---

## Commands & Verification

```bash
cd core/interop
mix test
mix credo --strict
mix dialyzer --force-check
```

## Upstream References

- Req: https://github.com/wojtekmach/req
- HAPI FHIR JPA Server: https://github.com/hapifhir/hapi-fhir-jpaserver-starter
- HL7 FHIR R4 Observation: https://hl7.org/fhir/R4/observation.html

## Related Packages

- [Med Fabric Workspace](../../README.md)
- [Domain](../domain/README.md)
- [Store](../store/README.md)
- [Exam App](../../apps/exam/README.md)
