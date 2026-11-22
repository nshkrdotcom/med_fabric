<p align="center"><img src="assets/store.svg" width="200" alt="Clinical persistence and audit" /></p>

<h1 align="center">Clinical persistence and audit</h1>

<p align="center">
  <a href="https://github.com/nshkrdotcom/med_fabric"><img src="https://img.shields.io/badge/GitHub-med_fabric-345366" alt="GitHub repository" /></a>
  <a href="LICENSE"><img src="https://img.shields.io/badge/license-MIT-458f8b" alt="MIT license" /></a>
</p>

## Planned responsibility

Persist events, observations and outbox entries in one PostgreSQL transaction. Store recording references and integrity metadata alongside the encounter. Apply access and retention policy at the storage boundary.

## Direct workspace dependencies

[domain](../domain/README.md)

## First acceptance scenario

A failed export remains retryable after its originating observation commits.

[Workspace plan](../../README.md)
