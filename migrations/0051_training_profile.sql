-- Private, editable onboarding context survives plan replacement. Account
-- deletion cascades; neither table participates in group sharing.
CREATE TABLE training_profiles (
  user_id TEXT PRIMARY KEY REFERENCES users(id) ON DELETE CASCADE,
  document TEXT NOT NULL CHECK (json_valid(document)),
  version INTEGER NOT NULL CHECK (version > 0),
  updated_at INTEGER NOT NULL
);

-- One first-workout acceptance per account. A lost response or app relaunch
-- returns this receipt, even if a coach has since changed the plan.
CREATE TABLE starter_workout_receipts (
  user_id TEXT PRIMARY KEY REFERENCES users(id) ON DELETE CASCADE,
  starter_id TEXT NOT NULL,
  profile_version INTEGER NOT NULL,
  plan_id TEXT NOT NULL,
  starter_workout_id TEXT NOT NULL,
  version INTEGER NOT NULL,
  created_at INTEGER NOT NULL
);
