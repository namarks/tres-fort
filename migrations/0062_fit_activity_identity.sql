-- One stored copy of each workout imported from a .fit file
-- (docs/plans/endurance-training-load P4). Two uploads of the same workout
-- under different client ids, even at the same moment from two devices,
-- land on one row: the member, kind and start instant identify it. A copy
-- the member deleted leaves the index so the workout can be imported again;
-- one hidden behind another source's copy stays in it.
CREATE UNIQUE INDEX IF NOT EXISTS external_activities_fit_identity
  ON external_activities (user_id, kind, start_date_utc_ms)
  WHERE source = 'fit' AND (deleted_at IS NULL OR duplicate_of IS NOT NULL);
