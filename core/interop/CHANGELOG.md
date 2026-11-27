
## 0.2.0 - 2026-11-26

Map validated native observations after acceptance. Pin exact FHIR identifiers,
references, resource bytes and mapping version; distinguish possible remote
effects, conflicting/multiple matches and exact clinical readback. Remove WAV
provenance and the duplicate unchecked device observation mapper.

This component remains private; it is included only in the `mf_exam` 0.3.0
monolith and is not a separately published package. Native qualification pending.

# Healthcare record exchange changelog

## 0.1.0

- Implemented `MedFabric.Interop.FhirClient` to map reviewed recording digests
  and manually entered pulse rates to HL7 FHIR R4 `Observation` resources with
  conditional create (`If-None-Exist`) and strict typed read-back confirmation.
