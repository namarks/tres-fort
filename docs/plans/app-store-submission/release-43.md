# Release 1.0 (43)

## Source and authority

The owner approved workout-library P0.5(b) on 2026-09-18 Pacific, followed by
combined internal TestFlight distribution of P0.4(a) usability fixes and
P0.5(a)/(b) exercise guidance, history and discovery. The release source is
`28dd647b5746e9459dad7ada68c0a961eaf8c86b`, tree
`c2c24df88fbb65bc3ee44b43b9ff224ad4ea2049`, merged in
[PR #214](https://github.com/namarks/tres-fort/pull/214).

The merged tree exactly matches independently reviewed head
`93fd547546c202257133ff4141152beb67da7360`. Both local and hosted reviews found
no actionable issue, no review threads remained, and all eight checks in
[the final-head CI run](https://github.com/namarks/tres-fort/actions/runs/35406147244)
were terminal-green before the pinned merge. CI completed 625 iOS unit tests
with one existing skip and no failures, and all 12 smoke journeys passed.
Focused local verification additionally covered alias/filter composition,
empty-result reset, Add/warm-up scope, preserved selection/history/timers,
cancellation and post-swap logging. Creation/review and complete swap journeys
passed at the largest system text size; screenshots were inspected.

## Production compatibility

The release has no change to Worker source, migrations, runtime configuration
or backend dependencies since [build 42](release-42.md). A fresh September 18
Cloudflare read confirmed deployment `5d5cc071-3ddc-4b58-83ac-82e1e61c45bc`,
Worker version `92adb0e0-28bd-4952-81ad-b09029f75ac9`, at **100% traffic**.
Its source annotation remains `5df9208fc01219f298866ee4528cda533b86d33d`.
No deployment, migration or production data change was performed for this beta.

Public checks at `2026-09-18T23:36:53.809Z` returned health HTTP 200 with the
expected service identity and unauthenticated API state HTTP 401. Health has no
source SHA; the Cloudflare deployment receipt separately establishes the serving
source. These checks do not establish authenticated training behavior.

## iOS package and distribution

The exact merged source archived and exported successfully as **1.0 (43)**.
The app and widget both report build 43, their distribution signatures verify,
and neither permits debugging. The app retains both associated domains.
Upload at `2026-09-18T23:57:17.514Z` reported **UPLOAD SUCCEEDED with no errors**,
delivery UUID `b2477c80-2ea4-4b7e-b1a3-4c3256b97b67`.

Uploaded IPA SHA-256:
`0b6c0148013b9872a4c4dd9f9880b654eac2c9dabab696ca0810423dd6971f5c`.

At `2026-09-19T00:00:16.241Z` (September 18 Pacific), Apple reported build
`b2477c80-2ea4-4b7e-b1a3-4c3256b97b67` **VALID** and **IN_BETA_TESTING**.
A complete group-build read confirmed assignment to internal **Testers**
(`5df996bf-8c8b-471e-b79e-f626a4f98211`). External Alpha Testers do not have
build 43; its external state is `READY_FOR_BETA_SUBMISSION`. No external-beta
submission or tester-group change was made.

## App Store and device boundaries

The September 18 post-upload read still selects **build 40**, **IN_REVIEW**,
with release type **AFTER_APPROVAL**. This upload did not change the App Review
submission, selected build, release mode, listing metadata or external beta
assignment. The canonical plan retains the open owner decision about automatic
public release; this internal beta does not supply that authority.

Physical-iPhone and VoiceOver acceptance remain unverified. Existing owner
deferrals and outstanding authenticated live-training checks retain their
previous scope; simulator tests and TestFlight availability do not close them.

Value-free source, review, CI, upload, package and Apple receipts, plus the final
IPA and signed archive, are retained on the release host in this task's
`exercise-discovery` artifact directory. Temporary release and build workspaces
are cleaned after verification.
