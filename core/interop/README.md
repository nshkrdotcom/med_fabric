<p align="center"><img src="assets/interop.svg" width="200" alt="Healthcare record exchange" /></p>

<h1 align="center">Healthcare record exchange</h1>

<p align="center">
  <a href="https://github.com/nshkrdotcom/med_fabric"><img src="https://img.shields.io/badge/GitHub-med_fabric-345366" alt="GitHub repository" /></a>
  <a href="LICENSE"><img src="https://img.shields.io/badge/license-MIT-458f8b" alt="MIT license" /></a>
</p>

## Planned responsibility

Single authoritative healthcare exchange plane across `med_fabric` and `med_ex`. Maps committed observations to HL7 FHIR resources at export time, preserving units, timestamps, provenance, and artifact continuity metadata. Uses stable identifiers so `mf_store` outbox retries safely reconcile remote FHIR records.

DICOM/DICOMweb export is intentionally deferred as a future `mf_interop` adapter until an imaging product requires it.

## Direct workspace dependencies

[domain](../domain/README.md)

## First acceptance scenario

Exercise failed FHIR delivery and idempotent outbox replay against a test endpoint.

[Workspace plan](../../README.md)
