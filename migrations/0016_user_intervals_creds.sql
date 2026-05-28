-- M1: Per-user intervals.icu credentials.
--
-- The cycling-awareness feature currently reads ONE pair of secrets
-- (`INTERVALS_ICU_API_KEY` / `INTERVALS_ICU_ATHLETE_ID`) from the Worker
-- env, so a second Apple sign-in (girlfriend's account, eventually) cannot
-- connect a SEPARATE intervals.icu athlete without clobbering the owner's
-- key. This migration moves the credentials onto the user row so each user
-- can connect their own intervals.icu account independently.
--
-- Both columns are nullable: a user without creds is in the same "dormant
-- no-op" state the env-less Worker is in today (no fetch, no error).
-- sync* in db.ts now enumerates `WHERE intervals_api_key IS NOT NULL AND
-- intervals_athlete_id IS NOT NULL` and loops per user.
--
-- Env → DB transition path. We CANNOT seed the existing owner row from
-- env here (a static SQL migration has no access to wrangler secrets).
-- The first call to syncExternalEvents/syncExternalActivities does the
-- one-time seed when (a) no user has creds set AND (b) env values are
-- present — see `seedOwnerIntervalsCredsFromEnv` in src/db.ts. Idempotent:
-- subsequent calls skip the seed because the columns are now populated.
--
-- Additive + idempotent (vitest's D1 path re-applies all migrations):
-- ADD COLUMN is idempotent here because the columns are guaranteed not
-- to pre-exist on a fresh schema, and D1's applyD1Migrations only re-runs
-- new migrations.

ALTER TABLE users ADD COLUMN intervals_api_key TEXT;
ALTER TABLE users ADD COLUMN intervals_athlete_id TEXT;
