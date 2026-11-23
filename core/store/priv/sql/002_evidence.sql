CREATE TABLE IF NOT EXISTS encounters (
  id text PRIMARY KEY,
  patient_actor text NOT NULL,
  clinician_actor text NOT NULL,
  closed_at timestamptz
);

CREATE TABLE IF NOT EXISTS acquisitions (
  encounter_id text NOT NULL REFERENCES encounters(id),
  id text NOT NULL,
  evidence jsonb NOT NULL,
  conflict boolean NOT NULL DEFAULT false,
  PRIMARY KEY (encounter_id, id),
  CHECK (jsonb_typeof(evidence->'kind') = 'string' AND evidence ? 'kind' AND jsonb_typeof(evidence->'provenance') = 'object' AND evidence ? 'provenance'),
  CHECK (
    (evidence->>'kind' = 'audio_pcm16_wav' AND evidence ? 'artifact_key' AND evidence ? 'file_sha256')
    OR
    (evidence->>'kind' = 'pulse_rate' AND NOT evidence ? 'artifact_key'
     AND NOT evidence ? 'file_sha256' AND evidence ? 'value' AND jsonb_typeof(evidence->'value') = 'number')
  )
);

CREATE TABLE IF NOT EXISTS observations (
  encounter_id text NOT NULL,
  acquisition_id text NOT NULL,
  actor text NOT NULL,
  accepted_at timestamptz NOT NULL DEFAULT now(),
  PRIMARY KEY (encounter_id, acquisition_id),
  FOREIGN KEY (encounter_id, acquisition_id) REFERENCES acquisitions(encounter_id, id)
);

CREATE TABLE IF NOT EXISTS outbox_deliveries (
  encounter_id text NOT NULL,
  acquisition_id text NOT NULL,
  destination text NOT NULL,
  external_id text NOT NULL,
  resource jsonb NOT NULL,
  remote_ref text,
  last_error text,
  PRIMARY KEY (encounter_id, acquisition_id),
  UNIQUE (destination, external_id),
  FOREIGN KEY (encounter_id, acquisition_id) REFERENCES observations(encounter_id, acquisition_id)
);
