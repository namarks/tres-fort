-- A partner lane is still an ordinary account-owned session. The marker pins
-- its shared prescription until that member finishes or continues alone.
ALTER TABLE sessions ADD COLUMN partner_workout_id TEXT;

-- These guards cover REST, MCP and full-plan rebuilds at the actual write,
-- including races with Start. A failed batch rolls back version/audit/snapshot.
CREATE TRIGGER partner_slot_insert BEFORE INSERT ON template_exercises
WHEN EXISTS (SELECT 1 FROM sessions s WHERE s.workout_id=NEW.workout_id
  AND s.status='in_progress' AND s.partner_workout_id IS NOT NULL
  AND NOT EXISTS (SELECT 1 FROM account_deletion_intents i WHERE i.user_id=s.user_id))
BEGIN SELECT RAISE(ABORT,'active_partner_workout'); END;
CREATE TRIGGER partner_slot_update BEFORE UPDATE ON template_exercises
WHEN EXISTS (SELECT 1 FROM sessions s WHERE s.workout_id IN (OLD.workout_id,NEW.workout_id)
  AND s.status='in_progress' AND s.partner_workout_id IS NOT NULL
  AND NOT EXISTS (SELECT 1 FROM account_deletion_intents i WHERE i.user_id=s.user_id))
BEGIN SELECT RAISE(ABORT,'active_partner_workout'); END;
CREATE TRIGGER partner_slot_delete BEFORE DELETE ON template_exercises
WHEN EXISTS (SELECT 1 FROM sessions s WHERE s.workout_id=OLD.workout_id
  AND s.status='in_progress' AND s.partner_workout_id IS NOT NULL
  AND NOT EXISTS (SELECT 1 FROM account_deletion_intents i WHERE i.user_id=s.user_id))
BEGIN SELECT RAISE(ABORT,'active_partner_workout'); END;
CREATE TRIGGER partner_workout_update BEFORE UPDATE ON workouts
WHEN EXISTS (SELECT 1 FROM sessions s WHERE s.workout_id=OLD.id
  AND s.status='in_progress' AND s.partner_workout_id IS NOT NULL
  AND NOT EXISTS (SELECT 1 FROM account_deletion_intents i WHERE i.user_id=s.user_id))
BEGIN SELECT RAISE(ABORT,'active_partner_workout'); END;
CREATE TRIGGER partner_workout_delete BEFORE DELETE ON workouts
WHEN EXISTS (SELECT 1 FROM sessions s WHERE s.workout_id=OLD.id
  AND s.status='in_progress' AND s.partner_workout_id IS NOT NULL
  AND NOT EXISTS (SELECT 1 FROM account_deletion_intents i WHERE i.user_id=s.user_id))
BEGIN SELECT RAISE(ABORT,'active_partner_workout'); END;

-- A cancelled, possibly in-flight Start needs a durable fence even if its
-- session has not been inserted yet. Reuse the append-only audit receipt.
CREATE UNIQUE INDEX partner_cancel_request ON audit_log(user_id, json_extract(args,'$.id'))
WHERE tool='cancel_partner_start';

CREATE TRIGGER partner_session_terminal AFTER UPDATE OF status ON sessions
WHEN NEW.status != 'in_progress' AND NEW.partner_workout_id IS NOT NULL
BEGIN UPDATE sessions SET partner_workout_id=NULL WHERE id=NEW.id; END;
CREATE TRIGGER partner_session_swap BEFORE UPDATE OF exercise_swaps ON sessions
WHEN OLD.status='in_progress' AND OLD.partner_workout_id IS NOT NULL
  AND NEW.exercise_swaps IS NOT OLD.exercise_swaps
  AND NOT EXISTS (SELECT 1 FROM account_deletion_intents i WHERE i.user_id=OLD.user_id)
BEGIN SELECT RAISE(ABORT,'active_partner_workout'); END;

-- Full-plan rebuilds remap sessions before deleting old slots. Pin that link
-- too, so the remap cannot evade the prescription guards above.
CREATE TRIGGER partner_session_assignment BEFORE UPDATE OF workout_id,plan_id ON sessions
WHEN OLD.status='in_progress' AND OLD.partner_workout_id IS NOT NULL
  AND (NEW.workout_id IS NOT OLD.workout_id OR NEW.plan_id IS NOT OLD.plan_id)
  AND NOT EXISTS (SELECT 1 FROM account_deletion_intents i WHERE i.user_id=OLD.user_id)
BEGIN SELECT RAISE(ABORT,'active_partner_workout'); END;
CREATE TRIGGER partner_plan_retire BEFORE UPDATE OF status ON plans
WHEN NEW.status IS NOT OLD.status AND EXISTS (SELECT 1 FROM sessions s WHERE s.plan_id=OLD.id
  AND s.status='in_progress' AND s.partner_workout_id IS NOT NULL
  AND NOT EXISTS (SELECT 1 FROM account_deletion_intents i WHERE i.user_id=s.user_id))
BEGIN SELECT RAISE(ABORT,'active_partner_workout'); END;
