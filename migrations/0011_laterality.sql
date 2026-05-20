-- Laterality on exercises: encodes the per-side convention so volume math
-- and the LLM stop guessing "is the 45x8 in this Bulgarian split squat per
-- leg or total?". Convention going forward (matches Strong/Hevy):
--   weight = per implement (DB, KB, etc.)
--   reps   = per side
-- For unilateral exercises, total reps = reps * 2 and tonnage = weight * reps * 2.
-- Bilateral is the safe default for the existing catalog.

ALTER TABLE exercises ADD COLUMN laterality TEXT NOT NULL DEFAULT 'bilateral';

-- Tag unilateral movements in the seeded catalog. Each is an exercise that
-- is performed one side at a time and almost always logged per-side by
-- lifters (DB Bulgarian split squat, lunges, single-leg/single-arm work).
UPDATE exercises SET laterality = 'unilateral' WHERE id IN (
  'ex_bb_lunge',
  'ex_db_lunge',
  'ex_bw_lunge',
  'ex_bb_walking_lunge',
  'ex_db_reverse_lunge',
  'ex_db_split_squat',
  'ex_db_step_up',
  'ex_bb_step_up',
  'ex_sl_glute_bridge',
  'ex_one_arm_db_row'
);
