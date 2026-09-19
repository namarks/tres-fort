-- Additive metadata; apply after the workout rename, before the compatible Worker.
ALTER TABLE workouts ADD COLUMN tags TEXT NOT NULL DEFAULT '[]'
  CHECK (json_valid(tags) AND json_type(tags) = 'array');
ALTER TABLE workouts ADD COLUMN archived_at INTEGER
  CHECK (archived_at IS NULL OR (typeof(archived_at) = 'integer' AND archived_at > 0));

-- Close read/assignment races across every released session writer. Existing
-- completed history may continue to reference archived workouts.
CREATE TRIGGER sessions_reject_archived_workout_insert
BEFORE INSERT ON sessions
WHEN NEW.status IN ('planned','in_progress') AND EXISTS (
  SELECT 1 FROM workouts WHERE id=NEW.workout_id AND archived_at IS NOT NULL
)
BEGIN SELECT RAISE(ABORT, 'workout_archived_assignment'); END;
CREATE TRIGGER sessions_reject_archived_workout_update
BEFORE UPDATE OF workout_id,status ON sessions
WHEN NEW.status IN ('planned','in_progress') AND EXISTS (
  SELECT 1 FROM workouts WHERE id=NEW.workout_id AND archived_at IS NOT NULL
)
BEGIN SELECT RAISE(ABORT, 'workout_archived_assignment'); END;
