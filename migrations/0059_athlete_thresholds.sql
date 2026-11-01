-- Athlete thresholds for training-load computation
-- (docs/plans/endurance-training-load). Append-only history: each row says
-- "from this civil date on, this sport's metric is this value". The client
-- UUID is the idempotency key; corrections soft-delete (deleted_at) and add a
-- new row. Private to the member: never part of group sharing.
CREATE TABLE athlete_thresholds (
  id TEXT PRIMARY KEY,
  user_id TEXT NOT NULL REFERENCES users(id) ON DELETE CASCADE,
  sport TEXT NOT NULL CHECK (sport IN ('ride', 'run')),
  metric TEXT NOT NULL CHECK (metric IN ('ftp_w', 'threshold_hr', 'threshold_pace_s_per_km')),
  value REAL NOT NULL CHECK (value > 0),
  effective_date TEXT NOT NULL CHECK (effective_date GLOB '[0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9]'),
  source TEXT NOT NULL CHECK (source IN ('member', 'coach', 'intervals')),
  created_at INTEGER NOT NULL,
  deleted_at INTEGER,
  CHECK (
    (sport = 'ride' AND metric IN ('ftp_w', 'threshold_hr'))
    OR (sport = 'run' AND metric IN ('threshold_hr', 'threshold_pace_s_per_km'))
  )
);

CREATE INDEX idx_athlete_thresholds_user
  ON athlete_thresholds (user_id, sport, metric, effective_date);
