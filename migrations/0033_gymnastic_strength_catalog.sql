-- 0033_gymnastic_strength_catalog.sql
--
-- Add the gymnastic-strength staples needed by bodyweight-first plans.
-- Static positions are timed in seconds; dynamic movements use the existing
-- bodyweight convention (weight is optional added load, reps are repetitions).
--
-- STRICTLY ADDITIVE + IDEMPOTENT. Existing ids and aliases remain untouched;
-- INSERT OR IGNORE makes a migration replay a no-op.

INSERT OR IGNORE INTO exercises
  (id, name, primary_muscle, secondary_muscles, modality, unit,
   aliases, created_at, laterality, load_mode, demo_slug)
VALUES
  ('ex_ring_dip', 'Ring Dip', 'triceps', '["chest","shoulders","core"]', 'bw', 'lb',
   '["ring dips", "gymnastic ring dip", "gymnastic ring dips"]', 0, 'bilateral', 'total', NULL),
  ('ex_ring_row', 'Ring Row', 'back', '["biceps","rear delts","core"]', 'bw', 'lb',
   '["ring rows", "gymnastic ring row", "bodyweight ring row"]', 0, 'bilateral', 'total', NULL),
  ('ex_ring_pushup', 'Ring Push-Up', 'chest', '["triceps","shoulders","core"]', 'bw', 'lb',
   '["ring push-up", "ring pushup", "ring push up", "ring pushups"]', 0, 'bilateral', 'total', NULL),
  ('ex_ring_support_hold', 'Ring Support Hold', 'triceps', '["shoulders","chest","core"]', 'timed', 'sec',
   '["ring support", "rings support hold", "support hold on rings"]', 0, 'bilateral', 'total', NULL),
  ('ex_bar_muscle_up', 'Bar Muscle-Up', 'back', '["biceps","triceps","chest","core"]', 'bw', 'lb',
   '["bar muscle-up", "bar muscle up", "bar muscleup", "muscle up on bar"]', 0, 'bilateral', 'total', NULL),
  ('ex_ring_muscle_up', 'Ring Muscle-Up', 'back', '["biceps","triceps","chest","core"]', 'bw', 'lb',
   '["ring muscle-up", "ring muscle up", "ring muscleup", "muscle up on rings"]', 0, 'bilateral', 'total', NULL),
  ('ex_l_sit', 'L-Sit', 'core', '["hip flexors","triceps","shoulders"]', 'timed', 'sec',
   '["l-sit", "l sit", "lsit", "l-sit hold"]', 0, 'bilateral', 'total', NULL),
  ('ex_tuck_front_lever', 'Tuck Front Lever', 'back', '["core","shoulders"]', 'timed', 'sec',
   '["tuck front lever", "tucked front lever", "front lever tuck"]', 0, 'bilateral', 'total', NULL),
  ('ex_front_lever', 'Front Lever', 'back', '["core","shoulders"]', 'timed', 'sec',
   '["front lever", "full front lever", "front lever hold"]', 0, 'bilateral', 'total', NULL),
  ('ex_back_lever', 'Back Lever', 'shoulders', '["back","chest","core"]', 'timed', 'sec',
   '["back lever", "full back lever", "back lever hold"]', 0, 'bilateral', 'total', NULL),
  ('ex_tuck_planche', 'Tuck Planche', 'shoulders', '["chest","triceps","core"]', 'timed', 'sec',
   '["tuck planche", "tucked planche", "planche tuck"]', 0, 'bilateral', 'total', NULL),
  ('ex_planche_lean', 'Planche Lean', 'shoulders', '["chest","triceps","core"]', 'timed', 'sec',
   '["planche lean", "planche leans", "planche lean hold"]', 0, 'bilateral', 'total', NULL),
  ('ex_handstand_hold', 'Handstand Hold', 'shoulders', '["triceps","core"]', 'timed', 'sec',
   '["handstand hold", "handstand", "freestanding handstand"]', 0, 'bilateral', 'total', NULL),
  ('ex_wall_walk', 'Wall Walk', 'shoulders', '["chest","triceps","core"]', 'bw', 'lb',
   '["wall walk", "wall walks", "handstand wall walk"]', 0, 'bilateral', 'total', NULL),
  ('ex_crow_pose', 'Crow Pose', 'shoulders', '["triceps","core"]', 'timed', 'sec',
   '["crow pose", "crow hold", "frog stand"]', 0, 'bilateral', 'total', NULL),
  ('ex_skin_the_cat', 'Skin the Cat', 'shoulders', '["back","chest","core"]', 'bw', 'lb',
   '["skin the cat", "skin-the-cat", "skin the cats"]', 0, 'bilateral', 'total', NULL),
  ('ex_dragon_flag', 'Dragon Flag', 'core', '["hip flexors","back"]', 'bw', 'lb',
   '["dragon flag", "dragon flags"]', 0, 'bilateral', 'total', NULL),
  ('ex_typewriter_pullup', 'Typewriter Pull-Up', 'back', '["biceps","forearms","core"]', 'bw', 'lb',
   '["typewriter pull-up", "typewriter pullup", "typewriter pull up", "typewriter pull-ups"]', 0, 'bilateral', 'total', NULL),
  ('ex_eccentric_pullup', 'Eccentric Pull-Up', 'back', '["biceps","forearms"]', 'bw', 'lb',
   '["eccentric pull-up", "eccentric pullup", "negative pull-up", "negative pullup"]', 0, 'bilateral', 'total', NULL),
  ('ex_back_extension', 'Back Extension', 'back', '["glutes","hamstrings"]', 'bw', 'lb',
   '["back extension", "back extensions", "hyperextension", "hyperextensions"]', 0, 'bilateral', 'total', NULL),
  ('ex_reverse_hyper', 'Reverse Hyperextension', 'glutes', '["hamstrings","back"]', 'bw', 'lb',
   '["reverse hyper", "reverse hypers", "reverse hyperextension"]', 0, 'bilateral', 'total', NULL),
  ('ex_gymnastic_bridge', 'Gymnastic Bridge', 'back', '["glutes","shoulders","core"]', 'timed', 'sec',
   '["gymnastic bridge", "bridge hold", "full bridge hold"]', 0, 'bilateral', 'total', NULL);
