<p align="center"><img src="assets/interop.svg" width="200" alt="Healthcare record exchange" /></p>

<h1 align="center">Healthcare record exchange</h1>

<p align="center">
  <a href="https://github.com/nshkrdotcom/med_fabric"><img src="https://img.shields.io/badge/GitHub-med_fabric-345366" alt="GitHub repository" /></a>
  <a href="LICENSE"><img src="https://img.shields.io/badge/license-MIT-458f8b" alt="MIT license" /></a>
</p>

## Planned responsibility

Map committed observations to FHIR resources at export time. Preserve units, timestamps and provenance. Use stable identifiers so that an outbox retry can reconcile the remote record.

## Direct workspace dependencies

[domain](../domain/README.md)

## First acceptance scenario

Exercise failed delivery and replay against a test endpoint.

[Workspace plan](../../README.md)
