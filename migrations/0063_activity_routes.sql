-- GPS routes of runs recorded in the app (docs/plans/run-recorder P5). On
-- 2026-11-02 the owner chose to keep recorded runs in Tres Fort itself, route
-- included, instead of passing the file through to intervals.icu only. The
-- run is an external_activities row with source = 'recording'. Its route is
-- kept here, one row per recording, in the compact encoding of
-- src/activityRoute.ts (delta-coded times, micro-degree coordinates and
-- decimeter altitudes, as JSON text).
--
-- A route is private to its member: only GET /api/activities/:id/route reads
-- it, and group views, the coach and intervals.icu sync never do. Deleting
-- the recording or the account removes the route.
CREATE TABLE IF NOT EXISTS activity_routes (
  activity_id TEXT PRIMARY KEY REFERENCES external_activities(id) ON DELETE CASCADE,
  user_id TEXT NOT NULL REFERENCES users(id) ON DELETE CASCADE,
  point_count INTEGER NOT NULL CHECK (point_count > 0),
  route TEXT NOT NULL,
  created_at INTEGER NOT NULL
);

CREATE INDEX IF NOT EXISTS idx_activity_routes_user ON activity_routes (user_id);
