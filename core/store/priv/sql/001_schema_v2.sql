-- statement
CREATE TABLE deployment_identity (
 singleton boolean PRIMARY KEY DEFAULT true CHECK(singleton),
 deployment_uuid uuid NOT NULL UNIQUE,
 revision integer NOT NULL CHECK(revision=2),
 schema_fingerprint text NOT NULL,
 migration_sha256 text NOT NULL CHECK(migration_sha256 ~ '^[0-9a-f]{64}$'),
 recovery_state text NOT NULL DEFAULT 'current' CHECK(recovery_state IN ('current','blocked')),
 restored_cut_point text,
 reconciliation_digest text CHECK(reconciliation_digest IS NULL OR reconciliation_digest ~ '^[0-9a-f]{64}$')
)
-- statement
CREATE TABLE encounters (
 id text PRIMARY KEY, patient_actor text NOT NULL, clinician_actor text NOT NULL,
 closed_at timestamptz, CHECK(patient_actor<>clinician_actor),
 CHECK(length(id) BETWEEN 1 AND 96)
)
-- statement
CREATE TABLE browser_sessions (
 id text PRIMARY KEY, encounter_id text NOT NULL REFERENCES encounters(id), actor text NOT NULL,
 role text NOT NULL CHECK(role IN ('patient','clinician')), expires_at timestamptz NOT NULL,
 revoked boolean NOT NULL DEFAULT false,
 UNIQUE(id,encounter_id,actor)
)
-- statement
CREATE TABLE encounter_exports (
 encounter_id text PRIMARY KEY REFERENCES encounters(id), destination text NOT NULL,
 patient_ref text NOT NULL, encounter_ref text NOT NULL,
 conditional_create_qualified boolean NOT NULL DEFAULT false, qualification_ref text,
 CHECK(NOT conditional_create_qualified OR qualification_ref IS NOT NULL)
)
-- statement
CREATE TABLE device_credentials (
 device_id text PRIMARY KEY, token_hash text NOT NULL UNIQUE CHECK(token_hash ~ '^[0-9a-f]{64}$'),
 revoked boolean NOT NULL DEFAULT false
)
-- statement
CREATE TABLE device_grants (
 encounter_id text NOT NULL REFERENCES encounters(id), device_id text NOT NULL REFERENCES device_credentials(device_id),
 profile text NOT NULL CHECK(profile IN ('paired_exam','plx_spot_check')),
 site text NOT NULL, expires_at timestamptz NOT NULL, authorized_by text NOT NULL,
 revoked boolean NOT NULL DEFAULT false,
 PRIMARY KEY(encounter_id,device_id,profile)
)
-- statement
CREATE TABLE acquisitions (
 id text PRIMARY KEY, encounter_id text NOT NULL REFERENCES encounters(id),
 source_kind text NOT NULL CHECK(source_kind IN ('device','browser')),
 principal text NOT NULL,
 profile text NOT NULL CHECK(profile IN ('paired_exam','plx_spot_check','browser_microphone')),
 state text NOT NULL CHECK(state IN ('reserved','capturing','finalizing','staged','promoted','interrupted','quarantined')),
 parent_acquisition_id text REFERENCES acquisitions(id), created_at timestamptz NOT NULL DEFAULT clock_timestamp(),
 UNIQUE(encounter_id,id), CHECK((source_kind='browser')=(profile='browser_microphone'))
)
-- statement
CREATE UNIQUE INDEX one_active_profile ON acquisitions(encounter_id,profile)
 WHERE state IN ('reserved','capturing','finalizing','staged')
-- statement
CREATE TABLE browser_creations (
 encounter_id text NOT NULL, actor text NOT NULL, request_id text NOT NULL,
 page text NOT NULL, session_id text NOT NULL, acquisition_id text NOT NULL UNIQUE REFERENCES acquisitions(id),
 binding_hash text NOT NULL, binding_secret text NOT NULL,
 PRIMARY KEY(encounter_id,actor,request_id),
 FOREIGN KEY(session_id,encounter_id,actor) REFERENCES browser_sessions(id,encounter_id,actor)
)
-- statement
CREATE TABLE acquisition_sessions (
 id text PRIMARY KEY REFERENCES acquisitions(id), encounter_id text NOT NULL,
 source_kind text NOT NULL CHECK(source_kind IN ('device','browser')), principal text NOT NULL,
 profile text NOT NULL, device_id text, patient_actor text, browser_session text,
 boot text NOT NULL, site text NOT NULL, descriptors jsonb NOT NULL CHECK(jsonb_typeof(descriptors)='object'),
 generation bigint NOT NULL DEFAULT 0 CHECK(generation>=0), lease_hash text NOT NULL,
 authority_state text NOT NULL DEFAULT 'authorized' CHECK(authority_state IN ('authorized','expired','revoked','closed')),
 connection_state text NOT NULL DEFAULT 'absent' CHECK(connection_state IN ('absent','authenticated','active','disconnected')),
 expires_at timestamptz NOT NULL, maximum_at timestamptz NOT NULL,
 final_inventory jsonb, frozen_at timestamptz, frozen_generation bigint,
 CHECK((frozen_at IS NULL AND frozen_generation IS NULL AND final_inventory IS NULL) OR (frozen_at IS NOT NULL AND frozen_generation IS NOT NULL AND final_inventory IS NOT NULL)),
 FOREIGN KEY(encounter_id,id) REFERENCES acquisitions(encounter_id,id),
 FOREIGN KEY(encounter_id,device_id,profile) REFERENCES device_grants(encounter_id,device_id,profile),
 FOREIGN KEY(browser_session,encounter_id,patient_actor) REFERENCES browser_sessions(id,encounter_id,actor),
 CHECK((source_kind='device' AND device_id IS NOT NULL AND patient_actor IS NULL AND browser_session IS NULL AND principal=device_id)
 OR (source_kind='browser' AND device_id IS NULL AND patient_actor IS NOT NULL AND browser_session IS NOT NULL AND principal=patient_actor))
)
-- statement
CREATE TABLE stream_attempts (
 acquisition_id text NOT NULL REFERENCES acquisitions(id), stream text NOT NULL CHECK(stream IN ('audio','ecg')),
 number integer NOT NULL CHECK(number IN (1,2)), generation bigint NOT NULL CHECK(generation>0),
 fence text PRIMARY KEY, attempt_state text NOT NULL DEFAULT 'reserved' CHECK(attempt_state IN ('reserved','open','quiescent','terminal','unknown')),
 receipt jsonb CHECK(receipt IS NULL OR (jsonb_typeof(receipt)='object' AND receipt->>'accepted_sequence'=receipt->>'durable_sequence' AND receipt->>'accepted_sample'=receipt->>'durable_sample')),
 sealed_index jsonb, index_digest text CHECK(index_digest IS NULL OR index_digest ~ '^[0-9a-f]{64}$'),
 UNIQUE(acquisition_id,stream,generation),
 CHECK((sealed_index IS NULL AND index_digest IS NULL) OR (sealed_index IS NOT NULL AND index_digest IS NOT NULL)),
 CHECK(attempt_state<>'terminal' OR (receipt IS NOT NULL AND index_digest IS NOT NULL))
)
-- statement
CREATE TABLE acquisition_facts (
 ordinal bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY, acquisition_id text NOT NULL REFERENCES acquisitions(id),
 kind text NOT NULL, fact jsonb NOT NULL, recorded_at timestamptz NOT NULL DEFAULT clock_timestamp()
)
-- statement
CREATE TABLE transport_observations (
 fence text NOT NULL REFERENCES stream_attempts(fence), sequence bigint NOT NULL CHECK(sequence>=0),
 raw_digest text NOT NULL CHECK(raw_digest ~ '^[0-9a-f]{64}$'), received_at timestamptz NOT NULL DEFAULT clock_timestamp(),
 PRIMARY KEY(fence,sequence)
)
-- statement
CREATE TABLE measurement_events (
 acquisition_id text NOT NULL REFERENCES acquisitions(id), event_id text NOT NULL,
 seq bigint NOT NULL CHECK(seq BETWEEN 0 AND 9999), fingerprint text NOT NULL,
 body jsonb NOT NULL, received_at timestamptz NOT NULL DEFAULT clock_timestamp(),
 PRIMARY KEY(acquisition_id,event_id), UNIQUE(acquisition_id,seq)
)
-- statement
CREATE TABLE device_commands (
 id text PRIMARY KEY, acquisition_id text NOT NULL REFERENCES acquisitions(id), fingerprint text NOT NULL,
 request jsonb NOT NULL, state text NOT NULL CHECK(state IN ('requested','dispatching','applied','rejected','outcome_unknown')),
 result jsonb, expires_at timestamptz NOT NULL, updated_at timestamptz NOT NULL DEFAULT clock_timestamp(),
 readback_count integer NOT NULL DEFAULT 0 CHECK(readback_count BETWEEN 0 AND 3)
)
-- statement
CREATE TABLE acquisition_manifest_staging (
 acquisition_id text PRIMARY KEY REFERENCES acquisitions(id), digest text NOT NULL,
 bytes bytea NOT NULL, snapshot_digest text NOT NULL,
 UNIQUE(acquisition_id,digest)
)
-- statement
CREATE TABLE acquisition_manifests (
 acquisition_id text PRIMARY KEY REFERENCES acquisitions(id), encounter_id text NOT NULL,
 digest text NOT NULL CHECK(digest ~ '^[0-9a-f]{64}$'), body jsonb NOT NULL, promoted_at timestamptz NOT NULL DEFAULT clock_timestamp(),
 FOREIGN KEY(encounter_id,acquisition_id) REFERENCES acquisitions(encounter_id,id),
 FOREIGN KEY(acquisition_id,digest) REFERENCES acquisition_manifest_staging(acquisition_id,digest),
 UNIQUE(encounter_id,acquisition_id,digest)
)
-- statement
CREATE TABLE manual_evidence (
 id text PRIMARY KEY, encounter_id text NOT NULL REFERENCES encounters(id), actor text NOT NULL,
 effective_at timestamptz NOT NULL, body jsonb NOT NULL, digest text NOT NULL CHECK(digest ~ '^[0-9a-f]{64}$'),
 UNIQUE(encounter_id,id,digest)
)
-- statement
CREATE TABLE reviews (
 id text PRIMARY KEY, encounter_id text NOT NULL REFERENCES encounters(id), actor text NOT NULL,
 request_id text NOT NULL CHECK(length(request_id) BETWEEN 1 AND 96), request_content jsonb NOT NULL,
 request_digest text NOT NULL, choice jsonb NOT NULL, decided_at timestamptz NOT NULL,
 acquisition_id text, manifest_digest text, manual_id text, manual_digest text,
 repeat_id text REFERENCES acquisitions(id),
 UNIQUE(encounter_id,actor,request_id), UNIQUE(encounter_id,id),
 UNIQUE(acquisition_id,manifest_digest), UNIQUE(manual_id,manual_digest),
 FOREIGN KEY(encounter_id,acquisition_id,manifest_digest) REFERENCES acquisition_manifests(encounter_id,acquisition_id,digest),
 FOREIGN KEY(encounter_id,manual_id,manual_digest) REFERENCES manual_evidence(encounter_id,id,digest),
 CHECK((acquisition_id IS NOT NULL AND manifest_digest IS NOT NULL AND manual_id IS NULL AND manual_digest IS NULL)
 OR (acquisition_id IS NULL AND manifest_digest IS NULL AND manual_id IS NOT NULL AND manual_digest IS NOT NULL))
)
-- statement
CREATE TABLE observations (
 id text PRIMARY KEY, encounter_id text NOT NULL, decision_id text NOT NULL,
 actor text NOT NULL, effective_at timestamptz NOT NULL, body jsonb NOT NULL, digest text NOT NULL,
 FOREIGN KEY(encounter_id,decision_id) REFERENCES reviews(encounter_id,id), UNIQUE(encounter_id,id)
)
-- statement
CREATE TABLE outbox_deliveries (
 id text PRIMARY KEY, encounter_id text NOT NULL, observation_id text NOT NULL UNIQUE,
 identifier_system text NOT NULL CHECK(identifier_system LIKE 'urn:uuid:%'), identifier_value text NOT NULL,
 status text NOT NULL DEFAULT 'pending' CHECK(status IN ('pending','blocked','ready','dispatching','unresolved','retryable','conflict','confirmed')),
 destination text, references_json jsonb, mapping_version text, resource jsonb, resource_bytes bytea, fingerprint text,
 conditional_qualified boolean NOT NULL DEFAULT false, qualification_ref text,
 claim_token text, attempt_id text, lease_until timestamptz, remote_ref text, proof jsonb,
 last_error text, next_due_at timestamptz DEFAULT clock_timestamp(), executions integer NOT NULL DEFAULT 0 CHECK(executions BETWEEN 0 AND 5),
 FOREIGN KEY(encounter_id,observation_id) REFERENCES observations(encounter_id,id),
 UNIQUE(destination,identifier_system,identifier_value),
 CHECK((destination IS NULL AND references_json IS NULL AND mapping_version IS NULL AND resource IS NULL AND resource_bytes IS NULL AND fingerprint IS NULL)
 OR (destination IS NOT NULL AND references_json IS NOT NULL AND mapping_version IS NOT NULL AND resource IS NOT NULL AND resource_bytes IS NOT NULL AND fingerprint IS NOT NULL)),
 CHECK(status NOT IN ('ready','dispatching','unresolved','retryable','conflict','confirmed') OR fingerprint IS NOT NULL),
 CHECK(status<>'dispatching' OR (claim_token IS NOT NULL AND attempt_id IS NOT NULL AND lease_until IS NOT NULL)),
 CHECK(status<>'confirmed' OR (remote_ref IS NOT NULL AND proof IS NOT NULL AND (proof->>'safe_confirmation'='true') IS TRUE)),
 CHECK(NOT conditional_qualified OR qualification_ref IS NOT NULL)
)
-- statement
CREATE INDEX outbox_due ON outbox_deliveries(next_due_at) WHERE next_due_at IS NOT NULL AND status<>'confirmed'
-- statement
CREATE TABLE delivery_attempts (
 ordinal bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY, delivery_id text NOT NULL REFERENCES outbox_deliveries(id),
 attempt_id text NOT NULL, token text NOT NULL, stage text NOT NULL,
 outcome text NOT NULL CHECK(outcome IN ('admitted','possible_send','noncommitted','unknown','matched','conflict','settled')),
 conditional_protected boolean NOT NULL, evidence_ref text, at timestamptz NOT NULL DEFAULT clock_timestamp(),
 UNIQUE(delivery_id,attempt_id,stage)
)
-- statement
CREATE FUNCTION immutable_evidence() RETURNS trigger LANGUAGE plpgsql AS $$
BEGIN RAISE EXCEPTION 'immutable_evidence'; END
$$
-- statement
CREATE TRIGGER deployment_identity_immutable BEFORE DELETE ON deployment_identity FOR EACH ROW EXECUTE FUNCTION immutable_evidence()
-- statement
CREATE FUNCTION immutable_deployment_uuid() RETURNS trigger LANGUAGE plpgsql AS $$
BEGIN IF NEW.deployment_uuid<>OLD.deployment_uuid OR NEW.revision<>OLD.revision OR NEW.migration_sha256<>OLD.migration_sha256 THEN RAISE EXCEPTION 'immutable_deployment_identity'; END IF; RETURN NEW; END
$$
-- statement
CREATE TRIGGER deployment_uuid_immutable BEFORE UPDATE ON deployment_identity FOR EACH ROW EXECUTE FUNCTION immutable_deployment_uuid()
-- statement
CREATE FUNCTION immutable_outbox_mapping() RETURNS trigger LANGUAGE plpgsql AS $$
BEGIN
 IF NEW.identifier_system<>OLD.identifier_system OR NEW.identifier_value<>OLD.identifier_value OR NEW.observation_id<>OLD.observation_id THEN RAISE EXCEPTION 'immutable_delivery_identity'; END IF;
 IF OLD.fingerprint IS NOT NULL AND (NEW.destination,NEW.references_json,NEW.mapping_version,NEW.resource,NEW.resource_bytes,NEW.fingerprint,NEW.conditional_qualified,NEW.qualification_ref) IS DISTINCT FROM (OLD.destination,OLD.references_json,OLD.mapping_version,OLD.resource,OLD.resource_bytes,OLD.fingerprint,OLD.conditional_qualified,OLD.qualification_ref) THEN RAISE EXCEPTION 'immutable_mapping'; END IF;
 IF OLD.status='confirmed' AND NEW IS DISTINCT FROM OLD THEN RAISE EXCEPTION 'confirmed_is_terminal'; END IF;
 RETURN NEW;
END
$$
-- statement
CREATE TRIGGER outbox_mapping_immutable BEFORE UPDATE ON outbox_deliveries FOR EACH ROW EXECUTE FUNCTION immutable_outbox_mapping()
-- statement
CREATE TRIGGER acquisition_facts_immutable BEFORE UPDATE OR DELETE ON acquisition_facts FOR EACH ROW EXECUTE FUNCTION immutable_evidence()
-- statement
CREATE TRIGGER transport_observations_immutable BEFORE UPDATE OR DELETE ON transport_observations FOR EACH ROW EXECUTE FUNCTION immutable_evidence()
-- statement
CREATE TRIGGER measurement_events_immutable BEFORE UPDATE OR DELETE ON measurement_events FOR EACH ROW EXECUTE FUNCTION immutable_evidence()
-- statement
CREATE TRIGGER acquisition_manifests_immutable BEFORE UPDATE OR DELETE ON acquisition_manifests FOR EACH ROW EXECUTE FUNCTION immutable_evidence()
-- statement
CREATE TRIGGER manual_evidence_immutable BEFORE UPDATE OR DELETE ON manual_evidence FOR EACH ROW EXECUTE FUNCTION immutable_evidence()
-- statement
CREATE TRIGGER reviews_immutable BEFORE UPDATE OR DELETE ON reviews FOR EACH ROW EXECUTE FUNCTION immutable_evidence()
-- statement
CREATE TRIGGER observations_immutable BEFORE UPDATE OR DELETE ON observations FOR EACH ROW EXECUTE FUNCTION immutable_evidence()
-- statement
CREATE TRIGGER delivery_attempts_immutable BEFORE UPDATE OR DELETE ON delivery_attempts FOR EACH ROW EXECUTE FUNCTION immutable_evidence()
-- statement
ALTER TABLE acquisitions ADD CONSTRAINT acquisition_source_identity UNIQUE(id,encounter_id,source_kind,principal,profile)
-- statement
ALTER TABLE acquisition_sessions ADD CONSTRAINT session_matches_acquisition FOREIGN KEY(id,encounter_id,source_kind,principal,profile) REFERENCES acquisitions(id,encounter_id,source_kind,principal,profile)
-- statement
CREATE UNIQUE INDEX one_open_attempt ON stream_attempts(acquisition_id,stream) WHERE attempt_state='open'
-- statement
CREATE INDEX acquisition_facts_source_order ON acquisition_facts(acquisition_id,ordinal)
-- statement
CREATE FUNCTION valid_durable_receipt(value jsonb, expected_stream text, expected_fence text) RETURNS boolean LANGUAGE plpgsql IMMUTABLE AS $$
DECLARE field text; allowed text[] := ARRAY['stream_id','source_epoch','descriptor_ref','fence','journal_id','journal_generation','journal_digest','accepted_sequence','accepted_sample','durable_sequence','durable_sample'];
BEGIN
 IF value IS NULL THEN RETURN true; END IF;
 IF jsonb_typeof(value)<>'object' OR NOT(value ?& allowed) OR value-allowed<>'{}'::jsonb THEN RETURN false; END IF;
 FOREACH field IN ARRAY allowed LOOP IF jsonb_typeof(value->field)<>'string' THEN RETURN false; END IF; END LOOP;
 IF value->>'stream_id'<>expected_stream OR value->>'fence'<>expected_fence OR length(value->>'journal_id') NOT BETWEEN 1 AND 256 OR value->>'descriptor_ref' !~ '^[0-9a-f]{64}$' OR value->>'journal_digest' !~ '^[0-9a-f]{64}$' THEN RETURN false; END IF;
 FOREACH field IN ARRAY ARRAY['source_epoch','journal_generation','accepted_sequence','accepted_sample','durable_sequence','durable_sample'] LOOP
  IF value->>field !~ '^(0|[1-9][0-9]{0,19})$' OR (value->>field)::numeric>18446744073709551615 THEN RETURN false; END IF;
 END LOOP;
 RETURN (value->>'source_epoch')::numeric<=4294967295 AND (value->>'journal_generation')::numeric BETWEEN 1 AND 100000 AND value->>'accepted_sequence'=value->>'durable_sequence' AND value->>'accepted_sample'=value->>'durable_sample';
EXCEPTION WHEN others THEN RETURN false;
END
$$
-- statement
ALTER TABLE stream_attempts ADD CONSTRAINT exact_durable_receipt CHECK(valid_durable_receipt(receipt,stream,fence))
-- statement
ALTER TABLE stream_attempts ADD CONSTRAINT index_matches_receipt CHECK(sealed_index IS NULL OR (receipt IS NOT NULL AND sealed_index->>'fence'=fence AND sealed_index->>'journal_id'=receipt->>'journal_id' AND sealed_index->>'journal_generation'=receipt->>'journal_generation' AND sealed_index->>'journal_digest'=receipt->>'journal_digest' AND sealed_index->>'next_sequence'=receipt->>'durable_sequence' AND sealed_index->>'next_sample'=receipt->>'durable_sample' AND sealed_index->>'terminal' IN ('finished','interrupted','failed')) IS TRUE)
-- statement
CREATE FUNCTION immutable_source_identity() RETURNS trigger LANGUAGE plpgsql AS $$
BEGIN
 IF TG_TABLE_NAME='acquisitions' THEN
  IF (NEW.id,NEW.encounter_id,NEW.source_kind,NEW.principal,NEW.profile,NEW.parent_acquisition_id,NEW.created_at) IS DISTINCT FROM (OLD.id,OLD.encounter_id,OLD.source_kind,OLD.principal,OLD.profile,OLD.parent_acquisition_id,OLD.created_at) THEN RAISE EXCEPTION 'immutable_acquisition_identity'; END IF;
 END IF;
 IF TG_TABLE_NAME='acquisition_sessions' THEN
  IF (NEW.id,NEW.encounter_id,NEW.source_kind,NEW.principal,NEW.profile,NEW.device_id,NEW.patient_actor,NEW.browser_session,NEW.boot,NEW.site,NEW.descriptors,NEW.maximum_at) IS DISTINCT FROM (OLD.id,OLD.encounter_id,OLD.source_kind,OLD.principal,OLD.profile,OLD.device_id,OLD.patient_actor,OLD.browser_session,OLD.boot,OLD.site,OLD.descriptors,OLD.maximum_at) THEN RAISE EXCEPTION 'immutable_source_identity'; END IF;
  IF NEW.generation<OLD.generation THEN RAISE EXCEPTION 'generation_rollback'; END IF;
  IF OLD.frozen_at IS NOT NULL AND (NEW.frozen_at,NEW.frozen_generation,NEW.final_inventory) IS DISTINCT FROM (OLD.frozen_at,OLD.frozen_generation,OLD.final_inventory) THEN RAISE EXCEPTION 'frozen_evidence'; END IF;
 END IF;
 RETURN NEW;
END
$$
-- statement
CREATE TRIGGER acquisition_identity_immutable BEFORE UPDATE ON acquisitions FOR EACH ROW EXECUTE FUNCTION immutable_source_identity()
-- statement
CREATE TRIGGER session_source_immutable BEFORE UPDATE ON acquisition_sessions FOR EACH ROW EXECUTE FUNCTION immutable_source_identity()
-- statement
CREATE FUNCTION monotone_attempt() RETURNS trigger LANGUAGE plpgsql AS $$
BEGIN
 IF (NEW.acquisition_id,NEW.stream,NEW.number,NEW.generation,NEW.fence) IS DISTINCT FROM (OLD.acquisition_id,OLD.stream,OLD.number,OLD.generation,OLD.fence) THEN RAISE EXCEPTION 'immutable_attempt_identity'; END IF;
 IF OLD.attempt_state='terminal' AND NEW IS DISTINCT FROM OLD THEN RAISE EXCEPTION 'terminal_attempt_immutable'; END IF;
 IF OLD.receipt IS NOT NULL THEN
  IF NEW.receipt IS NULL OR (NEW.receipt->>'source_epoch',NEW.receipt->>'descriptor_ref',NEW.receipt->>'journal_id') IS DISTINCT FROM (OLD.receipt->>'source_epoch',OLD.receipt->>'descriptor_ref',OLD.receipt->>'journal_id') THEN RAISE EXCEPTION 'receipt_identity_changed'; END IF;
  IF (NEW.receipt->>'journal_generation')::numeric<(OLD.receipt->>'journal_generation')::numeric OR (NEW.receipt->>'durable_sequence')::numeric<(OLD.receipt->>'durable_sequence')::numeric OR (NEW.receipt->>'durable_sample')::numeric<(OLD.receipt->>'durable_sample')::numeric THEN RAISE EXCEPTION 'receipt_rollback'; END IF;
  IF NEW.receipt->>'journal_generation'=OLD.receipt->>'journal_generation' AND NEW.receipt IS DISTINCT FROM OLD.receipt THEN RAISE EXCEPTION 'receipt_conflict'; END IF;
  IF NEW.receipt->>'journal_generation'<>OLD.receipt->>'journal_generation' AND NEW.receipt->>'journal_digest'=OLD.receipt->>'journal_digest' THEN RAISE EXCEPTION 'receipt_digest_conflict'; END IF;
 END IF;
 RETURN NEW;
END
$$
-- statement
CREATE TRIGGER attempt_monotonic BEFORE UPDATE ON stream_attempts FOR EACH ROW EXECUTE FUNCTION monotone_attempt()
-- statement
CREATE TRIGGER attempt_no_delete BEFORE DELETE ON stream_attempts FOR EACH ROW EXECUTE FUNCTION immutable_evidence()
-- statement
CREATE TRIGGER acquisition_staging_immutable BEFORE UPDATE OR DELETE ON acquisition_manifest_staging FOR EACH ROW EXECUTE FUNCTION immutable_evidence()
-- statement
CREATE TRIGGER outbox_no_delete BEFORE DELETE ON outbox_deliveries FOR EACH ROW EXECUTE FUNCTION immutable_evidence()
-- statement
ALTER TABLE measurement_events ADD CONSTRAINT event_digest CHECK(fingerprint ~ '^[0-9a-f]{64}$')
-- statement
ALTER TABLE delivery_attempts ADD CONSTRAINT bounded_attempt_diagnostic CHECK(evidence_ref IS NULL OR length(evidence_ref)<=256)
-- statement
CREATE FUNCTION attempt_source_binding() RETURNS trigger LANGUAGE plpgsql AS $$
DECLARE descriptor jsonb; current_generation bigint;
BEGIN
 SELECT descriptors->NEW.stream,generation INTO descriptor,current_generation FROM acquisition_sessions WHERE id=NEW.acquisition_id;
 IF descriptor IS NULL OR NEW.generation>current_generation THEN RAISE EXCEPTION 'unreserved_attempt'; END IF;
 IF NEW.receipt IS NOT NULL AND (NEW.receipt->>'descriptor_ref',NEW.receipt->>'source_epoch') IS DISTINCT FROM (descriptor->>'descriptor_ref',descriptor->>'source_epoch') THEN RAISE EXCEPTION 'receipt_source_mismatch'; END IF;
 RETURN NEW;
END
$$
-- statement
CREATE TRIGGER attempt_source_binding BEFORE INSERT OR UPDATE ON stream_attempts FOR EACH ROW EXECUTE FUNCTION attempt_source_binding()
-- statement
CREATE FUNCTION native_delivery_identity() RETURNS trigger LANGUAGE plpgsql AS $$
DECLARE namespace text;
BEGIN
 SELECT 'urn:uuid:'||deployment_uuid::text INTO namespace FROM deployment_identity WHERE singleton;
 IF NEW.identifier_system IS DISTINCT FROM namespace OR NEW.identifier_value<>NEW.observation_id OR NEW.id<>NEW.observation_id THEN RAISE EXCEPTION 'wrong_native_delivery_identity'; END IF;
 RETURN NEW;
END
$$
-- statement
CREATE TRIGGER native_delivery_identity BEFORE INSERT ON outbox_deliveries FOR EACH ROW EXECUTE FUNCTION native_delivery_identity()
