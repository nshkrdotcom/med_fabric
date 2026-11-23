ALTER TABLE acquisitions
  ALTER COLUMN evidence DROP NOT NULL,
  ADD COLUMN IF NOT EXISTS producer text,
  ADD COLUMN IF NOT EXISTS capture_source jsonb,
  ADD COLUMN IF NOT EXISTS first_received_at timestamptz,
  ADD COLUMN IF NOT EXISTS state text NOT NULL DEFAULT 'ready'
    CHECK (
      (state = 'ready' AND evidence IS NOT NULL AND producer IS NULL
       AND capture_source IS NULL AND first_received_at IS NULL)
      OR
      (state IN ('recording', 'interrupted') AND evidence IS NULL AND producer IS NOT NULL
       AND (capture_source IS NULL) = (first_received_at IS NULL))
    );

CREATE UNIQUE INDEX IF NOT EXISTS acquisitions_one_recording
  ON acquisitions (encounter_id) WHERE state = 'recording';
