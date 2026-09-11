# Release from latest main — 1.0 (37)

Dated release evidence for September 10, 2026 (Pacific). The owner requested
deployment of the latest main, including the Today/Calendar update and the
workout-runner fixes.

## Source and verification

- Release source: `2d11be717089bc989afa159e18c2438787465ac7`; tree:
  `1b4eb742031f2b445acbdc814caa2a088ffa3154`. Remote main still matched this
  source immediately before deployment.
- [PR #178](https://github.com/namarks/tres-fort/pull/178) completed independent
  review at `46934673b6c23965b27ac96bb009b74aed338672`, with all review threads
  resolved and all eight checks green in
  [CI run 34560244212](https://github.com/namarks/tres-fort/actions/runs/34560244212).
  The release differs from that reviewed head only in the previously reviewed
  gym-runner delivery record. App and backend source match.
- Local release preflight passed typechecking, all 994 backend tests in 70
  files, the auxiliary checks and the Worker dry run. The signed archive and
  exported app both passed signature verification. All 577 tracked source
  hashes remained unchanged through packaging.

## Production backend

- Version `aed5a37a-3c18-4b62-8bf2-c4c3a1b66c9f`, deployment
  `ea553925-5139-48db-9e4c-19ea5a8ba7bc`, serves 100% of traffic from
  2026-09-11 04:38:23 UTC. Its annotation identifies the source and tree above.
  The calendar-move endpoint was deployed before uploading its client.
- The migration ledger exactly matched all 48 source migrations; its SELECT
  reported no database changes or rows written. No migration was run.
  Runtime and binding metadata match the preceding deployment; owner identity
  remains configured and development auth is absent. The hourly cron remains.
- Public health and OAuth discovery passed. State and calendar-move requests
  without authentication returned 401; development auth returned 404.
  These checks do not establish authenticated write behavior. The owner's
  existing live-workout-canary deferral remains explicit; physical-device
  coverage remains unverified.

## TestFlight

The verified package is version 1.0, build 37, iPhone-only, bundle
`com.nmarkspdx.tresfort`, with matching widget version, the required-reason
privacy manifest, and no synthetic fixture environment marker. IPA SHA-256:
`d5d14fefc70fe6a15c344bc5243d9ebb0aef75eebf7b74d109817ae7003f8e0f`.

Build 37 was unused immediately before upload. Apple returned
`UPLOAD SUCCEEDED with no errors` at 2026-09-11 04:40:32 UTC, with delivery/build
ID `8bbb3c74-d993-4777-8b0b-8cacf17db5d2`. The 04:42:57 UTC read confirmed
version 1.0, build 37, VALID processing, IN_BETA_TESTING, notifications enabled,
and membership in the internal Testers group. External Alpha Testers does not
include this build. The signed package and provider receipts are retained on
the release host under
`~/.codex/visualizations/2026/09/10/01a08c61-b823-7fd0-974f-360756849cfc/latest-release/`.

The preceding build 36 was accepted from source
`4340c368e248d96cc6618be1a418a42e3d8f18c0` before the owner clarified that the
release should include all of latest main. Build 37 supersedes it.
The website source matches the already published version and required no
redeployment. No App Store review submission or public release is part of this
internal TestFlight distribution.
