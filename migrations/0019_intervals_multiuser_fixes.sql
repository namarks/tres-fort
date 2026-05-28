-- 0019_intervals_multiuser_fixes.sql
--
-- Three related multi-user fixes to the intervals.icu reconciled cache
-- (external_events, external_activities). All address Codex review
-- findings on PR #36.
--
-- 1) Re-key existing rows so the surrogate PK (`id`) includes user_id.
--    The table is keyed by `id TEXT PRIMARY KEY` with the deterministic
--    pattern "intervals:{external_id}" / "intervals:activity:{external_id}".
--    intervals.icu activity ids are scoped per-athlete, so two athletes
--    can return the same numeric external_id — under the single-user
--    schema that yields a PK collision and the ON CONFLICT(id) DO UPDATE
--    silently rewrites user_A's row with user_B's payload (without
--    changing user_id). Re-keying to "intervals:{user_id}:{external_id}"
--    and "intervals:activity:{user_id}:{external_id}" makes the PK
--    per-user and removes the collision class.
--
--    syncExternalEvents / syncExternalActivities are being updated in the
--    same change to emit the new format. After this migration, both the
--    backfilled rows and any newly-synced rows agree on the new id; no
--    duplicates.
--
--    Detection of "old format" is precise: id literally equals
--    "intervals:" || external_id (or "intervals:activity:" || ...). New
--    format rows won't match. Idempotent on re-apply.
--
-- 2) Add `start_date_local_ms` to both tables and backfill from the civil
--    `date` field (midnight UTC). The group feed currently uses
--    `synced_at` as the ride ordering proxy, but `synced_at` rewrites on
--    EVERY cron tick — so every recent ride bubbles to the top of the
--    feed after each sync and pagination becomes degenerate.
--    `start_date_local_ms` is the activity's actual start time; sync
--    populates it from intervals.icu's `start_date_local` going forward.
--    Backfilled rows get midnight-of-civil-date (best-available without
--    a re-sync) so feed ordering is stable until the next cron tick
--    fills in the precise timestamp.
--
-- Additive + idempotent under D1's applyD1Migrations (only-new-files
-- semantics): the ADD COLUMNs run exactly once, and the UPDATEs are
-- self-bounded (only match rows in the old format / NULL ms).

-- (1) Re-key existing rows. Order matters: external_events first (the
-- pattern is more general), then external_activities (the more-specific
-- "intervals:activity:" prefix). Don't worry about doing them out of
-- order — the literal-equality WHERE clause prevents any rebuild
-- ambiguity.
UPDATE external_events
   SET id = 'intervals:' || user_id || ':' || external_id
 WHERE id = 'intervals:' || external_id;

UPDATE external_activities
   SET id = 'intervals:activity:' || user_id || ':' || external_id
 WHERE id = 'intervals:activity:' || external_id;

-- (2) New column + backfill from civil date.
ALTER TABLE external_events ADD COLUMN start_date_local_ms INTEGER;
ALTER TABLE external_activities ADD COLUMN start_date_local_ms INTEGER;

-- Backfill: strftime returns the epoch SECONDS for the given civil
-- datetime treated as UTC. Multiplying by 1000 gives epoch-ms. The CAST
-- is defensive (strftime returns TEXT). For rows whose date is somehow
-- null (shouldn't happen per the table contract, but be safe), leave the
-- new column null.
UPDATE external_events
   SET start_date_local_ms = CAST(strftime('%s', date || ' 00:00:00') AS INTEGER) * 1000
 WHERE start_date_local_ms IS NULL AND date IS NOT NULL;

UPDATE external_activities
   SET start_date_local_ms = CAST(strftime('%s', date || ' 00:00:00') AS INTEGER) * 1000
 WHERE start_date_local_ms IS NULL AND date IS NOT NULL;
