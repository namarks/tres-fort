# Release 1.0 (52)

## Source and authority

This continues the owner's internal TestFlight rollout for the iPad workout
display and camera tracking. On October 10 the owner requested easier device
connection, then merged [PR #253](https://github.com/namarks/tres-fort/pull/253)
and confirmed the merge in this session. The release uses that merged main
commit `d5958f1c006ea58229a2877f8fb095b271d18d8b`, tree
`769e5ca0836a79713c1e789c8db2c77ea9fe4d1e`. The isolated source checkout was
clean through generation, archive and export; this documentation was written
afterward on a separate release-record branch.

The build adds a visible iPhone **iPad display** action, an iPad setup QR,
explicit phone confirmation and remembered account-scoped connection choices.
The QR contains only navigation and does not grant access or start a workout.
Pairing can happen before training, and reopening Station reconnects using the
same account's opt-in. Retry preserves pending count and Undo state, while
ending a workout clears its armed set, count and Undo before another begins.
Idle discovery allows phone auto-lock; a connected, open foreground workout
holds the phone awake. The existing app Theme and both iPad workout modes remain.

## Verification

The release tree is byte-for-byte identical to reviewed PR head
`baa0a915b6f4528e621d6d3e0d2d5d02d1079728`. Cloud Codex review completed with
no findings on that head, both earlier review threads are resolved, and all
15 jobs in [CI run 38080966056](https://github.com/namarks/tres-fort/actions/runs/38080966056)
passed: plan graph, backend shards and aggregate, all six full iOS groups,
iPhone and iPad public builds, camera-enabled iPad Station, and the iOS aggregate.

Focused native tests also cover real iOS setup-URL handoff, explicit consent
and cancellation, account isolation, remembered choices, QR decoding, retry
and Undo integrity, workout-boundary reset, screen-awake lifetime and the
existing Today navigation journey. Synthetic screenshots were checked against
the shared Theme. These checks do not establish physical pairing or counting
accuracy.

Backend source, migrations, Worker configuration and npm dependencies are
unchanged from build 51, which retained the release-49 backend. No Worker
deployment, migration or authenticated workout mutation was performed.

## Signed camera-enabled package

Xcode 27.0 (27A266a) generated the ordinary `ios/project.yml` beta project and
archived/exported using the explicit `CURRENT_PROJECT_VERSION=52` override.
The source version file was not changed. Generation verified MediaPipe 0.10.21,
all six audited binaries and Pose Landmarker Full float16 revision 1.

The signed archive and exported IPA both passed these checks:

- App and widget are **1.0 (52)**, minimum iOS 17.0, families **[1,2]**.
- The `tresfort` URL scheme, camera and Local Network descriptions, and
  `tresfort-stn` Bonjour services are present.
- The camera runtime and license notice are retained; the Full model is
  9,398,198 bytes with SHA-256
  `5134a3aad27a58b93da0088d431f366da362b44e3ccfbe3462b3827a839011b1`.
- `codesign --verify --deep --strict` succeeds for both packages.

The uploaded IPA is **26,832,412 bytes**, SHA-256
`31519e791eb323610aa932bdef3f976e0ae85563cc3e054d5132c659cbdefb78`.

## Apple availability

Fresh preflight found build 51 newest and build 52 unused. The uploader
reported **UPLOAD SUCCEEDED with no errors** at
`2026-10-10T14:41:32.131-07:00`. Delivery UUID and Apple build ID:
`27a848ec-e046-480c-b366-8c3864d44eb3`.

At `2026-10-10T21:43:38.967Z`, Apple reported **VALID**, not expired, and
**IN_BETA_TESTING**. Complete paginated group/build relationship reads confirmed
assignment to internal **Testers** (`5df996bf-8c8b-471e-b79e-f626a4f98211`),
with no external group assignment and no group mutation needed. Fresh direct
screenshot-feedback and crash-feedback queries returned no submissions.

This release did not select an App Review build or submit an external beta or
public release. The SDK-free public candidate remains a separate track.

## Device-testing handoff

Update both devices to **1.0 (52)** in TestFlight. On iPad, open Station and tap
**Connect iPhone**, then scan its QR using the iPhone and confirm **Connect iPad**.
The visible **iPad display** action on iPhone is another setup entry point.
Use the same signed-in account on both devices, allow Local Network access,
and fetch the link key online once. After opting in, opening the phone app
and iPad Station reconnects without repeating setup.

Start the workout on iPhone for linked control. On iPad, use **Camera & options**
and **Enable camera** only when testing tracking. Supported counted sets retain
the existing iPhone-controlled logging and Undo path; unsupported movements
stay manual. Standalone iPad workouts retain manual logging and timers.

Verify first pairing, relaunch/reconnect, before/after-workout transitions,
across-room readability, count accuracy, premature completion, Undo and manual
correction on the actual devices. No successful physical pairing, installation,
recording or workout was observed or initiated by this release workflow.

Sanitized source, package, upload and Apple receipts, plus the IPA and dSYMs,
are retained in `.artifacts/release-52` in the originating task workspace.
Temporary build outputs and the isolated release checkout are cleaned after
publishing this record; the release source above remains immutable.
