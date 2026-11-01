-- Effective training load per external activity
-- (docs/plans/endurance-training-load P1). training_load / intensity stay
-- exactly what the provider sent; these columns hold the load Tres Fort
-- shows: the provider's figure when it has one, otherwise one computed by
-- src/trainingLoad.ts from the member's athlete_thresholds. NULL means no
-- usable data, never zero. Recomputed on activity writes and threshold
-- changes, which advance synced_at so /api/state deltas carry it.
ALTER TABLE external_activities ADD COLUMN effective_load REAL;
ALTER TABLE external_activities ADD COLUMN effective_intensity REAL;
ALTER TABLE external_activities ADD COLUMN load_method TEXT
  CHECK (load_method IS NULL OR load_method IN
    ('provider', 'power', 'power_summary', 'heart_rate', 'heart_rate_average', 'pace'));

-- Provider loads are effective as they stand. Clients already hold these
-- rows with training_load, so synced_at is left alone.
UPDATE external_activities
   SET effective_load = ROUND(training_load),
       effective_intensity = CASE WHEN intensity > 0 THEN ROUND(intensity, 1) END,
       load_method = 'provider'
 WHERE training_load IS NOT NULL AND training_load >= 0;
