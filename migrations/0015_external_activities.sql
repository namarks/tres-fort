-- Completed endurance activities pulled from intervals.icu (rides/runs/etc).
--
-- `external_activities` is its OWN consistency class, PARALLEL to (and
-- distinct from) `external_events` (migration 0006):
--   * external_events       = PLANNED, FUTURE endurance commitments
--                             (the /events calendar) — drives ride/lift
--                             conflict awareness.
--   * external_activities   = COMPLETED, PAST recorded activities
--                             (the /activities feed) — the actuals the
--                             intervals.icu app shows: duration, power, HR,
--                             distance, TSS. Surfaced read-only in the lift
--                             calendar as "workouts completed".
-- Keeping them in separate tables preserves the frozen external_events
-- contract and keeps completed (past) activities out of the planned
-- conflict-detection path entirely.
--
-- Like external_events this is a SERVER-OWNED RECONCILED CACHE: NOT the
-- versioned plan tree and NOT the append-only client-UUID log. A sync MUST
-- NOT bump plans.version. Rows are soft-deleted (deleted_at), never hard
-- deleted (an activity removed in intervals.icu is tombstoned).
--
-- FROZEN CONTRACT (iOS decodes this verbatim — do not change a column
-- without flagging):
--   id                  TEXT PK = "intervals:activity:{external_id}"
--   user_id             TEXT
--   source              TEXT     -- 'intervals'
--   external_id         TEXT     -- intervals activity id
--   date                TEXT     -- YYYY-MM-DD from start_date_local, VERBATIM
--                                --  (device-local civil date; NO timezone math)
--   kind                TEXT     -- ride|run|swim|other (from intervals `type`)
--   name                TEXT
--   moving_time_sec     INT      -- actual moving time (intervals moving_time)
--   elapsed_time_sec    INT      -- elapsed_time
--   distance_m          REAL     -- meters
--   average_watts       REAL     -- avg power (icu_average_watts || average_watts)
--   weighted_avg_watts  REAL     -- normalized power (icu_weighted_avg_watts)
--   average_hr          REAL     -- bpm (average_heartrate)
--   max_hr              INT      -- bpm (max_heartrate)
--   training_load       INT      -- TSS-like load (icu_training_load)
--   intensity           REAL     -- IF (icu_intensity)
--   calories            INT
--   elevation_gain_m    REAL     -- total_elevation_gain
--   raw                 TEXT     -- source JSON
--   synced_at           INT      -- epoch-ms
--   deleted_at          INT      -- nullable; soft delete
--
-- Idempotent like 0005/0006/0008: CREATE TABLE / CREATE INDEX IF NOT EXISTS,
-- additive, a safe no-op on re-apply (the vitest D1 path applies it too).

CREATE TABLE IF NOT EXISTS external_activities (
  id                  TEXT PRIMARY KEY,
  user_id             TEXT NOT NULL,
  source              TEXT NOT NULL,
  external_id         TEXT NOT NULL,
  date                TEXT NOT NULL,
  kind                TEXT NOT NULL,
  name                TEXT,
  moving_time_sec     INTEGER,
  elapsed_time_sec    INTEGER,
  distance_m          REAL,
  average_watts       REAL,
  weighted_avg_watts  REAL,
  average_hr          REAL,
  max_hr              INTEGER,
  training_load       INTEGER,
  intensity           REAL,
  calories            INTEGER,
  elevation_gain_m    REAL,
  raw                 TEXT,
  synced_at           INTEGER NOT NULL,
  deleted_at          INTEGER
);

CREATE INDEX IF NOT EXISTS ix_ext_activities_user_date
  ON external_activities(user_id, date);
