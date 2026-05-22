-- load_mode: how an exercise's weight number should be read & displayed.
--
--   'total'    — one number is the whole load: barbell, machine, a single
--                dumbbell held two-handed (goblet, pullover), or a one-arm
--                movement (the number is just that dumbbell). Display "25 lb".
--   'per_hand' — TWO implements held simultaneously, one in each hand
--                (DB bench/press/curl/fly/lateral raise/lunge…). The number
--                is the weight of ONE dumbbell. Display "25 lb each hand",
--                never the vague doubled total.
--
-- Orthogonal to laterality (per-side reps): e.g. DB Bulgarian split squat is
-- per_hand AND unilateral. Default 'total' is correct for everything except
-- the two-dumbbell lifts tagged below.
ALTER TABLE exercises ADD COLUMN load_mode TEXT NOT NULL DEFAULT 'total';

UPDATE exercises SET load_mode = 'per_hand' WHERE id IN (
  'ex_db_press',
  'ex_db_squat',
  'ex_db_lunge',
  'ex_db_reverse_lunge',
  'ex_db_split_squat',
  'ex_db_step_up',
  'ex_db_rdl',
  'ex_db_calf_raise',
  'ex_incline_db_press',
  'ex_decline_db_press',
  'ex_db_fly',
  'ex_incline_db_fly',
  'ex_db_row_two',
  'ex_db_shrug',
  'ex_db_ohp',
  'ex_seated_db_press',
  'ex_arnold_press',
  'ex_lateral_raise',
  'ex_front_raise',
  'ex_reverse_fly',
  'ex_db_curl',
  'ex_hammer_curl',
  'ex_incline_db_curl'
);
