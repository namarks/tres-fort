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
    "${case_root}/repo/ios" \
    "${case_root}/bin" \
    "${case_root}/home/.appstoreconnect/private_keys"
  cp "${SUBJECT_SCRIPT}" "${case_root}/repo/scripts/upload-testflight.sh"
  printf '%s\n' \
    'settings:' \
    '  MARKETING_VERSION: "0.1.0"' \
    '  CURRENT_PROJECT_VERSION: "29"' \
    > "${case_root}/repo/ios/project.yml"
  : > "${case_root}/home/.appstoreconnect/private_keys/AuthKey_723T6CFSD9.p8"

  printf '%s\n' '#!/usr/bin/env bash' 'exit 0' > "${case_root}/bin/xcodegen"
  printf '%s\n' '#!/usr/bin/env bash' 'exit 0' > "${case_root}/bin/xcodebuild"
  # These expressions must remain literal so the generated stub expands them.
  # shellcheck disable=SC2016
  printf '%s\n' \
    '#!/usr/bin/env bash' \
    'printf "%s\n" "${STUB_XCRUN_OUTPUT}" >&2' \
    'exit "${STUB_XCRUN_STATUS}"' \
    > "${case_root}/bin/xcrun"
  chmod +x "${case_root}/bin/xcodegen" "${case_root}/bin/xcodebuild" "${case_root}/bin/xcrun"

  if last_output=$(cd "${case_root}/repo" && \
    HOME="${case_root}/home" \
    PATH="${case_root}/bin:${PATH}" \
    BUILD_NUMBER=30 \
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

echo "1..${case_number}"
