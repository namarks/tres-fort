-- Monotonic workout-attempt generation for the single (user,date) session
-- row. Discard keeps the current generation; an explicit revival increments
-- it so delayed ACKs from the prior attempt cannot overwrite newer state.
ALTER TABLE sessions ADD COLUMN attempt INTEGER NOT NULL DEFAULT 0;

-- Rolling-release fence for the attempt protocol. Rows created or last
-- operated by the released app remain `legacy` until an attempt-aware writer
-- atomically claims that generation. Once claimed, tokenless legacy mutations
-- are rejected instead of being silently retargeted across a discard/restart.
ALTER TABLE sessions ADD COLUMN write_protocol TEXT NOT NULL DEFAULT 'legacy'
  CHECK (write_protocol IN ('legacy', 'attempt-v1'));

-- `npm run release` applies migrations before deploying the Worker. During
-- that bounded interval the old Worker can still revive discarded/skipped
-- rows without knowing about `attempt`; advance the generation on its behalf.
-- The compatibility Worker writes attempt + 1 itself, so the equality guard
-- makes this trigger a no-op after cutover.
CREATE TRIGGER sessions_legacy_restart_attempt
AFTER UPDATE OF status ON sessions
WHEN OLD.status IN ('discarded', 'skipped')
  AND NEW.status = 'planned'
  AND NEW.attempt = OLD.attempt
BEGIN
  UPDATE sessions
     SET attempt = OLD.attempt + 1,
         write_protocol = 'legacy'
   WHERE id = NEW.id
     AND attempt = OLD.attempt;
END;

-- A generation-aware Worker cannot safely overlap an invocation of the
-- pre-fence Worker once attempt-v1 writes are admitted: the old invocation
-- could otherwise retarget an unscoped write onto a later generation.  Keep
-- this database-enforced cutover disabled while the compatibility Worker is
-- deployed, then activate it exactly once after that deploy succeeds.
CREATE TABLE workout_write_fence (
  id           INTEGER PRIMARY KEY CHECK (id = 1),
  enabled      INTEGER NOT NULL DEFAULT 0 CHECK (enabled IN (0, 1)),
  activated_at INTEGER,
  CHECK (
    (enabled = 0 AND activated_at IS NULL)
    OR (enabled = 1 AND activated_at IS NOT NULL)
  )
);

INSERT INTO workout_write_fence (id, enabled, activated_at)
VALUES (1, 0, NULL);

-- This singleton is deliberately empty outside a protected D1 batch.  The
-- compatibility Worker inserts the row, performs its session/set statements,
-- and deletes it in one batch transaction.  A failed statement rolls the
-- whole batch back, so the permit cannot leak from an interrupted request.
CREATE TABLE workout_write_permit (
  id INTEGER PRIMARY KEY CHECK (id = 1)
);

-- Activation is a one-way database transition.  In particular, rolling the
-- Worker back cannot silently disable the guard after attempt-v1 traffic has
-- started.  A leaked permit would leave the guard open, so reject activation
-- unless the permit table is empty.
CREATE TRIGGER workout_write_fence_activation_requires_empty_permit
BEFORE UPDATE OF enabled ON workout_write_fence
WHEN NEW.enabled = 1
  AND EXISTS (SELECT 1 FROM workout_write_permit WHERE id = 1)
BEGIN
  SELECT RAISE(ABORT, 'workout_write_fence_permit_not_empty');
END;

CREATE TRIGGER workout_write_fence_is_monotonic
BEFORE UPDATE ON workout_write_fence
WHEN OLD.enabled = 1
  AND (
    NEW.enabled IS NOT OLD.enabled
    OR NEW.activated_at IS NOT OLD.activated_at
  )
BEGIN
  SELECT RAISE(ABORT, 'workout_write_fence_is_monotonic');
END;

CREATE TRIGGER workout_write_fence_cannot_be_deleted
BEFORE DELETE ON workout_write_fence
BEGIN
  SELECT RAISE(ABORT, 'workout_write_fence_cannot_be_deleted');
END;

-- Deployment success is not itself the cutover.  Until the monotonic fence is
-- explicitly activated, even the compatibility Worker must keep rows legacy;
-- otherwise its first v1 claim could overlap a pre-fence invocation in the
-- narrow deploy-to-activation window.
CREATE TRIGGER sessions_attempt_protocol_requires_fence_insert
BEFORE INSERT ON sessions
WHEN NEW.write_protocol = 'attempt-v1'
  AND COALESCE((SELECT enabled FROM workout_write_fence WHERE id = 1), 0) <> 1
BEGIN
  SELECT RAISE(ABORT, 'workout_write_fence_not_active');
END;

CREATE TRIGGER sessions_attempt_protocol_requires_fence_update
BEFORE UPDATE ON sessions
WHEN NEW.write_protocol = 'attempt-v1'
  AND COALESCE((SELECT enabled FROM workout_write_fence WHERE id = 1), 0) <> 1
BEGIN
  SELECT RAISE(ABORT, 'workout_write_fence_not_active');
END;

-- After activation, every INSERT/UPDATE on the two workout-write tables must
-- be part of a permitted D1 batch.  Old or rolled-back Workers know nothing
-- about the permit and therefore fail closed at the database boundary.
CREATE TRIGGER sessions_workout_write_fence_insert
BEFORE INSERT ON sessions
WHEN (SELECT enabled FROM workout_write_fence WHERE id = 1) = 1
  AND NOT EXISTS (SELECT 1 FROM workout_write_permit WHERE id = 1)
BEGIN
  SELECT RAISE(ABORT, 'workout_write_fence_active');
END;

CREATE TRIGGER sessions_workout_write_fence_update
BEFORE UPDATE ON sessions
WHEN (SELECT enabled FROM workout_write_fence WHERE id = 1) = 1
  AND NOT EXISTS (SELECT 1 FROM workout_write_permit WHERE id = 1)
BEGIN
  SELECT RAISE(ABORT, 'workout_write_fence_active');
END;

CREATE TRIGGER set_logs_workout_write_fence_insert
BEFORE INSERT ON set_logs
WHEN (SELECT enabled FROM workout_write_fence WHERE id = 1) = 1
  AND NOT EXISTS (SELECT 1 FROM workout_write_permit WHERE id = 1)
BEGIN
  SELECT RAISE(ABORT, 'workout_write_fence_active');
END;

CREATE TRIGGER set_logs_workout_write_fence_update
BEFORE UPDATE ON set_logs
WHEN (SELECT enabled FROM workout_write_fence WHERE id = 1) = 1
  AND NOT EXISTS (SELECT 1 FROM workout_write_permit WHERE id = 1)
BEGIN
  SELECT RAISE(ABORT, 'workout_write_fence_active');
END;
