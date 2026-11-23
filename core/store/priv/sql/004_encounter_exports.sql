CREATE TABLE IF NOT EXISTS encounter_exports (
  encounter_id text PRIMARY KEY REFERENCES encounters(id),
  destination text NOT NULL,
  patient_ref text NOT NULL,
  encounter_ref text NOT NULL,
  UNIQUE (destination, encounter_ref)
);
