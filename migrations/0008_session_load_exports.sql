-- One-way lifting-load EXPORT to intervals.icu (Option C, milestone s/t/u).
--
-- `session_load_exports` is its OWN consistency class: a server-owned
-- export ledger for the best-effort, decoupled push of a completed
-- lifting session's sRPE training load into intervals.icu. It is NOT the
-- versioned plan tree and NOT the append-only client-UUID log:
--   * an export MUST NEVER bump plans.version
--   * an export MUST NEVER alter sessions / set_logs / the plan tree
--   * an intervals.icu failure MUST NEVER fail/block/throw into
--     log_workout_complete or set logging (that path is sacred).
--
-- Idempotency: PRIMARY KEY is session_id. Re-completing / re-exporting a
-- session UPSERTs the SAME row. If the recomputed sRPE load CHANGED (e.g.
-- the user edited perceived_fatigue / sets / RPE and re-ran completion),
-- the export PUT-updates the SAME intervals.icu activity (via the stored
-- intervals_ref) in place — never a duplicate. If the load is UNCHANGED
-- the re-export is a true no-op (no intervals.icu call at all).
--
-- FROZEN CONTRACT:
--   session_id    TEXT PK   -- sessions.id this export tracks
--   intervals_ref TEXT      -- intervals.icu event/activity id (nullable
--                           --  until a push first succeeds)
--   load          INTEGER   -- last computed sRPE load (icu_training_load)
--   status        TEXT      -- 'ok' | 'pending' | 'skipped' | 'disabled'
--   attempts      INTEGER   -- push attempts so far (cron retry bumps it)
--   updated_at    INTEGER   -- epoch-ms
--
-- Idempotent like 0005/0006: CREATE TABLE/INDEX IF NOT EXISTS, additive,
-- applies cleanly on top of 0001-0007 and is a safe no-op on re-apply
-- (the vitest D1 path applies it too).

CREATE TABLE IF NOT EXISTS session_load_exports (
  session_id    TEXT PRIMARY KEY,
  intervals_ref TEXT,
  load          INTEGER,
  status        TEXT NOT NULL,
  attempts      INTEGER NOT NULL DEFAULT 0,
  updated_at    INTEGER NOT NULL
);

CREATE INDEX IF NOT EXISTS ix_session_load_exports_status
  ON session_load_exports(status);
