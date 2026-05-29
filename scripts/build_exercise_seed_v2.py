#!/usr/bin/env python3
"""Generate migrations/0021_seed_exercises_v2.sql.

Net-new catalog rows on top of 0002/0004/0007/0009. Bias is heavy bodyweight /
at-home work (user can do these without a gym) and richer unilateral coverage
(the per-side accounting from 0011 + 0014 already handles the math; we just
need more rows tagged correctly). Every row carries:

  - laterality   'bilateral' | 'unilateral'  (column added by 0011)
  - load_mode    'total' | 'per_hand'         (column added by 0014)
  - demo_slug    free-exercise-db id or NULL  (column added by 0020)

When the upstream free-exercise-db has a matching entry, `demo_slug` rides
the upstream id and iOS loads `{slug}/0.jpg` + `{slug}/1.jpg` (bundled or
R2). When upstream is missing (most modern bodyweight progressions,
post-pandemic at-home staples, Olympic variants), `demo_slug` is NULL and
the iOS demo sheet shows the muscle/cue card without an image.

Strictly additive + idempotent: INSERT OR IGNORE on the UUID PK. The earlier
migrations' rows are NOT restated — this migration only emits net-new ex_*
ids. Re-running is a no-op.

Validation invariants (encoded as `python3 build_exercise_seed_v2.py --check`
exits non-zero on violation):
  - every new id is unique within 0021
  - every new id is absent from 0002/0004/0007/0009
  - every new canonical name is unique catalog-wide (no shadowing)
  - every new alias is owned by exactly one row catalog-wide
  - no new alias equals an existing canonical name in 0002/0004/0007/0009
"""
import json
import sys

# Field positions:
#   (ex_id, name, primary, secondary_json, modality, laterality, load_mode,
#    aliases_list, demo_slug_or_None)
#
# Laterality:
#   unilateral when ONE physical limb performs the work per rep and the
#   lifter logs reps per-side. Backend doubles tonnage + reps for unilateral.
#
# Load mode:
#   per_hand when TWO implements are held simultaneously (one each hand),
#   like a two-DB lunge. The number entered is the weight of one implement.
#   Bodyweight movements ARE 'total' (no implement) even if unilateral —
#   the math is just "no weight × reps × 2 sides = 0", which is correct
#   (volume comes from set count, not tonnage).

NEW_EXERCISES = [
    # ============================================================
    # BODYWEIGHT — LOWER BODY / GLUTES (at-home priority)
    # ============================================================
    ("ex_pistol_squat", "Pistol Squat", "quads", '["glutes","hamstrings","core"]', "bw", "unilateral", "total",
        ["pistol squat", "single leg squat", "pistol"], None),
    ("ex_skater_squat", "Skater Squat", "quads", '["glutes","hamstrings"]', "bw", "unilateral", "total",
        ["skater squat"], None),
    ("ex_shrimp_squat", "Shrimp Squat", "quads", '["glutes","hamstrings"]', "bw", "unilateral", "total",
        ["shrimp squat"], None),
    ("ex_cossack_squat", "Cossack Squat", "quads", '["glutes","hamstrings"]', "bw", "unilateral", "total",
        ["cossack squat", "cossack"], None),
    ("ex_bw_single_leg_rdl", "Bodyweight Single-Leg RDL", "hamstrings", '["glutes","back","core"]', "bw", "unilateral", "total",
        ["bodyweight single-leg rdl", "single leg rdl", "single-leg rdl bw", "single leg deadlift bw"], None),
    ("ex_bw_single_leg_hip_thrust", "Bodyweight Single-Leg Hip Thrust", "glutes", '["hamstrings"]', "bw", "unilateral", "total",
        ["bodyweight single-leg hip thrust", "single leg hip thrust bw", "single-leg hip thrust"], None),
    ("ex_bw_reverse_lunge", "Bodyweight Reverse Lunge", "quads", '["glutes","hamstrings"]', "bw", "unilateral", "total",
        ["bodyweight reverse lunge", "reverse lunge bw"], None),
    ("ex_bw_lateral_lunge", "Bodyweight Lateral Lunge", "quads", '["glutes","hamstrings"]', "bw", "unilateral", "total",
        ["bodyweight lateral lunge", "lateral lunge", "side lunge"], None),
    ("ex_bw_curtsy_lunge", "Bodyweight Curtsy Lunge", "glutes", '["quads","hamstrings"]', "bw", "unilateral", "total",
        ["bodyweight curtsy lunge", "curtsy lunge"], None),
    ("ex_jump_squat", "Jump Squat", "quads", '["glutes","calves"]', "bw", "bilateral", "total",
        ["jump squat", "jumping squat"], "Freehand_Jump_Squat"),
    ("ex_jumping_lunge", "Jumping Lunge", "quads", '["glutes","calves"]', "bw", "unilateral", "total",
        ["jumping lunge", "split jump"], None),
    ("ex_bw_good_morning", "Bodyweight Good Morning", "hamstrings", '["glutes","back"]', "bw", "bilateral", "total",
        ["bodyweight good morning", "bw good morning"], None),
    ("ex_nordic_curl", "Nordic Hamstring Curl", "hamstrings", '["glutes"]', "bw", "bilateral", "total",
        ["nordic curl", "nordic hamstring curl", "nghr"], "Natural_Glute_Ham_Raise"),
    ("ex_clamshell", "Clamshell", "glutes", '[]', "bw", "unilateral", "total",
        ["clamshell", "clam shell", "clams"], None),
    ("ex_fire_hydrant", "Fire Hydrant", "glutes", '["core"]', "bw", "unilateral", "total",
        ["fire hydrant", "fire hydrants"], None),
    ("ex_side_lying_abduction", "Side-Lying Hip Abduction", "glutes", '[]', "bw", "unilateral", "total",
        ["side-lying hip abduction", "side lying hip abduction", "side leg raise"], None),
    ("ex_glute_bridge_march", "Glute Bridge March", "glutes", '["core","hamstrings"]', "bw", "unilateral", "total",
        ["glute bridge march", "marching glute bridge"], None),
    ("ex_bw_calf_raise", "Bodyweight Calf Raise", "calves", '[]', "bw", "bilateral", "total",
        ["bodyweight calf raise", "bw calf raise"], None),
    ("ex_single_leg_calf_raise", "Single-Leg Calf Raise", "calves", '[]', "bw", "unilateral", "total",
        ["single-leg calf raise", "single leg calf raise", "one leg calf raise"], None),
    ("ex_wall_sit_marching", "Marching Wall Sit", "quads", '["core"]', "bw", "unilateral", "total",
        ["marching wall sit"], None),
    # ============================================================
    # BODYWEIGHT — UPPER BODY PUSH
    # ============================================================
    ("ex_archer_pushup", "Archer Push-Up", "chest", '["triceps","shoulders","core"]', "bw", "unilateral", "total",
        ["archer push-up", "archer pushup", "archer push up"], None),
    ("ex_single_arm_pushup", "Single-Arm Push-Up", "chest", '["triceps","shoulders","core"]', "bw", "unilateral", "total",
        ["single-arm push-up", "single arm push-up", "single arm pushup", "one arm pushup"], "Single-Arm_Push-Up"),
    ("ex_diamond_pushup", "Diamond Push-Up", "triceps", '["chest","shoulders"]', "bw", "bilateral", "total",
        ["diamond push-up", "diamond pushup", "diamond push up", "tricep pushup"], "Close-Grip_Push-Up_off_of_a_Dumbbell"),
    ("ex_wide_pushup", "Wide Push-Up", "chest", '["shoulders","triceps"]', "bw", "bilateral", "total",
        ["wide push-up", "wide pushup", "wide push up"], "Push-Up_Wide"),
    ("ex_plyo_pushup", "Plyo Push-Up", "chest", '["triceps","shoulders","core"]', "bw", "bilateral", "total",
        ["plyo push-up", "plyo pushup", "clap pushup", "explosive pushup"], "Plyo_Push-up"),
    ("ex_hindu_pushup", "Hindu Push-Up", "chest", '["shoulders","triceps","back"]', "bw", "bilateral", "total",
        ["hindu push-up", "hindu pushup", "dive bomber"], None),
    ("ex_pike_pushup", "Pike Push-Up", "shoulders", '["triceps","chest"]', "bw", "bilateral", "total",
        ["pike push-up", "pike pushup", "pike push up"], None),
    ("ex_pseudo_planche_pushup", "Pseudo-Planche Push-Up", "shoulders", '["chest","triceps","core"]', "bw", "bilateral", "total",
        ["pseudo-planche push-up", "pseudo planche pushup", "planche pushup"], None),
    ("ex_shoulder_tap", "Shoulder Tap Push-Up Plank", "shoulders", '["core","chest"]', "bw", "unilateral", "total",
        ["shoulder tap", "shoulder taps", "plank shoulder tap"], None),
    # ============================================================
    # BODYWEIGHT — UPPER BODY PULL
    # ============================================================
    ("ex_archer_pullup", "Archer Pull-Up", "back", '["biceps","forearms"]', "bw", "unilateral", "total",
        ["archer pull-up", "archer pullup", "archer pull up"], None),
    ("ex_scapular_pullup", "Scapular Pull-Up", "back", '["traps","shoulders"]', "bw", "bilateral", "total",
        ["scapular pull-up", "scap pullup", "scap pull-up"], "Scapular_Pull-Up"),
    ("ex_commando_pullup", "Commando Pull-Up", "back", '["biceps","core"]', "bw", "bilateral", "total",
        ["commando pull-up", "commando pullup"], None),
    ("ex_mixed_grip_pullup", "Mixed-Grip Pull-Up", "back", '["biceps","forearms"]', "bw", "bilateral", "total",
        ["mixed-grip pull-up", "mixed grip pullup", "mixed grip chin"], "Mixed_Grip_Chin"),
    ("ex_towel_pullup", "Towel Pull-Up", "back", '["biceps","forearms"]', "bw", "bilateral", "total",
        ["towel pull-up", "towel pullup"], None),
    # ============================================================
    # BODYWEIGHT — CORE / CONDITIONING
    # ============================================================
    ("ex_burpee", "Burpee", "core", '["chest","quads","shoulders"]', "bw", "bilateral", "total",
        ["burpee", "burpees"], None),
    ("ex_mountain_climber", "Mountain Climber", "core", '["shoulders","quads"]', "bw", "unilateral", "total",
        ["mountain climber", "mountain climbers"], None),
    ("ex_plank_to_pike", "Plank-to-Pike", "core", '["shoulders"]', "bw", "bilateral", "total",
        ["plank-to-pike", "plank to pike", "pike plank"], None),
    ("ex_v_up", "V-Up", "core", '[]', "bw", "bilateral", "total",
        ["v-up", "v up", "v ups", "vup"], None),
    ("ex_hollow_rocks", "Hollow Rocks", "core", '[]', "bw", "bilateral", "total",
        ["hollow rocks", "hollow rock"], None),
    ("ex_bear_crawl", "Bear Crawl", "core", '["shoulders","quads"]', "bw", "unilateral", "total",
        ["bear crawl"], None),
    ("ex_crab_walk", "Crab Walk", "shoulders", '["triceps","glutes","core"]', "bw", "unilateral", "total",
        ["crab walk"], None),
    ("ex_inchworm", "Inchworm", "core", '["shoulders","hamstrings"]', "bw", "bilateral", "total",
        ["inchworm", "inch worm"], "Inchworm"),
    ("ex_jumping_jack", "Jumping Jack", "calves", '["shoulders","core"]', "bw", "bilateral", "total",
        ["jumping jack", "jumping jacks"], None),
    ("ex_high_knees", "High Knees", "calves", '["core","quads"]', "bw", "unilateral", "total",
        ["high knees", "high knee"], None),
    ("ex_broad_jump", "Broad Jump", "quads", '["glutes","calves","hamstrings"]', "bw", "bilateral", "total",
        ["broad jump", "standing long jump", "broad jumps"], "Standing_Long_Jump"),
    ("ex_box_jump", "Box Jump", "quads", '["glutes","calves"]', "bw", "bilateral", "total",
        ["box jump", "box jumps"], "Bench_Jump"),
    ("ex_tuck_jump", "Tuck Jump", "quads", '["calves","core"]', "bw", "bilateral", "total",
        ["tuck jump", "tuck jumps", "knee tuck jump"], "Knee_Tuck_Jump"),
    ("ex_jackknife_situp", "Jackknife Sit-Up", "core", '[]', "bw", "bilateral", "total",
        ["jackknife sit-up", "jackknife situp", "jackknife"], "Jackknife_Sit-Up"),
    ("ex_scissor_kick", "Scissor Kick", "core", '[]', "bw", "bilateral", "total",
        ["scissor kick", "scissor kicks", "flutter scissor"], "Scissor_Kick"),
    ("ex_flutter_kick", "Flutter Kick", "core", '[]', "bw", "bilateral", "total",
        ["flutter kick", "flutter kicks"], "Flutter_Kicks"),
    ("ex_bicycle_crunch", "Bicycle Crunch", "core", '[]', "bw", "unilateral", "total",
        ["bicycle crunch", "bicycle crunches", "elbow to knee"], None),
    ("ex_toe_touch_crunch", "Toe-Touch Crunch", "core", '[]', "bw", "bilateral", "total",
        ["toe-touch crunch", "toe touch", "toe touchers"], "Toe_Touchers"),
    ("ex_superman", "Superman", "back", '["glutes"]', "bw", "bilateral", "total",
        ["superman", "supermans", "back extension bw"], "Superman"),
    # ============================================================
    # MOBILITY / STRETCH
    # ============================================================
    ("ex_worlds_greatest_stretch", "World's Greatest Stretch", "hamstrings", '["back","shoulders","glutes"]', "bw", "unilateral", "total",
        ["world's greatest stretch", "worlds greatest stretch", "wgs"], "Worlds_Greatest_Stretch"),
    ("ex_90_90_hip", "90/90 Hip Switch", "glutes", '["core"]', "bw", "unilateral", "total",
        ["90/90 hip", "90 90 hip", "90 90 switch", "90/90 hamstring"], "90_90_Hamstring"),
    ("ex_couch_stretch", "Couch Stretch", "quads", '[]', "bw", "unilateral", "total",
        ["couch stretch"], None),
    ("ex_pigeon_pose", "Pigeon Pose", "glutes", '[]', "bw", "unilateral", "total",
        ["pigeon pose", "pigeon stretch", "pigeon"], None),
    ("ex_childs_pose", "Child's Pose", "back", '["shoulders"]', "bw", "bilateral", "total",
        ["child's pose", "childs pose"], "Childs_Pose"),
    ("ex_thoracic_rotation", "Thoracic Rotation", "back", '["shoulders"]', "bw", "unilateral", "total",
        ["thoracic rotation", "t-spine rotation", "thoracic spine rotation"], None),
    # ============================================================
    # UNILATERAL LOADED — DB
    # ============================================================
    ("ex_sa_db_ohp", "Single-Arm Dumbbell Shoulder Press", "shoulders", '["triceps","core"]', "dumbbell", "unilateral", "total",
        ["single-arm dumbbell shoulder press", "single arm db ohp", "one arm db press standing"], None),
    ("ex_sa_db_bench", "Single-Arm Dumbbell Bench Press", "chest", '["triceps","core","shoulders"]', "dumbbell", "unilateral", "total",
        ["single-arm dumbbell bench press", "single arm db bench", "one arm db bench"], "One_Arm_Dumbbell_Bench_Press"),
    ("ex_db_bstance_rdl", "Dumbbell B-Stance RDL", "hamstrings", '["glutes","back"]', "dumbbell", "unilateral", "per_hand",
        ["dumbbell b-stance rdl", "b-stance rdl", "b stance rdl", "kickstand rdl"], None),
    ("ex_db_single_leg_rdl", "Dumbbell Single-Leg RDL", "hamstrings", '["glutes","back","core"]', "dumbbell", "unilateral", "total",
        ["dumbbell single-leg rdl", "db single leg rdl", "single-leg dumbbell deadlift"], None),
    ("ex_db_suitcase_dl", "Suitcase Deadlift", "back", '["forearms","glutes","hamstrings","core"]', "dumbbell", "unilateral", "total",
        ["suitcase deadlift", "db suitcase deadlift"], None),
    ("ex_db_farmers_walk", "Dumbbell Farmer's Walk", "forearms", '["traps","core"]', "dumbbell", "bilateral", "per_hand",
        ["dumbbell farmer's walk", "db farmers walk", "farmers walk", "farmer's walk", "farmer carry"], "Farmers_Walk"),
    ("ex_db_suitcase_carry", "Suitcase Carry", "core", '["forearms","traps"]', "dumbbell", "unilateral", "total",
        ["suitcase carry"], None),
    ("ex_db_overhead_carry", "Overhead Carry", "shoulders", '["core","triceps"]', "dumbbell", "bilateral", "per_hand",
        ["overhead carry", "overhead walk"], None),
    # ============================================================
    # UNILATERAL LOADED — CABLE / MACHINE
    # ============================================================
    ("ex_sa_cable_row", "Single-Arm Cable Row", "back", '["biceps","shoulders"]', "machine", "unilateral", "total",
        ["single-arm cable row", "single arm cable row", "one arm cable row"], None),
    ("ex_sa_lat_pulldown", "Single-Arm Lat Pulldown", "back", '["biceps","shoulders"]', "machine", "unilateral", "total",
        ["single-arm lat pulldown", "one arm lat pulldown", "single arm pulldown"], "One_Arm_Lat_Pulldown"),
    ("ex_sa_cable_lateral", "Single-Arm Cable Lateral Raise", "shoulders", '[]', "machine", "unilateral", "total",
        ["single-arm cable lateral raise", "single arm cable lateral", "cable lateral one arm"], None),
    ("ex_sa_cable_curl", "Single-Arm Cable Curl", "biceps", '[]', "machine", "unilateral", "total",
        ["single-arm cable curl", "single arm cable curl", "one arm cable curl"], None),
    ("ex_sa_cable_pushdown", "Single-Arm Cable Pushdown", "triceps", '[]', "machine", "unilateral", "total",
        ["single-arm cable pushdown", "single arm tricep pushdown", "one arm pushdown"], None),
    ("ex_single_leg_press", "Single-Leg Leg Press", "quads", '["glutes","hamstrings"]', "machine", "unilateral", "total",
        ["single-leg leg press", "single leg press", "one leg press"], None),
    ("ex_single_leg_curl", "Single-Leg Leg Curl", "hamstrings", '[]', "machine", "unilateral", "total",
        ["single-leg leg curl", "single leg curl"], None),
    ("ex_single_leg_extension", "Single-Leg Leg Extension", "quads", '[]', "machine", "unilateral", "total",
        ["single-leg leg extension", "single leg extension", "one leg extension"], None),
    # ============================================================
    # UNILATERAL LOADED — LANDMINE / SPECIALTY
    # ============================================================
    ("ex_landmine_press", "Single-Arm Landmine Press", "shoulders", '["chest","triceps","core"]', "barbell", "unilateral", "total",
        ["single-arm landmine press", "landmine press", "single arm landmine press"], "Single-Arm_Linear_Jammer"),
    ("ex_landmine_row", "Single-Arm Landmine Row", "back", '["biceps","traps"]', "barbell", "unilateral", "total",
        ["single-arm landmine row", "landmine row", "meadows row"], None),
    ("ex_landmine_rdl", "Landmine RDL", "hamstrings", '["glutes","back"]', "barbell", "bilateral", "total",
        ["landmine rdl", "landmine romanian deadlift"], None),
    # ============================================================
    # OLYMPIC LIFTS
    # ============================================================
    ("ex_power_clean", "Power Clean", "back", '["traps","hamstrings","glutes","quads","shoulders"]', "barbell", "bilateral", "total",
        ["power clean"], "Power_Clean"),
    ("ex_hang_power_clean", "Hang Power Clean", "back", '["traps","hamstrings","glutes","shoulders"]', "barbell", "bilateral", "total",
        ["hang power clean", "hang clean"], "Hang_Clean"),
    ("ex_clean_pull", "Clean Pull", "back", '["traps","hamstrings","glutes"]', "barbell", "bilateral", "total",
        ["clean pull"], "Clean_Pull"),
    ("ex_muscle_clean", "Muscle Clean", "back", '["traps","shoulders"]', "barbell", "bilateral", "total",
        ["muscle clean"], None),
    ("ex_power_snatch", "Power Snatch", "back", '["traps","shoulders","hamstrings","glutes"]', "barbell", "bilateral", "total",
        ["power snatch"], "Power_Snatch"),
    ("ex_hang_snatch", "Hang Snatch", "back", '["traps","shoulders","hamstrings"]', "barbell", "bilateral", "total",
        ["hang snatch"], "Hang_Snatch"),
    ("ex_muscle_snatch", "Muscle Snatch", "back", '["traps","shoulders"]', "barbell", "bilateral", "total",
        ["muscle snatch"], "Muscle_Snatch"),
    ("ex_snatch_pull", "Snatch Pull", "back", '["traps","hamstrings","glutes"]', "barbell", "bilateral", "total",
        ["snatch pull"], "Snatch_Pull"),
    ("ex_high_pull", "High Pull", "back", '["traps","shoulders"]', "barbell", "bilateral", "total",
        ["high pull", "barbell high pull"], None),
    ("ex_full_snatch", "Snatch", "back", '["traps","shoulders","hamstrings","glutes","quads"]', "barbell", "bilateral", "total",
        ["snatch", "full snatch", "squat snatch"], "Snatch"),
    ("ex_clean_jerk", "Clean and Jerk", "back", '["traps","hamstrings","glutes","shoulders","quads"]', "barbell", "bilateral", "total",
        ["clean and jerk", "c&j", "clean & jerk", "clean and press"], "Clean_and_Jerk"),
    ("ex_push_jerk", "Push Jerk", "shoulders", '["triceps","quads"]', "barbell", "bilateral", "total",
        ["push jerk"], None),
    ("ex_split_jerk", "Split Jerk", "shoulders", '["triceps","quads","glutes"]', "barbell", "bilateral", "total",
        ["split jerk"], "Split_Jerk"),
    # ============================================================
    # SPECIALTY BARBELL / FREE WEIGHT
    # ============================================================
    ("ex_trap_bar_dl", "Trap Bar Deadlift", "back", '["traps","hamstrings","glutes","quads","forearms"]', "barbell", "bilateral", "total",
        ["trap bar deadlift", "hex bar deadlift", "trap bar dl"], "Trap_Bar_Deadlift"),
    ("ex_pin_squat", "Pin Squat", "quads", '["glutes","core"]', "barbell", "bilateral", "total",
        ["pin squat", "pin squats"], None),
    ("ex_paused_squat", "Paused Squat", "quads", '["glutes","core"]', "barbell", "bilateral", "total",
        ["paused squat", "pause squat"], None),
    ("ex_paused_bench", "Paused Bench Press", "chest", '["triceps","shoulders"]', "barbell", "bilateral", "total",
        ["paused bench press", "pause bench"], None),
    ("ex_jefferson_curl", "Jefferson Curl", "back", '["hamstrings","glutes"]', "barbell", "bilateral", "total",
        ["jefferson curl"], None),
    ("ex_zercher_squat", "Zercher Squat", "quads", '["glutes","core","biceps"]', "barbell", "bilateral", "total",
        ["zercher squat", "zercher"], None),
    # ============================================================
    # MACHINE ADDITIONS
    # ============================================================
    ("ex_pec_deck", "Pec Deck", "chest", '["shoulders"]', "machine", "bilateral", "total",
        ["pec deck", "machine fly", "machine chest fly", "pec deck fly"], None),
    ("ex_belt_squat", "Belt Squat", "quads", '["glutes","hamstrings"]', "machine", "bilateral", "total",
        ["belt squat"], None),
    ("ex_hip_abduction", "Hip Abduction Machine", "glutes", '[]', "machine", "bilateral", "total",
        ["hip abduction", "hip abduction machine", "abductor machine"], None),
    ("ex_hip_adduction", "Hip Adduction Machine", "glutes", '["quads"]', "machine", "bilateral", "total",
        ["hip adduction", "hip adduction machine", "adductor machine", "inner thigh machine"], None),
    ("ex_assisted_pullup", "Assisted Pull-Up", "back", '["biceps"]', "machine", "bilateral", "total",
        ["assisted pull-up", "assisted pullup", "assisted chin-up", "assisted chinup"], None),
    ("ex_smith_squat", "Smith Machine Squat", "quads", '["glutes"]', "machine", "bilateral", "total",
        ["smith machine squat", "smith squat"], None),
    ("ex_smith_bench", "Smith Machine Bench Press", "chest", '["triceps","shoulders"]', "machine", "bilateral", "total",
        ["smith machine bench press", "smith bench"], None),
    # ============================================================
    # KETTLEBELL ADDITIONS
    # ============================================================
    ("ex_kb_swing", "Kettlebell Swing", "hamstrings", '["glutes","back","core"]', "kettlebell", "bilateral", "total",
        ["kettlebell swing", "kb swing", "two-arm kettlebell swing"], None),
    # NOTE: ex_kb_swing already exists in 0009 — re-use without re-insertion.
    # The line above is a NO-OP via INSERT OR IGNORE; kept here for clarity.
    ("ex_sa_kb_swing", "Single-Arm Kettlebell Swing", "hamstrings", '["glutes","back","core"]', "kettlebell", "unilateral", "total",
        ["single-arm kettlebell swing", "one-arm kb swing", "one arm kettlebell swing"], "One-Arm_Kettlebell_Swings"),
    ("ex_kb_snatch", "Kettlebell Snatch", "back", '["traps","shoulders","glutes","hamstrings"]', "kettlebell", "unilateral", "total",
        ["kettlebell snatch", "kb snatch", "one arm kettlebell snatch"], "One-Arm_Kettlebell_Snatch"),
    ("ex_kb_goblet_squat", "Kettlebell Goblet Squat", "quads", '["glutes","core"]', "kettlebell", "bilateral", "total",
        ["kettlebell goblet squat", "kb goblet squat"], None),
    ("ex_kb_clean", "Kettlebell Clean", "back", '["traps","glutes","shoulders"]', "kettlebell", "unilateral", "total",
        ["kettlebell clean", "kb clean"], None),
]

# Validate + emit.

# Prior catalog ids (from 0002 + 0004 + 0007 + 0009) — must NOT collide.
PRIOR_IDS = {
    # 0002 originals
    "ex_back_squat","ex_front_squat","ex_deadlift","ex_rdl","ex_bench","ex_incline_bench",
    "ex_ohp","ex_barbell_row","ex_pullup","ex_db_press","ex_lat_pulldown","ex_leg_press",
    # 0004 timed
    "ex_plank","ex_side_plank","ex_hollow","ex_dead_hang","ex_wall_sit",
    # 0007 (114)
    "ex_goblet_squat","ex_db_squat","ex_hack_squat","ex_bw_squat","ex_box_squat","ex_ohs",
    "ex_bb_lunge","ex_db_lunge","ex_bw_lunge","ex_bb_walking_lunge","ex_db_reverse_lunge",
    "ex_db_split_squat","ex_db_step_up","ex_bb_step_up","ex_leg_extension","ex_lying_leg_curl",
    "ex_seated_leg_curl","ex_standing_leg_curl","ex_stiff_leg_dl","ex_db_rdl","ex_sumo_dl",
    "ex_good_morning","ex_ghr","ex_rack_pull","ex_deficit_dl","ex_hip_thrust","ex_glute_bridge",
    "ex_sl_glute_bridge","ex_glute_kickback","ex_cable_kickback","ex_pull_through",
    "ex_standing_calf_raise","ex_seated_calf_raise","ex_calf_press","ex_db_calf_raise","ex_bb_calf_raise",
    "ex_decline_bench","ex_incline_db_press","ex_decline_db_press","ex_db_fly","ex_incline_db_fly",
    "ex_cable_crossover","ex_low_cable_crossover","ex_machine_chest_press","ex_machine_incline_press",
    "ex_pushup","ex_incline_pushup","ex_decline_pushup","ex_feet_elevated_pushup","ex_db_pullover",
    "ex_db_row_two","ex_one_arm_db_row","ex_seated_cable_row","ex_tbar_row","ex_inverted_row",
    "ex_wide_pulldown","ex_close_pulldown","ex_straight_arm_pulldown","ex_chinup","ex_neutral_pullup",
    "ex_reverse_grip_row","ex_smith_row","ex_bb_shrug","ex_db_shrug","ex_cable_shrug","ex_upright_row",
    "ex_face_pull","ex_db_ohp","ex_seated_db_press","ex_arnold_press","ex_push_press","ex_lateral_raise",
    "ex_cable_lateral_raise","ex_front_raise","ex_reverse_fly","ex_machine_reverse_fly",
    "ex_machine_shoulder_press","ex_cable_rear_delt_fly","ex_hspu","ex_seated_bb_press",
    "ex_bb_curl","ex_db_curl","ex_hammer_curl","ex_incline_db_curl","ex_preacher_curl",
    "ex_concentration_curl","ex_ez_curl","ex_cable_curl","ex_spider_curl","ex_reverse_curl",
    "ex_tricep_pushdown","ex_rope_pushdown","ex_cgbp","ex_skullcrusher","ex_dips","ex_bench_dips",
    "ex_overhead_tricep_ext","ex_db_overhead_ext","ex_tricep_kickback","ex_machine_tricep_ext","ex_machine_dip",
    "ex_hanging_leg_raise","ex_cable_crunch","ex_crunch","ex_situp","ex_russian_twist","ex_reverse_crunch",
    "ex_pallof_press","ex_woodchop","ex_dead_bug","ex_wrist_curl","ex_reverse_wrist_curl",
    "ex_ab_wheel","ex_sissy_squat",
    # 0009 warmup
    "ex_kb_deadlift","ex_kb_swing","ex_bird_dog","ex_cat_cow","ex_banded_pull_apart",
    "ex_banded_glute_bridge","ex_chest_supported_row",
}

# Prior catalog canonical names (lowercased) — must NOT be shadowed by a new
# alias and must NOT clash with a new canonical name.
PRIOR_NAMES_LC = {
    "back squat","front squat","conventional deadlift","romanian deadlift","bench press",
    "incline bench press","overhead press","barbell row","pull-up","dumbbell bench press",
    "lat pulldown","leg press","plank","side plank","hollow hold","dead hang","wall sit",
    "goblet squat","dumbbell squat","hack squat","bodyweight squat","box squat","overhead squat",
    "barbell lunge","dumbbell lunge","bodyweight walking lunge","barbell walking lunge",
    "dumbbell reverse lunge","dumbbell bulgarian split squat","dumbbell step-up","barbell step-up",
    "leg extension","lying leg curl","seated leg curl","standing leg curl","stiff-legged deadlift",
    "dumbbell romanian deadlift","sumo deadlift","good morning","glute ham raise","rack pull",
    "deficit deadlift","hip thrust","glute bridge","single-leg glute bridge","glute kickback",
    "cable glute kickback","cable pull-through","standing calf raise","seated calf raise",
    "calf press","dumbbell calf raise","barbell calf raise","decline barbell bench press",
    "incline dumbbell press","decline dumbbell bench press","dumbbell fly","incline dumbbell fly",
    "cable crossover","low cable crossover","machine chest press","machine incline press",
    "push-up","incline push-up","decline push-up","feet-elevated push-up","dumbbell pullover",
    "two-arm dumbbell row","one-arm dumbbell row","seated cable row","t-bar row","inverted row",
    "wide-grip lat pulldown","close-grip lat pulldown","straight-arm pulldown","chin-up",
    "neutral-grip pull-up","reverse-grip barbell row","smith machine row","barbell shrug",
    "dumbbell shrug","cable shrug","upright row","face pull","dumbbell shoulder press",
    "seated dumbbell press","arnold press","push press","dumbbell lateral raise","cable lateral raise",
    "dumbbell front raise","dumbbell reverse fly","machine reverse fly","machine shoulder press",
    "cable rear delt fly","handstand push-up","seated barbell press","barbell curl","dumbbell curl",
    "hammer curl","incline dumbbell curl","preacher curl","concentration curl","ez-bar curl",
    "cable curl","spider curl","reverse curl","triceps pushdown","rope triceps pushdown",
    "close-grip bench press","skullcrusher","dips","bench dip","cable overhead triceps extension",
    "dumbbell overhead triceps extension","triceps kickback","machine triceps extension","machine dip",
    "hanging leg raise","cable crunch","crunch","sit-up","russian twist","reverse crunch",
    "pallof press","cable woodchop","dead bug","barbell wrist curl","barbell reverse wrist curl",
    "ab wheel rollout","sissy squat","kettlebell deadlift","kettlebell swing","bird dog","cat-cow",
    "banded pull-apart","banded glute bridge","chest-supported row",
}

# Prior alias tokens — collected from grepping migrations directly (this
# avoids drift if the lists above fall out of sync).

def collect_prior_aliases() -> set[str]:
    import re
    out: set[str] = set()
    for path in ("migrations/0002_seed_exercises.sql",
                 "migrations/0004_set_duration_and_timed.sql",
                 "migrations/0007_seed_exercises_expanded.sql",
                 "migrations/0009_seed_warmup_core.sql"):
        try:
            txt = open(path).read()
        except FileNotFoundError:
            continue
        # match aliases columns: '[" … "]' single-quoted JSON arrays
        for m in re.finditer(r"'(\[[^']*\])'", txt):
            try:
                arr = json.loads(m.group(1))
                if isinstance(arr, list):
                    for a in arr:
                        if isinstance(a, str):
                            out.add(a.lower())
            except (json.JSONDecodeError, ValueError):
                pass
    return out


def main() -> int:
    check_only = "--check" in sys.argv

    # 1) duplicate id within 0021
    seen_ids: set[str] = set()
    for row in NEW_EXERCISES:
        ex_id = row[0]
        if ex_id in seen_ids:
            print(f"DUP id within 0021: {ex_id}", file=sys.stderr)
            return 1
        seen_ids.add(ex_id)

    # 2) collision with prior migrations' ids (excluding ex_kb_swing which is
    # an explicit no-op INSERT OR IGNORE — see note in NEW_EXERCISES)
    collisions = (seen_ids & PRIOR_IDS) - {"ex_kb_swing"}
    if collisions:
        print(f"id collision with prior migrations: {collisions}", file=sys.stderr)
        return 1

    # 3) canonical-name uniqueness across the full post-0021 catalog
    seen_names: dict[str, str] = {}
    for row in NEW_EXERCISES:
        ex_id, name = row[0], row[1]
        if ex_id == "ex_kb_swing":
            continue  # INSERT OR IGNORE no-op
        lc = name.lower()
        if lc in PRIOR_NAMES_LC:
            print(f"name shadows prior catalog: {name!r} ({ex_id})", file=sys.stderr)
            return 1
        if lc in seen_names:
            print(f"duplicate canonical name within 0021: {name!r} "
                  f"({ex_id} vs {seen_names[lc]})", file=sys.stderr)
            return 1
        seen_names[lc] = ex_id

    # 4) alias determinism: every alias owned by exactly one row; no alias
    # shadows another canonical name (catalog-wide).
    prior_aliases = collect_prior_aliases()
    alias_owner: dict[str, str] = {}
    for row in NEW_EXERCISES:
        ex_id, name, aliases = row[0], row[1], row[7]
        if ex_id == "ex_kb_swing":
            continue
        # Auto-include lowercased name as an alias (mirrors 0007's generator).
        bundle = [name.lower()] + [a.lower() for a in aliases]
        for a in bundle:
            if a in prior_aliases and a not in [n.lower() for n in [name]]:
                # OK only if prior owner is this same id (impossible since
                # we excluded prior ids); else collision.
                print(f"alias collision with prior migrations: {a!r} ({ex_id})",
                      file=sys.stderr)
                return 1
            if a in PRIOR_NAMES_LC and a != name.lower():
                print(f"alias {a!r} shadows prior canonical name ({ex_id})",
                      file=sys.stderr)
                return 1
            if a in alias_owner and alias_owner[a] != ex_id:
                print(f"alias {a!r} owned by two new rows: "
                      f"{ex_id} vs {alias_owner[a]}", file=sys.stderr)
                return 1
            alias_owner[a] = ex_id

    if check_only:
        print(f"OK: {len(seen_ids)} new exercises, all invariants pass",
              file=sys.stderr)
        return 0

    # Emit migration.
    print(
        "-- 0021_seed_exercises_v2.sql\n"
        "-- GENERATED by scripts/build_exercise_seed_v2.py.\n"
        "--\n"
        "-- Net-new catalog rows: bodyweight / at-home priority, deeper\n"
        "-- unilateral coverage, Olympic + specialty additions. All three\n"
        "-- post-0011 columns (laterality, load_mode, demo_slug) are set\n"
        "-- inline at INSERT time — no follow-up UPDATEs needed.\n"
        "--\n"
        f"-- Adds {len(seen_ids) - 1} net-new exercises (ex_kb_swing is\n"
        "-- intentionally re-listed as a no-op so the rebuild is self-\n"
        "-- describing; INSERT OR IGNORE drops it).\n"
        "--\n"
        "-- STRICTLY ADDITIVE + IDEMPOTENT. INSERT OR IGNORE on the PK\n"
        "-- keeps re-runs a no-op; the catalog.test.ts replay check covers\n"
        "-- this in CI.\n"
    )
    print(
        "INSERT OR IGNORE INTO exercises\n"
        "  (id, name, primary_muscle, secondary_muscles, modality, unit,\n"
        "   aliases, created_at, laterality, load_mode, demo_slug)\n"
        "VALUES"
    )
    def sq(s: str) -> str:
        """SQLite single-quote escape: ' -> ''. Applied to every value
        going into a single-quoted SQL string literal (names, aliases JSON,
        slugs) — without this, 'World's Greatest Stretch' or 'Child's Pose'
        break the migration with a syntax error at the embedded apostrophe.
        """
        return s.replace("'", "''")

    parts: list[str] = []
    for row in NEW_EXERCISES:
        (ex_id, name, pm, sec, mod, lat, load, aliases, slug) = row
        # auto-include lowercased name as alias; dedupe.
        full_aliases = list(dict.fromkeys([name.lower()] + aliases))
        slug_sql = "NULL" if slug is None else f"'{sq(slug)}'"
        parts.append(
            f"  ('{sq(ex_id)}', '{sq(name)}', '{sq(pm)}', '{sq(sec)}', '{sq(mod)}', 'lb',\n"
            f"   '{sq(json.dumps(full_aliases))}', 0, '{sq(lat)}', '{sq(load)}', {slug_sql})"
        )
    print(",\n".join(parts) + ";")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
