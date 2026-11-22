<p align="center"><img src="assets/store.svg" width="200" alt="Clinical persistence and audit" /></p>

<h1 align="center">Clinical persistence and audit</h1>

<p align="center">
  <a href="https://github.com/nshkrdotcom/med_fabric"><img src="https://img.shields.io/badge/GitHub-med_fabric-345366" alt="GitHub repository" /></a>
  <a href="LICENSE"><img src="https://img.shields.io/badge/license-MIT-458f8b" alt="MIT license" /></a>
</p>

`mf_store` owns atomic persistence of clinician-accepted observations, recording artifact provenance, and transactional FHIR export outbox intents in [Med Fabric](../../README.md).

---

## Persistence

PostgreSQL stores immutable ready metadata keyed by encounter and acquisition, flags conflicting redelivery, and records the original reviewer and export intent in one transaction. WAV files live in the exam artifact directory. Serving and acceptance read the file and verify its SHA-256. A failed delivery stays pending for manual retry.

Run `mix test integration` with a dedicated `DATABASE_URL` for concurrent acceptance, artifact tampering, conflicts and reconnect. See the [native runbook](../../docs/architecture/browser-to-record.md).
