<p align="center"><img src="assets/store.svg" width="200" alt="Clinical persistence and audit" /></p>

<h1 align="center">Clinical persistence and audit</h1>

<p align="center">
  <a href="https://github.com/nshkrdotcom/med_fabric"><img src="https://img.shields.io/badge/GitHub-med_fabric-345366" alt="GitHub repository" /></a>
  <a href="https://github.com/nshkrdotcom/med_fabric/blob/main/core/store/LICENSE"><img src="https://img.shields.io/badge/license-MIT-458f8b" alt="MIT license" /></a>
</p>

`mf_store` (`core/store`) owns atomic persistence of encounters, typed evidence,
clinician-accepted observations, and transactional FHIR export outbox intents in
[Med Fabric](https://github.com/nshkrdotcom/med_fabric).

---

## Persistence

Device ingestion records admitted attempts, durable stream progress and sealed
manifests. Spot-check review commits accepted metrics and their FHIR delivery
intents together. Browser recording has its own admission and recovery path.

`MedFabric.Store.Postgres` runs the SQL files in `priv/sql/` in filename order
under an advisory transaction lock. Use a dedicated candidate database and
volume. Each recording has an acquisition-specific directory on that volume.
Keep both stores across exam restarts. Existing 0.1.0 recordings retain
their original flat file layout and database records in the 0.1.0 deployment.

Admission reserves an encounter, acquisition ID and producer before the writer
receives PCM. The first accepted frame persists the browser source settings
and server receipt time. Only a ready acquisition appears in the review list.
The acceptance transaction compares the exact reviewed evidence and writes
the observation and delivery intent together.

One running exam instance owns the configured encounters and local recording
volume. Startup, status lookup and the next admission can reconcile an
abandoned recording. A validated final WAV becomes ready. An attempt with
only an unfinished file becomes interrupted and the writer's temporary file
is removed. A filesystem or database I/O error leaves the attempt available
for another recovery pass.

With `DATABASE_URL` set, the store's `mix test integration` exercises
transaction rollback and concurrent acceptance. From `apps/exam`, use
`mix test integration/recording_test.exs` against a dedicated test database
with `MF_LAB` unset to exercise recording interruptions and near-limit range
playback. [Browser-to-record guide](https://github.com/nshkrdotcom/med_fabric/blob/main/guides/browser_to_record.md)
