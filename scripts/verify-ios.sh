#!/usr/bin/env bash
# Build and test an unsigned copy. Never reuse a person's simulator or keychain.
set -euo pipefail
repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
usage() {
  echo 'Usage: npm run ios:verify -- --runtime RUNTIME --device DEVICE [--ui-suite full|smoke] [--ci-shard 1|2|3] [--only-testing Target[/Class[/method]]] [--content-size SIZE]'
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
  [[ "$ci_shard" == 1 || "$ci_shard" == 2 || "$ci_shard" == 3 ]] || { usage >&2; exit 2; }
fi
if [[ -n "$ci_shard" || "$ui_suite" == smoke ]]; then
  [[ ${#test_args[@]} -eq 0 ]] || { echo 'CI selection cannot be combined with --only-testing' >&2; exit 2; }
fi
if [[ "$ui_suite" == smoke ]]; then
  [[ "$ci_shard" != 3 ]] || { echo 'Smoke coverage uses shards 1 and 2' >&2; exit 2; }
  # Bound the PR gate to twelve representative journeys. Select methods, never
  # whole UI classes: adding a regression must not silently grow the smoke run.
  # Every unit test still runs; all UI methods remain in nightly/manual full runs.
  if [[ -z "$ci_shard" || "$ci_shard" == 1 ]]; then
    test_args+=("-only-testing:TresFortTests")
    for method in testMixedSportSetupCreatesFirstWorkoutAndKeepsProfile \
      testCoachSetupOffersCodexClaudeAndOtherApps testMobileCoachApprovalRequiresExplicitDecision; do
      test_args+=("-only-testing:TresFortUITests/MemberActivationJourneyTests/$method")
    done
    test_args+=("-only-testing:TresFortUITests/TrainingJourneyTests/testOrdinarySetLogsAndCompletesThroughAcknowledgement")
    test_args+=("-only-testing:TresFortUITests/TrainingJourneyTests/testWeightEntryAndKeyboardCanSaveExactLoad")
    test_args+=("-only-testing:TresFortUITests/IntervalsConnectionJourneyTests/testConnectImmediatelyRefreshesCalendar")
  fi
  if [[ -z "$ci_shard" || "$ci_shard" == 2 ]]; then
    test_args+=("-only-testing:TresFortUITests/TodayNavigationJourneyTests/testTodayButtonsOpenNamedDetailsLibraryCreatorAndActivity")
    for method in testVerifiedEmptyPlanCanCreateRoutineAndFirstWorkout testSwapExerciseMidWorkoutPreservesCompletedSetAndRoutine; do
      test_args+=("-only-testing:TresFortUITests/TrainingJourneyTests/$method")
    done
    test_args+=("-only-testing:TresFortUITests/PlanChangeJourneyTests/testDismissRelaunchRevisitBothActorsAndRestore")
    test_args+=("-only-testing:TresFortUITests/WorkoutFeedbackJourneyTests/testVoiceEditedTranscriptAndFatigueReachAcknowledgedWorkout")
    test_args+=("-only-testing:TresFortUITests/GroupSafetyJourneyTests/testReportFallbackBlockAndUnblock")
  fi
elif [[ -n "$ci_shard" ]]; then
  # Shard 1 runs the complement, so new tests automatically remain covered.
  full_second=(TrainingJourneyTests WorkoutFeedbackJourneyTests)
  full_third=(TodayNavigationJourneyTests UIActionJourneyTests
    IntervalsConnectionJourneyTests HistoryJourneyTests ExerciseGroupJourneyTests)
  if [[ "$ci_shard" == 1 ]]; then
    for suite in "${full_second[@]}" "${full_third[@]}"; do
      test_args+=("-skip-testing:TresFortUITests/$suite")
    done
  elif [[ "$ci_shard" == 2 ]]; then
    for suite in "${full_second[@]}"; do
      test_args+=("-only-testing:TresFortUITests/$suite")
    done
  else
    for suite in "${full_third[@]}"; do
      test_args+=("-only-testing:TresFortUITests/$suite")
    done
  fi
fi
for tool in xcodegen xcodebuild xcrun python3; do
  command -v "$tool" >/dev/null || { echo "Required tool missing: $tool" >&2; exit 1; }
done

scratch="$(mktemp -d "${TMPDIR:-/tmp}/tres-fort-ios.XXXXXX")"
simulator=''
evidence_root="${IOS_EVIDENCE_DIR:-$repo_root/.artifacts/ios}"
recording_root="$scratch"
cleanup() {
  result=$?
  trap - EXIT
  if [[ -n "$simulator" ]]; then
    xcrun simctl shutdown "$simulator" >>"$recording_root/cleanup.log" 2>&1 || true
    if ! xcrun simctl delete "$simulator" >>"$recording_root/cleanup.log" 2>&1; then
      echo "Could not delete verification simulator $simulator; see cleanup.log" >&2
      result=1
    fi
  fi
  # Retain logs and the result bundle (including synthetic UI screenshots).
  # DerivedData, copied sources, and simulator data never become artifacts.
  if [[ "$result" -ne 0 || "${IOS_KEEP_RESULTS:-0}" == 1 ]]; then
    evidence="$evidence_root/$(basename "$scratch")"
    if mkdir -p "$evidence"; then
      if [[ "$recording_root" != "$evidence" ]]; then
        for path in "$recording_root"/*.log "$recording_root"/*.json "$recording_root"/*.xcresult; do
          if [[ -e "$path" ]] && ! cp -R "$path" "$evidence/"; then result=1; fi
        done
      fi
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

if [[ "${IOS_KEEP_RESULTS:-0}" == 1 ]]; then
  # A CI timeout can kill the shell before its cleanup trap finishes. Record
  # diagnostics directly in the upload directory so cancellation retains them.
  mkdir -p "$evidence_root/$(basename "$scratch")"
  recording_root="$evidence_root/$(basename "$scratch")"
fi

xcrun simctl list runtimes -j >"$recording_root/runtimes.json"
xcrun simctl list devicetypes -j >"$recording_root/devicetypes.json"
python3 - "$recording_root" "$runtime" "$device" <<'PY'
import json, pathlib, sys
root, runtime, device = pathlib.Path(sys.argv[1]), sys.argv[2], sys.argv[3]
runtimes = json.loads((root / 'runtimes.json').read_text())['runtimes']
devices = json.loads((root / 'devicetypes.json').read_text())['devicetypes']
if not any(r['identifier'] == runtime and r.get('isAvailable') for r in runtimes):
    sys.exit('Selected runtime is not installed and available: ' + runtime)
if not any(d['identifier'] == device for d in devices):
    sys.exit('Selected device type is not installed: ' + device)
PY
python3 -B - "$repo_root/ios" "$scratch/ios" "$recording_root" <<'PY'
import json, pathlib, sys
sys.path.insert(0, str(pathlib.Path(sys.argv[1]).parent / 'scripts'))
from ios_sources import copy_sources
root = pathlib.Path(sys.argv[2])
manifest = copy_sources(sys.argv[1], root)
(pathlib.Path(sys.argv[3]) / 'sources.json').write_text(json.dumps(manifest, indent=2) + '\n')
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
} >"$recording_root/environment.log"
xcodegen generate --spec "$scratch/ios/project.yml" >"$recording_root/xcodegen.log" 2>&1
simulator="$(xcrun simctl create "TresFort verification $(basename "$scratch")" "$device" "$runtime")"
echo "Verifying TresFort on $runtime / $device ($simulator)"
xcrun simctl boot "$simulator" >"$recording_root/boot.log" 2>&1
# Let the fresh simulator finish its first boot while Xcode compiles. The
# build and test actions share this invocation's sources and DerivedData.
build_args=(-project "$scratch/ios/TresFort.xcodeproj" -scheme TresFort -configuration Debug
  -destination "platform=iOS Simulator,id=$simulator" -derivedDataPath "$scratch/DerivedData"
  -parallel-testing-enabled NO CODE_SIGNING_ALLOWED=NO)
echo 'Building app and test bundles while the simulator starts...'
if ! xcodebuild build-for-testing "${build_args[@]}" \
    -resultBundlePath "$recording_root/Build.xcresult" >"$recording_root/build.log" 2>&1; then
  tail -n 100 "$recording_root/build.log" >&2
  exit 1
fi
echo 'Build complete; waiting for simulator boot readiness...'
if ! xcrun simctl bootstatus "$simulator" -b >>"$recording_root/boot.log" 2>&1; then
  tail -n 100 "$recording_root/boot.log" >&2
  exit 1
fi
if [[ -n "$content_size" ]]; then
  # Set the actual simulator preference: a root SwiftUI environment override
  # alone may not reach system controls or separately presented sheets.
  xcrun simctl ui "$simulator" content_size "$content_size" >"$recording_root/ui-settings.log" 2>&1
  xcrun simctl ui "$simulator" content_size >>"$recording_root/ui-settings.log" 2>&1
fi
# Disable test cloning so every simulator this command creates has one owner.
echo "Running $ui_suite tests (shard ${ci_shard:-all})..."
if ! xcodebuild test-without-building "${build_args[@]}" \
    -resultBundlePath "$recording_root/Tests.xcresult" \
    ${test_args[@]+"${test_args[@]}"} >"$recording_root/xcodebuild.log" 2>&1; then
  tail -n 100 "$recording_root/xcodebuild.log" >&2
  exit 1
fi
awk '/Executed [0-9]+ tests|\*\* TEST/{print}' "$recording_root/xcodebuild.log"
