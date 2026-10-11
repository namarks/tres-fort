# Release 1.0 (53)

## Source and authority

On October 11 the owner asked to update the builds and the App Store
submission to the latest app. They chose build 53 for the SDK-free App Store
candidate and build 54 for the camera-enabled internal beta, so TestFlight
auto-update lands test devices on the camera build. The beta is recorded in
[release 54](release-54.md). After the
uploads, they explicitly approved selecting build 53 for version 1.0.

The source is main `47be49d11e6720826bc53444382c4cc7ec0df8ae`, tree
`5593e6c13f7f8d0ad391ab68e158d44314015f4d` (PR #261's merge). It adds
the Today widget and opt-in reminders ([#256](https://github.com/namarks/tres-fort/pull/256)),
exercise line drawings ([#257](https://github.com/namarks/tres-fort/pull/257)),
the Progress streak and day grid ([#258](https://github.com/namarks/tres-fort/pull/258)),
iPhone/iPad link fixes ([#259](https://github.com/namarks/tres-fort/pull/259),
[#260](https://github.com/namarks/tres-fort/pull/260)) and the Today cleanup
([#261](https://github.com/namarks/tres-fort/pull/261)). The checkout was clean
for both captures and the archive.

## Review and CI

Codex completed a review on each PR's final head, with a 👍 and no
findings on that head. No review thread is unresolved. Findings on earlier heads
were addressed before those final reviews.

| PR | Final head | CI on final head |
|---|---|---|
| #256 | `d1e532b` | 11 of 11 passed |
| #257 | `9a751be` | 11 of 11 passed |
| #258 | `89977b3` | 11 of 11 passed |
| #259 | `7c08acf` | Backend, plan graph and typecheck passed; iOS jobs incomplete (see below) |
| #260 | `2125be1` | 11 of 11 passed |
| #261 | `90353c8` | 11 of 11 passed |

#259 merged at 02:09 UTC while its iOS jobs were still running. GitHub cancelled
them at 02:26 and reported the iOS aggregate as failed, so its final head has no
completed iOS result. Its code is covered by later main runs. The
[push run on `a5f4cb7`](https://github.com/namarks/tres-fort/actions/runs/38106394391),
which includes #259 and #260, passed all 11 jobs. So did the
[push run on `47be49d`](https://github.com/namarks/tres-fort/actions/runs/38158678759),
the release source.

## Backend compatibility

`src/`, `migrations/`, `wrangler.jsonc` and npm dependencies are unchanged
from release-49 source `cd3cf40`. A read-only `wrangler deployments status`
showed deployment `8e68bb87-2898-4155-8112-5c4a4f42c371` still serving that
source at 100% traffic. The API and schema build 53 uses are therefore already
deployed, and no migration is needed.

The policy page is the exception. The Worker's `/privacy` route bundles
`website/privacy.mjs`, which changed after `cd3cf40` in #247 and #248
(8 additions, 6 deletions; policy dated October 8). The new text covers native
iPad, Health weight, Intervals metadata and partner training. The serving Worker,
like the public website, still serves the older policy. Publishing the current
policy on both hosts remains an owner action before resubmission, as **Next
step** already requires. No Worker deployment or migration was made.

## Signing

The first archive attempt failed before upload: Xcode had no signed-in
account, and the provisioning profiles lacked the App Group
`group.com.nmarkspdx.tresfort` that #256 added to the app and widget. A
read-only API check showed neither App ID had App Groups enabled. CI builds
unsigned for the simulator, so it could not catch this. The owner signed in to
Xcode, and the retry's automatic signing registered the group and regenerated
the profiles. Nothing was uploaded by the failed attempt.

## Package

`BUILD_NUMBER=53 APP_STORE_BUILD=1 ./scripts/upload-testflight.sh` on Xcode
27.0 (27A266a), iPhoneOS 27.0 SDK. A fresh App Store Connect read showed
**52** as the highest build. `ios/project.yml` was not edited.

- App and widget are **1.0 (53)**, minimum iOS 17.0, `UIDeviceFamily`
  **[1,2]**. The exported IPA's app Info.plist also reads [1,2].
- The Station SDK and its model are excluded. The archive and IPA contain no
  MediaPipe, `.task` or `pose_landmarker` entries, and the app has no
  `Frameworks` directory.
- Privacy manifests are embedded in the app (UserDefaults `CA92.1` and
  `1C8F.1`, system boot time `35F9.1`) and, new in this build, in the widget.
- The distribution-signed app and widget both carry the
  `group.com.nmarkspdx.tresfort` App Group, with `get-task-allow` false.
- `codesign --verify --deep --strict` passed on the archived app.

The 14,508,182-byte IPA has SHA-256
`ec3b061c2ef2219b1c7cdf730d92ae0e89f662f1f60428e57f0975fda8c6d16a`.

## Apple availability

Upload reported **UPLOAD SUCCEEDED with no errors** at `2026-10-11T18:21:17Z`,
delivery UUID and Apple build ID `4fd94ce1-5c14-4101-9120-fdde3089670d`. At
`2026-10-11T18:22:39Z` Apple reported **VALID** and **APP_STORE_ELIGIBLE**.

A read at `2026-10-11T18:25` showed version 1.0 on build 40, **REJECTED**.
With the owner's approval, one App Store Connect write
(`PATCH appStoreVersions/…/relationships/build`, HTTP 204) replaced build 40
with build 53. A readback at `2026-10-11T18:25:31Z` shows version 1.0 on
**build 53**, release type **MANUAL**. Its state moved from REJECTED to
**PREPARE_FOR_SUBMISSION**, Apple's editable state after a build change.

No screenshots, metadata, App Privacy answers, App Review reply, submission or
release were changed. The original review submission `ea595b5e…` remains
UNRESOLVED_ISSUES with its single item REJECTED until the owner replies and
resubmits.

## Screenshots

Fresh draft sets were captured from `47be49d` with
`scripts/capture-app-store-screenshots.sh` (iOS 26.2 runtime, en_US, fictional
data):

| Set | Device | Images | Size | Captured (UTC) |
|---|---|---|---|---|
| `.artifacts/app-store-iphone-53` | iPhone 17 Pro | 5 | 1206 × 2622 | 2026-10-11 18:11:56 |
| `.artifacts/app-store-ipad-53` | iPad Pro 13-inch (M4) | 6 (adds Station) | 2064 × 2752 | 2026-10-11 18:14:22 |

All images validated as opaque RGB at native size, with source parity. On each
device the capture journeys passed, and the device-specific test was skipped by
design. The folders are gitignored on the release Mac and were not uploaded to
App Store Connect.

Changes visible since build 50:
- Today has a header "+" menu and a Coming Up list. On iPhone, the second
  Coming Up card scrolls under the tab bar.
- The iPhone runner and Today show the iPad-display control.
- The iPad runner uses the large display layout.
- Station shows the new Connect iPhone setup and the "Reconnect automatically"
  option.

Progress is not in the capture sequence, so its new streak and day grid do not
appear.

The three build-50 cosmetic points remain:
- The iPadOS window-corner handle shows at the bottom right of every iPad image.
- `05-feedback` on both devices shows the scrolled "Optional" header ghosting
  behind the "Finish workout" title.
- `06-station` shows Train together disabled before a partner connects.

## Verification boundary

Simulator captures do not establish physical-device behavior, widget or
reminder delivery on device, speech recognition or App Review approval. The
designated-account, native iPad and three-device partner checks remain
unperformed (P1/P3(a)).
