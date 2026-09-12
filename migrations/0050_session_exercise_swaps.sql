-- Workout-only substitutions ride the existing session delta and attempt boundary.
-- The recurring plan and all previously logged sets remain unchanged.
ALTER TABLE sessions ADD COLUMN exercise_swaps TEXT;
