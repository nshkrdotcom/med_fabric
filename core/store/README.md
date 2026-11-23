<p align="center"><img src="assets/store.svg" width="200" alt="Clinical persistence and audit" /></p>

<h1 align="center">Clinical persistence and audit</h1>

<p align="center">
  <a href="https://github.com/nshkrdotcom/med_fabric"><img src="https://img.shields.io/badge/GitHub-med_fabric-345366" alt="GitHub repository" /></a>
  <a href="LICENSE"><img src="https://img.shields.io/badge/license-MIT-458f8b" alt="MIT license" /></a>
</p>

`mf_store` owns atomic persistence of clinician-accepted observations, recording artifact provenance, and transactional FHIR export outbox intents in [Med Fabric](../../README.md).

---

## Persistence

PostgreSQL stores encounters, immutable audio and pulse-rate evidence, accepted observations and FHIR outbox intents. Acceptance and outbox insertion share one transaction. The exam verifies WAV bytes before calling the store. Use `DATABASE_URL` and `mix test integration` to exercise rollback and concurrent acceptance. See the [native runbook](../../guides/browser_to_record.md).
