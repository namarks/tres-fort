# Internal comparison build 1.0 (45)

## Source and authority

On 2026-10-03 the owner requested TestFlight upload of the iPad Station Mode
comparison after being told that Mac CI remained queued. The source is
`cfcdf87a6c663f2f4d678e09422ed424cc181ae1`, tree
`1e740d91be7efa609527dcfb780cbacd26e9ca95`, on
[PR #228](https://github.com/namarks/tres-fort/pull/228).
[Independent review of that source](https://github.com/namarks/tres-fort/pull/228#issuecomment-5973527266)
found no major issues. Backend/plan checks passed; seven Mac checks were queued
at upload. This is an owner-authorized internal branch build. The PR remains
unmerged and still requires every configured check plus current-head review.

The build compares the custom cycle counter and Apple HumanBodyActionCounter
on a shared stream of local camera poses. No camera frames are recorded or
uploaded; the trial cannot write workouts or advance sets. This upload performed
no backend deployment, database migration, external-beta distribution, App Review
candidate replacement or public App Store release.

## Verification and package

Local verification passed 17 custom-counter tests, all 16 comparison tests and
three iPad UI journeys. iPhone checks passed 710 unit tests with one skipped,
and three navigation/set-logging journeys. The new joint-coordinate case also
passed on iPad from the exact uploaded source. Physical camera accuracy,
placement, interruptions and thermal behavior remain device-trial evidence.

Archive and export used existing signing assets. All 339 iOS source inputs
remained unchanged. App and widget in both archive and IPA passed signature,
team, arm64/iPhoneOS, version 1.0/build 45 and iPhone+iPad device-family checks.
The 10,128,098-byte IPA SHA-256 is
`e1f45873c747be4625c4de4450e50d9dad11dc080b373c84ea2e0ffb8ebe12f4`.

A complete App Store Connect read at `2026-10-03T21:13:17.793Z` confirmed build 45
was unused. Apple validation returned **VERIFY SUCCEEDED with no errors** at
`2026-10-03T21:14:17.041Z`. Upload returned **UPLOAD SUCCEEDED with no errors** at
`2026-10-03T21:14:58.586Z`, delivery UUID
`56825dc7-cf9d-47c7-8593-7afc108e4daa`. The IPA checksum was rechecked unchanged.

## Apple availability

App Store Connect readback at `2026-10-03T21:18:16.656Z` confirmed exact build
`56825dc7-cf9d-47c7-8593-7afc108e4daa` as **VALID**, **IN_BETA_TESTING**, and
not expired, with non-exempt encryption false. A complete group read confirmed
assignment to internal **Testers** (`5df996bf-8c8b-471e-b79e-f626a4f98211`).
Assignment happened automatically; no group mutation was needed. Build 45 is
available for internal installation. Do not upload it again.

Value-free package, validation/upload and Apple receipts are retained with the
signed candidate under the task's ignored
`.artifacts/station-delivery/build45-cfcdf87a6c663f2f4d678e09422ed424cc181ae1/`.
The [Station plan](../ipad-workout-station/plan.md) owns physical evaluation and
later workout-write/automation gates.
