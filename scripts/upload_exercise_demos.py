#!/usr/bin/env python3
"""Upload exercise demo frames to the tres-fort-demos R2 bucket.

Reads free-exercise-db images (a one-time generation input, NOT committed),
converts each `{slug}/{0,1}.jpg` to a small webp, and uploads them to R2
under `demos/{slug}/{0,1}.webp`. The Worker's GET /api/exercises/:id/demo/:frame
route reads from this same key space.

ONE-TIME setup (not in CI):
    git clone --depth 1 https://github.com/yuhonas/free-exercise-db /tmp/fxdb
    pip install pillow
    wrangler r2 bucket create tres-fort-demos     # if not already
    python3 scripts/upload_exercise_demos.py /tmp/fxdb/exercises /tmp/fxdb/dist/exercises.json

The script:
  1. Loads exercises.json to discover the slug list backing the catalog.
  2. Walks scripts/build_demo_backfill.py + scripts/build_exercise_seed_v2.py
     to find every demo_slug the catalog references.
  3. For each referenced slug + frame: converts to webp (max 384px on the
     long edge, quality 80 — plenty for a sub-200pt iOS thumbnail), uploads
     via `wrangler r2 object put`.
  4. Skips uploads when the local cache (~/.cache/tres-fort-demos/uploaded.txt)
     records the same (slug, frame, sha256) — idempotent across re-runs.

Output: one line per slug — UPLOADED / SKIPPED / MISSING (frame not in source).
"""
import hashlib
import json
import os
import re
import shutil
import subprocess
import sys
from pathlib import Path


def referenced_slugs() -> set[str]:
    """Slugs referenced by 0020 backfill + 0021 v2 seed.

    We parse the .sql files directly (post-generation) rather than the .py
    generators so the upload reflects what actually shipped, not what the
    generator intends.
    """
    out: set[str] = set()
    sql_0020 = Path("migrations/0020_exercise_demo_slugs.sql").read_text()
    # UPDATE … SET demo_slug = '…'
    for m in re.finditer(r"SET\s+demo_slug\s*=\s*'([^']+)'", sql_0020):
        out.add(m.group(1))
    sql_0021 = Path("migrations/0021_seed_exercises_v2.sql").read_text()
    # last VALUES tuple slot is the demo_slug — match '…' immediately before )
    for m in re.finditer(r",\s*'([^']+)'\)\s*[,;]", sql_0021):
        # skip 'lb' (unit), 'unilateral' / 'bilateral' (laterality), etc.
        candidate = m.group(1)
        if candidate in {"lb", "unilateral", "bilateral", "total", "per_hand"}:
            continue
        # Slugs have underscores or '-' and at least one of either.
        if "_" in candidate or "-" in candidate:
            out.add(candidate)
    return out


def main() -> int:
    if len(sys.argv) < 2:
        print(__doc__, file=sys.stderr)
        return 2
    images_dir = Path(sys.argv[1])
    if not images_dir.is_dir():
        print(f"images dir not found: {images_dir}", file=sys.stderr)
        return 1

    try:
        from PIL import Image  # type: ignore
    except ImportError:
        print("pip install pillow", file=sys.stderr)
        return 1

    cache_dir = Path.home() / ".cache" / "tres-fort-demos"
    cache_dir.mkdir(parents=True, exist_ok=True)
    cache_file = cache_dir / "uploaded.txt"
    uploaded: dict[tuple[str, str], str] = {}  # (slug, frame) -> sha256
    if cache_file.exists():
        for line in cache_file.read_text().splitlines():
            if not line.strip():
                continue
            slug, frame, sha = line.split("\t", 2)
            uploaded[(slug, frame)] = sha

    slugs = referenced_slugs()
    print(f"catalog references {len(slugs)} demo slugs", file=sys.stderr)
    work_dir = cache_dir / "build"
    work_dir.mkdir(exist_ok=True)
    stats = {"uploaded": 0, "skipped": 0, "missing": 0}

    for slug in sorted(slugs):
        for frame in ("0", "1"):
            src = images_dir / slug / f"{frame}.jpg"
            if not src.exists():
                print(f"MISSING {slug}/{frame}.jpg (source not in dump)")
                stats["missing"] += 1
                continue
            sha = hashlib.sha256(src.read_bytes()).hexdigest()
            if uploaded.get((slug, frame)) == sha:
                print(f"SKIP    {slug}/{frame}.jpg (cached, sha unchanged)")
                stats["skipped"] += 1
                continue
            # Convert to webp at <=384px (fits a 96-128pt iOS thumbnail at @3x).
            out_path = work_dir / f"{slug}__{frame}.webp"
            with Image.open(src) as im:
                im.thumbnail((384, 384))
                im.save(out_path, "webp", quality=80, method=6)
            key = f"demos/{slug}/{frame}.webp"
            # Prefer a globally-installed `wrangler` when present, fall back
            # to `npx wrangler` (the repo's package.json pulls it in via the
            # devDependency, so this works without a global install).
            wrangler_cmd = ["wrangler"] if shutil.which("wrangler") \
                else ["npx", "--yes", "wrangler"]
            r = subprocess.run(
                wrangler_cmd + ["r2", "object", "put",
                 f"tres-fort-demos/{key}",
                 "--file", str(out_path),
                 "--content-type", "image/webp",
                 "--remote"],
                capture_output=True, text=True,
            )
            if r.returncode != 0:
                print(f"FAIL    {key}: {r.stderr.strip()}", file=sys.stderr)
                return 1
            uploaded[(slug, frame)] = sha
            print(f"UPLOAD  {key}")
            stats["uploaded"] += 1

    with cache_file.open("w") as f:
        for (slug, frame), sha in sorted(uploaded.items()):
            f.write(f"{slug}\t{frame}\t{sha}\n")
    print(
        f"\ndone: uploaded={stats['uploaded']} skipped={stats['skipped']} "
        f"missing={stats['missing']}",
        file=sys.stderr,
    )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
