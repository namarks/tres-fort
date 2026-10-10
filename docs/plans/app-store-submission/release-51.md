# Release 1.0 (51)

## Source and authority

On October 9 the owner explicitly requested a new internal TestFlight build
with the iPad workout display and camera tracking enabled for testing on both
devices. The source is merged main
`8cf823538370d275bc738de7b005eff5199b30d8`, tree
`bbb7f176761e86c9d9a5ac4ce28b3707ea58f731` (PR #251's merge).
The isolated source checkout was clean throughout generation, archive and export;
these release records were written afterward.

This delivers the native, Theme-backed distance-readable display for standalone
iPad workouts and workouts controlled by an iPhone, including current and next
prescriptions, RPE, set/round and rest/timed-set countdowns. The beta configuration
also restores the experimental on-device camera tracking omitted from build 50.
Camera-assisted logging continues to use the iPhone as controller; standalone
camera logging and new automatic-progression policy are not added.

## Verification

All 15 jobs in [CI run 37964867289](https://github.com/namarks/tres-fort/actions/runs/37964867289)
passed on PR #251's final head `3a96ecb7a38c94b5a140bae55b0b5049c60cc304`:
plan graph, three backend shards, six full iOS shards, iPad Station, both public
device jobs, and the required aggregates. The release source differs from that
head only in the build-50 receipt and App Store plan; application, test, dependency
and CI source are identical.

The cloud Codex review of the final implementation head remained unavailable
because of usage limits. A fresh independent local advisory review found no
P1-P3 findings, and the earlier RPE finding was fixed. The owner subsequently
merged PR #251 and requested this internal release after the review gap was
disclosed. This receipt does not claim a completed exact-head cloud review.

Backend source, migrations, Worker configuration and npm dependencies are
unchanged from release-49 source `cd3cf4057320daa474292b86f3ddbbca401d5099`.
No Worker deployment, migration or authenticated workout mutation was performed
for this release.

## Signed camera-enabled package

Xcode 27.0 (27A266a), with the iPhoneOS 27.0 SDK, generated the ordinary
`ios/project.yml` beta configuration and archived/exported with the explicit
`CURRENT_PROJECT_VERSION=51` override. The source version file was not bumped.
The project generation step verified pinned MediaPipe 0.10.21 artifacts, all six
audited binaries, and Pose Landmarker Full float16 revision 1.

Before upload, both the signed archive and the exported IPA were inspected:

- App and widget are **1.0 (51)**, minimum iOS 17.0, with device families
  **[1,2]** for iPhone and iPad.
- The camera usage description and MediaPipe license notice are present.
- `pose_landmarker_full.task` is 9,398,198 bytes, SHA-256
  `5134a3aad27a58b93da0088d431f366da362b44e3ccfbe3462b3827a839011b1`.
- The app binary retains the Pose Landmarker runtime class and graph metadata;
  the new workout display source was included in the archive compilation.
- `codesign --verify --deep --strict` passed for both packages.

The uploaded IPA is **26,759,463 bytes**, SHA-256
`7e5f458b1edbf94013c40e4eac74beb4a1d1d7e29523f8087346b336a24833ed`.

## Apple availability

A fresh preflight showed build 50 as the newest upload and build 51 unused.
The uploader reported **UPLOAD SUCCEEDED with no errors** at
`2026-10-09 21:55:18` Pacific. Delivery UUID and Apple build ID:
`659f9291-e2f8-48a6-89f7-dc634dad3f85`.

At `2026-10-10T04:57:37.713Z` (October 9 Pacific), Apple reported build 51 as
**VALID**, not expired, and **IN_BETA_TESTING**. Complete paginated beta-group
relationship reads verified assignment to internal **Testers**
(`5df996bf-8c8b-471e-b79e-f626a4f98211`), with no external group assignment.
No group mutation was needed. Fresh direct screenshot-feedback and
crash-feedback reads returned no submissions for this build.

This internal beta was not selected for App Review or submitted for public
release. The SDK-free public candidate remains a separate delivery track.

## Device-testing handoff

Update both devices to **1.0 (51)**. Before publication, the connected iPad was
verified on build 50 and the owner reported build 50 on iPhone. Availability of
51 does not establish installation or physical acceptance.

For linked testing, keep the workout open on iPhone and enable **Use iPad
workout display** in its workout options. On iPad, open Station and enable
**Follow my iPhone workout**. Both devices need the same signed-in account and
an internet connection once to obtain the link key. Use **Camera & options**
and **Enable camera** on iPad for tracking. Supported counted sets use the
existing guarded iPhone logging path with Undo; unsupported movements stay manual.
Standalone iPad workouts use manual logging and existing timers.

Physical readability, connection recovery, count accuracy, premature completion,
Undo, corrections and sustained mounted-device behavior remain to be tested.
No recording or device workout was started by this release workflow.

Sanitized source, package, upload and Apple receipts are retained under
`.artifacts/release-51` in the originating task workspace, along with the IPA
and dSYMs. Temporary build outputs and the isolated release checkout are cleaned
up after the release record is published. The release documentation branch is
independent of the immutable source used for build 51.
