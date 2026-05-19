-- Weekly schedule + future-calendar projection (milestone j/k/l).
--
-- No new table: the recurring weekly pattern lives in plans.meta JSON,
-- consistent with DESIGN.md's "no weeks/mesocycles tables" decision. The
-- frozen contract is:
--
--   "schedule": { "version": 1,
--     "week": { "mon": <day_template_id|null>, "tue": ..., ... "sun": ... } }
--
-- Keyed by weekday; null/absent = rest day. Values are stable
-- day_template_id strings resolved by set_schedule.
--
-- This migration is an idempotent backfill: every existing plan gets a
-- well-formed empty schedule (all weekdays null) UNLESS it already has a
-- schedule object. Existing meta keys are preserved (json_set patches in
-- place; NULL/invalid meta is replaced with a fresh object). Re-running is
-- a no-op because the WHERE clause excludes rows that already carry a
-- schedule object.

UPDATE plans
SET meta = json_set(
      CASE
        WHEN meta IS NOT NULL AND json_valid(meta) THEN meta
        ELSE '{}'
      END,
      '$.schedule',
      json('{"version":1,"week":{"mon":null,"tue":null,"wed":null,"thu":null,"fri":null,"sat":null,"sun":null}}')
    ),
    updated_at = updated_at
WHERE meta IS NULL
   OR NOT json_valid(meta)
   OR json_type(meta, '$.schedule') IS NULL;
