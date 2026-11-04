-- Migration 0065: the member's own "How hard was it?" for an imported workout
-- (docs/plans/sport-activities P2, endurance-training-load P6).
--
-- `effort` is the member's rating on a 1 to 10 scale (src/trainingLoad.ts,
-- EFFORT_SCALE). It is their own data, never a provider's: importers neither
-- send nor overwrite it. When a workout has no heart-rate, power, pace or
-- provider load, refreshActivityLoads scores it from the rating and labels it
-- load_method = 'effort', an estimate.
ALTER TABLE external_activities ADD COLUMN effort INTEGER
  CHECK (effort IS NULL OR (typeof(effort) = 'integer' AND effort BETWEEN 1 AND 10));

-- load_method's CHECK (migration 0060) gains 'effort'. SQLite cannot change a
-- column's CHECK in place, so the column is replaced: a new one with the
-- wider CHECK takes every value, the old one is dropped (only its own CHECK
-- names it: no index, trigger or view does) and the new one takes its name.
-- Values and synced_at are unchanged, so clients see no difference.
ALTER TABLE external_activities ADD COLUMN load_method_0065 TEXT
  CHECK (load_method_0065 IS NULL OR load_method_0065 IN
    ('provider', 'power', 'power_summary', 'heart_rate', 'heart_rate_average', 'pace', 'effort'));
UPDATE external_activities SET load_method_0065 = load_method WHERE load_method IS NOT NULL;
ALTER TABLE external_activities DROP COLUMN load_method;
ALTER TABLE external_activities RENAME COLUMN load_method_0065 TO load_method;
