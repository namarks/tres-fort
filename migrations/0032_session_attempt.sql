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
