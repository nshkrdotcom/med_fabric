DROP INDEX IF EXISTS acquisitions_one_recording;

CREATE UNIQUE INDEX IF NOT EXISTS acquisitions_one_recording_per_profile
  ON acquisitions (encounter_id, producer, capture_profile)
  WHERE state = 'recording';
