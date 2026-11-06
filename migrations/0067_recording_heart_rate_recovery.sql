-- Migration 0067: heart rate recovery after a run recorded in the app
-- (docs/plans/run-recorder P7).
--
-- When a Bluetooth strap stays connected after the member stops a run, the
-- recorder keeps reading it for two minutes and sends the heart rate at the
-- stop and one and two minutes after it. Only `source = 'recording'` rows
-- carry them. They describe the cool-down, not the run: moving time,
-- distance, average and maximum heart rate and load never include those
-- minutes. NULL when nothing was measured (no strap, Done tapped early, or
-- the strap dropped).
ALTER TABLE external_activities ADD COLUMN recovery_hr_at_stop INTEGER
  CHECK (recovery_hr_at_stop IS NULL OR (typeof(recovery_hr_at_stop) = 'integer'
    AND recovery_hr_at_stop BETWEEN 20 AND 250));
ALTER TABLE external_activities ADD COLUMN recovery_hr_after_60s INTEGER
  CHECK (recovery_hr_after_60s IS NULL OR (typeof(recovery_hr_after_60s) = 'integer'
    AND recovery_hr_after_60s BETWEEN 20 AND 250));
ALTER TABLE external_activities ADD COLUMN recovery_hr_after_120s INTEGER
  CHECK (recovery_hr_after_120s IS NULL OR (typeof(recovery_hr_after_120s) = 'integer'
    AND recovery_hr_after_120s BETWEEN 20 AND 250));
