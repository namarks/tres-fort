-- 0058_run_steps.sql
--
-- Planned runs (docs/plans/planned-runs, P0). A run slot of a plan workout can
-- carry ordered steps: warm-up, work, recovery or cool-down, each ending after
-- a duration or a distance, with an optional pace or heart rate range, and
-- repeat groups for intervals. The steps are canonical JSON text validated by
-- src/runSteps.ts on every write. They live on the slot, so they travel with
-- the versioned plan document, its snapshots and /api/state like progression.
-- NULL (every existing row) means no steps.
--
-- The steps belong on an outdoor run, which the catalog could not express:
-- Treadmill is the only running row. Aliases never take an existing phrase,
-- so the bare "run" and "jog" stay on ex_treadmill. modality 'cardio' and
-- unit 'min' match the other cardio rows, so clients treat the slot as a
-- timed slot until they learn about steps.
--
-- STRICTLY ADDITIVE. ADD COLUMN fires no write-fence trigger, and INSERT OR
-- IGNORE keeps a replay of the catalog row a no-op; created_at = 0 marks a
-- timeless seed like every earlier catalog row.

ALTER TABLE template_exercises ADD COLUMN run_steps TEXT;

INSERT OR IGNORE INTO exercises
  (id, name, primary_muscle, secondary_muscles, modality, unit,
   aliases, created_at, laterality, load_mode, demo_slug)
VALUES
  ('ex_outdoor_run', 'Outdoor Run', 'full body', '["quads","hamstrings","calves"]', 'cardio', 'min',
   '["outdoor run","outdoor running","road run","trail run","running outside","run outside","planned run","interval run","tempo run","easy run","long run"]', 0, 'bilateral', 'total', NULL);
