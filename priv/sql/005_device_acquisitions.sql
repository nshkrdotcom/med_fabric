-- statement
ALTER TABLE acquisitions
  ADD COLUMN capture_profile text NOT NULL DEFAULT 'legacy',
  ADD COLUMN parent_acquisition_id text,
  ADD COLUMN source_event_id text,
  ADD FOREIGN KEY (encounter_id,parent_acquisition_id) REFERENCES acquisitions(encounter_id,id)
-- statement
DO $migration$
DECLARE old_constraint record;
BEGIN
  FOR old_constraint IN SELECT conname FROM pg_constraint
    WHERE conrelid='acquisitions'::regclass AND contype='c'
    AND (pg_get_constraintdef(oid) LIKE '%audio_pcm16_wav%' OR pg_get_constraintdef(oid) LIKE '%interrupted%')
  LOOP
    EXECUTE format('ALTER TABLE acquisitions DROP CONSTRAINT %I', old_constraint.conname);
  END LOOP;
END; $migration$
-- statement
ALTER TABLE acquisitions ADD CHECK (
  (state IN ('ready','ready_partial') AND evidence IS NOT NULL AND producer IS NULL AND capture_source IS NULL AND first_received_at IS NULL)
  OR (state IN ('recording','interrupted') AND evidence IS NULL AND producer IS NOT NULL AND (capture_source IS NULL)=(first_received_at IS NULL))
), ADD CHECK (evidence IS NULL OR (
  (capture_profile='legacy' AND (
    (evidence->>'kind'='audio_pcm16_wav' AND evidence ?& ARRAY['artifact_key','file_sha256']) OR
    (evidence->>'kind'='pulse_rate' AND jsonb_typeof(evidence->'value')='number' AND NOT evidence ?| ARRAY['artifact_key','file_sha256'])
  )) OR (capture_profile IN ('paired_exam','plx_spot_check') AND evidence->>'kind'=capture_profile AND evidence ? 'manifest_digest')
  OR (capture_profile='derived_device_metric' AND evidence->>'kind' IN ('device_spo2_v1','device_pulse_rate_v1') AND parent_acquisition_id IS NOT NULL AND source_event_id IS NOT NULL)
))
-- statement
CREATE TABLE device_credentials (
  device_id text PRIMARY KEY, token_hash text UNIQUE NOT NULL, revoked boolean NOT NULL DEFAULT false)
-- statement
CREATE TABLE device_grants (
  encounter_id text REFERENCES encounters, device_id text REFERENCES device_credentials, profile text NOT NULL CHECK(profile IN ('paired_exam','plx_spot_check')),
  site text NOT NULL, expires_at timestamptz NOT NULL, authorized_by text NOT NULL, PRIMARY KEY(encounter_id,device_id,profile))
-- statement
CREATE TABLE device_sessions (
  id text PRIMARY KEY, encounter_id text NOT NULL, device_id text NOT NULL, profile text NOT NULL,
  boot text NOT NULL, site text NOT NULL, descriptors jsonb NOT NULL, generation bigint NOT NULL DEFAULT 0,
  lease_hash text NOT NULL, phase text NOT NULL, expires_at timestamptz NOT NULL,
  created_at timestamptz NOT NULL DEFAULT now(), final_inventory jsonb, manifest_digest text,
  FOREIGN KEY(encounter_id,id) REFERENCES acquisitions(encounter_id,id),
  FOREIGN KEY(encounter_id,device_id,profile) REFERENCES device_grants)
-- statement
CREATE TABLE stream_attempts (
  acquisition_id text REFERENCES device_sessions, stream text NOT NULL, number integer NOT NULL,
  generation bigint NOT NULL, fence text NOT NULL UNIQUE, receipt jsonb, sealed_index jsonb, index_digest text,
  PRIMARY KEY(acquisition_id,stream,generation), UNIQUE(acquisition_id,number,generation))
-- statement
CREATE TABLE device_facts (
  ordinal bigserial PRIMARY KEY, acquisition_id text NOT NULL REFERENCES device_sessions,
  kind text NOT NULL, fact jsonb NOT NULL, recorded_at timestamptz NOT NULL DEFAULT clock_timestamp())
-- statement
CREATE TABLE device_commands (
  id text PRIMARY KEY, acquisition_id text REFERENCES device_sessions NOT NULL, fingerprint text NOT NULL,
  request jsonb NOT NULL, state text NOT NULL, result jsonb, updated_at timestamptz NOT NULL DEFAULT now())
-- statement
CREATE UNIQUE INDEX one_pending_device_command ON device_commands(acquisition_id)
  WHERE state IN ('requested','dispatching','outcome_unknown')
-- statement
CREATE TABLE measurement_events (
  acquisition_id text REFERENCES device_sessions, event_id text NOT NULL, seq bigint NOT NULL CHECK(seq>=0),
  fingerprint text NOT NULL, body jsonb NOT NULL, received_at timestamptz NOT NULL DEFAULT clock_timestamp(),
  PRIMARY KEY(acquisition_id,event_id), UNIQUE(acquisition_id,seq))
-- statement
ALTER TABLE acquisitions ADD FOREIGN KEY(parent_acquisition_id,source_event_id)
  REFERENCES measurement_events(acquisition_id,event_id)
-- statement
CREATE TABLE device_manifests (
  acquisition_id text REFERENCES device_sessions PRIMARY KEY, digest text NOT NULL UNIQUE, body jsonb NOT NULL,
  installed_at timestamptz NOT NULL DEFAULT now())
-- statement
CREATE TABLE device_reviews (
  acquisition_id text REFERENCES device_manifests PRIMARY KEY, digest text NOT NULL REFERENCES device_manifests(digest),
  actor text NOT NULL, choice jsonb NOT NULL, reviewed_at timestamptz NOT NULL DEFAULT now())
-- statement
CREATE TABLE device_heartbeats (
  acquisition_id text PRIMARY KEY REFERENCES device_sessions,
  generation bigint NOT NULL, seen_at timestamptz NOT NULL DEFAULT clock_timestamp(), count bigint NOT NULL DEFAULT 1)
-- statement
CREATE TABLE device_limits_observed (
  fence text PRIMARY KEY REFERENCES stream_attempts(fence), max_frame_bytes integer NOT NULL,
  max_pending_bytes integer NOT NULL,max_pending_frames integer NOT NULL,durable_acks bigint NOT NULL DEFAULT 0)
-- statement
CREATE TABLE device_manifest_staging (
  acquisition_id text PRIMARY KEY REFERENCES device_sessions, digest text NOT NULL, bytes bytea NOT NULL)
-- statement
ALTER TABLE device_sessions ADD COLUMN repeat_of text UNIQUE REFERENCES device_sessions(id)
-- statement
ALTER TABLE device_commands ADD COLUMN readback_count integer NOT NULL DEFAULT 0
-- statement
CREATE TABLE device_transport_observations (
  fence text REFERENCES stream_attempts(fence), sequence numeric(20,0) NOT NULL,
  raw_digest text NOT NULL, received_at timestamptz NOT NULL DEFAULT clock_timestamp(),
  PRIMARY KEY(fence,sequence,raw_digest))
-- statement
ALTER TABLE device_manifests ADD UNIQUE(acquisition_id,digest)
-- statement
ALTER TABLE device_reviews ADD FOREIGN KEY(acquisition_id,digest) REFERENCES device_manifests(acquisition_id,digest)
-- statement
CREATE FUNCTION mf_device_immutable() RETURNS trigger LANGUAGE plpgsql AS $fn$
BEGIN
  RAISE EXCEPTION 'immutable evidence relation %',TG_TABLE_NAME;
END; $fn$
-- statement
DO $install$
DECLARE rel text;
BEGIN
  FOREACH rel IN ARRAY ARRAY['device_manifests','device_manifest_staging','device_reviews','measurement_events','device_facts','device_transport_observations']
  LOOP
    EXECUTE format('CREATE TRIGGER immutable_content BEFORE UPDATE OR DELETE ON %I FOR EACH ROW EXECUTE FUNCTION mf_device_immutable()',rel);
  END LOOP;
END; $install$
