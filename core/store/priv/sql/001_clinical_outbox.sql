CREATE TABLE IF NOT EXISTS exam_recordings (
  encounter_id text NOT NULL,
  acquisition_id text NOT NULL,
  metadata jsonb NOT NULL,
  conflict boolean NOT NULL DEFAULT false,
  accepted_by text,
  accepted_at timestamptz,
  PRIMARY KEY (encounter_id, acquisition_id),
  CHECK ((accepted_by IS NULL) = (accepted_at IS NULL))
);

CREATE TABLE IF NOT EXISTS exam_deliveries (
  encounter_id text NOT NULL,
  acquisition_id text NOT NULL,
  attempts integer NOT NULL DEFAULT 0,
  last_error text,
  remote_ref text,
  PRIMARY KEY (encounter_id, acquisition_id),
  FOREIGN KEY (encounter_id, acquisition_id) REFERENCES exam_recordings
);
