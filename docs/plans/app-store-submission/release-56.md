# Release 1.0 (56)

## Source and authority

This camera-enabled internal beta restores camera tracking on test devices after
TestFlight moved them to App Store build [55](release-55.md), which has none. On
October 30 the owner approved uploading it as build 56.

The source is main `2b3007832bdf69cf60195bfdf233977d3fb1b501`, the same as build
55. Later commits on main, including the run recorder (#268–#270) and its backend
routes, are deliberately not included. The checkout was clean through archive
and export. No Worker deployment or migration was made.

## Signed camera-enabled package

`BUILD_NUMBER=56 ./scripts/upload-testflight.sh` used the ordinary `ios/project.yml`
beta configuration on Xcode 27.0. `ios/project.yml` was not edited. Archive
readback:

- App and widget are **1.0 (56)**, families **[1,2]**; the exported IPA's app
  Info.plist reads [1,2] as well.
- The camera usage description and `Notices/MediaPipe-LICENSE.txt` are present.
- `pose_landmarker_full.task` is 9,398,198 bytes, SHA-256
  `5134a3aad27a58b93da0088d431f366da362b44e3ccfbe3462b3827a839011b1`, the same
  model as builds 51, 52 and 54.
- `codesign --verify --deep --strict` passed on the archived app.

The uploaded IPA is **30,402,188 bytes**, SHA-256
`6cec1cb1f9148be590262700d86f35a898404319011a77b5a5eebcc7720d19f0`.

## Apple availability

Upload reported **UPLOAD SUCCEEDED with no errors**, delivery UUID and Apple build
ID `7fdc8d7c-33f1-4267-ab76-8ca3f8c79ae7`, uploaded `2026-10-30T06:21:10Z`. At
`2026-10-30T06:23:56Z` Apple reported **VALID**, **IN_BETA_TESTING** and internal
**Testers** membership, with no group change from this release. External state is
READY_FOR_BETA_SUBMISSION, meaning not submitted.

Apple also labels this build APP_STORE_ELIGIBLE, which is its audience
classification, not a selection. This build carries the experimental camera SDK
and must never be selected for version 1.0. Version 1.0 selects build 55.

Physical acceptance, counting accuracy and partner trials remain unperformed.
