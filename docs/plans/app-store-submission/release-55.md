# Release 1.0 (55)

## Source and authority

On October 30 (UTC) the owner asked for help with the resubmission. In the
App Store Connect project thread they approved, in order:

1. updating the version 1.0 description and promotional text, replacing the
   App Review notes, and clearing the stored demo login;
2. uploading an App Store candidate as build 55 from main and selecting it for
   version 1.0;
3. adding Contacts, Other Data Types and Product Interaction to App Privacy and
   publishing.

Replying to App Review and resubmitting were not approved and were not done.

The source is main `2b3007832bdf69cf60195bfdf233977d3fb1b501`, tree
`47efc3b53878e80094f6df1c87f35f553b1e9b3a`. It adds, since build 53, the
linked-iPad control of the iPhone workout with outline and clock
([#265](https://github.com/namarks/tres-fort/pull/265)) and intervals.icu
routing of endurance `log_activity` entries
([#266](https://github.com/namarks/tres-fort/pull/266)). The checkout was clean.

Main's push CI on `2b30078` passed. Codex completed reviews with a 👍 and no
findings on #265's final head `a8878f6` and #266's final head `0da2163`, with no
unresolved threads. #265 passed all 11 checks on its head. #266 passed 6 checks
with one matrix job skipped by the iOS scope selector.

## Backend at upload time

A Worker deployed at `2026-10-29T23:27:22Z` (version `156a73d0-7efd-4256-b885-769f8df3e439`,
no deployment message) serves 100% of traffic. Migration `0057_activity_metrics`
is applied, and the remote ledger had nothing pending. The deployment has no
source annotation, so its exact commit is unverified. On main, backend changes
since the policy-publication source `e49cd62` are limited to intervals.icu sync,
the MCP `log_activity` path and that additive migration. The only route file
touched is `src/routes/intervalsAuth.ts`, part of the intervals.icu connect flow;
the workout, state and account REST routes used by the iOS client are not in that
diff. Health
returned the expected service identity, `/privacy` returned 200, and
unauthenticated `/api/state` returned 401. That deployment was not made by
this release workflow.

## Package

`BUILD_NUMBER=55 APP_STORE_BUILD=1 ./scripts/upload-testflight.sh` on Xcode
27.0 (27A266a). A fresh App Store Connect read showed **54** as the highest
build. `ios/project.yml` was not edited.

- App and widget are **1.0 (55)**, minimum iOS 17.0, families **[1,2]**. The
  exported IPA's app Info.plist also reads [1,2].
- No MediaPipe, `.task` or `pose_landmarker` entries in the archive or IPA.
- App and widget privacy manifests are embedded.
- `codesign --verify --deep --strict` passed on the archived app.

The 14,659,341-byte IPA has SHA-256
`9cb2f0f994743efb038369c2cd99494c60e754061681589e1b4e9f6a5ff3b461`.

## Apple availability and selection

Upload reported **UPLOAD SUCCEEDED with no errors**, delivery UUID and Apple
build ID `8741d6c3-255a-4b71-9474-e160613f2e1b`, uploaded `2026-10-30T01:10:40Z`.
At `2026-10-30T01:12:08Z` Apple reported **VALID** and **APP_STORE_ELIGIBLE**.
The build appears in internal **Testers** (IN_BETA_TESTING) with no group change
from this release, and is not submitted for external beta.

One `PATCH appStoreVersions/…/relationships/build` (HTTP 204) replaced build 53
with build 55. A readback at `2026-10-30T01:13:28Z` shows version 1.0 on
**build 55**, **PREPARE_FOR_SUBMISSION**, release type **MANUAL**. Review
submission `ea595b5e…` remains UNRESOLVED_ISSUES.

TestFlight devices will update to build 55, which has no camera tracking. The
camera-enabled beta remains build 54 unless a newer beta is uploaded.

## Listing and App Privacy changes

Listing (API, readback at `2026-10-30T00:54:12Z`):

- **Description and promotional text:** the en-US values are byte-identical to
  the review package's prepared text (1,865 and 150 characters).
- **App Review notes:** replaced with a 1,583-character explanation of the
  consent step, policy, sign-in, manual path, iPad and optional connections.
  The demo username and password were cleared, sign-in-required stays off, and
  the contact fields are untouched.
- **Unchanged:** keywords, support and marketing URLs, name, subtitle and
  privacy-policy URL.

The notes first began "Version 1.0 (53)". With the owner's approval they were
changed to "Version 1.0 (55)" on October 30; the rest of the text is unchanged.

App Privacy (App Store Connect web UI in the owner's signed-in browser): before
the change, the published label had 10 data types. Contacts, Product Interaction
and Other Data Types were added, each as App Functionality, linked to the user,
not used for tracking, and published. These match the categories declared in
the app's privacy manifest. The label now lists 13 types, with "Published a few
seconds ago" by the owner at about `2026-10-30T01:12Z`.

Agreements (read only): the Free Apps Agreement is Active. The Paid Apps
Agreement and EU trader prompts do not apply to the free, US-only app.

## Screenshots

The owner approved recapturing and replacing changed screenshots. All three sets
were recaptured from `2b30078` and compared pixel by pixel with the uploaded
build-53 sets.

- **Unchanged (14 of 16):** both iPhone sets and iPad Today, Workouts, History and
  Station differ only in the status-bar clock, so they were left in place.
- **Changed (2):** iPad `02-runner` and `05-feedback`, which shows the runner behind
  its sheet. #265 added a header with a workout stopwatch and the time of day.

The first recapture showed the stopwatch at 1247:25:47: the display reads the real
clock while the screenshot fixture freezes the model on its fictional date. Those
images were not uploaded. The Debug-simulator-only fixture fix `2da2048` gives the
fixture a plausible running time, and release builds are unaffected. Capture commit
`b06d784` is `2b30078` plus only that fix, and the set is in
`.artifacts/app-store-ipad-55b`. Both images matched their manifest hashes.

Each replacement reached COMPLETE before its old image was deleted, and the set's
order was restored. A readback at `2026-10-30T17:45:15Z` shows iPhone 6.9-inch
(5 × 1320 × 2868), iPhone 6.3-inch (5 × 1206 × 2622) and iPad 13-inch
(6 × 2064 × 2752), all COMPLETE; the 6.5-inch set is empty.

The three earlier cosmetic points remain. Progress is not in the capture sequence,
so its streak and day grid do not appear.

## Verification boundary

The designated-account, native iPad and three-device partner checks remain
unperformed on the public candidate. Authenticated workout compatibility with
the serving Worker is also unverified. No App Review reply, resubmission or
release occurred.
