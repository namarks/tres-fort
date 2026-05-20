#!/usr/bin/env bash
# Build, archive, export, and upload LiftCoach to TestFlight via App Store Connect API.
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
# lockstep — lift-coach's project.yml is the single source of truth.)
#
# Marketing version (MARKETING_VERSION) is always left alone — bump that
# manually in ios/project.yml when you want a new train (e.g. 0.1.0 -> 0.1.1)
# and create the matching version in App Store Connect first.
#
# Usage:
#   Local:  ./scripts/upload-testflight.sh
#   CI:     BUILD_NUMBER=$GITHUB_RUN_NUMBER ./scripts/upload-testflight.sh
#
# Requires: xcodegen, an ASC API key at ~/.appstoreconnect/private_keys/AuthKey_<ID>.p8
set -euo pipefail

readonly TEAM_ID="8BA2RY6RCA"
readonly API_KEY_ID="723T6CFSD9"
readonly API_ISSUER_ID="b169cd8d-cb73-4efc-8d72-8c92c5ad29ed"
readonly SCHEME="LiftCoach"

cd "$(dirname "$0")/../ios"

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

xcodegen generate

rm -rf build/LiftCoach.xcarchive build/export

# Sanity-check the ASC API .p8 exists — altool uses it by key id below.
readonly P8_PATH="${HOME}/.appstoreconnect/private_keys/AuthKey_${API_KEY_ID}.p8"
test -f "${P8_PATH}" || { echo "Missing ASC API key at ${P8_PATH}"; exit 1; }

# Signing-asset fetching (Distribution cert + App Store provisioning profile)
# goes through Xcode's signed-in account, NOT the ASC API key, because Apple
# never granted this account-level .p8 the "Access to Cloud Managed App
# Distribution" permission. So no -authenticationKey* flags here — passing
# them produces a "Cloud signing permission error" on exportArchive. Make
# sure Xcode is signed in: Xcode → Settings → Accounts → +Apple ID.
#
# TODO(future): grant the ASC API key 723T6CFSD9 the cloud-signing permission
# in ASC web UI (Users and Access → Integrations → key → enable cloud-managed
# distribution access), then re-add -authenticationKeyPath / -authenticationKeyID
# / -authenticationKeyIssuerID flags below. That makes this script work on any
# Mac with the .p8 on disk, regardless of Xcode GUI state — needed if we ever
# move this to CI.
xcodebuild \
  -project LiftCoach.xcodeproj \
  -scheme "${SCHEME}" \
  -configuration Release \
  -destination 'generic/platform=iOS' \
  -archivePath build/LiftCoach.xcarchive \
  -allowProvisioningUpdates \
  DEVELOPMENT_TEAM="${TEAM_ID}" \
  CODE_SIGN_STYLE=Automatic \
  CURRENT_PROJECT_VERSION="${next_build}" \
  archive

xcodebuild \
  -exportArchive \
  -archivePath build/LiftCoach.xcarchive \
  -exportPath build/export \
  -exportOptionsPlist ExportOptions.plist \
  -allowProvisioningUpdates

xcrun altool --upload-app \
  --type ios \
  --file build/export/LiftCoach.ipa \
  --apiKey "${API_KEY_ID}" \
  --apiIssuer "${API_ISSUER_ID}"

echo
echo "Uploaded ${marketing_version} (${next_build}). Apple processes ~10-15 min, then it appears in TestFlight."
