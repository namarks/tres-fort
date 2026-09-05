-- P2: make both intervals-cache delta reads seek by member and true change
-- cursor. P2 makes synced_at advance only on a real row change; these indexes
-- make an empty incremental poll constant-cost instead of a lifetime scan.
--
-- Index-only and additive: no table rebuild, application-data backfill, or
-- application-visible value change. CREATE INDEX does build entries for every
-- existing row, so applying this migration has a one-time set of D1 index
-- writes. Each later real cache-row mutation maintains one additional secondary
-- index; a quiet no-op reconcile still writes nothing.

CREATE INDEX IF NOT EXISTS ix_ext_events_user_synced
  ON external_events(user_id, synced_at);

CREATE INDEX IF NOT EXISTS ix_ext_activities_user_synced
  ON external_activities(user_id, synced_at);
