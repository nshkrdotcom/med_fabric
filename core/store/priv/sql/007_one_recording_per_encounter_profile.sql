-- Tighten 006 for databases that already ran the Phase 3A candidate.
CREATE UNIQUE INDEX acquisitions_one_recording_per_encounter_profile
  ON acquisitions (encounter_id, capture_profile)
  WHERE state = 'recording';

DROP INDEX acquisitions_one_recording_per_profile;
