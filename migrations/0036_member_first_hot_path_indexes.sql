-- P3: make the remaining per-member hot reads seek by member first.
--
-- The exercise/time index is replaced rather than duplicated: every current
-- exercise-history read is tenant-scoped through set_logs.user_id, which was
-- backfilled and made mandatory in migration 0034. The audit and OAuth indexes
-- support the two per-member Claude-connection lookups in GET /api/me.
--
-- Index-only: no table rebuild or application-visible value change. Creating
-- these indexes writes one entry per existing row. Each later set mutation
-- maintains one additional set_logs index net (two added since P0, one removed),
-- and each audit insert maintains one additional audit_log index.

DROP INDEX IF EXISTS ix_sets_ex_time;

CREATE INDEX ix_sets_user_ex_time
  ON set_logs(user_id, exercise_id, logged_at);

CREATE INDEX ix_audit_user_actor_created
  ON audit_log(user_id, actor, created_at);

CREATE INDEX ix_oauth_tokens_user
  ON oauth_tokens(user_id);
