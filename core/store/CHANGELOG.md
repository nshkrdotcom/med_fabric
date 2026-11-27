
## 0.2.0 - 2026-11-26

Replace the former schema with the fresh revision-2 relational contract.
Add explicit database/transaction acquisition operations, actor/request replay,
immutable native evidence/decisions/observations, atomic export intents, pinned
delivery mapping and outcomes, schema/deployment identity and coordinated restore
checks. Remove global database defaults and legacy recording relations.

This component remains private; it is included only in the `mf_exam` 0.3.0
monolith and is not a separately published package. Native qualification pending.

# Clinical persistence and audit changelog

## 0.1.0

- Implemented `MedFabric.Store.Postgres` and `MedFabric.Store.Records` backed by
  `priv/sql/002_evidence.sql` with SQL-enforced audio/vital evidence variants,
  atomic acceptance + FHIR outbox commits, and advisory-locked schema setup.
