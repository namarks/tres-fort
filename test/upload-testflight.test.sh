#!/usr/bin/env bash
set -euo pipefail

SUBJECT_SCRIPT="$(cd "$(dirname "$0")/.." && pwd)/scripts/upload-testflight.sh"
readonly SUBJECT_SCRIPT
test_root=$(mktemp -d "${TMPDIR:-/tmp}/tres-fort-upload-test.XXXXXX")
cleanup() {
  rm -rf "${test_root}"
}
trap cleanup EXIT

case_number=0
last_output=""
last_status=0

fail() {
  echo "not ok ${case_number} - $1" >&2
  printf '%s\n' "${last_output}" >&2
  exit 1
}

assert_status() {
  local expected="$1"
  [ "${last_status}" -eq "${expected}" ] || fail "expected status ${expected}, got ${last_status}"
}

assert_contains() {
  local expected="$1"
  [[ "${last_output}" == *"${expected}"* ]] || fail "missing output: ${expected}"
}

assert_not_contains() {
  local unexpected="$1"
  [[ "${last_output}" != *"${unexpected}"* ]] || fail "unexpected output: ${unexpected}"
}

run_case() {
  local name="$1"
  local xcrun_status="$2"
  local xcrun_output="$3"
  local case_root="${test_root}/case-${case_number}"

  mkdir -p \
    "${case_root}/repo/scripts" \
    "${case_root}/repo/ios/Dependencies" \
    "${case_root}/bin" \
    "${case_root}/home/.appstoreconnect/private_keys"
  cp "${SUBJECT_SCRIPT}" "${case_root}/repo/scripts/upload-testflight.sh"
  cp "$(dirname "${SUBJECT_SCRIPT}")/../ios/Dependencies/verify_app_store_project.py" \
    "${case_root}/repo/ios/Dependencies/verify_app_store_project.py"
  printf '%s\n' \
    'settings:' \
    '  MARKETING_VERSION: "0.1.0"' \
    '  CURRENT_PROJECT_VERSION: "29"' \
    > "${case_root}/repo/ios/project.yml"
  : > "${case_root}/home/.appstoreconnect/private_keys/AuthKey_VP9G3R7Q85.p8"

  # shellcheck disable=SC2016
  printf '%s\n' \
    '#!/usr/bin/env bash' \
    'printf "%s\n" "$*" >> "${STUB_XCODEGEN_LOG}"' \
    'mkdir -p TresFort.xcodeproj' \
    'printf "%s\n" "${STUB_PROJECT_CONTENTS}" > TresFort.xcodeproj/project.pbxproj' \
    > "${case_root}/bin/xcodegen"
  # shellcheck disable=SC2016
  printf '%s\n' \
    '#!/usr/bin/env bash' \
    'printf "%s\n" "$@" >> "${STUB_XCODEBUILD_LOG}"' \
    'if [ "${STUB_ARCHIVE_SDK}" = 1 ]; then mkdir -p build/TresFort.xcarchive/Products/Applications/TresFort.app; touch build/TresFort.xcarchive/Products/Applications/TresFort.app/pose_landmarker_full.task; fi' \
    > "${case_root}/bin/xcodebuild"
  # shellcheck disable=SC2016
  printf '%s\n' \
    '#!/usr/bin/env bash' \
    'printf "%s\n" "$*" >> "${STUB_PLUTIL_LOG}"' \
    'printf "%s\n" "${STUB_DEVICE_FAMILY}"' \
    > "${case_root}/bin/plutil"
  # These expressions must remain literal so the generated stub expands them.
  # shellcheck disable=SC2016
  printf '%s\n' \
    '#!/usr/bin/env bash' \
    'printf "%s\n" "${STUB_XCRUN_OUTPUT}" >&2' \
    'exit "${STUB_XCRUN_STATUS}"' \
    > "${case_root}/bin/xcrun"
  chmod +x "${case_root}/bin/xcodegen" "${case_root}/bin/xcodebuild" "${case_root}/bin/xcrun" "${case_root}/bin/plutil"
  xcodebuild_log="${case_root}/xcodebuild.log"
  xcodegen_log="${case_root}/xcodegen.log"
  plutil_log="${case_root}/plutil.log"
  : > "${xcodebuild_log}"
  : > "${xcodegen_log}"
  : > "${plutil_log}"

  if last_output=$(cd "${case_root}/repo" && \
    HOME="${case_root}/home" \
    PATH="${case_root}/bin:${PATH}" \
    BUILD_NUMBER=30 \
    APP_STORE_IPHONE_ONLY="${CASE_IPHONE_ONLY:-0}" \
    STUB_DEVICE_FAMILY="${CASE_DEVICE_FAMILY:-[1]}" \
    STUB_XCODEBUILD_LOG="${xcodebuild_log}" \
    STUB_XCODEGEN_LOG="${xcodegen_log}" \
    STUB_PROJECT_CONTENTS="${CASE_PROJECT_CONTENTS:-APP_STORE_IPHONE_ONLY}" \
    STUB_ARCHIVE_SDK="${CASE_ARCHIVE_SDK:-0}" \
    STUB_PLUTIL_LOG="${plutil_log}" \
    STUB_XCRUN_STATUS="${xcrun_status}" \
    STUB_XCRUN_OUTPUT="${xcrun_output}" \
    bash scripts/upload-testflight.sh 2>&1); then
    last_status=0
  else
    last_status=$?
  fi

  echo "ok ${case_number} - ${name}"
}

case_number=$((case_number + 1))
run_case \
  "textual rejection fails closed when altool exits zero" \
  0 \
  $'ERROR: Failed to upload package.\nRequestUUID = rejected-delivery'
assert_status 1
assert_contains "ERROR: Failed to upload package."
assert_contains "reported an upload failure despite exiting successfully"
assert_not_contains "Uploaded 0.1.0 (30)."

case_number=$((case_number + 1))
run_case \
  "affirmative success passes and preserves delivery UUID" \
  0 \
  $'UPLOAD SUCCEEDED with no errors\nRequestUUID = accepted-delivery'
assert_status 0
assert_contains "UPLOAD SUCCEEDED with no errors"
assert_contains "RequestUUID = accepted-delivery"
assert_contains "Uploaded 0.1.0 (30)."

case_number=$((case_number + 1))
run_case \
  "nonzero altool status propagates" \
  7 \
  "Transport unavailable"
assert_status 7
assert_contains "altool exited with status 7"
assert_not_contains "Uploaded 0.1.0 (30)."

case_number=$((case_number + 1))
run_case \
  "ambiguous zero exit fails closed" \
  0 \
  "RequestUUID = ambiguous-delivery"
assert_status 1
assert_contains "did not report affirmative upload success"
assert_not_contains "Uploaded 0.1.0 (30)."

case_number=$((case_number + 1))
run_case \
  "negated success wording fails closed" \
  0 \
  "The package was not successfully uploaded."
assert_status 1
assert_contains "did not report affirmative upload success"
assert_not_contains "Uploaded 0.1.0 (30)."

case_number=$((case_number + 1))
run_case \
  "default build keeps both device families" \
  0 \
  "UPLOAD SUCCEEDED with no errors"
assert_status 0
grep -q 'TARGETED_DEVICE_FAMILY' "${xcodebuild_log}" && fail "default archive overrode the device family"
grep -qx 'generate --spec project.yml' "${xcodegen_log}" || fail "default archive selected the wrong spec"
[ -s "${plutil_log}" ] && fail "default archive ran the iPhone-only check"

case_number=$((case_number + 1))
CASE_IPHONE_ONLY=1 run_case \
  "App Store candidate archives iPhone-only and verifies both bundles" \
  0 \
  "UPLOAD SUCCEEDED with no errors"
assert_status 0
assert_contains "Archiving the iPhone-only App Store candidate"
assert_contains "Uploaded 0.1.0 (30)."
grep -qx 'generate --spec project-app-store.yml' "${xcodegen_log}" || fail "missing App Store spec selection"
grep -q 'TresFort.app/Info.plist' "${plutil_log}" || fail "app bundle not verified"
grep -q 'TresFortWidgets.appex/Info.plist' "${plutil_log}" || fail "widget bundle not verified"

case_number=$((case_number + 1))
CASE_IPHONE_ONLY=1 CASE_DEVICE_FAMILY='[1,2]' run_case \
  "App Store candidate with an iPad family fails before export" \
  0 \
  "UPLOAD SUCCEEDED with no errors"
assert_status 1
assert_contains "Expected iPhone-only UIDeviceFamily [1]"
assert_not_contains "Uploaded 0.1.0 (30)."
grep -q -- '-exportArchive' "${xcodebuild_log}" && fail "exported despite the iPad family"

case_number=$((case_number + 1))
CASE_IPHONE_ONLY=yes run_case \
  "unrecognized App Store flag is rejected before building" \
  0 \
  "UPLOAD SUCCEEDED with no errors"
assert_status 2
assert_contains "APP_STORE_IPHONE_ONLY must be 0 or 1"
[ -s "${xcodebuild_log}" ] && fail "built despite an invalid flag"

case_number=$((case_number + 1))
CASE_IPHONE_ONLY=1 CASE_PROJECT_CONTENTS='APP_STORE_IPHONE_ONLY .dependencies/mediapipe' run_case \
  "App Store project with Station SDK inputs fails before archiving" \
  0 \
  "UPLOAD SUCCEEDED with no errors"
assert_status 1
assert_contains "App Store project retains Station SDK input"
[ -s "${xcodebuild_log}" ] && fail "built despite retaining Station SDK inputs"

case_number=$((case_number + 1))
CASE_IPHONE_ONLY=1 CASE_PROJECT_CONTENTS='wrong project' run_case \
  "App Store project missing its Swift condition fails before archiving" \
  0 \
  "UPLOAD SUCCEEDED with no errors"
assert_status 1
assert_contains "App Store project is missing APP_STORE_IPHONE_ONLY"
[ -s "${xcodebuild_log}" ] && fail "built despite using the wrong project"

case_number=$((case_number + 1))
CASE_IPHONE_ONLY=1 CASE_ARCHIVE_SDK=1 run_case \
  "App Store archive with a stale Station model fails before exporting" \
  0 \
  "UPLOAD SUCCEEDED with no errors"
assert_status 1
assert_contains "App Store archive retains Station SDK asset"
grep -q -- '-exportArchive' "${xcodebuild_log}" && fail "exported despite a stale model"

echo "1..${case_number}"
