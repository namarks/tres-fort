#!/usr/bin/env bash
# Build, archive, export, and upload TresFort to TestFlight via App Store Connect API.
#
# Build-number strategy depends on environment:
#   - BUILD_NUMBER env var set (CI):
#       Use it as CURRENT_PROJECT_VERSION via xcodebuild build-setting override.
#       project.yml is NOT modified — no commit-back needed.
#   - BUILD_NUMBER unset (local):
#       Read CURRENT_PROJECT_VERSION from ios/project.yml, increment by 1, sed
#       the bumped value back so the next local run continues from there.
#       Commit the resulting project.yml diff after upload.
#
# Either way the Info.plists need no edits — they reference
# $(CURRENT_PROJECT_VERSION) and xcodebuild resolves it at build time, picking
# up the command-line override when set. (Unlike Tally, which has literal
# CFBundleVersion values in three plists that all need sed/PlistBuddy in
# lockstep — tres-fort's project.yml is the single source of truth.)
#
# Marketing version (MARKETING_VERSION) is always left alone — bump that
# manually in ios/project.yml when you want a new train (e.g. 0.1.0 -> 0.1.1)
# and create the matching version in App Store Connect first.
#
# APP_STORE_BUILD=1 archives the public iPhone + iPad candidate using
# project-app-store.yml: device families 1,2 for app and widget, manual Station
# and partner training, and no experimental camera SDK/model. Default beta
# builds retain experimental Station inference. The obsolete iPhone-only flag
# is rejected even when set to 0; remove it from old release commands.
# The archive's UIDeviceFamily is verified before anything is exported.
#
# Usage:
#   Local:  ./scripts/upload-testflight.sh
#   CI:     BUILD_NUMBER=$GITHUB_RUN_NUMBER ./scripts/upload-testflight.sh
#   App Store candidate:  APP_STORE_BUILD=1 ./scripts/upload-testflight.sh
#
# Requires: xcodegen, an ASC API key at ~/.appstoreconnect/private_keys/AuthKey_<ID>.p8
set -euo pipefail

readonly TEAM_ID="8BA2RY6RCA"
# Existing "TresFort CI Signing" team key, with App Manager access.
readonly API_KEY_ID="VP9G3R7Q85"
readonly API_ISSUER_ID="b169cd8d-cb73-4efc-8d72-8c92c5ad29ed"
readonly SCHEME="TresFort"

cd "$(dirname "$0")/../ios"

if [[ ${APP_STORE_IPHONE_ONLY+x} ]]; then
  echo 'APP_STORE_IPHONE_ONLY is obsolete; remove it and use APP_STORE_BUILD=1 for the public iPhone + iPad build.' >&2
  exit 2
fi
app_store_build="${APP_STORE_BUILD-0}"
case "${app_store_build}" in
  0) project_spec=project.yml ;;
  1)
    project_spec=project-app-store.yml
    echo "Archiving the iPhone + iPad App Store candidate"
    ;;
  *)
    echo "APP_STORE_BUILD must be 0 or 1, got '${app_store_build}'." >&2
    exit 2
    ;;
esac

marketing_version=$(awk '/MARKETING_VERSION:/ { gsub(/"/, "", $2); print $2; exit }' project.yml)

if [ -n "${BUILD_NUMBER:-}" ]; then
  next_build="${BUILD_NUMBER}"
  echo "Using BUILD_NUMBER=${next_build} from env (CI mode — project.yml not modified)"
else
  current_build=$(awk '/CURRENT_PROJECT_VERSION:/ { gsub(/"/, "", $2); print $2; exit }' project.yml)
  next_build=$((current_build + 1))
  echo "Bumping ${SCHEME} ${marketing_version} build ${current_build} -> ${next_build} (local mode)"
  sed -i '' "s/CURRENT_PROJECT_VERSION: \"${current_build}\"/CURRENT_PROJECT_VERSION: \"${next_build}\"/" project.yml
fi

xcodegen generate --spec "${project_spec}"
if [ "${app_store_build}" = "1" ]; then
  python3 Dependencies/verify_app_store_project.py TresFort.xcodeproj/project.pbxproj
fi

rm -rf build/TresFort.xcarchive build/export

# Sanity-check the ASC API .p8 exists — altool uses it by key id below.
readonly P8_PATH="${HOME}/.appstoreconnect/private_keys/AuthKey_${API_KEY_ID}.p8"
test -f "${P8_PATH}" || { echo "Missing ASC API key at ${P8_PATH}"; exit 1; }

# Signing assets still use Xcode's signed-in account and local keychain.
# App Manager API access permits upload and build selection, but does not by
# itself prove unattended signing works. Keep this verified signing path until
# a separate signing-runner setup is tested. Xcode → Settings → Accounts.
xcodebuild \
  -project TresFort.xcodeproj \
  -scheme "${SCHEME}" \
  -configuration Release \
  -destination 'generic/platform=iOS' \
  -archivePath build/TresFort.xcarchive \
  -allowProvisioningUpdates \
  DEVELOPMENT_TEAM="${TEAM_ID}" \
  CODE_SIGN_STYLE=Automatic \
  CURRENT_PROJECT_VERSION="${next_build}" \
  archive

if [ "${app_store_build}" = "1" ]; then
  readonly ARCHIVED_APP="build/TresFort.xcarchive/Products/Applications/TresFort.app"
  for bundle in "${ARCHIVED_APP}" "${ARCHIVED_APP}/PlugIns/TresFortWidgets.appex"; do
    family=$(plutil -extract UIDeviceFamily json -o - "${bundle}/Info.plist" | tr -d '[:space:]')
    if [ "${family}" != "[1,2]" ]; then
      echo "Expected iPhone + iPad UIDeviceFamily [1,2] in ${bundle}, got '${family}'; not exporting." >&2
      exit 1
    fi
  done
  # Also reject stale copied resources left by a previous beta build.
  for asset in "${ARCHIVED_APP}/pose_landmarker_full.task" \
    "${ARCHIVED_APP}/Notices/MediaPipe-LICENSE.txt" \
    "${ARCHIVED_APP}/Frameworks/MediaPipeTasksVision.framework" \
    "${ARCHIVED_APP}/Frameworks/MediaPipeTasksCommon.framework"; do
    if [ -e "${asset}" ]; then
      echo "App Store archive retains Station SDK asset ${asset}; not exporting." >&2
      exit 1
    fi
  done
fi

xcodebuild \
  -exportArchive \
  -archivePath build/TresFort.xcarchive \
  -exportPath build/export \
  -exportOptionsPlist ExportOptions.plist \
  -allowProvisioningUpdates

upload_log=$(mktemp "${TMPDIR:-/tmp}/tres-fort-altool.XXXXXX")
cleanup_upload_log() {
  rm -f "${upload_log}"
}
trap cleanup_upload_log EXIT

# Xcode 26.3's altool can report an App Store Connect rejection in its output
# while still exiting 0. Stream the output for operator visibility, but retain
# a copy so the script can require affirmative success and reject textual
# errors instead of trusting the process status alone.
if xcrun altool --upload-app \
  --type ios \
  --file build/export/TresFort.ipa \
  --apiKey "${API_KEY_ID}" \
  --apiIssuer "${API_ISSUER_ID}" 2>&1 | tee "${upload_log}"; then
  upload_statuses=("${PIPESTATUS[@]}")
else
  upload_statuses=("${PIPESTATUS[@]}")
fi

altool_status="${upload_statuses[0]}"
tee_status="${upload_statuses[1]}"

if [ "${tee_status}" -ne 0 ]; then
  echo "Failed to capture altool output; upload status is unknown." >&2
  exit 1
fi

if [ "${altool_status}" -ne 0 ]; then
  echo "altool exited with status ${altool_status}; upload was not accepted." >&2
  exit "${altool_status}"
fi

if LC_ALL=C grep -Eiq '(^|[^[:alnum:]_])(error|failed|failure)([^[:alnum:]_]|$)' "${upload_log}"; then
  echo "altool reported an upload failure despite exiting successfully; upload was not accepted." >&2
  exit 1
fi

if ! LC_ALL=C grep -Eiq '^[[:space:]]*UPLOAD SUCCEEDED with no errors[[:space:]]*$' "${upload_log}"; then
  echo "altool did not report affirmative upload success; upload status is unknown." >&2
  exit 1
fi

echo
echo "Uploaded ${marketing_version} (${next_build}). Apple processes ~10-15 min, then it appears in TestFlight."
