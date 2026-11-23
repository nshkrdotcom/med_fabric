<p align="center"><img src="assets/store.svg" width="200" alt="Clinical persistence and audit" /></p>

<h1 align="center">Clinical persistence and audit</h1>

<p align="center">
  <a href="https://github.com/nshkrdotcom/med_fabric"><img src="https://img.shields.io/badge/GitHub-med_fabric-345366" alt="GitHub repository" /></a>
  <a href="LICENSE"><img src="https://img.shields.io/badge/license-MIT-458f8b" alt="MIT license" /></a>
</p>

`mf_store` (`core/store`) owns atomic persistence of encounters, typed evidence,
clinician-accepted observations, and transactional FHIR export outbox intents in
[Med Fabric](../../README.md).

---

## Persistence

`MedFabric.Store.Postgres` manages the PostgreSQL connection and applies
`priv/sql/002_evidence.sql` idempotently under an advisory transaction lock.
`MedFabric.Store.Records` owns encounter membership, evidence readiness,
serialized acceptance + outbox commits, and delivery tracking—with zero
filesystem I/O inside SQL transactions (the exam verifies WAV bytes before
entering acceptance).

Use `DATABASE_URL` and `mix test integration` to exercise rollback and
concurrent acceptance. See the [browser-to-record guide](../../guides/browser_to_record.md).
