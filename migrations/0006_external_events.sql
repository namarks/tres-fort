-- Cycling-awareness in the lift calendar (milestone o).
--
-- `external_events` is its OWN consistency class: a server-owned,
-- reconciled cache of planned endurance events pulled from intervals.icu.
-- It is NOT the versioned plan tree and NOT the append-only client-UUID
-- log. A ride sync MUST NOT bump plans.version. Rows are soft-deleted
-- (deleted_at), never hard-deleted, consistent with set_logs.
--
-- FROZEN CONTRACT (iOS builds against this in parallel — do not change a
-- column without flagging):
--   id                  TEXT PK = "intervals:{external_id}"
--   user_id             TEXT
--   source              TEXT     -- 'intervals'
--   external_id         TEXT     -- intervals event id
--   date                TEXT     -- YYYY-MM-DD from start_date_local, VERBATIM
--                                --  (device-local civil date; NO timezone math)
--   kind                TEXT     -- ride|run|swim|other (from intervals `type`)
--   title               TEXT
--   description         TEXT
--   planned_duration_sec INT
--   training_load       INT
--   intensity           REAL
--   raw                 TEXT     -- source JSON
--   synced_at           INT      -- epoch-ms
--   deleted_at          INT      -- nullable; soft delete
--
-- Idempotent like 0005: CREATE TABLE / CREATE INDEX IF NOT EXISTS, so the
-- migration is a safe no-op on re-apply (vitest D1 path applies it too).

CREATE TABLE IF NOT EXISTS external_events (
  id                   TEXT PRIMARY KEY,
  user_id              TEXT NOT NULL,
  source               TEXT NOT NULL,
  external_id          TEXT NOT NULL,
  date                 TEXT NOT NULL,
  kind                 TEXT NOT NULL,
  title                TEXT,
  description          TEXT,
  planned_duration_sec INTEGER,
  training_load        INTEGER,
  intensity            REAL,
  raw                  TEXT,
  synced_at            INTEGER NOT NULL,
  deleted_at           INTEGER
);

CREATE INDEX IF NOT EXISTS ix_ext_events_user_date
  ON external_events(user_id, date);
