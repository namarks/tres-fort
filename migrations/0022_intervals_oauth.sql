-- 0022: intervals.icu OAuth (per-user bearer tokens) + auth-flow state.
--
-- Adds OAuth as an ALTERNATIVE to the per-user API key from 0016. After this,
-- a user's cycling-awareness is active when they have an `intervals_athlete_id`
-- AND either:
--   * `intervals_api_key`            → HTTP Basic ("API_KEY":<key>)  [legacy], or
--   * `intervals_oauth_access_token` → Bearer <token>               [OAuth].
-- The athlete id is shared across both schemes: the OAuth token-exchange
-- response returns `athlete.id`, which the callback stores into the SAME
-- `intervals_athlete_id` column the API-key path already uses — so every
-- `…/athlete/{id}/…` URL and the per-user sync enumeration keep working
-- unchanged. Bearer is preferred over Basic when both happen to be present.
--
-- `intervals_oauth_expires_at` is epoch-ms; NULL = no known expiry (the
-- documented intervals.icu token response carries no expires_in, i.e. tokens
-- are long-lived — the column + refresh_token exist so we can honour an
-- expiry/refresh if the live response turns out to include them).
--
-- Additive + idempotent under D1's applyD1Migrations (new file runs once;
-- ADD COLUMN is safe on the guaranteed-absent columns, CREATE TABLE/INDEX
-- are IF NOT EXISTS).

ALTER TABLE users ADD COLUMN intervals_oauth_access_token TEXT;
ALTER TABLE users ADD COLUMN intervals_oauth_refresh_token TEXT;
ALTER TABLE users ADD COLUMN intervals_oauth_expires_at INTEGER;

-- Short-lived CSRF/link state for the authorize → callback round-trip.
-- iOS hits POST /auth/intervals/start (app-JWT authenticated) which mints a
-- `state` mapped to the caller's user_id; the PUBLIC /auth/intervals/callback
-- looks the state up to attribute intervals.icu's returned `code` to the
-- right user, then deletes it (single-use). Stale rows are swept lazily on
-- lookup (expires_at) — no cron needed.
CREATE TABLE IF NOT EXISTS intervals_oauth_states (
  state      TEXT PRIMARY KEY,
  user_id    TEXT NOT NULL,
  created_at INTEGER NOT NULL,
  expires_at INTEGER NOT NULL
);

CREATE INDEX IF NOT EXISTS idx_intervals_oauth_states_user
  ON intervals_oauth_states(user_id);
