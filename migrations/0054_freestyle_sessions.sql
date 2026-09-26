ALTER TABLE sessions ADD COLUMN kind TEXT NOT NULL DEFAULT 'planned'
  CHECK (kind IN ('planned', 'freestyle'));

-- A save receipt survives later library edits/deletion and settles a lost ACK.
CREATE TABLE freestyle_workout_receipts (
  user_id TEXT NOT NULL REFERENCES users(id),
  new_workout_id TEXT NOT NULL,
  session_id TEXT NOT NULL REFERENCES sessions(id),
  source_attempt INTEGER NOT NULL,
  request TEXT NOT NULL,
  response TEXT NOT NULL,
  created_at INTEGER NOT NULL,
  PRIMARY KEY (user_id, new_workout_id),
  UNIQUE (session_id, source_attempt)
);

-- Kind is fixed within a generation. Empty/skipped/discarded dates can start
-- a different kind only through an explicit attempt-advancing restart.
CREATE TRIGGER sessions_kind_generation BEFORE UPDATE OF kind ON sessions
WHEN NEW.kind != OLD.kind AND
  (NEW.attempt <= OLD.attempt OR OLD.status NOT IN ('planned','skipped','discarded')
   OR EXISTS (SELECT 1 FROM set_logs WHERE session_id=OLD.id AND deleted_at IS NULL))
BEGIN SELECT RAISE(ABORT, 'session_kind_conflict'); END;

CREATE TRIGGER freestyle_set_slot_insert BEFORE INSERT ON set_logs
WHEN NEW.deleted_at IS NULL AND NEW.template_exercise_id IS NOT NULL AND EXISTS (
  SELECT 1 FROM sessions WHERE id=NEW.session_id AND kind='freestyle')
BEGIN SELECT RAISE(ABORT, 'session_kind_conflict'); END;

CREATE TRIGGER freestyle_set_slot_update BEFORE UPDATE OF template_exercise_id,session_id,deleted_at ON set_logs
WHEN NEW.deleted_at IS NULL AND NEW.template_exercise_id IS NOT NULL AND EXISTS (
  SELECT 1 FROM sessions WHERE id=NEW.session_id AND kind='freestyle')
BEGIN SELECT RAISE(ABORT, 'session_kind_conflict'); END;

CREATE TRIGGER freestyle_live_pin BEFORE UPDATE OF workout_id ON sessions
WHEN NEW.kind='freestyle' AND NEW.workout_id IS NOT NULL AND NEW.status NOT IN ('completed','discarded')
BEGIN SELECT RAISE(ABORT, 'session_kind_conflict'); END;
