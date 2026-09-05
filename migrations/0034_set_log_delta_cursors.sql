-- Add member ownership and a mutable sync cursor without rebuilding set_logs.
-- Placeholder defaults keep the migration compatible with the previously
-- deployed Worker, whose INSERT column list does not know about these fields.
ALTER TABLE set_logs ADD COLUMN user_id TEXT NOT NULL DEFAULT '';
ALTER TABLE set_logs ADD COLUMN updated_at INTEGER NOT NULL DEFAULT 0;
ALTER TABLE activities ADD COLUMN updated_at INTEGER NOT NULL DEFAULT 0;

-- Production may already have the monotonic workout-write fence enabled.
-- Hold its singleton permit only for the protected set_logs backfill; D1
-- applies each migration atomically, so a failed UPDATE cannot leak it.
INSERT INTO workout_write_permit (id) VALUES (1);
UPDATE set_logs
   SET user_id = (
         SELECT sessions.user_id
           FROM sessions
          WHERE sessions.id = set_logs.session_id
       ),
       updated_at = CAST(strftime('%s', 'now') AS INTEGER) * 1000
 WHERE user_id = ''
   AND updated_at = 0;
DELETE FROM workout_write_permit WHERE id = 1;

-- Abort the migration if the additive backfill did not reproduce the owning
-- session and produce a server-owned cursor. The table exists only long
-- enough to make the CHECK constraint an executable migration assertion.
CREATE TABLE p1_set_log_backfill_assertion (
  valid INTEGER NOT NULL CHECK (valid = 1)
);
INSERT INTO p1_set_log_backfill_assertion (valid)
SELECT CASE WHEN EXISTS (
  SELECT 1
    FROM set_logs AS sl
    LEFT JOIN sessions AS s ON s.id = sl.session_id
   WHERE s.id IS NULL
      OR sl.user_id IS NOT s.user_id
      OR sl.updated_at <= 0
) THEN 0 ELSE 1 END;
DROP TABLE p1_set_log_backfill_assertion;

-- Existing manual activities predate a server-owned cursor. A mandatory first
-- full reload carries their history, so initialize every cursor from D1's
-- clock rather than trusting client-authored event time.
UPDATE activities
   SET updated_at = CAST(strftime('%s', 'now') AS INTEGER) * 1000
 WHERE updated_at = 0;

-- Migration-first rolling-release compatibility. The old Worker omits both
-- new columns, so both exact placeholder defaults identify its insert. New
-- writes supply both fields and bypass this trigger.
CREATE TRIGGER set_logs_legacy_delta_fields
AFTER INSERT ON set_logs
WHEN NEW.user_id = '' AND NEW.updated_at = 0
BEGIN
  UPDATE set_logs
     SET user_id = (
           SELECT user_id FROM sessions WHERE id = NEW.session_id
         ),
         updated_at = CAST(strftime('%s', 'now') AS INTEGER) * 1000
   WHERE id = NEW.id
     AND user_id = ''
     AND updated_at = 0;
END;

-- During the migration-to-deploy window the previous Worker updates these
-- mutable fields without naming updated_at. Advance the cursor only when a
-- value really changed and the statement did not advance it itself. MAX keeps
-- rapid same-ms writes monotonic; limiting UPDATE OF also prevents recursion
-- when this trigger's own cursor-only UPDATE runs.
CREATE TRIGGER set_logs_legacy_update_cursor
AFTER UPDATE OF
  template_exercise_id, weight, reps, rpe, notes, duration_s, deleted_at
ON set_logs
WHEN NEW.updated_at <= OLD.updated_at
  AND (
    NEW.template_exercise_id IS NOT OLD.template_exercise_id
    OR NEW.weight IS NOT OLD.weight
    OR NEW.reps IS NOT OLD.reps
    OR NEW.rpe IS NOT OLD.rpe
    OR NEW.notes IS NOT OLD.notes
    OR NEW.duration_s IS NOT OLD.duration_s
    OR NEW.deleted_at IS NOT OLD.deleted_at
  )
BEGIN
  UPDATE set_logs
     SET updated_at = MAX(
           OLD.updated_at + 1,
           CAST(strftime('%s', 'now') AS INTEGER) * 1000
         )
   WHERE id = NEW.id
     AND updated_at <= OLD.updated_at;
END;

-- The old Worker omits activities.updated_at. Use D1's clock for legacy
-- inserts so a skewed client logged_at cannot strand the row behind a later
-- server-time watermark. Millisecond precision is unnecessary during this
-- bounded compatibility window because clients overlap cursors by 60 seconds.
CREATE TRIGGER activities_legacy_insert_cursor
AFTER INSERT ON activities
WHEN NEW.updated_at = 0
BEGIN
  UPDATE activities
     SET updated_at = CAST(strftime('%s', 'now') AS INTEGER) * 1000
   WHERE id = NEW.id
     AND updated_at = 0;
END;

-- The old Worker soft-deletes with a server-clock deleted_at but cannot name
-- updated_at yet. New code updates both columns, so this exact unchanged-
-- cursor condition fires only for the legacy statement shape.
CREATE TRIGGER activities_legacy_delete_cursor
AFTER UPDATE OF deleted_at ON activities
WHEN NEW.deleted_at IS NOT OLD.deleted_at
  AND NEW.updated_at = OLD.updated_at
BEGIN
  UPDATE activities
     SET updated_at = MAX(OLD.updated_at + 1, NEW.deleted_at)
   WHERE id = NEW.id
     AND updated_at <= OLD.updated_at;
END;

CREATE INDEX ix_sets_user_updated ON set_logs(user_id, updated_at);
CREATE INDEX ix_sessions_user_updated ON sessions(user_id, updated_at);
CREATE INDEX ix_activities_user_updated ON activities(user_id, updated_at);
