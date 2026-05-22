# fastlane — TresForte TestFlight setup

Local-only pipeline for shipping TresForte to TestFlight. No CI. Modeled on
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
`~/.appstoreconnect/private_keys/AuthKey_723T6CFSD9.p8`. This is the same
account-level key Tally uses (team `8BA2RY6RCA`); no per-app provisioning
needed. If missing, regenerate from App Store Connect → Users and Access →
Integrations → App Store Connect API.

### 3. Register the bundle ID in Apple Developer Portal

[developer.apple.com](https://developer.apple.com/account) → Certificates,
Identifiers & Profiles → Identifiers → **+** → App IDs → App.

- **Description:** TresForte
- **Bundle ID:** Explicit, `com.nmarkspdx.tresforte`
- **Capabilities:** check **Sign in with Apple**. (Live Activities is an
  Info.plist key — `NSSupportsLiveActivities` — not a Developer Portal
  capability, so nothing to toggle there.)
- **Continue → Register**.

The widget extension bundle id `com.nmarkspdx.tresforte.widgets` will be
auto-registered on first archive by Xcode's automatic signing
(`-allowProvisioningUpdates` flag in `scripts/upload-testflight.sh`). If
that ever fails, register it manually with the same flow above, no
capabilities needed.

### 4. Create the App Store Connect record

[appstoreconnect.apple.com](https://appstoreconnect.apple.com) → My Apps →
**+** → New App.

- **Platforms:** iOS
- **Name:** Tres Forte *(editable later, before App Store submission)*
- **Primary Language:** English (U.S.)
- **Bundle ID:** select `com.nmarkspdx.tresforte` from the dropdown (it
  only appears if step 3 was done)
- **SKU:** `tresforte-ios` *(immutable, choose carefully)*
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
cd ios && bundle exec fastlane submit_for_review
```

Requires `ios/fastlane/metadata/` and `ios/fastlane/screenshots/` to be
populated (currently empty — set up before first submission).
