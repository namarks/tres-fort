#!/usr/bin/env python3
"""Bundle reviewed Workout Guide line drawings into the iOS asset catalog.

DemoImageLoader looks up `drawing_{exercise_id}__{0|1}` before the
free-exercise-db photos, so every exercise listed in
`scripts/exercise_drawings.json` shows a drawing offline. Exercises missing
from that file keep the existing photo path.

The mapping is explicit and reviewed by eye: a matching name alone does not
prove the same equipment or variation. `frames` lists the Workout Guide frame
numbers to ship, first frame first; the first one is the preview thumbnail and
two frames crossfade in the technique sheet. Holds ship one frame.

Each exercise's frames share one crop (the union of their figures plus a small
margin) so the crossfade does not jump.

ONE-TIME setup (not in CI):
    git clone https://github.com/bryllim/workout-guide /tmp/workout-guide
    git -C /tmp/workout-guide checkout <commit from exercise_drawings.json>
    pip install pillow
    python3 scripts/bundle_exercise_drawings.py /tmp/workout-guide

Re-running replaces the Drawings folder, so removed mappings drop their art.
"""
import json
import re
import shutil
import subprocess
import sys
from pathlib import Path

from PIL import Image

ROOT = Path(__file__).resolve().parents[1]
MAPPING = ROOT / 'scripts' / 'exercise_drawings.json'
OUT = ROOT / 'ios' / 'TresFort' / 'Assets.xcassets' / 'Drawings'
MIGRATIONS = ROOT / 'migrations'
MARGIN = 0.04  # of the crop's longer side
ALPHA_LEVELS = 32


def catalog_ids():
    text = '\n'.join(p.read_text() for p in sorted(MIGRATIONS.glob('*.sql')))
    return set(re.findall(r"'(ex_[a-z0-9_]+)'", text))


def line_art_alpha(path):
    """Every visible source pixel is white, so only alpha carries the drawing."""
    rgba = Image.open(path).convert('RGBA')
    if any(r < 250 for (r, _, _, a) in rgba.get_flattened_data() if a):
        raise SystemExit(f'{path} has non-white line art')
    return rgba.getchannel('A')


def crop_box(alphas):
    boxes = [a.getbbox() for a in alphas]
    if any(b is None for b in boxes):
        raise SystemExit('Empty drawing frame')
    left = min(b[0] for b in boxes)
    top = min(b[1] for b in boxes)
    right = max(b[2] for b in boxes)
    bottom = max(b[3] for b in boxes)
    pad = round(max(right - left, bottom - top) * MARGIN)
    width, height = alphas[0].size
    return (max(0, left - pad), max(0, top - pad),
            min(width, right + pad), min(height, bottom + pad))


def white_palette_png(alpha, path):
    """Store alpha as palette indices over an all-white palette.

    Index i is white at opacity i. Rounding opacity to 32 evenly spaced levels
    is invisible on these antialiased lines and halves the bundle size.
    """
    steps = ALPHA_LEVELS - 1
    alpha = alpha.point(lambda v: (v * steps + 127) // 255 * 255 // steps)
    image = Image.frombytes('P', alpha.size, alpha.tobytes())
    image.putpalette([255] * 768)
    image.save(path, optimize=True, transparency=bytes(range(256)))


def imageset(name, image):
    folder = OUT / f'{name}.imageset'
    folder.mkdir(parents=True)
    white_palette_png(image, folder / 'frame.png')
    contents = {
        'images': [
            {'idiom': 'universal', 'scale': '1x'},
            {'idiom': 'universal', 'filename': 'frame.png', 'scale': '2x'},
            {'idiom': 'universal', 'scale': '3x'},
        ],
        'info': {'author': 'xcode', 'version': 1},
    }
    (folder / 'Contents.json').write_text(json.dumps(contents, indent=2) + '\n')


def main(checkout):
    mapping = json.loads(MAPPING.read_text())
    source = mapping['source']
    head = subprocess.check_output(['git', '-C', str(checkout), 'rev-parse', 'HEAD'],
                                   text=True).strip()
    if head != source['commit']:
        raise SystemExit(f'Workout Guide checkout is {head}, expected {source["commit"]}')
    known = catalog_ids()
    assets = Path(checkout) / source['assets']

    if OUT.exists():
        shutil.rmtree(OUT)
    OUT.mkdir(parents=True)
    (OUT / 'Contents.json').write_text(
        json.dumps({'info': {'author': 'xcode', 'version': 1}}, indent=2) + '\n')

    for exercise_id, entry in sorted(mapping['exercises'].items()):
        if exercise_id not in known:
            raise SystemExit(f'{exercise_id} is not in the exercise catalog')
        numbers = entry['frames']
        if not 1 <= len(numbers) <= 2 or len(set(numbers)) != len(numbers):
            raise SystemExit(f'{exercise_id} must ship one or two distinct frames')
        frames = [line_art_alpha(assets / entry['drawing'] / f'frame-{n}.png')
                  for n in numbers]
        box = crop_box(frames)
        for index, frame in enumerate(frames):
            imageset(f'drawing_{exercise_id}__{index}', frame.crop(box))
    print(f'Bundled {len(mapping["exercises"])} exercise drawings into {OUT}')


if __name__ == '__main__':
    if len(sys.argv) != 2:
        raise SystemExit(__doc__)
    main(sys.argv[1])
