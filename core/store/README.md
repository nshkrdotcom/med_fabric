<p align="center"><img src="assets/store.svg" width="200" alt="Clinical persistence and audit" /></p>

<h1 align="center">Clinical persistence and audit</h1>

<p align="center">
  <a href="https://github.com/nshkrdotcom/med_fabric"><img src="https://img.shields.io/badge/GitHub-med_fabric-345366" alt="GitHub repository" /></a>
  <a href="LICENSE"><img src="https://img.shields.io/badge/license-MIT-458f8b" alt="MIT license" /></a>
</p>

`mf_store` owns atomic persistence of clinician-accepted observations, recording artifact provenance, and transactional FHIR export outbox intents in [Med Fabric](../../README.md).

---

## Persistence

`MedFabric.Store.Postgres` applies the SQL schema and commits accepted observations, artifact provenance, and export intents in one transaction. Retry verifies the acceptance identity. Delivery status is persisted with the confirmed remote reference.

Run `mix test integration` from this project with `DATABASE_URL` pointing at a test database. The suite checks actual rollback, concurrent retries, reconnect, and delivery transitions. See the [native runbook](../../docs/architecture/browser-to-record.md).
