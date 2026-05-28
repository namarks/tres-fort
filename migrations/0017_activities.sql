-- M3: Generic activities log — the "everything else" bucket alongside
-- strength sessions (set_logs) and intervals.icu rides (external_activities).
--
-- This is the APPEND-ONLY LOG class (same as set_logs / notes / sessions):
--   * `id` is the CLIENT-generated UUID and is the idempotency key. iOS
--     outbox safe-retries land on ON CONFLICT(id) DO NOTHING. MCP writes
--     mint the id server-side (Claude doesn't retry like the iOS outbox).
--   * Rows are SOFT-deleted (deleted_at), never hard-deleted — preserve
--     history per project convention.
--   * Writes do NOT bump plans.version (this is not the versioned tree).
--
-- Why a new table instead of overloading external_activities (0015): that
-- table is a SERVER-OWNED RECONCILED CACHE of intervals.icu actuals with a
-- frozen wire contract (per-column power/HR/distance, intervals-specific
-- ids, synced_at watermark). `activities` is user-authored free-form
-- logging — completely different consistency class, schema, and
-- ownership. Keeping them separate preserves the 0015 frozen contract
-- and keeps the iOS decoders simple.
--
-- Idempotent on re-apply (CREATE TABLE/INDEX IF NOT EXISTS), matching the
-- pattern used by 0005/0006/0008/0015 — the vitest D1 path re-applies
-- migrations per suite and must be a safe no-op.

CREATE TABLE IF NOT EXISTS activities (
  id               TEXT PRIMARY KEY,        -- client-generated UUID = idempotency key
  user_id          TEXT NOT NULL REFERENCES users(id),
  date             TEXT NOT NULL,           -- 'YYYY-MM-DD' device-local (no UTC math)
  type             TEXT NOT NULL,           -- lower-case freeform: 'pilates'|'cardio'|'yoga'|'walk'|'other'|...
  title            TEXT,                    -- e.g. "Reformer class at Studio MDR"
  duration_minutes INTEGER,
  notes            TEXT,
  logged_at        INTEGER NOT NULL,        -- epoch ms (also the delta-sync cursor)
  source           TEXT NOT NULL,           -- 'ios'|'mcp'
  deleted_at       INTEGER                  -- soft delete (never hard-delete logged data)
);

CREATE INDEX IF NOT EXISTS ix_activities_user_date ON activities(user_id, date);
