#!/usr/bin/env bash
# Build and test an unsigned copy. Never reuse a person's simulator or keychain.
set -euo pipefail
repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
usage() {
  echo 'Usage: npm run ios:verify -- --runtime RUNTIME --device DEVICE [--ui-suite full|smoke] [--ci-shard 1|2] [--only-testing Target[/Class[/method]]] [--content-size SIZE]'
}
runtime=''
device=''
content_size=''
ci_shard=''
ui_suite='full'
test_args=()
while [[ $# -gt 0 ]]; do
  case "$1" in
    --runtime|--device|--only-testing|--content-size|--ci-shard|--ui-suite)
      [[ $# -ge 2 && -n "$2" && "$2" != --* ]] || { usage >&2; exit 2; }
      case "$1" in
        --runtime) runtime="$2" ;;
        --device) device="$2" ;;
        --content-size) content_size="$2" ;;
        --ci-shard) ci_shard="$2" ;;
        --ui-suite) ui_suite="$2" ;;
        --only-testing) test_args+=("-only-testing:$2") ;;
      esac
      shift 2 ;;
    --help|-h) usage; exit 0 ;;
    *) usage >&2; exit 2 ;;
  esac
done
[[ -n "$runtime" && -n "$device" ]] || { usage >&2; exit 2; }
[[ "$ui_suite" == full || "$ui_suite" == smoke ]] || { usage >&2; exit 2; }
if [[ -n "$ci_shard" ]]; then
  [[ "$ci_shard" == 1 || "$ci_shard" == 2 ]] || { usage >&2; exit 2; }
fi
if [[ -n "$ci_shard" || "$ui_suite" == smoke ]]; then
  [[ ${#test_args[@]} -eq 0 ]] || { echo 'CI selection cannot be combined with --only-testing' >&2; exit 2; }
fi
if [[ "$ui_suite" == smoke ]]; then
  if [[ "$ci_shard" != 2 ]]; then
    test_args+=("-only-testing:TresFortTests")
    test_args+=("-only-testing:TresFortUITests/WorkoutFeedbackJourneyTests")
    test_args+=("-only-testing:TresFortUITests/MemberActivationJourneyTests")
    test_args+=("-only-testing:TresFortUITests/PlanChangeJourneyTests")
    test_args+=("-only-testing:TresFortUITests/CoachingContextJourneyTests")
    for method in testVerifiedEmptyPlanCanCreateRoutineAndFirstWorkout \
      testOrdinarySetLogsAndCompletesThroughAcknowledgement \
      testSwapExerciseMidWorkoutPreservesCompletedSetAndRoutine \
      testCorrectionRecoveryRemainsReachable testWeightEntryAndKeyboardCanSaveExactLoad; do
      test_args+=("-only-testing:TresFortUITests/TrainingJourneyTests/$method")
    done
  fi
  if [[ "$ci_shard" != 1 ]]; then
    test_args+=("-only-testing:TresFortUITests/TodayNavigationJourneyTests")
    test_args+=("-only-testing:TresFortUITests/UIActionJourneyTests")
    test_args+=("-only-testing:TresFortUITests/WorkoutLibraryJourneyTests")
    test_args+=("-only-testing:TresFortUITests/IntervalsConnectionJourneyTests")
    test_args+=("-only-testing:TresFortUITests/GroupSafetyJourneyTests")
    test_args+=("-only-testing:TresFortUITests/ExerciseGroupJourneyTests/testAuthorWarmupAndWorkingSupersetThenRunAlternatingRounds")
  fi
elif [[ -n "$ci_shard" ]]; then
  # Shard 1 runs the complement, so new tests automatically remain covered.
  for suite in HistoryJourneyTests ExerciseGroupJourneyTests; do
    if [[ "$ci_shard" == 1 ]]; then
      test_args+=("-skip-testing:TresFortUITests/$suite")
    else
      test_args+=("-only-testing:TresFortUITests/$suite")
    fi
  done
fi
for tool in xcodegen xcodebuild xcrun python3; do
  command -v "$tool" >/dev/null || { echo "Required tool missing: $tool" >&2; exit 1; }
done

scratch="$(mktemp -d "${TMPDIR:-/tmp}/tres-fort-ios.XXXXXX")"
simulator=''
evidence_root="${IOS_EVIDENCE_DIR:-$repo_root/.artifacts/ios}"
cleanup() {
  result=$?
  trap - EXIT
  if [[ -n "$simulator" ]]; then
    xcrun simctl shutdown "$simulator" >>"$scratch/cleanup.log" 2>&1 || true
    if ! xcrun simctl delete "$simulator" >>"$scratch/cleanup.log" 2>&1; then
      echo "Could not delete verification simulator $simulator; see cleanup.log" >&2
      result=1
    fi
  fi
  # Retain logs and the result bundle (including synthetic UI screenshots).
  # DerivedData, copied sources, and simulator data never become artifacts.
  if [[ "$result" -ne 0 || "${IOS_KEEP_RESULTS:-0}" == 1 ]]; then
    evidence="$evidence_root/$(basename "$scratch")"
    if mkdir -p "$evidence"; then
      for path in "$scratch"/*.log "$scratch"/*.json "$scratch"/*.xcresult; do
        if [[ -e "$path" ]] && ! cp -R "$path" "$evidence/"; then result=1; fi
      done
      echo "iOS verification evidence: $evidence"
    else
      echo "Could not retain verification evidence at $evidence" >&2
      result=1
    fi
  fi
  rm -rf "$scratch"
  exit "$result"
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

xcrun simctl list runtimes -j >"$scratch/runtimes.json"
xcrun simctl list devicetypes -j >"$scratch/devicetypes.json"
python3 - "$scratch" "$runtime" "$device" <<'PY'
import json, pathlib, sys
root, runtime, device = pathlib.Path(sys.argv[1]), sys.argv[2], sys.argv[3]
runtimes = json.loads((root / 'runtimes.json').read_text())['runtimes']
devices = json.loads((root / 'devicetypes.json').read_text())['devicetypes']
if not any(r['identifier'] == runtime and r.get('isAvailable') for r in runtimes):
    sys.exit('Selected runtime is not installed and available: ' + runtime)
if not any(d['identifier'] == device for d in devices):
    sys.exit('Selected device type is not installed: ' + device)
PY
python3 -B - "$repo_root/ios" "$scratch/ios" <<'PY'
import json, pathlib, sys
sys.path.insert(0, str(pathlib.Path(sys.argv[1]).parent / 'scripts'))
from ios_sources import copy_sources
root = pathlib.Path(sys.argv[2])
manifest = copy_sources(sys.argv[1], root)
(root.parent / 'sources.json').write_text(json.dumps(manifest, indent=2) + '\n')
PY
{
  xcodebuild -version
  xcodegen --version
  echo "Runtime: $runtime"
  echo "Device type: $device"
  echo "CI shard: ${ci_shard:-full or focused}"
  echo "UI suite: $ui_suite"
  printf 'Test selection: %s\n' ${test_args[@]+"${test_args[@]}"}
  git -C "$repo_root" rev-parse HEAD
  git -C "$repo_root" status --short
} >"$scratch/environment.log"
xcodegen generate --spec "$scratch/ios/project.yml" >"$scratch/xcodegen.log" 2>&1
simulator="$(xcrun simctl create "TresFort verification $(basename "$scratch")" "$device" "$runtime")"
echo "Verifying TresFort on $runtime / $device ($simulator)"
xcrun simctl boot "$simulator" >"$scratch/boot.log" 2>&1
# Let the fresh simulator finish its first boot while Xcode compiles. The
# build and test actions share this invocation's sources and DerivedData.
build_args=(-project "$scratch/ios/TresFort.xcodeproj" -scheme TresFort -configuration Debug
  -destination "platform=iOS Simulator,id=$simulator" -derivedDataPath "$scratch/DerivedData"
  -parallel-testing-enabled NO CODE_SIGNING_ALLOWED=NO)
echo 'Building app and test bundles while the simulator starts...'
if ! xcodebuild build-for-testing "${build_args[@]}" \
    -resultBundlePath "$scratch/Build.xcresult" >"$scratch/build.log" 2>&1; then
  tail -n 100 "$scratch/build.log" >&2
  exit 1
fi
echo 'Build complete; waiting for simulator boot readiness...'
if ! xcrun simctl bootstatus "$simulator" -b >>"$scratch/boot.log" 2>&1; then
  tail -n 100 "$scratch/boot.log" >&2
  exit 1
fi
if [[ -n "$content_size" ]]; then
  # Set the actual simulator preference: a root SwiftUI environment override
  # alone may not reach system controls or separately presented sheets.
  xcrun simctl ui "$simulator" content_size "$content_size" >"$scratch/ui-settings.log" 2>&1
  xcrun simctl ui "$simulator" content_size >>"$scratch/ui-settings.log" 2>&1
fi
# Disable test cloning so every simulator this command creates has one owner.
echo "Running $ui_suite tests (shard ${ci_shard:-all})..."
if ! xcodebuild test-without-building "${build_args[@]}" \
    -resultBundlePath "$scratch/Tests.xcresult" \
    ${test_args[@]+"${test_args[@]}"} >"$scratch/xcodebuild.log" 2>&1; then
  tail -n 100 "$scratch/xcodebuild.log" >&2
  exit 1
fi
awk '/Executed [0-9]+ tests|\*\* TEST/{print}' "$scratch/xcodebuild.log"
