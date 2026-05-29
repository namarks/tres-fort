#!/usr/bin/env python3
"""Generate migrations/0020_exercise_demo_slugs.sql.

Pairs every existing ex_* row to the corresponding free-exercise-db `id` (the
slug + image directory name) so iOS can look up `{slug}/0.jpg` + `{slug}/1.jpg`
demo frames out of either the bundled asset catalog (foundational lifts) or
the Worker-fronted R2 bucket (long tail). Backfill is nullable: rows with no
upstream entry (planks/holds/bird-dog/banded primitives) stay NULL — the
demo sheet will render the cue text without an image instead of 404'ing.

Strictly additive + idempotent:
  ALTER TABLE … ADD COLUMN demo_slug TEXT   -- nullable, no default
  UPDATE exercises SET demo_slug = '…' WHERE id = 'ex_*'   -- one per row

The slugs themselves are content-addressed (the upstream id changes only when
the upstream movement changes), so once written they don't need to move.

Reproduce:
    curl -sL -o /tmp/free-exercise-db.json \\
      https://raw.githubusercontent.com/yuhonas/free-exercise-db/main/dist/exercises.json
    python3 scripts/build_demo_backfill.py /tmp/free-exercise-db.json \\
      > migrations/0020_exercise_demo_slugs.sql
"""
import json
import sys

# Mapping is ex_id -> source NAME (we resolve to id via the JSON). NULL when
# upstream has no matching entry — the field stays NULL in the DB and the
# iOS demo sheet falls back to cue text.

# --- 0002 original 12 ---
ORIG_12 = {
    "ex_back_squat":     "Barbell Squat",
    "ex_front_squat":    "Front Squat (Clean Grip)",
    "ex_deadlift":       "Barbell Deadlift",
    "ex_rdl":            "Romanian Deadlift",
    "ex_bench":          "Barbell Bench Press - Medium Grip",
    "ex_incline_bench":  "Barbell Incline Bench Press - Medium Grip",
    "ex_ohp":            "Standing Military Press",
    "ex_barbell_row":    "Bent Over Barbell Row",
    "ex_pullup":         "Pullups",
    "ex_db_press":       "Dumbbell Bench Press",
    "ex_lat_pulldown":   "Wide-Grip Lat Pulldown",
    "ex_leg_press":      "Leg Press",
}

# --- 0004 timed exercises ---
# Only Plank + Side Bridge have upstream entries; the rest stay NULL.
TIMED_5 = {
    "ex_plank":      "Plank",
    "ex_side_plank": "Side Bridge",
    "ex_hollow":     None,
    "ex_dead_hang":  None,
    "ex_wall_sit":   None,
}

# --- 0007 curated. Source name -> ex_id, copied from build_exercise_seed.py's
# CURATED dict (one-way: ex_id is the target). We re-list here rather than
# importing because that script's CURATED is keyed by source name (and 0007
# may evolve); this keeps the backfill independent and inspectable.
CURATED_0007 = {
    # quads / squat pattern
    "Goblet Squat": "ex_goblet_squat",
    "Dumbbell Squat": "ex_db_squat",
    "Hack Squat": "ex_hack_squat",
    "Bodyweight Squat": "ex_bw_squat",
    "Box Squat": "ex_box_squat",
    "Overhead Squat": "ex_ohs",
    "Barbell Lunge": "ex_bb_lunge",
    "Dumbbell Lunges": "ex_db_lunge",
    "Bodyweight Walking Lunge": "ex_bw_lunge",
    "Barbell Walking Lunge": "ex_bb_walking_lunge",
    "Dumbbell Rear Lunge": "ex_db_reverse_lunge",
    "Split Squat with Dumbbells": "ex_db_split_squat",
    "Dumbbell Step Ups": "ex_db_step_up",
    "Barbell Step Ups": "ex_bb_step_up",
    "Leg Extensions": "ex_leg_extension",
    # hamstrings
    "Lying Leg Curls": "ex_lying_leg_curl",
    "Seated Leg Curl": "ex_seated_leg_curl",
    "Standing Leg Curl": "ex_standing_leg_curl",
    "Stiff-Legged Barbell Deadlift": "ex_stiff_leg_dl",
    "Stiff-Legged Dumbbell Deadlift": "ex_db_rdl",
    "Sumo Deadlift": "ex_sumo_dl",
    "Good Morning": "ex_good_morning",
    "Glute Ham Raise": "ex_ghr",
    "Rack Pulls": "ex_rack_pull",
    "Deficit Deadlift": "ex_deficit_dl",
    # glutes
    "Barbell Hip Thrust": "ex_hip_thrust",
    "Barbell Glute Bridge": "ex_glute_bridge",
    "Single Leg Glute Bridge": "ex_sl_glute_bridge",
    "Glute Kickback": "ex_glute_kickback",
    "One-Legged Cable Kickback": "ex_cable_kickback",
    "Pull Through": "ex_pull_through",
    # calves
    "Standing Calf Raises": "ex_standing_calf_raise",
    "Seated Calf Raise": "ex_seated_calf_raise",
    "Calf Press": "ex_calf_press",
    "Standing Dumbbell Calf Raise": "ex_db_calf_raise",
    "Standing Barbell Calf Raise": "ex_bb_calf_raise",
    # chest
    "Decline Barbell Bench Press": "ex_decline_bench",
    "Incline Dumbbell Press": "ex_incline_db_press",
    "Decline Dumbbell Bench Press": "ex_decline_db_press",
    "Dumbbell Flyes": "ex_db_fly",
    "Incline Dumbbell Flyes": "ex_incline_db_fly",
    "Cable Crossover": "ex_cable_crossover",
    "Low Cable Crossover": "ex_low_cable_crossover",
    "Machine Bench Press": "ex_machine_chest_press",
    "Leverage Incline Chest Press": "ex_machine_incline_press",
    "Pushups": "ex_pushup",
    "Incline Push-Up": "ex_incline_pushup",
    "Decline Push-Up": "ex_decline_pushup",
    "Push-Ups With Feet Elevated": "ex_feet_elevated_pushup",
    "Straight-Arm Dumbbell Pullover": "ex_db_pullover",
    # back / lats / rows
    "Bent Over Two-Dumbbell Row": "ex_db_row_two",
    "One-Arm Dumbbell Row": "ex_one_arm_db_row",
    "Seated Cable Rows": "ex_seated_cable_row",
    "T-Bar Row with Handle": "ex_tbar_row",
    "Inverted Row": "ex_inverted_row",
    "Wide-Grip Lat Pulldown": "ex_wide_pulldown",
    "Close-Grip Front Lat Pulldown": "ex_close_pulldown",
    "Straight-Arm Pulldown": "ex_straight_arm_pulldown",
    "Chin-Up": "ex_chinup",
    "V-Bar Pullup": "ex_neutral_pullup",
    "Reverse Grip Bent-Over Rows": "ex_reverse_grip_row",
    "Smith Machine Bent Over Row": "ex_smith_row",
    # traps
    "Barbell Shrug": "ex_bb_shrug",
    "Dumbbell Shrug": "ex_db_shrug",
    "Cable Shrugs": "ex_cable_shrug",
    "Upright Barbell Row": "ex_upright_row",
    "Face Pull": "ex_face_pull",
    # shoulders
    "Standing Dumbbell Press": "ex_db_ohp",
    "Seated Dumbbell Press": "ex_seated_db_press",
    "Arnold Dumbbell Press": "ex_arnold_press",
    "Push Press": "ex_push_press",
    "Side Lateral Raise": "ex_lateral_raise",
    "Cable Seated Lateral Raise": "ex_cable_lateral_raise",
    "Front Dumbbell Raise": "ex_front_raise",
    "Reverse Flyes": "ex_reverse_fly",
    "Reverse Machine Flyes": "ex_machine_reverse_fly",
    "Machine Shoulder (Military) Press": "ex_machine_shoulder_press",
    "Cable Rear Delt Fly": "ex_cable_rear_delt_fly",
    "Handstand Push-Ups": "ex_hspu",
    "Seated Barbell Military Press": "ex_seated_bb_press",
    # biceps
    "Barbell Curl": "ex_bb_curl",
    "Dumbbell Bicep Curl": "ex_db_curl",
    "Hammer Curls": "ex_hammer_curl",
    "Incline Dumbbell Curl": "ex_incline_db_curl",
    "Preacher Curl": "ex_preacher_curl",
    "Concentration Curls": "ex_concentration_curl",
    "EZ-Bar Curl": "ex_ez_curl",
    "Cable Hammer Curls - Rope Attachment": "ex_cable_curl",
    "Spider Curl": "ex_spider_curl",
    "Reverse Barbell Curl": "ex_reverse_curl",
    # triceps
    "Triceps Pushdown": "ex_tricep_pushdown",
    "Triceps Pushdown - Rope Attachment": "ex_rope_pushdown",
    "Close-Grip Barbell Bench Press": "ex_cgbp",
    "EZ-Bar Skullcrusher": "ex_skullcrusher",
    "Dips - Triceps Version": "ex_dips",
    "Bench Dips": "ex_bench_dips",
    "Cable Rope Overhead Triceps Extension": "ex_overhead_tricep_ext",
    "Standing Dumbbell Triceps Extension": "ex_db_overhead_ext",
    "Tricep Dumbbell Kickback": "ex_tricep_kickback",
    "Machine Triceps Extension": "ex_machine_tricep_ext",
    "Dip Machine": "ex_machine_dip",
    # core
    "Hanging Leg Raise": "ex_hanging_leg_raise",
    "Cable Crunch": "ex_cable_crunch",
    "Crunches": "ex_crunch",
    "Sit-Up": "ex_situp",
    "Russian Twist": "ex_russian_twist",
    "Reverse Crunch": "ex_reverse_crunch",
    "Pallof Press": "ex_pallof_press",
    "Standing Cable Wood Chop": "ex_woodchop",
    "Dead Bug": "ex_dead_bug",
    # forearms
    "Palms-Up Barbell Wrist Curl Over A Bench": "ex_wrist_curl",
    "Seated Palms-Down Barbell Wrist Curl": "ex_reverse_wrist_curl",
    # MANUAL_EXTRA (no source mapping)
    # "Ab Wheel Rollout": "ex_ab_wheel",  # not in upstream
    # "Sissy Squat":      "ex_sissy_squat",  # not in upstream
}

# Leave demo_slug NULL on rows without a clean upstream pairing
# (band/quadruped/ab-wheel/sissy/timed-holds).

# --- 0009 warmup/core/activation. Most have no upstream entry (band/quadruped
# primitives the source DB doesn't ship); only Cat-Cow has a matching frame.
WARMUP_0009 = {
    "ex_kb_deadlift":         None,
    "ex_kb_swing":             None,  # upstream has only One-Arm_Kettlebell_Swings
    "ex_bird_dog":             None,
    "ex_cat_cow":             "Cat Stretch",
    "ex_banded_pull_apart":    None,
    "ex_banded_glute_bridge":  None,
    "ex_chest_supported_row":  None,
}


def main() -> int:
    src_path = sys.argv[1] if len(sys.argv) > 1 else "/tmp/free-exercise-db.json"
    data = json.load(open(src_path))
    by_name = {x["name"]: x for x in data}

    # ex_id -> slug (free-exercise-db id), or None.
    mapping: dict[str, str | None] = {}
    for ex_id, src_name in ORIG_12.items():
        mapping[ex_id] = by_name[src_name]["id"]
    for ex_id, src_name in TIMED_5.items():
        mapping[ex_id] = by_name[src_name]["id"] if src_name else None
    for src_name, ex_id in CURATED_0007.items():
        ex = by_name.get(src_name)
        mapping[ex_id] = ex["id"] if ex else None
    for ex_id, src_name in WARMUP_0009.items():
        mapping[ex_id] = by_name[src_name]["id"] if src_name else None

    # Multiple ex_* may share a slug (the generic Lat Pulldown row + the
    # explicit Wide-Grip variant point at the same upstream frames). That's
    # fine — slug is content-addressed, the asset is shared by both rows.

    nonnull = sum(1 for v in mapping.values() if v is not None)
    out: list[str] = []
    out.append(
        "-- 0020_exercise_demo_slugs.sql\n"
        "-- GENERATED by scripts/build_demo_backfill.py from\n"
        "-- free-exercise-db (github.com/yuhonas/free-exercise-db,\n"
        "-- public domain / Unlicense).\n"
        "--\n"
        "-- Adds `demo_slug` to exercises and backfills every existing row\n"
        "-- (0002 + 0004 + 0007 + 0009) that has a corresponding upstream\n"
        "-- entry. The slug is the upstream `id` field (e.g. 'Barbell_Squat'),\n"
        "-- which iOS uses as a key into either the bundled asset catalog\n"
        "-- (foundational lifts) or the Worker-fronted R2 bucket (long tail).\n"
        "-- Nullable on purpose: rows without an upstream pairing (planks,\n"
        f"-- holds, bird-dog, banded primitives) stay NULL — the demo sheet\n"
        f"-- renders cue text only. Backfilled here: {nonnull} / "
        f"{len(mapping)} ex_* rows.\n"
        "--\n"
        "-- STRICTLY ADDITIVE: one ALTER + per-row UPDATEs. Re-running the\n"
        "-- UPDATEs is idempotent (writes the same literal each time).\n"
    )
    out.append("ALTER TABLE exercises ADD COLUMN demo_slug TEXT;\n")
    # Stable order for readable diffs.
    for ex_id in sorted(mapping):
        slug = mapping[ex_id]
        if slug is None:
            continue
        out.append(
            f"UPDATE exercises SET demo_slug = '{slug}' WHERE id = '{ex_id}';"
        )
    print("\n".join(out))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
