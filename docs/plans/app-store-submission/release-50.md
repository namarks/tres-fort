# Release 1.0 (50)

## Source and authority

On October 8 the owner settled version 1.0 as **iPhone and native iPad**, merged
in [#248](https://github.com/namarks/tres-fort/pull/248), and then asked for the
App Store screenshots and the public 1.0 candidate upload. This receipt covers
those two actions only. Selecting the build for version 1.0, uploading
screenshots or metadata, replying to App Review, submission and release remain
owner actions. No Worker deployment or migration was made.

The source is main `b3f10ccfe483c2e4eafe4098d8259d359d6c83f3`, tree
`eb873cdf747b751da37975386b637dc90689b731` (the #248 merge). The checkout was
clean for both captures and the archive.

All 15 required checks passed on the #248 final head `c77e494`, including
`plan graph`, `typecheck + tests`, `iOS build + tests`, iPad Station and both
App Store capture shards. No review thread was unresolved. Codex completed a
review without findings on `aa80e84`. Later re-requests on the final head hit
Codex usage limits, so the last four commits (`9c5f538`..`c77e494`: native iPad
screenshot/privacy copy, the iPad feedback sheet, asset consistency and a
cold-resume test) have CI evidence but no completed exact-head Codex review.

## Backend compatibility

Backend source, migrations, Worker configuration and dependencies are
identical between the serving release-49 source `cd3cf40` and `b3f10cc`. A
read-only `wrangler deployments status` at upload time showed deployment
`8e68bb87-2898-4155-8112-5c4a4f42c371` serving version
`5306d0d6-a4bf-4092-890b-55c4d6089000` at 100% traffic, tagged with source
`cd3cf4057320daa474292b86f3ddbbca401d5099`. Build 50 needs no backend change.

## Screenshots

Both sets were captured with `scripts/capture-app-store-screenshots.sh` on
Xcode 27.0 (27A266a) with the iOS 26.2 runtime, `project-app-store.yml`,
en_US and fictional, network-isolated data:

| Set | Device | Images | Size | Captured (UTC) |
|---|---|---|---|---|
| `.artifacts/app-store-iphone` | iPhone 17 Pro | 5 (Today, runner, workouts, History, feedback) | 1206 × 2622 | 2026-10-09 02:23:41 |
| `.artifacts/app-store-ipad` | iPad Pro 13-inch (M4) | 6 (adds manual Station) | 2064 × 2752 | 2026-10-09 02:25:47 |

The script validated every PNG as opaque RGB at the native size, and
source parity held at the same head. The capture journeys passed on each
device. The device-specific test (Station on iPhone, saved-partner-setup
cancellation on iPad) is skipped by design. Each folder keeps `manifest.json`
(per-image SHA-256), `sources.json` and `capture-tests.log`. The folders are
gitignored and stay in the primary checkout on the release Mac.

A visual pass found no system alerts, personal data or clipped primary
controls. Points for the owner's review before publishing:

- Every iPad image shows the iPadOS window-corner handle at the bottom right.
- `05-feedback` on both devices shows a scrolled "Optional" section header
  ghosting behind the "Finish workout" title bar.
- `06-station` shows Train together disabled until the host's iPhone is connected,
  which is the real initial state.

The images remain drafts until the owner compares them with the selected
candidate and authorizes metadata publication.

## iOS package and Apple availability

A fresh App Store Connect read before upload showed **49** as the highest
build (all VALID), and version 1.0 still selected build 40, **REJECTED**, with
**MANUAL** release. The release used
`BUILD_NUMBER=50 APP_STORE_BUILD=1 ./scripts/upload-testflight.sh`, so
`ios/project.yml` was not edited. A plain local run would have bumped its stale
build 29 to a colliding 30.

Xcode 27.0 (27A266a) with the iPhoneOS 27.0 SDK archived and exported
**1.0 (50)**, minimum iOS 17.0. Archive readback:

- App and widget both carry `UIDeviceFamily` **[1,2]** and build 50. The
  exported IPA's app Info.plist also reads [1,2].
- The Station SDK and its model are excluded. The archive has no
  `pose_landmarker_full.task`, MediaPipe notice or MediaPipe frameworks, and its
  `Frameworks` directory is empty. The IPA lists no MediaPipe or `.task` entries.
- The app's `PrivacyInfo.xcprivacy` is embedded: UserDefaults `CA92.1`, system
  boot time `35F9.1`, and the declared collected-data types.
- `codesign --verify --deep --strict` passed on the archived app.

The 10,837,269-byte IPA has SHA-256
`08ef70cc6c853b612e323d76b7fe8520cb3e10d95a307edee0e880890b6fec5b`.
Build 49's beta IPA, which still carried the camera SDK, was 26,567,160 bytes.

Upload reported **UPLOAD SUCCEEDED with no errors** at `2026-10-09T02:27:54Z`,
delivery UUID and Apple build ID `a75d5a6b-9263-4672-ae0d-1214708663df`.
At `2026-10-09T02:29:57Z`, Apple reported **VALID**, audience
**APP_STORE_ELIGIBLE**, minimum iOS 17.0, non-exempt encryption false, under
pre-release version 1.0. Internal beta state is **IN_BETA_TESTING**, and the
build already appears in the internal **Testers** group
(`5df996bf-8c8b-471e-b79e-f626a4f98211`) with no group change from this release.
External state is READY_FOR_BETA_SUBMISSION, meaning not submitted.

The build was not selected for version 1.0 or submitted for review. The same
readback shows version 1.0 still on build 40, **REJECTED**, with **MANUAL**
release.

## Verification boundary

Simulator captures show the visible UI. They do not establish physical-device
behavior, speech recognition or App Review approval. The native iPad layout
checks, three-device partner trial, designated-account
consent/workout/export/deletion checks and authenticated workout compatibility
remain unperformed (P1/P3(a)). The policy publication, App Privacy answers and
agreements in **Next step** remain owner actions.

Temporary build outputs remain in the ignored `ios/build`; the capture
simulators and builds were removed by the capture script. Apple retains the
uploaded build.
