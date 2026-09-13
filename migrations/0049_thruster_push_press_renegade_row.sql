-- 0049_thruster_push_press_renegade_row.sql
--
-- Four loaded conditioning staples the catalog could not express: the
-- thruster (barbell and dumbbell), the dumbbell push press and the renegade
-- row. Requested by the owner with the movement standards quoted below; the
-- catalog has no description column, so those standards live here as the
-- rationale for each row's muscle attribution, laterality and load mode.
-- Coaches apply per-slot `cues` when programming the movement.
--
-- Conventions (see 0011 / 0014 / 0021):
--   - laterality 'unilateral' = reps are logged per side (renegade row rows
--     one arm at a time); the rollups double the reps.
--   - load_mode 'per_hand' = two dumbbells MOVE on every rep, the number is
--     the weight of ONE dumbbell and the rollups double the load (dumbbell
--     thruster, dumbbell push press). The barbell thruster stays 'total'.
--   - The renegade row is 'unilateral' + 'total', the one-arm convention
--     (0014: "a one-arm movement (the number is just that dumbbell)", like
--     ex_one_arm_db_row). Only the rowed dumbbell moves on a rep; the other
--     is a stationary support, so per_hand would double the load on top of
--     the per-side rep doubling and report 25 lb x 10/side as 1,000 lb
--     instead of 500 lb.
--   - demo_slug stays NULL: free-exercise-db only carries kettlebell or
--     barbell push-press variants (Kettlebell_Thruster,
--     Double_Kettlebell_Push_Press, Alternating_Renegade_Row) and 0021 does
--     not pair a row to a different implement's demo. The demo sheet renders
--     the cue card instead.
--
-- Thruster (barbell) — the base movement the dumbbell version refers to; it
-- was not in the catalog. Bar racked in the front-squat position, squat to
-- depth, stand and press the bar overhead in one continuous drive, lock out,
-- return to the rack. Quads carry the load, so it rolls up as quad volume.
--
-- Dumbbell thruster — "Same movement with a dumbbell in each hand racked at
-- the shoulders. Squat, stand, press both overhead as you come out of the
-- hole. Elbows stay forward at the bottom so the DBs don't drift back."
--
-- Renegade row — "Get into a plank with your hands on two dumbbells. Row one
-- DB to your ribs while the other arm stays locked and your hips stay square
-- — the point is resisting rotation, not the row itself. Set it down, row the
-- other side. Wider feet make it easier." Anti-rotation is the point, so the
-- primary muscle is core, with the row as secondary work.
--
-- Dumbbell push press — "DBs racked at the shoulders, standing. Dip a few
-- inches by bending the knees, then drive up hard with the legs and let that
-- momentum carry the DBs overhead. Lock out, lower under control, reset. The
-- leg drive lets you move more weight or more reps than a strict press."
--
-- Aliases never take an existing phrase: "push press" stays on the barbell
-- ex_push_press, "dumbbell press" / "db press" stay on ex_db_press, and the
-- bare "row" / "db row" keep their original rows.
--
-- STRICTLY ADDITIVE + IDEMPOTENT. INSERT OR IGNORE keeps a replay a no-op;
-- created_at = 0 marks a timeless seed like every earlier catalog row.

INSERT OR IGNORE INTO exercises
  (id, name, primary_muscle, secondary_muscles, modality, unit,
   aliases, created_at, laterality, load_mode, demo_slug)
VALUES
  ('ex_thruster', 'Thruster', 'quads', '["shoulders","glutes","triceps","core"]', 'barbell', 'lb',
   '["thruster", "thrusters", "barbell thruster", "bb thruster", "front squat to press"]', 0, 'bilateral', 'total', NULL),
  ('ex_db_thruster', 'Dumbbell Thruster', 'quads', '["shoulders","glutes","triceps","core"]', 'dumbbell', 'lb',
   '["dumbbell thruster", "dumbbell thrusters", "db thruster", "db thrusters"]', 0, 'bilateral', 'per_hand', NULL),
  ('ex_renegade_row', 'Renegade Row', 'core', '["back","biceps","shoulders","triceps"]', 'dumbbell', 'lb',
   '["renegade row", "renegade rows", "plank row", "plank rows", "dumbbell renegade row", "db renegade row"]', 0, 'unilateral', 'total', NULL),
  ('ex_db_push_press', 'Dumbbell Push Press', 'shoulders', '["quads","triceps","glutes"]', 'dumbbell', 'lb',
   '["dumbbell push press", "dumbbell push presses", "db push press", "db push presses"]', 0, 'bilateral', 'per_hand', NULL);
