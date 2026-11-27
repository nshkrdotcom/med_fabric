
## 0.2.0 - 2026-11-26

Add pure native review plans, exact decimal eligibility and explicit manual
evidence provenance. Remove continuous-WAV evidence and move clinical selection,
range/defect validation and stable observation identity into Domain. No external
FHIR mapping or database access participates in native validation.

This component remains private; it is included only in the `mf_exam` 0.3.0
monolith and is not a separately published package. Native qualification pending.

# Pure encounter decisions changelog

## 0.1.0

- Implemented `MedFabric.Domain.Evidence` constructors for validated 48 kHz mono
  PCM16LE recording artifacts and manually entered pulse-rate measurements.
