#!/usr/bin/env bash
# Capture fictional data through real app screens. No provider or ASC writes.
set -euo pipefail
repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
family="${2:-iphone}"
output="${1:-$repo_root/.artifacts/app-store-screenshots-$family}"
if [[ ${APP_STORE_IPHONE_ONLY+x} ]]; then
  echo 'APP_STORE_IPHONE_ONLY is obsolete; remove it. Captures use APP_STORE_BUILD=1 for iPhone and iPad.' >&2
  exit 2
fi
case "${APP_STORE_BUILD-0}" in
  0|1) ;; # This capture command always selects the public build below.
  *) echo 'APP_STORE_BUILD must be 0 or 1.' >&2; exit 2 ;;
esac
if [[ $# -gt 2 || -e "$output" || ( "$family" != iphone && "$family" != ipad ) ]]; then
  echo 'Usage: capture-app-store-screenshots.sh [new-output-directory] [iphone|ipad]' >&2
  echo 'Choose a new directory; existing screenshots are never overwritten.' >&2
  exit 2
fi
case "$family" in
  iphone) device=com.apple.CoreSimulator.SimDeviceType.iPhone-17-Pro ;;
  ipad) device=com.apple.CoreSimulator.SimDeviceType.iPad-Pro-13-inch-M4-8GB ;;
esac
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
if ! APP_STORE_BUILD=1 IOS_KEEP_RESULTS=1 IOS_EVIDENCE_DIR="$scratch/results" \
  bash "$repo_root/scripts/verify-ios.sh" \
    --runtime com.apple.CoreSimulator.SimRuntime.iOS-26-2 \
    --device "$device" \
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
python3 -B - "$repo_root" "$evidence" "$scratch/attachments" "$output" "$scratch/source-identity.json" "$family" <<'PY'
import datetime, hashlib, json, pathlib, re, shutil, subprocess, sys
repo, evidence, attachments, output, identity_path = map(pathlib.Path, sys.argv[1:6])
family = sys.argv[6]
sys.path.insert(0, str(repo / 'scripts'))
from ios_sources import require_unchanged_sources
from app_store_assets import require, screenshot_dimensions, validate_png
sources = json.loads((evidence / 'sources.json').read_text())
require_unchanged_sources(repo / 'ios', sources)
images = {}
dimensions = screenshot_dimensions(family)
for test in json.loads((attachments / 'manifest.json').read_text()):
    for item in test['attachments']:
        match = re.match(r'app-store-(\d{2}-[a-z]+)_', item['suggestedHumanReadableName'])
        if not match:
            continue
        name = match[1] + '.png'
        require(name in dimensions, f'Unexpected {family} screenshot: {name}')
        require(name not in images, f'Duplicate screenshot: {name}')
        source = attachments / item['exportedFileName']
        data = source.read_bytes()
        validate_png(data, dimensions[name])
        images[name] = (source, hashlib.sha256(data).hexdigest())
require(set(images) == set(dimensions), f'Wrong screenshot set: {set(images)}')
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
    'device': 'iPhone 17 Pro' if family == 'iphone' else 'iPad Pro 13-inch (M4)',
    'device_family': family, 'runtime': 'iOS 26.2', 'locale': 'en_US',
    'configuration': 'Debug simulator; production views with fictional, network-isolated data',
    'project_spec': 'project-app-store.yml',
    'app_store_build': True,
    'image_dimensions': dimensions,
    'images': {name: digest for name, (_, digest) in sorted(images.items())},
    'status': 'Draft assets. Visually review and match to the final selected release candidate before publication.',
    'specification': 'https://developer.apple.com/help/app-store-connect/reference/app-information/screenshot-specifications/'
}
(output / 'manifest.json').write_text(json.dumps(manifest, indent=2) + '\n')
print(f'Captured {len(images)} draft {family} screenshots in {output}')
PY
