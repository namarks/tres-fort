-- Migration 0068: heart-rate series of a member's own workouts
-- (docs/plans/run-detail-charts P3).
--
-- On 2026-11-06 the owner chose to keep a compact heart-rate series for runs
-- recorded in the app and for every Apple Health and .fit workout with heart
-- rate, so their charts show heart rate as an intervals.icu activity's do
-- (that one is read from intervals.icu live and never stored). One row per
-- workout, in the encoding of src/heartRateSeries.ts: one reading per whole
-- second of moving time, delta-coded, as JSON text.
--
-- Private to its member like activity_routes: only
-- GET /api/activities/:id/streams reads it, and group views, the coach and
-- intervals.icu sync never do. The account export includes it; deleting the
-- workout or the account removes it.
CREATE TABLE IF NOT EXISTS activity_heart_rates (
  activity_id TEXT PRIMARY KEY REFERENCES external_activities(id) ON DELETE CASCADE,
  user_id TEXT NOT NULL REFERENCES users(id) ON DELETE CASCADE,
  point_count INTEGER NOT NULL CHECK (point_count > 0),
  series TEXT NOT NULL,
  created_at INTEGER NOT NULL
);

CREATE INDEX IF NOT EXISTS idx_activity_heart_rates_user ON activity_heart_rates (user_id);
