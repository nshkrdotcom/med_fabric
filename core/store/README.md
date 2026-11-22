<p align="center"><img src="assets/store.svg" width="200" alt="Clinical persistence and audit" /></p>

<h1 align="center">Clinical persistence and audit</h1>

<p align="center">
  <a href="https://github.com/nshkrdotcom/med_fabric"><img src="https://img.shields.io/badge/GitHub-med_fabric-345366" alt="GitHub repository" /></a>
  <a href="LICENSE"><img src="https://img.shields.io/badge/license-MIT-458f8b" alt="MIT license" /></a>
</p>

## Planned responsibility

Persist encounter events, clinician-accepted observations, finalized recording provenance references (`artifact_sha256`, storage URI, and `:med_ex` continuity reports), and FHIR outbox entries in one PostgreSQL transaction. Apply clinical access and retention policy at the storage boundary.

## Direct workspace dependencies

[domain](../domain/README.md)

## First acceptance scenario

A failed FHIR export remains retryable after its originating accepted observation and artifact provenance metadata commit atomically.

[Workspace plan](../../README.md)
