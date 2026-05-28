-- tres-fort initial schema. See docs/DESIGN.md §3.
-- Plan-tree tables (plans/day_templates/template_exercises) are the versioned
-- document; set_logs/notes/sessions are the append-only event log.

CREATE TABLE users (
  id            TEXT PRIMARY KEY,
  apple_sub     TEXT UNIQUE NOT NULL,
  email         TEXT,
  display_name  TEXT,
  created_at    INTEGER NOT NULL
);

CREATE TABLE exercises (
  id                TEXT PRIMARY KEY,
  name              TEXT NOT NULL,
  primary_muscle    TEXT NOT NULL,
  secondary_muscles TEXT,
  modality          TEXT,
  unit              TEXT NOT NULL DEFAULT 'lb',
  aliases           TEXT,
  created_at        INTEGER NOT NULL
);

CREATE TABLE plans (
  id          TEXT PRIMARY KEY,
  user_id     TEXT NOT NULL REFERENCES users(id),
  name        TEXT NOT NULL,
  status      TEXT NOT NULL DEFAULT 'active',
  version     INTEGER NOT NULL DEFAULT 1,
  meta        TEXT,
  created_at  INTEGER NOT NULL,
  updated_at  INTEGER NOT NULL
);

CREATE TABLE day_templates (
  id          TEXT PRIMARY KEY,
  plan_id     TEXT NOT NULL REFERENCES plans(id),
  name        TEXT NOT NULL,
  day_label   TEXT,
  order_index INTEGER NOT NULL,
  notes       TEXT,
  created_at  INTEGER NOT NULL,
  updated_at  INTEGER NOT NULL
);

CREATE TABLE template_exercises (
  id               TEXT PRIMARY KEY,
  day_template_id  TEXT NOT NULL REFERENCES day_templates(id),
  exercise_id      TEXT NOT NULL REFERENCES exercises(id),
  order_index      INTEGER NOT NULL,
  target_sets      INTEGER NOT NULL,
  target_reps      INTEGER NOT NULL,
  target_reps_max  INTEGER,
  target_rpe       REAL,
  rest_seconds     INTEGER NOT NULL DEFAULT 120,
  target_weight    REAL,
  progression      TEXT,
  cues             TEXT,
  created_at       INTEGER NOT NULL,
  updated_at       INTEGER NOT NULL
);

CREATE TABLE sessions (
  id                TEXT PRIMARY KEY,
  user_id           TEXT NOT NULL REFERENCES users(id),
  plan_id           TEXT NOT NULL REFERENCES plans(id),
  day_template_id   TEXT REFERENCES day_templates(id),
  date              TEXT NOT NULL,
  status            TEXT NOT NULL DEFAULT 'planned',
  started_at        INTEGER,
  completed_at      INTEGER,
  perceived_fatigue INTEGER,
  notes             TEXT,
  created_at        INTEGER NOT NULL,
  updated_at        INTEGER NOT NULL
);

CREATE TABLE set_logs (
  id                   TEXT PRIMARY KEY,
  session_id           TEXT NOT NULL REFERENCES sessions(id),
  exercise_id          TEXT NOT NULL REFERENCES exercises(id),
  template_exercise_id TEXT REFERENCES template_exercises(id),
  set_index            INTEGER NOT NULL,
  weight               REAL NOT NULL,
  reps                 INTEGER NOT NULL,
  rpe                  REAL,
  is_warmup            INTEGER NOT NULL DEFAULT 0,
  notes                TEXT,
  logged_at            INTEGER NOT NULL,
  source               TEXT NOT NULL,
  deleted_at           INTEGER
);

CREATE TABLE notes (
  id         TEXT PRIMARY KEY,
  user_id    TEXT NOT NULL REFERENCES users(id),
  scope      TEXT NOT NULL,
  ref_id     TEXT,
  author     TEXT NOT NULL,
  body       TEXT NOT NULL,
  created_at INTEGER NOT NULL
);

CREATE TABLE audit_log (
  id         TEXT PRIMARY KEY,
  user_id    TEXT NOT NULL,
  actor      TEXT NOT NULL,
  tool       TEXT NOT NULL,
  args       TEXT,
  result     TEXT,
  created_at INTEGER NOT NULL
);

CREATE INDEX ix_sets_session ON set_logs(session_id);
CREATE INDEX ix_sets_ex_time ON set_logs(exercise_id, logged_at);
CREATE INDEX ix_sessions_user_date ON sessions(user_id, date);
CREATE INDEX ix_te_day ON template_exercises(day_template_id, order_index);
CREATE UNIQUE INDEX ux_one_active_plan ON plans(user_id) WHERE status = 'active';
