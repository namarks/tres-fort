#!/usr/bin/env python3
"""Generate migrations/0007_seed_exercises_expanded.sql from free-exercise-db.

Source: https://github.com/yuhonas/free-exercise-db (public domain, Unlicense),
raw `dist/exercises.json`. The raw dump and images are a one-time generation
input and are NOT committed; only this script and the generated SQL are.

Reproduce:
    curl -sL -o /tmp/free-exercise-db.json \
      https://raw.githubusercontent.com/yuhonas/free-exercise-db/main/dist/exercises.json
    python3 scripts/build_exercise_seed.py /tmp/free-exercise-db.json \
      > migrations/0007_seed_exercises_expanded.sql

Curation criteria (judgment, encoded as the explicit CURATED allowlist below):
  - Foundational compound lifts + the commonly-programmed accessory movements
    a real lifter / this app would actually prescribe.
  - All major muscle groups covered: quads, hamstrings, glutes, chest, back,
    lats, shoulders, traps, biceps, triceps, calves, core, forearms.
  - All modalities: barbell, dumbbell, machine, cable, AND bodyweight (bw) --
    bodyweight staples (push-up, plank, dips, BW squat/lunge, chin-up,
    inverted row, hanging leg raise ...) are explicitly included to close
    the known catalog gap. (NB: the barbell glute bridge / hip thrust are
    seeded with modality='barbell', not bw -- they are barbell movements.)
  - Excluded: near-duplicate grip/stance/Smith variants, behind-the-neck
    variants, novelty/circus lifts, band/ball/foam-roll-only, kettlebell flow
    movements, stretching/cardio/plyometric-only entries.

Field mapping:
  - name             -> app display name (overridden where the source name is
                        awkward, e.g. "Pushups" -> "Push-Up")
  - primary_muscle   -> single string in the app's volume-grouping vocabulary
                        (quads/hamstrings/glutes/chest/back/shoulders/biceps/
                         triceps/calves/core/forearms/traps) -- normalized from
                        free-exercise-db primaryMuscles via MUSCLE_MAP
  - secondary_muscles-> JSON array, normalized to the app's secondary vocab
                        used by the original 12 (glutes/core/triceps/back/
                        front delts/rear delts/biceps/...)
  - modality         -> 'barbell'|'dumbbell'|'machine'|'bw' inferred from
                        equipment (cable/e-z curl bar collapse to the closest
                        of the 4 the original 12 use; body only -> bw)
  - unit             -> always 'lb' (matches all original 12, incl. ex_pullup)
  - aliases          -> deterministic JSON array; see ALIASES + auto-gen below.

STRICTLY ADDITIVE: 0007 emits INSERTs ONLY for ids NOT already inserted by an
earlier migration. It does NOT restate the original 12 (0002) nor the 5 timed
core/hold exercises (0004) -- those rows are owned and frozen by their own
migrations. The PRIOR_SEEDED_* tables below are reference data used purely to
(a) exclude any colliding id from emission and (b) feed the resolver
collision/shadow invariant so determinism holds DB-wide, not just within
0007's own rows. Net result: 0007 = exactly the net-new exercises, zero id
overlap with 0002/0004.

One targeted, idempotent UPDATE is emitted: it appends the conventional alias
"dumbbell press" to the existing 0002 row ex_db_press (Dumbbell Bench Press)
so that common phrase resolves to the bench press, not the new dumbbell
shoulder press. This is additive (mutates only an alias array, no row
insert/delete, re-running writes the identical literal) and keeps 0002 itself
untouched on disk.
"""
import json
import sys

# --- 0002's original 12, copied verbatim. REFERENCE ONLY: used for id
# exclusion + DB-wide collision validation. NOT emitted by 0007 (0002 owns
# these rows). ex_db_press's alias list is augmented at runtime with
# "dumbbell press" to mirror the UPDATE 0007 emits (see DB_PRESS_ALIAS_ADD).
# (id, name, primary_muscle, secondary_muscles_json, modality, unit, aliases_json)
ORIGINAL_12 = [
    ("ex_back_squat", "Back Squat", "quads", '["glutes","core"]', "barbell", "lb", '["squat","back squat","bb squat"]'),
    ("ex_front_squat", "Front Squat", "quads", '["glutes","core"]', "barbell", "lb", '["front squat"]'),
    ("ex_deadlift", "Conventional Deadlift", "hamstrings", '["glutes","back"]', "barbell", "lb", '["deadlift","dl","conventional deadlift"]'),
    ("ex_rdl", "Romanian Deadlift", "hamstrings", '["glutes","back"]', "barbell", "lb", '["rdl","romanian deadlift","romanian"]'),
    ("ex_bench", "Bench Press", "chest", '["triceps","front delts"]', "barbell", "lb", '["bench","bench press","bp","flat bench"]'),
    ("ex_incline_bench", "Incline Bench Press", "chest", '["triceps","front delts"]', "barbell", "lb", '["incline","incline bench"]'),
    ("ex_ohp", "Overhead Press", "shoulders", '["triceps"]', "barbell", "lb", '["ohp","overhead press","press","military press"]'),
    ("ex_barbell_row", "Barbell Row", "back", '["biceps","rear delts"]', "barbell", "lb", '["row","barbell row","bb row","pendlay row"]'),
    ("ex_pullup", "Pull-Up", "back", '["biceps"]', "bw", "lb", '["pullup","pull-up","pull up","chin up"]'),
    ("ex_db_press", "Dumbbell Bench Press", "chest", '["triceps","front delts"]', "dumbbell", "lb", '["db press","dumbbell bench","db bench"]'),
    ("ex_lat_pulldown", "Lat Pulldown", "back", '["biceps"]', "machine", "lb", '["pulldown","lat pulldown"]'),
    ("ex_leg_press", "Leg Press", "quads", '["glutes"]', "machine", "lb", '["leg press"]'),
]

# --- 0004's timed exercises, copied verbatim from
# 0004_set_duration_and_timed.sql. REFERENCE ONLY: used for id exclusion +
# DB-wide collision validation. NOT emitted by 0007 (0004 owns these rows;
# they are modality='timed'/unit='sec' and 0007 must not restate them stale).
PRIOR_SEEDED_0004 = [
    ("ex_plank", "Plank", "core", '["shoulders"]', "timed", "sec", '["plank","front plank","rkc plank"]'),
    ("ex_side_plank", "Side Plank", "core", '["obliques"]', "timed", "sec", '["side plank"]'),
    ("ex_hollow", "Hollow Hold", "core", '[]', "timed", "sec", '["hollow hold","hollow body"]'),
    ("ex_dead_hang", "Dead Hang", "back", '["grip"]', "timed", "sec", '["dead hang","bar hang"]'),
    ("ex_wall_sit", "Wall Sit", "quads", '[]', "timed", "sec", '["wall sit"]'),
]

# Conventional alias appended to the EXISTING 0002 row ex_db_press via an
# idempotent UPDATE in 0007 (NOT a new row). "db press" is already a 0002
# alias; "dumbbell press" is added so it routes to the bench press rather
# than the new ex_db_ohp (dumbbell shoulder press).
DB_PRESS_ALIAS_ADD = "dumbbell press"

# free-exercise-db primaryMuscles -> app volume-grouping vocabulary.
MUSCLE_MAP = {
    "quadriceps": "quads",
    "hamstrings": "hamstrings",
    "glutes": "glutes",
    "chest": "chest",
    "lats": "back",
    "middle back": "back",
    "lower back": "back",
    "shoulders": "shoulders",
    "traps": "traps",
    "biceps": "biceps",
    "triceps": "triceps",
    "calves": "calves",
    "abdominals": "core",
    "forearms": "forearms",
}
# secondary muscle normalization (kept close to the original 12's vocab).
SECONDARY_MAP = {
    "quadriceps": "quads",
    "hamstrings": "hamstrings",
    "glutes": "glutes",
    "chest": "chest",
    "lats": "back",
    "middle back": "back",
    "lower back": "back",
    "shoulders": "shoulders",
    "traps": "traps",
    "biceps": "biceps",
    "triceps": "triceps",
    "calves": "calves",
    "abdominals": "core",
    "forearms": "forearms",
}

# Per-id modality override for entries whose source equipment doesn't map
# cleanly onto the app's 4 modalities.
MODALITY_OVERRIDE = {
    "ex_goblet_squat": "dumbbell",
}

EQUIP_MODALITY = {
    "barbell": "barbell",
    "e-z curl bar": "barbell",
    "dumbbell": "dumbbell",
    "machine": "machine",
    "cable": "machine",
    "body only": "bw",
    None: "bw",
}

# Curated allowlist. Each entry:
#   source name : (stable_id, override_display_name_or_None, extra_aliases[])
# The id is hand-stabilized (ex_<snake>). override name only where the source
# string reads awkwardly. extra_aliases are conversational forms; the script
# also auto-derives a lowercased-name alias and dedups/validates collisions.
CURATED = {
    # ---- quads / squat pattern ----
    # NB: Back Squat / Front Squat / (Incline) Bench / Conventional DL / RDL /
    # OHP / Barbell Row / Pull-Up / DB Bench / Lat Pulldown / Leg Press are
    # owned by the ORIGINAL_12 and intentionally NOT re-sourced here.
    # Goblet Squat: source equipment is 'kettlebells'; the app has no
    # kettlebell modality so it is programmed as dumbbell (MODALITY_OVERRIDE).
    "Goblet Squat": ("ex_goblet_squat", None, ["goblet"]),
    "Dumbbell Squat": ("ex_db_squat", None, ["dumbbell squat"]),
    "Hack Squat": ("ex_hack_squat", None, ["hack squat"]),
    "Bodyweight Squat": ("ex_bw_squat", None, ["bodyweight squat", "air squat"]),
    "Box Squat": ("ex_box_squat", None, ["box squat"]),
    "Overhead Squat": ("ex_ohs", None, ["overhead squat", "ohs"]),
    "Barbell Lunge": ("ex_bb_lunge", None, ["barbell lunge"]),
    "Dumbbell Lunges": ("ex_db_lunge", "Dumbbell Lunge", ["dumbbell lunge", "db lunge"]),
    "Bodyweight Walking Lunge": ("ex_bw_lunge", None, ["walking lunge", "bodyweight lunge"]),
    "Barbell Walking Lunge": ("ex_bb_walking_lunge", None, ["barbell walking lunge"]),
    "Dumbbell Rear Lunge": ("ex_db_reverse_lunge", "Dumbbell Reverse Lunge", ["reverse lunge", "db reverse lunge"]),
    "Split Squat with Dumbbells": ("ex_db_split_squat", "Dumbbell Bulgarian Split Squat", ["bulgarian split squat", "split squat", "rfess"]),
    "Dumbbell Step Ups": ("ex_db_step_up", "Dumbbell Step-Up", ["step up", "step-up", "db step up"]),
    "Barbell Step Ups": ("ex_bb_step_up", "Barbell Step-Up", ["barbell step up"]),
    "Leg Extensions": ("ex_leg_extension", "Leg Extension", ["leg extension", "leg extensions", "quad extension"]),

    # ---- hamstrings / posterior chain ----
    "Lying Leg Curls": ("ex_lying_leg_curl", "Lying Leg Curl", ["leg curl", "lying leg curl", "hamstring curl"]),
    "Seated Leg Curl": ("ex_seated_leg_curl", None, ["seated leg curl"]),
    "Standing Leg Curl": ("ex_standing_leg_curl", None, ["standing leg curl"]),
    "Stiff-Legged Barbell Deadlift": ("ex_stiff_leg_dl", "Stiff-Legged Deadlift", ["stiff leg deadlift", "sldl", "stiff legged deadlift"]),
    "Stiff-Legged Dumbbell Deadlift": ("ex_db_rdl", "Dumbbell Romanian Deadlift", ["dumbbell rdl", "db rdl", "dumbbell romanian deadlift"]),
    "Sumo Deadlift": ("ex_sumo_dl", None, ["sumo deadlift", "sumo dl"]),
    "Good Morning": ("ex_good_morning", None, ["good morning", "good mornings"]),
    "Glute Ham Raise": ("ex_ghr", None, ["ghr", "glute ham raise", "glute-ham raise"]),
    "Rack Pulls": ("ex_rack_pull", "Rack Pull", ["rack pull", "rack pulls"]),
    "Deficit Deadlift": ("ex_deficit_dl", None, ["deficit deadlift"]),

    # ---- glutes ----
    "Barbell Hip Thrust": ("ex_hip_thrust", "Hip Thrust", ["hip thrust", "hip thrusts"]),
    "Barbell Glute Bridge": ("ex_glute_bridge", "Glute Bridge", ["glute bridge"]),
    "Single Leg Glute Bridge": ("ex_sl_glute_bridge", "Single-Leg Glute Bridge", ["single leg glute bridge"]),
    "Glute Kickback": ("ex_glute_kickback", None, ["glute kickback", "donkey kick"]),
    "One-Legged Cable Kickback": ("ex_cable_kickback", "Cable Glute Kickback", ["cable kickback"]),
    "Pull Through": ("ex_pull_through", "Cable Pull-Through", ["pull through", "cable pull through"]),

    # ---- calves ----
    "Standing Calf Raises": ("ex_standing_calf_raise", "Standing Calf Raise", ["calf raise", "standing calf raise", "calf raises"]),
    "Seated Calf Raise": ("ex_seated_calf_raise", None, ["seated calf raise"]),
    "Calf Press": ("ex_calf_press", None, ["calf press"]),
    "Standing Dumbbell Calf Raise": ("ex_db_calf_raise", "Dumbbell Calf Raise", ["dumbbell calf raise"]),
    "Standing Barbell Calf Raise": ("ex_bb_calf_raise", "Barbell Calf Raise", ["barbell calf raise"]),

    # ---- chest ---- (Bench / Incline Bench / DB Bench owned by ORIGINAL_12)
    "Decline Barbell Bench Press": ("ex_decline_bench", None, ["decline bench", "decline bench press"]),
    "Incline Dumbbell Press": ("ex_incline_db_press", None, ["incline dumbbell press", "incline db press", "incline db bench"]),
    "Decline Dumbbell Bench Press": ("ex_decline_db_press", "Decline Dumbbell Bench Press", ["decline dumbbell press", "decline db bench"]),
    "Dumbbell Flyes": ("ex_db_fly", "Dumbbell Fly", ["dumbbell fly", "db fly", "dumbbell flyes", "chest fly"]),
    "Incline Dumbbell Flyes": ("ex_incline_db_fly", "Incline Dumbbell Fly", ["incline dumbbell fly", "incline db fly"]),
    "Cable Crossover": ("ex_cable_crossover", None, ["cable crossover", "cable crossovers"]),
    "Low Cable Crossover": ("ex_low_cable_crossover", None, ["low cable crossover"]),
    "Machine Bench Press": ("ex_machine_chest_press", "Machine Chest Press", ["machine chest press", "machine bench press", "chest press"]),
    "Leverage Incline Chest Press": ("ex_machine_incline_press", "Machine Incline Press", ["machine incline press"]),
    "Pushups": ("ex_pushup", "Push-Up", ["pushup", "push up", "push-up", "press up", "press-up"]),
    "Incline Push-Up": ("ex_incline_pushup", None, ["incline pushup", "incline push up", "incline push-up"]),
    "Decline Push-Up": ("ex_decline_pushup", None, ["decline pushup", "decline push up"]),
    "Push-Ups With Feet Elevated": ("ex_feet_elevated_pushup", "Feet-Elevated Push-Up", ["feet elevated pushup"]),
    "Straight-Arm Dumbbell Pullover": ("ex_db_pullover", "Dumbbell Pullover", ["dumbbell pullover", "db pullover", "pullover"]),

    # ---- back / lats / rows ----
    "Bent Over Two-Dumbbell Row": ("ex_db_row_two", "Two-Arm Dumbbell Row", ["two arm dumbbell row", "bent over dumbbell row"]),
    "One-Arm Dumbbell Row": ("ex_one_arm_db_row", None, ["one arm dumbbell row", "single arm row", "db row", "dumbbell row"]),
    "Seated Cable Rows": ("ex_seated_cable_row", "Seated Cable Row", ["seated cable row", "cable row", "seated row"]),
    "T-Bar Row with Handle": ("ex_tbar_row", "T-Bar Row", ["t-bar row", "t bar row", "tbar row"]),
    "Inverted Row": ("ex_inverted_row", None, ["inverted row", "bodyweight row", "australian pullup"]),
    "Wide-Grip Lat Pulldown": ("ex_wide_pulldown", "Wide-Grip Lat Pulldown", ["wide grip pulldown", "wide pulldown"]),
    "Close-Grip Front Lat Pulldown": ("ex_close_pulldown", "Close-Grip Lat Pulldown", ["close grip pulldown", "close pulldown"]),
    "Straight-Arm Pulldown": ("ex_straight_arm_pulldown", None, ["straight arm pulldown", "straight-arm pulldown"]),
    "Chin-Up": ("ex_chinup", None, ["chinup", "chin-up", "underhand pullup"]),
    "V-Bar Pullup": ("ex_neutral_pullup", "Neutral-Grip Pull-Up", ["neutral grip pullup", "v-bar pullup", "neutral pullup"]),
    "Reverse Grip Bent-Over Rows": ("ex_reverse_grip_row", "Reverse-Grip Barbell Row", ["reverse grip row", "underhand row", "yates row"]),
    "Smith Machine Bent Over Row": ("ex_smith_row", "Smith Machine Row", ["smith machine row", "smith row"]),

    # ---- traps ----
    "Barbell Shrug": ("ex_bb_shrug", "Barbell Shrug", ["barbell shrug", "shrug", "shrugs"]),
    "Dumbbell Shrug": ("ex_db_shrug", None, ["dumbbell shrug", "db shrug"]),
    "Cable Shrugs": ("ex_cable_shrug", "Cable Shrug", ["cable shrug"]),
    "Upright Barbell Row": ("ex_upright_row", "Upright Row", ["upright row", "barbell upright row"]),
    "Face Pull": ("ex_face_pull", None, ["face pull", "face pulls"]),

    # ---- shoulders ----
    # BLOCKER fix: "dumbbell press" REMOVED -- it is ambiguous with the
    # original ex_db_press (Dumbbell Bench Press) and resolveExercise has no
    # ORDER BY (LIMIT 1), so it could misroute. ex_db_ohp keeps only
    # unambiguous shoulder-press aliases; "dumbbell press"/"db press" route
    # to ex_db_press (0002 + the DB_PRESS_ALIAS_ADD UPDATE). NB: "seated
    # dumbbell press" is owned by ex_seated_db_press, so it is intentionally
    # NOT added here (would collide).
    "Standing Dumbbell Press": ("ex_db_ohp", "Dumbbell Shoulder Press", ["dumbbell shoulder press", "db shoulder press", "db ohp"]),
    "Seated Dumbbell Press": ("ex_seated_db_press", "Seated Dumbbell Press", ["seated dumbbell press", "seated db press"]),
    "Arnold Dumbbell Press": ("ex_arnold_press", "Arnold Press", ["arnold press", "arnold"]),
    "Push Press": ("ex_push_press", None, ["push press"]),
    "Side Lateral Raise": ("ex_lateral_raise", "Dumbbell Lateral Raise", ["lateral raise", "side lateral raise", "lat raise", "side raise"]),
    "Cable Seated Lateral Raise": ("ex_cable_lateral_raise", "Cable Lateral Raise", ["cable lateral raise"]),
    "Front Dumbbell Raise": ("ex_front_raise", "Dumbbell Front Raise", ["front raise", "front raises"]),
    "Reverse Flyes": ("ex_reverse_fly", "Dumbbell Reverse Fly", ["reverse fly", "rear delt fly", "reverse flyes", "rear delt flye"]),
    "Reverse Machine Flyes": ("ex_machine_reverse_fly", "Machine Reverse Fly", ["machine reverse fly", "reverse pec deck"]),
    "Machine Shoulder (Military) Press": ("ex_machine_shoulder_press", "Machine Shoulder Press", ["machine shoulder press"]),
    "Cable Rear Delt Fly": ("ex_cable_rear_delt_fly", None, ["cable rear delt fly"]),
    "Handstand Push-Ups": ("ex_hspu", "Handstand Push-Up", ["handstand pushup", "hspu", "handstand push up"]),
    "Seated Barbell Military Press": ("ex_seated_bb_press", "Seated Barbell Press", ["seated barbell press", "seated military press"]),

    # ---- biceps ----
    "Barbell Curl": ("ex_bb_curl", None, ["barbell curl", "bb curl", "bicep curl", "biceps curl"]),
    "Dumbbell Bicep Curl": ("ex_db_curl", "Dumbbell Curl", ["dumbbell curl", "db curl", "dumbbell bicep curl"]),
    "Hammer Curls": ("ex_hammer_curl", "Hammer Curl", ["hammer curl", "hammer curls", "hammers"]),
    "Incline Dumbbell Curl": ("ex_incline_db_curl", None, ["incline dumbbell curl", "incline curl", "incline db curl"]),
    "Preacher Curl": ("ex_preacher_curl", None, ["preacher curl", "preacher curls"]),
    "Concentration Curls": ("ex_concentration_curl", "Concentration Curl", ["concentration curl", "concentration curls"]),
    "EZ-Bar Curl": ("ex_ez_curl", None, ["ez bar curl", "ez-bar curl", "ez curl"]),
    "Cable Hammer Curls - Rope Attachment": ("ex_cable_curl", "Cable Curl", ["cable curl", "cable bicep curl"]),
    "Spider Curl": ("ex_spider_curl", None, ["spider curl", "spider curls"]),
    "Reverse Barbell Curl": ("ex_reverse_curl", "Reverse Curl", ["reverse curl", "reverse barbell curl"]),

    # ---- triceps ----
    "Triceps Pushdown": ("ex_tricep_pushdown", "Triceps Pushdown", ["tricep pushdown", "pushdown", "triceps pushdown", "tricep pressdown"]),
    "Triceps Pushdown - Rope Attachment": ("ex_rope_pushdown", "Rope Triceps Pushdown", ["rope pushdown", "rope tricep pushdown"]),
    "Close-Grip Barbell Bench Press": ("ex_cgbp", "Close-Grip Bench Press", ["close grip bench", "cgbp", "close-grip bench press"]),
    "EZ-Bar Skullcrusher": ("ex_skullcrusher", "Skullcrusher", ["skullcrusher", "skull crusher", "lying tricep extension"]),
    "Dips - Triceps Version": ("ex_dips", "Dips", ["dip", "dips", "tricep dip", "tricep dips", "chest dip", "parallel bar dip"]),
    "Bench Dips": ("ex_bench_dips", "Bench Dip", ["bench dip", "bench dips"]),
    "Cable Rope Overhead Triceps Extension": ("ex_overhead_tricep_ext", "Cable Overhead Triceps Extension", ["overhead tricep extension", "overhead triceps extension", "tricep extension"]),
    "Standing Dumbbell Triceps Extension": ("ex_db_overhead_ext", "Dumbbell Overhead Triceps Extension", ["dumbbell overhead extension", "db tricep extension"]),
    "Tricep Dumbbell Kickback": ("ex_tricep_kickback", "Triceps Kickback", ["tricep kickback", "triceps kickback", "kickback"]),
    "Machine Triceps Extension": ("ex_machine_tricep_ext", "Machine Triceps Extension", ["machine tricep extension"]),
    "Dip Machine": ("ex_machine_dip", "Machine Dip", ["machine dip", "assisted dip"]),

    # ---- core ----
    "Plank": ("ex_plank", None, ["plank", "front plank"]),
    "Side Bridge": ("ex_side_plank", "Side Plank", ["side plank", "side bridge"]),
    "Hanging Leg Raise": ("ex_hanging_leg_raise", None, ["hanging leg raise", "hanging leg raises", "leg raise"]),
    "Cable Crunch": ("ex_cable_crunch", None, ["cable crunch", "cable crunches"]),
    "Crunches": ("ex_crunch", "Crunch", ["crunch", "crunches"]),
    "Sit-Up": ("ex_situp", "Sit-Up", ["situp", "sit up", "sit-up", "situps"]),
    "Russian Twist": ("ex_russian_twist", None, ["russian twist", "russian twists"]),
    "Reverse Crunch": ("ex_reverse_crunch", None, ["reverse crunch", "reverse crunches"]),
    "Pallof Press": ("ex_pallof_press", None, ["pallof press", "pallof"]),
    "Standing Cable Wood Chop": ("ex_woodchop", "Cable Woodchop", ["woodchop", "wood chop", "cable woodchop"]),
    "Dead Bug": ("ex_dead_bug", None, ["dead bug", "deadbug"]),

    # ---- forearms ----
    "Palms-Up Barbell Wrist Curl Over A Bench": ("ex_wrist_curl", "Barbell Wrist Curl", ["wrist curl", "wrist curls", "barbell wrist curl"]),
    "Seated Palms-Down Barbell Wrist Curl": ("ex_reverse_wrist_curl", "Barbell Reverse Wrist Curl", ["reverse wrist curl", "wrist extension"]),
}

# A handful of curated movements that are great programming staples but whose
# free-exercise-db entry sits under an excluded equipment bucket ('other'); we
# whitelist them explicitly with synthetic field values.
MANUAL_EXTRA = [
    # id, name, primary, secondary_json, modality, aliases extra (+ name)
    ("ex_ab_wheel", "Ab Wheel Rollout", "core", '["shoulders","back"]', "bw",
     ["ab wheel", "ab rollout", "ab wheel rollout", "ab roller"]),
    ("ex_sissy_squat", "Sissy Squat", "quads", '[]', "bw",
     ["sissy squat"]),
]


def sql_str(s: str) -> str:
    return "'" + s.replace("'", "''") + "'"


def main() -> int:
    src_path = sys.argv[1] if len(sys.argv) > 1 else "/tmp/free-exercise-db.json"
    data = json.load(open(src_path))
    by_name = {x["name"]: x for x in data}

    # Ids already inserted by an EARLIER migration. 0007 must NOT restate or
    # collide with any of these (strictly additive).
    prior_rows = []
    for (eid, name, pm, sec, mod, unit, al) in ORIGINAL_12:
        # mirror the idempotent UPDATE 0007 emits: ex_db_press gains the
        # conventional alias "dumbbell press" so collision validation sees
        # the post-migration alias set.
        if eid == "ex_db_press":
            cur = json.loads(al)
            if DB_PRESS_ALIAS_ADD not in cur:
                cur.append(DB_PRESS_ALIAS_ADD)
            al = json.dumps(cur)
        prior_rows.append((eid, name, pm, sec, mod, unit, al))
    for r in PRIOR_SEEDED_0004:
        prior_rows.append(r)
    prior_ids = {r[0] for r in prior_rows}

    rows = []  # net-new rows ONLY (id,name,primary,sec,mod,unit,aliases)
    seen_ids = set()

    # 1) curated, mapped from source -- skip anything an earlier migration
    #    already owns.
    for src_name, (eid, override, extra) in CURATED.items():
        if eid in prior_ids:
            # owned/frozen by 0002 or 0004 (e.g. ex_plank, ex_side_plank);
            # do not restate -- the existing row's definition survives.
            continue
        ex = by_name.get(src_name)
        if ex is None:
            # source name not present (e.g. pruned variant); skip silently.
            continue
        pm_src = (ex.get("primaryMuscles") or [None])[0]
        pm = MUSCLE_MAP.get(pm_src)
        if pm is None:
            continue
        sec = []
        for m in ex.get("secondaryMuscles") or []:
            mm = SECONDARY_MAP.get(m)
            if mm and mm != pm and mm not in sec:
                sec.append(mm)
        modality = MODALITY_OVERRIDE.get(
            eid, EQUIP_MODALITY.get(ex.get("equipment"), "bw"))
        name = override or ex["name"]
        if eid in seen_ids:
            raise SystemExit(f"duplicate id {eid} for {src_name}")
        seen_ids.add(eid)
        aliases = list(dict.fromkeys([name.lower()] + list(extra)))
        rows.append((eid, name, pm, json.dumps(sec), modality, "lb",
                     json.dumps(aliases)))

    # 2) manual extras
    for (eid, name, pm, sec_json, mod, extra) in MANUAL_EXTRA:
        if eid in prior_ids:
            continue
        if eid in seen_ids:
            raise SystemExit(f"duplicate manual id {eid}")
        seen_ids.add(eid)
        aliases = list(dict.fromkeys([name.lower()] + list(extra)))
        rows.append((eid, name, pm, sec_json, mod, "lb", json.dumps(aliases)))

    # additive-only invariant: zero id overlap with prior migrations.
    overlap = seen_ids & prior_ids
    if overlap:
        raise SystemExit(f"0007 id overlap with prior migrations: {overlap}")

    # ---- collision validation (resolver determinism), DB-WIDE -------------
    # The resolver matches: id, lower(name) exact, or lower(aliases) LIKE
    # '%"<q>"%', LIMIT 1, no ORDER BY. Determinism must hold across the WHOLE
    # post-0007 catalog (prior migrations' rows + the net-new rows), not just
    # 0007's own rows. So validate over prior_rows + rows: (a) no two
    # exercises share an alias token; (b) no alias token equals another
    # exercise's canonical lower(name); (c) ids unique; (d) names unique.
    all_rows = prior_rows + rows
    alias_owner = {}
    name_owner = {}
    for (eid, name, pm, sec, mod, unit, al) in all_rows:
        nlc = name.lower()
        if nlc in name_owner and name_owner[nlc] != eid:
            raise SystemExit(f"duplicate canonical name: {name!r}")
        name_owner[nlc] = eid
    for (eid, name, pm, sec, mod, unit, al) in all_rows:
        for a in json.loads(al):
            a = a.lower()
            if a in alias_owner and alias_owner[a] != eid:
                raise SystemExit(
                    f"alias collision {a!r}: {alias_owner[a]} vs {eid}")
            alias_owner[a] = eid
    for a in alias_owner:
        owner = alias_owner[a]
        if a in name_owner and name_owner[a] != owner:
            raise SystemExit(
                f"alias {a!r} (owned by {owner}) shadows canonical name "
                f"of {name_owner[a]}")

    # ---- emit SQL ---------------------------------------------------------
    out = []
    out.append("-- 0007_seed_exercises_expanded.sql")
    out.append("-- GENERATED by scripts/build_exercise_seed.py from")
    out.append("-- free-exercise-db (github.com/yuhonas/free-exercise-db,")
    out.append("-- public domain / Unlicense). Raw dump + images are a")
    out.append("-- one-time generation input and are NOT committed.")
    out.append("--")
    out.append("-- Curation: foundational compound lifts + commonly-")
    out.append("-- programmed accessories across ALL major muscle groups")
    out.append("-- (quads/hams/glutes/chest/back/shoulders/traps/biceps/")
    out.append("-- triceps/calves/core/forearms) and ALL modalities")
    out.append("-- (barbell/dumbbell/machine/cable->machine/bw incl. the")
    out.append("-- bodyweight staples push-up, plank, dips, BW squat/lunge,")
    out.append("-- chin-up, inverted row, hanging leg raise) and the")
    out.append("-- barbell glute bridge (barbell).")
    out.append("-- Excluded: near-duplicate grip/stance/Smith variants,")
    out.append("-- behind-the-neck, novelty/circus, band/ball/foam-only,")
    out.append("-- kettlebell flows, stretching/cardio/plyo-only.")
    out.append("--")
    out.append("-- STRICTLY ADDITIVE + IDEMPOTENT. 0007 inserts ONLY the")
    out.append("-- net-new exercises -- ids NOT already seeded by ANY earlier")
    out.append("-- migration. It does NOT restate the original 12 (0002) nor")
    out.append("-- the 5 timed core/hold exercises (0004: ex_plank,")
    out.append("-- ex_side_plank, ex_hollow, ex_dead_hang, ex_wall_sit) --")
    out.append("-- those rows are owned + frozen by their own migrations and")
    out.append("-- keep their original definitions (e.g. plank stays")
    out.append("-- modality='timed'/unit='sec'). Zero id overlap with")
    out.append("-- 0002/0004. INSERT OR IGNORE on the UUID PK keeps re-runs")
    out.append("-- a no-op. created_at = 0 (epoch): seed rows are timeless.")
    out.append("--")
    out.append("-- Plus ONE idempotent UPDATE: appends the conventional")
    out.append("-- alias \"dumbbell press\" to the EXISTING 0002 row")
    out.append("-- ex_db_press (Dumbbell Bench Press) so that phrase resolves")
    out.append("-- to the bench press, not the new dumbbell shoulder press.")
    out.append("-- Additive (alias-only mutation, no row add/delete) and")
    out.append("-- idempotent (writes the identical literal each run).")
    out.append("INSERT OR IGNORE INTO exercises")
    out.append("  (id, name, primary_muscle, secondary_muscles, modality, unit, aliases, created_at)")
    out.append("VALUES")
    lines = []
    for (eid, name, pm, sec, mod, unit, al) in rows:
        lines.append(
            f"  ({sql_str(eid)}, {sql_str(name)}, {sql_str(pm)}, "
            f"{sql_str(sec)}, {sql_str(mod)}, {sql_str(unit)}, "
            f"{sql_str(al)}, 0)")
    out.append(",\n".join(lines) + ";")
    out.append("")
    # Idempotent alias augmentation of the existing 0002 ex_db_press row.
    db_press_al = None
    for (eid, name, pm, sec, mod, unit, al) in ORIGINAL_12:
        if eid == "ex_db_press":
            cur = json.loads(al)
            if DB_PRESS_ALIAS_ADD not in cur:
                cur.append(DB_PRESS_ALIAS_ADD)
            db_press_al = json.dumps(cur)
    out.append("-- Conventional-alias backfill for the existing 0002 row.")
    out.append("-- Idempotent: sets the exact target literal regardless of")
    out.append("-- current value, so re-running is a no-op.")
    out.append(
        f"UPDATE exercises SET aliases = {sql_str(db_press_al)} "
        "WHERE id = 'ex_db_press';")
    out.append("")
    sys.stdout.write("\n".join(out))
    sys.stderr.write(
        f"emitted {len(rows)} net-new rows (zero overlap with "
        f"{len(prior_ids)} prior-seeded ids: 12 from 0002 + 5 from 0004) "
        f"+ 1 idempotent ex_db_press alias UPDATE\n")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
