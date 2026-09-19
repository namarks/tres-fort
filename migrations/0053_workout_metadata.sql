-- Additive metadata; apply after the workout rename, before the compatible Worker.
ALTER TABLE workouts ADD COLUMN tags TEXT NOT NULL DEFAULT '[]'
  CHECK (json_valid(tags) AND json_type(tags) = 'array');
ALTER TABLE workouts ADD COLUMN archived_at INTEGER
  CHECK (archived_at IS NULL OR (typeof(archived_at) = 'integer' AND archived_at > 0));

-- Close read/assignment races across every released session writer. Existing
-- completed history may continue to reference archived workouts.
CREATE TRIGGER sessions_reject_archived_workout_insert
BEFORE INSERT ON sessions
WHEN NEW.status IN ('planned','in_progress') AND (EXISTS (
  SELECT 1 FROM workouts WHERE id=NEW.workout_id AND archived_at IS NOT NULL
) OR EXISTS (
  SELECT 1 FROM set_logs l JOIN template_exercises te ON te.id=l.template_exercise_id
  JOIN workouts w ON w.id=te.workout_id
  WHERE l.session_id=NEW.id AND l.deleted_at IS NULL AND w.archived_at IS NOT NULL
))
BEGIN SELECT RAISE(ABORT, 'workout_archived_assignment'); END;
CREATE TRIGGER sessions_reject_archived_workout_update
BEFORE UPDATE OF workout_id,status ON sessions
WHEN NEW.status IN ('planned','in_progress') AND (EXISTS (
  SELECT 1 FROM workouts WHERE id=NEW.workout_id AND archived_at IS NOT NULL
) OR EXISTS (
  SELECT 1 FROM set_logs l JOIN template_exercises te ON te.id=l.template_exercise_id
  JOIN workouts w ON w.id=te.workout_id
  WHERE l.session_id=NEW.id AND l.deleted_at IS NULL AND w.archived_at IS NOT NULL
))
BEGIN SELECT RAISE(ABORT, 'workout_archived_assignment'); END;

-- A local override may log A's slots into a session pinned to B. Fence that
-- delayed first set as well as the session pin, without blocking completed
-- history or soft deletion. Updates fence changing/reviving the reference.
CREATE TRIGGER set_logs_reject_archived_workout_insert
BEFORE INSERT ON set_logs
WHEN NEW.deleted_at IS NULL AND EXISTS (
  SELECT 1 FROM sessions s JOIN template_exercises te ON te.id=NEW.template_exercise_id
  JOIN workouts w ON w.id=te.workout_id
  WHERE s.id=NEW.session_id AND s.status<>'completed' AND w.archived_at IS NOT NULL
)
BEGIN SELECT RAISE(ABORT, 'workout_archived_assignment'); END;
CREATE TRIGGER set_logs_reject_archived_workout_update
BEFORE UPDATE OF session_id,template_exercise_id,deleted_at ON set_logs
WHEN NEW.deleted_at IS NULL AND EXISTS (
  SELECT 1 FROM sessions s JOIN template_exercises te ON te.id=NEW.template_exercise_id
  JOIN workouts w ON w.id=te.workout_id
  WHERE s.id=NEW.session_id AND s.status<>'completed' AND w.archived_at IS NOT NULL
)
BEGIN SELECT RAISE(ABORT, 'workout_archived_assignment'); END;
