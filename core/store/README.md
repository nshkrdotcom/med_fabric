<p align="center"><img src="assets/store.svg" width="200" alt="Clinical persistence and audit" /></p>

<h1 align="center">Clinical persistence and audit</h1>

<p align="center">
  <a href="https://github.com/nshkrdotcom/med_fabric"><img src="https://img.shields.io/badge/GitHub-med_fabric-345366" alt="GitHub repository" /></a>
  <a href="LICENSE"><img src="https://img.shields.io/badge/license-MIT-458f8b" alt="MIT license" /></a>
</p>

`mf_store` owns atomic persistence of clinician-accepted observations, recording artifact provenance, and transactional FHIR export outbox intents in [Med Fabric](../../README.md).

---

## What This Owns (and Does Not Own)

**`mf_store` owns:**
- `MedFabric.Store.OutboxStore` — Serialized transactional store committing `{observation, provenance, outbox}` atomically keyed by `observation_id` / `intent_id` with outbox states `:pending | :retry_scheduled | :delivered` and stable external identifier `"urn:med_fabric:observation:<observation_id>"`.
- Crash-recovery idempotency: retrying `commit_acceptance/4` after a pre-commit failure or a post-commit lost reply converges on 1 observation and 1 outbox intent; retrying with a conflicting `artifact_sha256` fails closed (`{:error, :conflicting_observation_digest}`).
- `priv/sql/001_clinical_outbox.sql` — Reference PostgreSQL 17 DDL (`accepted_observations`, `artifact_provenance`, `fhir_export_outbox`) matching the optional `ops/compose.yml` Postgres container.

**`mf_store` does not own:**
- Domain acceptance rules (`core/domain`) or HTTP/FHIR serialization (`core/interop`).

---

## Walkthrough

```elixir
{:ok, store} = MedFabric.Store.OutboxStore.start_link()
{:ok, :committed, record} = OutboxStore.commit_acceptance(store, acceptance, provenance)
{:ok, :already_committed, ^record} = OutboxStore.commit_acceptance(store, acceptance, provenance)
{:ok, _retry} = OutboxStore.mark_delivery_failed(store, record.outbox.intent_id, :timeout, 5_000)
{:ok, _done} = OutboxStore.mark_delivered(store, record.outbox.intent_id, "Observation/hapi-1")
```

See `test/mf_store_test.exs` for all 3 executable tests covering pre-commit crash recovery, post-commit lost-reply recovery, conflicting digest rejection, and outbox retry-to-delivered transitions.

---

## Commands & Verification

```bash
cd core/store
mix test
mix credo --strict
mix dialyzer --force-check
```

## Related Packages

- [Med Fabric Workspace](../../README.md)
- [Domain](../domain/README.md)
- [Runtime](../runtime/README.md)
- [Interop](../interop/README.md)
- [Exam App](../../apps/exam/README.md)
