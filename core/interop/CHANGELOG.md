# Healthcare record exchange changelog

## 0.1.0

- Implemented `MedFabric.Interop.FhirClient` to map reviewed recording digests
  and manually entered pulse rates to HL7 FHIR R4 `Observation` resources with
  conditional create (`If-None-Exist`) and strict typed read-back confirmation.
