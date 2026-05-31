-- A set-level timed flag: 1 = this set was a deliberate timed hold (renders
-- as "Ns"), 0 = a conventional rep set. `duration_s` alone is NOT a reliable
-- timed signal — rep sets logged before #30 carry an incidental wall-clock
-- duration, so renderers can't infer timed-ness from duration_s and instead
-- fall back to the catalog modality. An explicit per-set flag lets a coach pin
-- target_duration_s on ANY exercise and have the logged set render
-- consistently as timed across Today / history / agenda, independent of the
-- exercise's catalog modality.
ALTER TABLE set_logs ADD COLUMN is_timed INTEGER NOT NULL DEFAULT 0;

-- Backfill: existing sets of timed-modality exercises ARE timed holds, so they
-- keep rendering as durations once clients switch to reading is_timed. Legacy
-- rep sets stay 0 so their incidental duration_s keeps reading as reps.
UPDATE set_logs
   SET is_timed = 1
 WHERE exercise_id IN (SELECT id FROM exercises WHERE modality = 'timed');
