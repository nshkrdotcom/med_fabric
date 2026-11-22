-- Reference PostgreSQL 17 DDL for MedFabric.Store.OutboxStore (optional ops/compose.yml).
-- Enforces atomic single-transaction persistence of accepted clinical observations,
-- artifact provenance, and FHIR export outbox intents with idempotency constraints.

CREATE TABLE IF NOT EXISTS accepted_observations (
  observation_id TEXT PRIMARY KEY,
  encounter_id TEXT NOT NULL,
  acquisition_id TEXT NOT NULL,
  session_id TEXT NOT NULL,
  artifact_sha256 TEXT NOT NULL,
  interval_start_ms BIGINT NOT NULL,
  interval_end_ms BIGINT NOT NULL,
  continuity TEXT NOT NULL CHECK (continuity IN ('observed_continuous', 'observed_gap', 'unknown')),
  accepted_by TEXT NOT NULL,
  accepted_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  UNIQUE (encounter_id, acquisition_id)
);

CREATE TABLE IF NOT EXISTS artifact_provenance (
  observation_id TEXT PRIMARY KEY REFERENCES accepted_observations (observation_id) ON DELETE RESTRICT,
  source_kind TEXT NOT NULL,
  source_ref TEXT NOT NULL,
  sample_rate_hz INTEGER,
  sample_count BIGINT,
  recorded_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

CREATE TABLE IF NOT EXISTS fhir_export_outbox (
  intent_id TEXT PRIMARY KEY,
  observation_id TEXT NOT NULL UNIQUE REFERENCES accepted_observations (observation_id) ON DELETE RESTRICT,
  target TEXT NOT NULL,
  external_id TEXT NOT NULL UNIQUE,
  artifact_sha256 TEXT NOT NULL,
  status TEXT NOT NULL CHECK (status IN ('pending', 'retry_scheduled', 'delivered')),
  attempts INTEGER NOT NULL DEFAULT 0,
  last_error TEXT,
  next_retry_at_ms BIGINT,
  remote_ref TEXT,
  updated_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
);
