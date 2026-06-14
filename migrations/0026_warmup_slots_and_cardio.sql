-- 0026_warmup_slots_and_cardio.sql
--
-- Two gaps a real warm-up surfaced (Nick's post-workout review):
--
-- 1. A plan slot could not be marked a WARM-UP. is_warmup existed only on
--    set_logs (the *logged* set), so a coach/app could not PRESCRIBE "5 min
--    erg, then your working sets" — warm-ups had to be talked into existence
--    with Claude per session. This adds the *planned* counterpart so a slot
--    is durably a warm-up: it renders in a warm-up section, its logged sets
--    default to is_warmup=1, and it stays out of working-set rollups / session
--    RPE (which already filter is_warmup) exactly like an ad-hoc warm-up set.
--    NOT NULL DEFAULT 0 — every existing slot stays a working slot.
--
-- 2. There was no ergometer / cardio movement in the catalog at all (the only
--    "cardio" string in the repo was a comment). You literally could not add
--    an erg warm-up. These rows fill that: duration-based machines logged by
--    time. modality 'cardio' (new, free-text — downstream handles unknown
--    modalities generically), unit 'min'. Clients treat a cardio slot as a
--    timed/duration slot (count down target_duration_s, log duration). All
--    post-0011 columns set inline (laterality/load_mode/demo_slug) like 0021.
--    created_at = 0 (timeless seed); INSERT OR IGNORE keeps re-runs a no-op.

ALTER TABLE template_exercises ADD COLUMN is_warmup INTEGER NOT NULL DEFAULT 0;

INSERT OR IGNORE INTO exercises
  (id, name, primary_muscle, secondary_muscles, modality, unit,
   aliases, created_at, laterality, load_mode, demo_slug)
VALUES
  ('ex_row_erg',        'Rowing Erg',      'full body', '["back","quads","hamstrings","core"]', 'cardio', 'min',
   '["rowing erg","row erg","erg","rower","concept2","concept 2","c2 row","indoor rower","rowing machine"]', 0, 'bilateral', 'total', NULL),
  ('ex_bike_erg',       'Bike Erg',        'full body', '["quads","hamstrings"]',               'cardio', 'min',
   '["bike erg","bikeerg","echo bike","assault bike","air bike","airdyne","fan bike"]', 0, 'bilateral', 'total', NULL),
  ('ex_ski_erg',        'Ski Erg',         'full body', '["back","triceps","core"]',            'cardio', 'min',
   '["ski erg","skierg","ski"]', 0, 'bilateral', 'total', NULL),
  ('ex_stationary_bike','Stationary Bike', 'quads',     '["hamstrings","glutes"]',              'cardio', 'min',
   '["stationary bike","exercise bike","spin bike","spin","cycling","indoor bike"]', 0, 'bilateral', 'total', NULL),
  ('ex_treadmill',      'Treadmill',       'full body', '["quads","hamstrings","calves"]',      'cardio', 'min',
   '["treadmill","run","jog","incline walk","treadmill walk"]', 0, 'bilateral', 'total', NULL),
  ('ex_elliptical',     'Elliptical',      'full body', '["quads","glutes"]',                   'cardio', 'min',
   '["elliptical","cross trainer"]', 0, 'bilateral', 'total', NULL),
  ('ex_stairmaster',    'StairMaster',     'quads',     '["glutes","calves"]',                  'cardio', 'min',
   '["stairmaster","stair master","stair climber","stepmill","stairs"]', 0, 'bilateral', 'total', NULL),
  ('ex_jump_rope',      'Jump Rope',       'calves',    '["full body"]',                        'cardio', 'min',
   '["jump rope","jumprope","skipping","skip rope"]', 0, 'bilateral', 'total', NULL);
