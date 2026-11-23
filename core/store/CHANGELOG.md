# Clinical persistence and audit changelog

## 0.1.0

- Implemented `MedFabric.Store.Postgres` and `MedFabric.Store.Records` backed by
  `priv/sql/002_evidence.sql` with SQL-enforced audio/vital evidence variants,
  atomic acceptance + FHIR outbox commits, and advisory-locked schema setup.
