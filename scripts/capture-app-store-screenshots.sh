#!/usr/bin/env bash
# Capture fictional data through real app screens. No provider or ASC writes.
set -euo pipefail
repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
output="${1:-$repo_root/.artifacts/app-store-screenshots}"
if [[ $# -gt 1 || -e "$output" ]]; then
  echo 'Usage: capture-app-store-screenshots.sh [new-output-directory]' >&2
  echo 'Choose a new directory; existing screenshots are never overwritten.' >&2
  exit 2
fi
scratch="$(mktemp -d "${TMPDIR:-/tmp}/tres-fort-app-store-capture.XXXXXX")"
trap 'rm -rf "$scratch"' EXIT
python3 - "$repo_root" "$scratch/source-identity.json" <<'PY'
import json, pathlib, subprocess, sys
def git(*args):
    return subprocess.check_output(['git', '-C', sys.argv[1], *args], text=True).strip()
pathlib.Path(sys.argv[2]).write_text(json.dumps({
    'source_head': git('rev-parse', 'HEAD'),
    'source_tree': git('rev-parse', 'HEAD^{tree}'),
    'working_tree_changes': git('status', '--porcelain')}))
PY
if ! APP_STORE_IPHONE_ONLY=1 IOS_KEEP_RESULTS=1 IOS_EVIDENCE_DIR="$scratch/results" \
  bash "$repo_root/scripts/verify-ios.sh" \
    --runtime com.apple.CoreSimulator.SimRuntime.iOS-26-2 \
    --device com.apple.CoreSimulator.SimDeviceType.iPhone-17-Pro \
    --only-testing TresFortUITests/AppStoreScreenshotTests >"$scratch/verify.log" 2>&1; then
  cat "$scratch/verify.log" >&2
  # Retain failure evidence at the requested new location before cleaning the
  # owned staging directory. The simulator/build cleanup belongs to verify-ios.
  mkdir -p "$(dirname "$output")"
  mkdir "$output"
  if [[ -d "$scratch/results" ]]; then cp -R "$scratch/results" "$output/failed-results"; fi
  cp "$scratch/verify.log" "$output/verify.log"
  exit 1
fi
bundles=("$scratch"/results/*/Tests.xcresult)
[[ ${#bundles[@]} -eq 1 && -d "${bundles[0]}" ]] || { echo 'Missing unique test result' >&2; exit 1; }
evidence="$(dirname "${bundles[0]}")"
xcrun xcresulttool export attachments --path "${bundles[0]}" \
  --output-path "$scratch/attachments" --test-id AppStoreScreenshotTests
python3 -B - "$repo_root" "$evidence" "$scratch/attachments" "$output" "$scratch/source-identity.json" <<'PY'
import datetime, hashlib, json, pathlib, re, shutil, subprocess, sys
repo, evidence, attachments, output, identity_path = map(pathlib.Path, sys.argv[1:])
sys.path.insert(0, str(repo / 'scripts'))
from ios_sources import require_unchanged_sources
from app_store_assets import require, validate_png
sources = json.loads((evidence / 'sources.json').read_text())
require_unchanged_sources(repo / 'ios', sources)
images = {}
for test in json.loads((attachments / 'manifest.json').read_text()):
    for item in test['attachments']:
        match = re.match(r'app-store-(\d{2}-[a-z]+)_', item['suggestedHumanReadableName'])
        if not match:
            continue
        name = match[1] + '.png'
        require(name not in images, f'Duplicate screenshot: {name}')
        source = attachments / item['exportedFileName']
        data = source.read_bytes()
        validate_png(data)
        images[name] = (source, hashlib.sha256(data).hexdigest())
expected = {'01-today.png', '02-runner.png', '03-workouts.png', '04-history.png', '05-feedback.png'}
require(set(images) == expected, f'Wrong screenshot set: {set(images)}')
def git(*args):
    return subprocess.check_output(['git', '-C', str(repo), *args], text=True).strip()
identity = json.loads(identity_path.read_text())
require(identity == {'source_head': git('rev-parse', 'HEAD'),
                     'source_tree': git('rev-parse', 'HEAD^{tree}'),
                     'working_tree_changes': git('status', '--porcelain')},
        'Checkout identity changed during capture')
output.mkdir(parents=True, exist_ok=False)
for name, (source, _) in images.items():
    shutil.copy2(source, output / name)
shutil.copy2(evidence / 'sources.json', output / 'sources.json')
shutil.copy2(evidence / 'xcodebuild.log', output / 'capture-tests.log')
manifest = {
    'captured_at': datetime.datetime.now(datetime.timezone.utc).isoformat(),
    **identity,
    'ios_source_manifest': 'sources.json',
    'test_evidence': 'capture-tests.log',
    'device': 'iPhone 17 Pro', 'runtime': 'iOS 26.2', 'locale': 'en_US',
    'configuration': 'Debug simulator; production views with fictional, network-isolated data',
    'project_spec': 'project-app-store.yml',
    'app_store_iphone_only': True,
    'image_size': [1206, 2622], 'images': {name: digest for name, (_, digest) in sorted(images.items())},
    'status': 'Draft assets. Visually review and match to the final selected release candidate before publication.',
    'specification': 'https://developer.apple.com/help/app-store-connect/reference/app-information/screenshot-specifications/'
}
(output / 'manifest.json').write_text(json.dumps(manifest, indent=2) + '\n')
print(f'Captured five draft screenshots in {output}')
PY
