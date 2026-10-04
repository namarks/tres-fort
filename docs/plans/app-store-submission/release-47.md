# Release 1.0 (47)

## Source and authority

On October 3, the owner requested TestFlight distribution of the implemented
Focus UI changes, then separately approved production deployment after review
identified a pre-existing client/server mismatch in slot-edit version handling.
No migration was needed or performed. App Review, external beta and public
release were not changed.

The pinned source is `e3251de9bf8ff6f2e447068b69fe4154c0b468a8`, merged in
[PR #229](https://github.com/namarks/tres-fort/pull/229), with tree
`aba65725ce8a9dddb1001e6af30fdea66be5ccc6`. Fresh main ancestry and tree equality
were verified against independently reviewed head
`343fb2ee9c7d52bc3c47727585a65787f97325a4`. Hosted review completed without open
findings on that head; all eight checks in [the final source CI run](https://github.com/namarks/tres-fort/actions/runs/37157621092)
passed. Final CI executed 685 native unit tests (684 passed, one simulator-only
file-protection skip) and passed 12 UI smoke journeys. Separately, 51 distinct
local targeted UI journeys passed across implementation and repaired-case runs;
that count is not one complete final-head suite.

The client keeps load/reps and logging central, with compact rest/correction,
circuit context, a Workout outline for secondary actions and Minimize/Resume.
Date selection is separate from library management, Calendar starts or continues
today's workout, and completed sets expand beneath exercise summaries.

## Production deployment

Before deployment, Worker `af9f084e-75a6-443d-ac81-2592ee627cb5` rejected a slot
PATCH containing the client's `expected_version` as `unknown_fields`; add and
delete did not enforce the caller's reviewed version. This mismatch predates
PR #229. The reviewed source already extracts that token from the PATCH body
and validates it through the shared slot writer for add/edit/delete.

The D1 ledger already contained every migration in the source, including
`0055_weight_units.sql`. Read-only schema checks confirmed both unit columns,
their defaults/check constraints and no invalid unit values. There were no
pending migrations. The Worker dry-run passed before the owner approved the
exact source deployment. No authenticated training mutation was performed.

Deployment `dbb136b7-ca48-4f7f-acc6-530af2955f5d`, created at
`2026-10-03T23:30:07.611728Z`, serves Worker
`b42af081-459b-477b-82ee-dfa8a39b327f` at **100% traffic**. Both deployment and
version metadata annotate the exact source and tree above. Existing D1/R2
bindings, compatibility settings and hourly schedule were retained.

At `2026-10-03T23:31:54.490Z`, public health returned HTTP 200 with the expected
service identity; unauthenticated state and MCP POST returned 401. Health does
not expose a source SHA, so the provider receipt establishes source attribution.
An initial Python urllib request received edge error 1010/403; the Node release
HTTP client completed all three checks. These checks do not prove authenticated
production workout behavior.

An independent check downloaded the newly deployed Worker and passed 19 local
checks using exact extracted JavaScript with synthetic inputs and stubbed
service/database boundaries. PATCH strips and passes `expected_version`
separately; add/edit/delete reject stale or malformed versions. Valid service
paths pass validation and stop before database mutation. Load units remain
forwarded and SQL-bound. The downloaded bundle SHA-256 is
`c6f34f6e82d3c4b5886cbaaee4e2ca6356182117e0f6ab3e570987d8ab5da747`.
This verifies the deployed implementation without claiming a live account write.

## iOS package and Apple availability

Xcode 27.0 (27A266a) archived and exported the pinned source as **1.0 (47)**.
The app and widget both carry build 47, and archive signatures verified. The
10,003,610-byte IPA has SHA-256
`b971a5cb09bb262b28187ffc33ac1d276af860d2e19650941276e84d9a9391a7`.

Upload at `2026-10-03T23:12:22.522Z` reported **UPLOAD SUCCEEDED with no errors**,
delivery UUID `eda2ae3a-5331-4020-bfb2-c6bceda714e0`. At
`2026-10-03T23:31:29.944Z`, Apple reported that build **VALID** and
**IN_BETA_TESTING**. Complete paginated relationship reads confirmed assignment
to internal **Testers** (`5df996bf-8c8b-471e-b79e-f626a4f98211`). External Alpha
Testers do not have build 47; its external state is READY_FOR_BETA_SUBMISSION.

The same read confirms App Store version 1.0 remains on **build 40**, now
**REJECTED**, with **MANUAL** release. No candidate replacement, resubmission,
listing change or public release was made.

## Verification boundary

Authenticated production current/stale-version slot writes, session swaps,
workout-name compatibility and the live workout canary remain unperformed.
Physical-device, file-protection and manual VoiceOver acceptance remain open.
The build-44 live-verification deferral remains historical; this release does
not infer a new waiver or close App Review/public-readiness requirements.

Sanitized provider, schema, upload, package and Apple receipts are retained in
the task's local `testflight-focus` artifact directory. Canonical next actions
remain in the linked plans. Temporary build outputs are removed after release
verification; Apple retains the distributed build.
