# fastlane — TresFort TestFlight setup

Local-only pipeline for shipping TresFort to TestFlight. No CI. Modeled on
`tally-app/apple/fastlane/`.

> Why not `README.md`? fastlane regenerates `fastlane/README.md` from the
> Fastfile's lane `desc` strings on every run, clobbering any hand-written
> content. So setup docs live here.

## One-time setup

### 1. Install fastlane

```bash
cd ios && bundle install --path vendor/bundle
```

The `--path` argument is necessary on macOS system Ruby (Bundler 1.17.2) to
avoid `sudo` prompts when installing into `/Library/Ruby/Gems`. Future
`bundle exec` calls in `ios/` pick up the path from `ios/.bundle/config`.

### 2. ASC API key on disk

Verify the key exists at
`~/.appstoreconnect/private_keys/AuthKey_VP9G3R7Q85.p8`, owned by the release
user with file permissions `600`. This is the existing **TresFort CI Signing**
team key with **App Manager** access (team `8BA2RY6RCA`). Both the upload script
and fastlane use it. The previous Developer key could upload but received HTTP
403 when selecting the App Store build.

Team keys apply across all apps in the Apple account; their names do not limit
app access. Leave unrelated keys intact. If this key is missing, the owner must
install it privately on the release Mac. Never commit or paste the `.p8` into
chat. A successful read-only API call proves authentication; verify permission
to change a build through the actual authorized build selection.

Apple API access and code signing are separate. Archiving and exporting still
use Xcode's signed-in account and the local keychain. Changing this API key does
not establish unattended signing or authorize a public release.

### 3. Register the bundle ID in Apple Developer Portal

[developer.apple.com](https://developer.apple.com/account) → Certificates,
Identifiers & Profiles → Identifiers → **+** → App IDs → App.

- **Description:** TresFort
- **Bundle ID:** Explicit, `com.nmarkspdx.tresfort`
- **Capabilities:** check **Sign in with Apple**. (Live Activities is an
  Info.plist key — `NSSupportsLiveActivities` — not a Developer Portal
  capability, so nothing to toggle there.)
- **Continue → Register**.

The widget extension bundle id `com.nmarkspdx.tresfort.widgets` will be
auto-registered on first archive by Xcode's automatic signing
(`-allowProvisioningUpdates` flag in `scripts/upload-testflight.sh`). If
that ever fails, register it manually with the same flow above, no
capabilities needed.

### 4. Create the App Store Connect record

[appstoreconnect.apple.com](https://appstoreconnect.apple.com) → My Apps →
**+** → New App.

- **Platforms:** iOS
- **Name:** Très Fort *(editable later, before App Store submission)*
- **Primary Language:** English (U.S.)
- **Bundle ID:** select `com.nmarkspdx.tresfort` from the dropdown (it
  only appears if step 3 was done)
- **SKU:** `tresfort-ios` *(immutable, choose carefully)*
- **User Access:** Full Access

Why manual instead of `fastlane produce`? fastlane's produce uses Spaceship
(the Apple Developer Portal scraping API), which needs Apple ID + password
auth — the ASC API .p8 key doesn't authorize entity creation, only build &
metadata ops. With 2FA on the account, automating produce requires an
app-specific password and a macOS keychain dance for a one-time op. Web UI
is 5 minutes and you get to set category/age rating/contact info in the
same flow, which you'd need to do before App Store submission anyway.

## Releasing a TestFlight build

From the repo root:

```bash
npm run ios:testflight
# or directly:
./scripts/upload-testflight.sh
```

The script bumps `CURRENT_PROJECT_VERSION` in `ios/project.yml`, regenerates
the Xcode project, archives, exports, and uploads via `altool`. Commit the
bumped `project.yml` after the upload so the next run continues from the
real latest.

To bump the marketing version (e.g. 0.1.0 → 0.1.1), edit
`MARKETING_VERSION` in `ios/project.yml` manually first and create the
matching version in App Store Connect.

## Submitting for App Store review

```bash
cd ios && bundle exec fastlane submit_for_review version:1.0 build_number:<verified-build-number>
```

This submits to App Review; submission preparation does not authorize running
it. Supply the exact verified version and build. The lane does not select the
latest upload, withdraw an existing submission, or automatically release after
approval. Verify compliance and content-rights answers in App Store Connect;
the lane does not supply blanket declarations.

Requires `ios/fastlane/metadata/` and `ios/fastlane/screenshots/` to be populated
from the approved [review package](../../docs/plans/app-store-submission/review-package.md).
App Privacy answers are separate from `deliver` metadata. See the canonical
[submission plan](../../docs/plans/app-store-submission/plan.md) for remaining gates.
