-- Migration 0069: laps of a planned run recorded in the app
-- (docs/plans/planned-runs P9).
--
-- A run recorded from a planned slot moves through its steps (warm-up,
-- each interval and recovery, cool-down). The recorder now keeps where each
-- step started and ended and sends the steps as laps with the recording:
-- each lap's moving time, distance and heart rate, with the step it ran and
-- that step's target. Anything run after the plan finished (a walk to cool
-- down) is its own last lap, so the run's average never hides how the
-- intervals went. One row per recording, as canonical JSON text in the
-- shape of src/runLaps.ts.
--
-- Private to its member like activity_routes: only
-- GET /api/activities/:id/route reads it, and group views, the coach and
-- intervals.icu sync never do. The account export includes it; deleting the
-- run or the account removes it.
CREATE TABLE IF NOT EXISTS activity_laps (
  activity_id TEXT PRIMARY KEY REFERENCES external_activities(id) ON DELETE CASCADE,
  user_id TEXT NOT NULL REFERENCES users(id) ON DELETE CASCADE,
  lap_count INTEGER NOT NULL CHECK (lap_count > 0),
  laps TEXT NOT NULL,
  created_at INTEGER NOT NULL
);

CREATE INDEX IF NOT EXISTS idx_activity_laps_user ON activity_laps (user_id);
