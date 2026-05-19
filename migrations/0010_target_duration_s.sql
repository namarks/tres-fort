-- 0010_target_duration_s.sql
-- Adds an explicit duration target on plan slots so timed exercises
-- (planks, holds, Cat-Cow flows, etc.) can be specified natively rather
-- than overloaded onto target_reps with the duration jammed into the
-- `cues` text — the agent-facing bug report's P1.
--
-- NULLable, no default. Existing rows stay null; clients ignore. The
-- column mirrors set_logs.duration_s (added by 0004) — the *planned*
-- counterpart to the *logged* duration. Encoding rule for clients:
--   target_duration_s NOT NULL → this is a timed slot; ignore target_reps.
--   target_duration_s NULL     → conventional weight-and-reps slot.
-- iOS Runner adoption is a separate change; the server is the source
-- of truth and accepts/returns the field today.

ALTER TABLE template_exercises ADD COLUMN target_duration_s INTEGER;
