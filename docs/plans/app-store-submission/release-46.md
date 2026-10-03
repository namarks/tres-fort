# Internal iPad corrective build 1.0 (46)

## Source and authority

This continues the owner-authorized internal Station Mode device trial. After
installing build 45, the owner reported repeated setup for an existing Apple
account, insufficient full-body framing and unsuccessful tracking. The
corrective source is `5989bce81942e18b53e9ba35918986b595408411`, tree
`316927ed68199c786ca290d14aa582e93e3942de`, on
[PR #228](https://github.com/namarks/tres-fort/pull/228).
[Independent review of that exact source](https://github.com/namarks/tres-fort/pull/228#issuecomment-5973785346)
found no major issues. Backend, typecheck and plan CI passed; seven Mac jobs
remained queued at upload. Repository merge still requires all configured
checks and review of the current head.

The client now checks existing server training before fresh-install setup,
prefers the front Ultra Wide camera with fixed framing, displays detected joints,
and reacquires both counters in fresh segments after tracking loss. Missing
movement remains visibly partial. A sustained native probe also exposed an
Apple framework trap on the second analysis window; the adapter now uses the
pose-index ranges emitted by Apple's SlidingWindowTransformer, while retaining
capture timestamps separately for measured timing.

This internal beta does not write workouts from camera detections, record or
upload frames, deploy the Worker, migrate data, distribute to external testers,
replace the App Review candidate or make a public App Store release.

## Verification and package

- iPad checks passed 17 custom-counter, 23 comparison, seven camera-format and
  four overlay/visibility cases, plus three Station interface journeys and
  three fresh-device sign-in journeys.
- The iPhone run passed 740 unit tests with one existing skip, all 23 activation
  journeys and two navigation/set-logging journeys. It preceded only the final
  Apple adapter and its comparison-test change; all 23 comparison cases then
  passed against the exact candidate's complete iOS source set on iPad,
  including real Apple inference across two overlapping windows.
- The fixed production engine completed 180 synthetic poses with 19 estimates,
  zero admission failures and clean finish on the Mac. Synthetic input proves
  sustained API execution, not movement accuracy or A16 performance.
- The plan compiler and all 19 verification-harness/CI-selection tests passed.
  Physical framing, overlay alignment, motion-count accuracy and thermal
  behavior still need the owner's next device trial.

Evidence is retained under `.artifacts/ios/`: `tres-fort-ios.N2tWjT/` (passing
Station cases within the initial run; unrelated new test assertions were
corrected), `tres-fort-ios.RD8r7z/` (fresh iPad sign-in),
`tres-fort-ios.XueYM6/` (iPhone) and `tres-fort-ios.QSDi8b/` (exact final
comparison source). The explicit source-difference map is
`.artifacts/station-delivery/build46-verification-map.json`.

Archive/export used existing signing assets without credential or provisioning
changes. All 342 iOS source inputs remained unchanged. App and widget in both
archive and IPA passed signature, team, arm64/iPhoneOS, version 1.0/build 46 and
iPhone+iPad device-family checks. The 10,200,438-byte IPA SHA-256 is
`59ca29d8da7be54b9e336acecc2d87e18f5422258ba8ac490a9a148c7f320633`.

Apple validation returned **VERIFY SUCCEEDED with no errors** at
`2026-10-03T21:45:58.520455Z`. A fresh complete App Store Connect read confirmed
46 was unused immediately before upload. Upload returned **UPLOAD SUCCEEDED
with no errors** at `2026-10-03T21:53:05.718943Z`, delivery UUID
`d96aad86-bb9d-4df2-982e-5238698d1fd0`. The IPA hash remained unchanged.

## Apple availability

At `2026-10-03T21:55:28.607Z`, App Store Connect confirmed exact build
`d96aad86-bb9d-4df2-982e-5238698d1fd0` as **VALID**, **IN_BETA_TESTING**, not
expired and with non-exempt encryption false. The existing internal **Testers**
group (`5df996bf-8c8b-471e-b79e-f626a4f98211`) includes this build. Assignment
happened automatically; no group mutation was needed. Build 46 is available
for internal installation. Do not upload it again.

Package, validation, upload and Apple readback receipts remain alongside the
signed candidate under
`.artifacts/station-delivery/build46-5989bce81942e18b53e9ba35918986b595408411/`.
The [Station plan](../ipad-workout-station/plan.md) owns physical evaluation and
later workout-write/automation gates.
