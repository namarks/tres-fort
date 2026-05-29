#!/usr/bin/env python3
"""Bundle ~30 foundational exercise demos into the iOS asset catalog.

DemoImageLoader looks up `{slug}__0` / `{slug}__1` via UIImage(named:) first —
any miss falls through to the Worker /api/exercises/:id/demo/:frame route
(backed by R2). This script populates the bundled set: the foundational lifts
that users do every session, so the demos work fully offline + render with
zero latency on the most common rows.

Frames are emitted as @2x .png inside per-frame .imageset directories
(`Demos/{slug}__{0|1}.imageset/`). 256px on the long edge, which is a
1024-byte-class PNG when transparent flat free-exercise-db illustrations
compress well — keeps the catalog growth ~3-5 MB across 30 lifts × 2 frames.

ONE-TIME setup (not in CI):
    git clone --depth 1 https://github.com/yuhonas/free-exercise-db /tmp/fxdb
    pip install pillow
    python3 scripts/bundle_foundational_demos.py /tmp/fxdb/exercises

Re-running is safe: existing .imageset directories are overwritten.
"""
import json
import shutil
import sys
from pathlib import Path

# ex_id -> upstream slug. The picks are: the original 12 + the most
# commonly-prescribed accessories (presses, lunges, RDLs, hip thrust, the
# barbell glute bridge, pushup, plank, dips). Together they cover ~90% of
# what shows up in a typical week's logged sessions.
FOUNDATIONAL = {
    # Original 12
    "ex_back_squat":    "Barbell_Squat",
    "ex_front_squat":   "Front_Squat_Clean_Grip",
    "ex_deadlift":      "Barbell_Deadlift",
    "ex_rdl":           "Romanian_Deadlift",
    "ex_bench":         "Barbell_Bench_Press_-_Medium_Grip",
    "ex_incline_bench": "Barbell_Incline_Bench_Press_-_Medium_Grip",
    "ex_ohp":           "Standing_Military_Press",
    "ex_barbell_row":   "Bent_Over_Barbell_Row",
    "ex_pullup":        "Pullups",
    "ex_db_press":      "Dumbbell_Bench_Press",
    "ex_lat_pulldown":  "Wide-Grip_Lat_Pulldown",
    "ex_leg_press":     "Leg_Press",
    # Foundational accessories
    "ex_db_ohp":          "Standing_Dumbbell_Press",
    "ex_seated_db_press": "Seated_Dumbbell_Press",
    "ex_incline_db_press":"Incline_Dumbbell_Press",
    "ex_one_arm_db_row":  "One-Arm_Dumbbell_Row",
    "ex_chinup":          "Chin-Up",
    "ex_dips":            "Dips_-_Triceps_Version",
    "ex_pushup":          "Pushups",
    "ex_plank":           "Plank",
    "ex_hip_thrust":      "Barbell_Hip_Thrust",
    "ex_glute_bridge":    "Barbell_Glute_Bridge",
    "ex_db_split_squat":  "Split_Squat_with_Dumbbells",
    "ex_db_lunge":        "Dumbbell_Lunges",
    "ex_db_rdl":          "Stiff-Legged_Dumbbell_Deadlift",
    "ex_bb_curl":         "Barbell_Curl",
    "ex_db_curl":         "Dumbbell_Bicep_Curl",
    "ex_hammer_curl":     "Hammer_Curls",
    "ex_tricep_pushdown": "Triceps_Pushdown",
    "ex_lateral_raise":   "Side_Lateral_Raise",
    "ex_face_pull":       "Face_Pull",
    "ex_hanging_leg_raise":"Hanging_Leg_Raise",
}


def imageset_contents() -> str:
    return json.dumps({
        "images": [
            {"idiom": "universal", "scale": "1x"},
            {"idiom": "universal", "filename": "frame.png", "scale": "2x"},
            {"idiom": "universal", "scale": "3x"},
        ],
        "info": {"author": "xcode", "version": 1},
    }, indent=2)


def main() -> int:
    if len(sys.argv) < 2:
        print(__doc__, file=sys.stderr)
        return 2
    src_dir = Path(sys.argv[1])
    if not src_dir.is_dir():
        print(f"source dir not found: {src_dir}", file=sys.stderr)
        return 1
    try:
        from PIL import Image  # type: ignore
    except ImportError:
        print("pip install pillow", file=sys.stderr)
        return 1

    out_root = Path("ios/TresFort/Assets.xcassets/Demos")
    if not out_root.is_dir():
        print(f"asset catalog dir not found: {out_root}", file=sys.stderr)
        return 1

    bundled = missing = 0
    for ex_id, slug in FOUNDATIONAL.items():
        for frame in ("0", "1"):
            src = src_dir / slug / f"{frame}.jpg"
            if not src.exists():
                print(f"MISSING {slug}/{frame}.jpg", file=sys.stderr)
                missing += 1
                continue
            iset = out_root / f"{slug}__{frame}.imageset"
            if iset.exists():
                shutil.rmtree(iset)
            iset.mkdir(parents=True)
            (iset / "Contents.json").write_text(imageset_contents())
            with Image.open(src) as im:
                im.thumbnail((256, 256))
                im.save(iset / "frame.png", "PNG", optimize=True)
            bundled += 1
            print(f"BUNDLE  {slug}__{frame}.imageset")
    print(f"\ndone: bundled={bundled} frames, missing={missing}",
          file=sys.stderr)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
