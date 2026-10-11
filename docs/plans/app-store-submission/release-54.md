# Release 1.0 (54)

## Source and authority

This is the camera-enabled internal beta that pairs with the App Store candidate
[1.0 (53)](release-53.md). On October 11 the owner asked to update the builds to
the latest app and chose 53 for the candidate and 54 for the beta, so TestFlight
auto-update lands test devices on the camera build.

The source is main `47be49d11e6720826bc53444382c4cc7ec0df8ae`, tree
`5593e6c13f7f8d0ad391ab68e158d44314015f4d`, the same as build 53. Review, CI,
backend-compatibility and signing evidence are in [release 53](release-53.md).
No Worker deployment or migration was made.

## Signed camera-enabled package

`BUILD_NUMBER=54 ./scripts/upload-testflight.sh` used the ordinary
`ios/project.yml` beta configuration on Xcode 27.0 (27A266a), iPhoneOS 27.0 SDK.
`ios/project.yml` was not edited. Archive readback:

- App and widget are **1.0 (54)**, minimum iOS 17.0, families **[1,2]**. The
  exported IPA's app Info.plist also reads [1,2].
- The camera usage description and `Notices/MediaPipe-LICENSE.txt` are present.
- `pose_landmarker_full.task` is 9,398,198 bytes, SHA-256
  `5134a3aad27a58b93da0088d431f366da362b44e3ccfbe3462b3827a839011b1`, the
  same model as builds 51 and 52.
- `codesign --verify --deep --strict` passed on the archived app.

The uploaded IPA is **30,249,038 bytes**, SHA-256
`09fbf93b9e05896e6fb416755a3374eb3ae4157ba6ad84aae733eede00c37a78`.

## Apple availability

Upload reported **UPLOAD SUCCEEDED with no errors** at `2026-10-11T18:24:18Z`,
delivery UUID and Apple build ID `b3a4b493-428f-41c6-9ba7-7ab94c6972da`. At
`2026-10-11T18:26:31Z` Apple reported **VALID**, not expired, internal state
**IN_BETA_TESTING** and membership in internal **Testers**
(`5df996bf-8c8b-471e-b79e-f626a4f98211`). External state is
READY_FOR_BETA_SUBMISSION, meaning not submitted. No group change was made.

Apple also labels this build APP_STORE_ELIGIBLE. That is Apple's audience
classification, not a selection. This build carries the experimental camera
SDK and must never be selected for version 1.0. Version 1.0 selects build 53.

## Device-testing handoff

TestFlight will offer 54 as the newest build on both devices. It adds the
changes listed in [release 53](release-53.md) to the existing camera-tracking
trial. Physical widget and reminder delivery, pairing recovery, count accuracy
and partner trials remain untested by this release.

Temporary build outputs remain in the ignored `ios/build` on the release Mac.
Apple retains the uploaded build.
