# First App Store Submission

Slug: app-store-submission · Status: active · Updated: 2026-09-19 · Theme: release

## Goal

Prepare a verified Très Fort 1.0 build and complete App Store review package
for a free, United States-only first release. Completion requires an exact
candidate, compatible production backend, documented verification and owner
exceptions, accurate privacy disclosures, listing and reviewer access. The owner
requested expedited shipment on 2026-09-10. Complete the prepared App Store
package and submission requirements while retaining the existing submission.
The current Apple release setting is AFTER_APPROVAL, as read back on 2026-09-19
Pacific, with build 40 IN_REVIEW. Build 40 is now known to use retired workout
routes/fields and is incompatible with the serving canonical Worker. Public
release is blocked on a compatible candidate; the unchanged Apple setting can
still publish automatically if review completes. Request an authorized change
to MANUAL before that happens. Preparation
and TestFlight availability do not mean public release.

## Phases

- [x] **P0 — Submission foundations and release defects**
  - Add privacy/support links before sign-in and in Profile, and bundle a
    required-reason manifest for actual API use.
  - Explain optional Claude/Anthropic and Apple Health data sharing at the
    authorization controls; preserve manual use without integrations.
  - Diagnose feedback replacement failure without weakening saved-text
    assertions; pass focused behavioral and required full checks.
  - Align marketing version with the App Store 1.0 record; choose the build
    number only after a fresh App Store Connect read.
- [ ] **P1 — Privacy and public-user review readiness**
  - Trace deletion/export, HealthKit cache/backup behavior, coach access and
    withdrawal, and private-group content through the actual paths.
  - Resolve essential reporting/blocking/filtering requirements for group
    content with a bounded design before changing member/data policy.
  - Prepare accurate App Privacy and age-rating answers against final source
    and provider behavior. Confirm public policy/support URLs work.
- [ ] **P2 — Review package**
  - Prepare copy, category, synthetic-data screenshots from the actual candidate
    UI, and reviewer instructions for manual onboarding, logging, optional
    integrations, export and deletion.
  - Confirm viable reviewer access without personal training data; any reviewer
    credentials remain owner-managed.
  - Verify free pricing, US-only availability and applicable agreements; request
    owner confirmation for fields inaccessible to existing tools.
- [ ] **P3 — Exact candidate and production verification**
  - [ ] **(a) Compatible production backend**
    - Independently review the final head and pass all required checks.
    - Read deployed source/configuration and migration ledger; prepare an exact
      migration/deployment proposal if the candidate needs a newer backend.
    - Retain the authenticated session-swap and workout-name compatibility
      verification requirements. These live checks remain unperformed after
      the owner-authorized build 40 upload; neither public health nor Apple
      processing establishes those API behaviors.
    - Retain physical-iPhone verification results and any explicit owner deferral
      without claiming unperformed checks passed. The owner deferred the live
      pre-upload workout canary and its observation on 2026-09-10. Other physical
      coverage remains unverified; reuse the [device procedure](../completed/coaching-feedback-loop/device-verification.md)
      when that follow-up resumes.
  - [x] **(b) Signed candidate and Apple processing**
    - The owner separately approved Xcode signing and then explicitly approved
      validation and upload of 1.0 (40). Xcode validation/upload succeeded;
      Apple reports VALID and IN_BETA_TESTING in internal Testers. Exact source
      and the signed archive are retained. P3(a) live checks remain unperformed.
- [ ] **P4 — Submission and public-release handoff**
  - [x] Select build 40 and retain Apple's review-submission receipt. The owner
    submitted 1.0 (40) on 2026-09-14 at 01:23:28 UTC (2026-09-13 Pacific);
    API readback confirms WAITING_FOR_REVIEW and MANUAL release.
  - [ ] Resolve remaining P1/P2/P3 verification requirements and any Apple review
    response before the separately authorized public-release decision. Submission
    acceptance does not establish that unperformed checks passed or were waived.

## Execution frontier

- P1
- P2

## Dependencies

| Local phase | Relationship | Target | Reason |
|---|---|---|---|
| P4 | gated_by | external:app-store-owner-fields | Build 40 is incompatible with the serving canonical backend; request MANUAL to prevent automatic publication, then verify a compatible candidate and agreements/privacy before public release. |

## Next step

**Now (@owner):** Authorize changing build 40's AFTER_APPROVAL setting to MANUAL
before Apple finishes review. The selected build is known to be incompatible
with the current canonical backend: its default `.legacy` client writes to
`/api/days` and sends `day_template_id`; the serving Worker rejects that route
with 404 and those fields with 400. Do not publicly release this candidate.
After preventing automatic publication, replace it with a verified compatible
canonical build under separate App Review authority. The request to switch to
MANUAL is pending; the Apple setting has not changed. TestFlight/backend
approval does not authorize App Review changes or public release.

**Internal beta follow-up (2026-09-18):** The owner approved workout-library
P0.5(b), then a combined internal TestFlight build including P0.4(a), P0.5(a)
and P0.5(b). [Build 43's release receipt](release-43.md) records completion from
reviewed merged source `28dd647b5746e9459dad7ada68c0a961eaf8c86b`, successful
archive/export/upload and verified distribution signatures. At
`2026-09-19T00:00:16.241Z` (September 18 Pacific), Apple confirmed VALID,
IN_BETA_TESTING and internal Testers assignment. The Worker is unchanged from
build 42 and needed no deployment. This beta does not replace build 40 in App
Review or authorize public release or metadata changes.

**Build 44 preparation and backend release (2026-09-19):** The owner requested
TestFlight and separately approved migrations 0053/0054 and the matching
canonical Worker. [The release receipt](release-44.md) records the applied
migrations, verified production source at 100% traffic, and signed,
Apple-validated 1.0 (44) package. Build 44 is not uploaded: authenticated live
workout checks remain unperformed, and the requested specific deferral is
pending. This does not change the App Review build or publication authority.

**Current Apple readback (2026-09-19):** Version 1.0 now has build 40
**IN_REVIEW** with **AFTER_APPROVAL**. Build 43 is the latest internal beta,
VALID and available to Testers; external Alpha Testers do not have it. This run
did not change the App Review build or release mode. The owner decision above
remains open.

**Agent follow-through:** Finish the runnable P1/P2 audit against pinned source
`9373d6f0acad9a9ef444e54fe9c9d8a8b7ad24c8`: reconcile privacy/account and group
controls, public policy/support availability, listing and reviewer instructions,
and the documented verification exceptions. Record evidence and identify any
owner-only App Store fields before completing those phases. The App Review
candidate remains pinned, but the serving backend is now canonical source
`d801e9dbfdb402531ddae6266b9b16e3da46dece`, recorded in [release 44](release-44.md).
The reviewed build-40 source defaults to the retired REST contract, so its
workout mutations are known to be incompatible, not merely unverified. Keep
public release blocked until a compatible candidate replaces it and required
verification is satisfied. Authenticated session-swap and workout-name compatibility
verification remains unperformed; public health and unauthenticated responses
do not establish those behaviors. Build 40 was subsequently validated and uploaded
with explicit owner approval. Do not mark the outstanding live checks passed or
waived from that upload approval or Apple's submission acceptance. The owner
has now submitted build 40; finish P1/P2 and retain the P3(a) evidence or a specific
verification exception before the public-release decision. Inspect the existing
submission for Apple review responses, carry out the owner's release-mode
decision when supplied, and read the result back. Do not resubmit or change the
selected build from a TestFlight upload.

**Historical production release and preceding beta (2026-09-14 Pacific):** The owner
requested the latest version. [Build 42's release receipt](release-42.md) records
source `5df9208fc01219f298866ee4528cda533b86d33d`, terminal-green checks,
production at 100% traffic, public health/discovery and app-link verification,
and iOS 1.0 (42) VALID in internal Testers. No migration was needed. That
beta did not replace the App Review candidate. Apple readback at
2026-09-15T03:02:09.514Z still selects **build 40**, WAITING_FOR_REVIEW, with
**AFTER_APPROVAL** release. That live setting supersedes the older MANUAL
receipts below; this run did not change it or make a public App Store release.
External Alpha Testers do not have build 42. Physical-device and authenticated
training verification remain open; no new waiver is inferred from this release.

**App Review submitted (2026-09-13 Pacific):** At 2026-09-14T01:23:28.16Z Apple
accepted review submission `ea595b5e-86a6-4704-b1ef-ae87b971c728`. A fresh API
read at 01:24:20 UTC confirmed version 1.0 and that submission both in
`WAITING_FOR_REVIEW`, build `34ed891c-837b-451a-aae8-28ef5ef9b0f7` (40) `VALID`,
and release type `MANUAL`. The owner performed the final browser submission.
The value-free receipt is retained on the release host under
`release-credential/final-apple-state.json`. No public release occurred.

**Credential and selection resolved (2026-09-13):** The owner identified the
existing **TresFort CI Signing** team key as App Manager. Its installed key
authenticated, and the authorized build-selection PATCH returned HTTP 204;
readback confirmed build 40 on version 1.0, READY_FOR_REVIEW, with MANUAL release.
The older Developer key caused the earlier 403. Upload and fastlane configuration
now use the existing App Manager key; no key was created, copied or revoked.
Team keys cover all apps in the account. API authorization does not prove
unattended code signing; the existing Xcode account/keychain path is retained.
Refresh privacy publication and agreements before public release. If a field
remains inaccessible, use the owner's signed-in browser rather than requesting
repeated agent-browser sign-ins. Do not create a duplicate submission.

The [Garmin attribution fix](attribution.md) and [retired reviewer login](reviewer-access.md)
merged in [PR #193](https://github.com/namarks/tres-fort/pull/193) at
`fd061849aeb5d7701f8db02f4a9d497d79600ee8`. Its tree
`55d39b3f89bc41d245b0cd2f99e586f3eab9e113` matches the tested integration.
Both configured independent reviews passed on head
`5cb222173f20dc25f1bd42b655d96cf2dcf39ac7`; all eight checks in
[CI run 34735238755](https://github.com/namarks/tres-fort/actions/runs/34735238755)
were terminal-green and no review threads remained. An earlier UI run failed to
navigate from Today to Profile; the same journey passed locally and the final
required CI passed without a speculative app change or added test retry.

The replacement **1.0 (40)** archive is pinned to reviewed source
`9373d6f0acad9a9ef444e54fe9c9d8a8b7ad24c8`, tree
`f2a29e8e21e94bfc6f25b85b1406849a9ea3433d`. Xcode's desktop Release archive
succeeded, code signing verifies, both app and widget report 1.0 (40), and all
293 tracked snapshot inputs still match. Build 40 was unused at preparation.
The owner confirmed the signing dialog, then explicitly approved sending this
same build to Apple for validation and upload. Xcode reported all validation
checks passed and upload complete. Apple build
`34ed891c-837b-451a-aae8-28ef5ef9b0f7` was uploaded at 2026-09-13 05:09:18 UTC;
readback confirms version 1.0 (40), VALID processing, IN_BETA_TESTING and internal
Testers membership, with non-exempt encryption false. No second upload is needed.
The signed archive, source manifest and affirmative Xcode/API receipts are retained.
Xcode's optional post-upload local export button remained disabled; no separate
IPA export is claimed. Build 40 remains selected and **Waiting for Review**;
the current release setting is recorded in the latest distribution update above.

PR #192's onboarding work and PR #188's catalog additions advanced main during
preparation. PR #193's tested integration includes that work, but the release
remains pinned to the source above; a later integration commit must not silently
replace it. The owner explicitly approved additive migration **0050** after the
initial automatic approval rejection. It was applied once; readback confirms its
ledger entry and the nullable `sessions.exercise_swaps` TEXT column. The separate
Worker deployment initially required separate approval, which the owner then
provided. At 2026-09-13 04:42:59 UTC, deployment
`e738fc8f-9625-441d-b0c5-e811ad2f5cca` activated version
`09d2241f-5869-477b-b6b1-a3288dccbbed` at 100% traffic. Its provider annotation
matches the pinned source/tree above. Existing D1/R2 bindings, credentials,
runtime compatibility and hourly cron are preserved; development auth is absent.
Health, privacy and OAuth discovery returned 200; the removed reviewer-login
endpoint returned 404. Unauthenticated state returned 401, which is not evidence
of authenticated session-swap behavior. Deployment receipts are retained alongside
the archive. Migration 0051,
the new onboarding feature and PR #188's catalog migration are outside this
pinned candidate. The pre-migration private recovery bookmark, migration receipts and signed archive/manifest
are retained under the release host's `release-attribution` artifact directory.

The 2026-09-12 provider readback confirmed version 1.0 in `READY_FOR_REVIEW`,
build 38 selected, `MANUAL` release and Apple-only notes with
`demoAccountRequired: false`. The original credential error was form validation;
it did not establish that Apple reviewers cannot use Sign in with Apple. Build
39's password workaround was uploaded but is not the selected draft. The new
candidate removes that login and revokes old sample API/renewal access, retaining
only legacy identity/data-isolation safeguards. The replacement has since passed
validation and processing; build 40 is selected and Apple has acknowledged its review submission.

The owner is completing App Store Connect on another Mac. Do not repeatedly ask
for sign-in on the agent browser. Listing copy, running-aware Claude description,
five iPhone screenshots, subtitle/category, review contact, free US availability
and manual release were saved during the walkthrough. Privacy answers were
entered; final privacy publication and applicable agreements still need readback.
The saved privacy URL is `https://tresfort.app/privacy`; that page, the homepage,
Worker privacy page, health and OAuth discovery returned HTTP 200. The old
Developer key could not read pricing or territory availability (403). The App
Manager key subsequently read all 175 territory records: USA alone is enabled,
new-territory availability is off, and the active US manual price is USD 0.0
with no end date. Value-free receipts are retained in `release-credential/`.
The agent browser remains on Apple's failed sign-in page.
Keep review-contact values and all credentials out of repository documentation.

The owner explicitly deferred the live workout canary and observation and asked
to ship ASAP. The retained signed **1.0 (35)** IPA was uploaded successfully at
23:54:09 UTC. At 23:56:53 UTC, Apple reported **VALID / IN_BETA_TESTING** and
membership in the internal **Testers** group. Do not upload it again or restore
the waived canary as an upload gate. Other physical-device coverage remains
unverified; neither the exception nor public reads establish production writes.

Earlier internal distribution: the owner requested deployment of the merged UI
fixes. [Version 1.0 (38)](release-38.md) ships workout browsing, compact Profile
account controls, a pinned set action, simpler editing modes, and corrected
deletion/completion behavior from source `0ac5d46b5a245c674fbc10727117b264a38db580`.
Apple confirmed VALID, IN_BETA_TESTING and internal Testers membership. Backend
source matches build 37's release; this distribution performed no backend or
database change. Build 38 supersedes build 37 for internal testing without
changing the App Store review selection or remaining submission/device gates.

Previous internal distribution: [version 1.0 (37)](release-37.md) includes the
workout-runner fixes and Today/Calendar navigation from source
`2d11be717089bc989afa159e18c2438787465ac7`.
Its matching calendar-move Worker was deployed first, and Apple confirmed VALID,
IN_BETA_TESTING and internal Testers membership. Build 37 superseded builds 35/36
for internal testing; it did not select an App Store review build or complete
the remaining submission/device requirements above.

Earlier candidate release record (2026-09-10):

- [PR #175](https://github.com/namarks/tres-fort/pull/175) passed independent review
  at `88bb610352973a08d6d8dd9b9810adf86fbd1720`, with all eight review threads
  resolved and [all eight required checks green](https://github.com/namarks/tres-fort/actions/runs/34533893828).
  Merge `361cf2ba9d40ef6572de700b65cf649c665559ba` has identical tree
  `8cde9125232d605b4988ce9986abae9234537856`. The release uses that exact source.
- After saving a private native D1 recovery bookmark, only migrations 0046,
  0047 and 0048 were applied. The ledger confirms all three; no pending migrations
  or foreign-key violations remain. Migration 0045 was not repeated.
- Worker version `722fbf91-4b13-48e2-b233-747b1d437ca6`, deployment
  `33658947-639c-4a54-b94a-f3cc7167883b` at 22:36:27 UTC, serves 100% of traffic.
  Its annotation identifies the source and tree above. Existing bindings,
  credentials, runtime compatibility and hourly cron are preserved. Owner
  identity is configured and development auth is absent (presence checks only).
  The approved configuration disables detailed observability persistence and
  export; live metadata omits the disabled observability subtree, reports
  Logpush false and no tail consumers. Aggregate metrics remain available.
- Website version `37485aa6-6045-48d0-aabf-b951af4f5e21` publishes the matching
  policy. Both privacy URLs, health, OAuth discovery, homepage and icon pass;
  protected endpoints return 401 without authentication and a missing website
  URL returns 404. Public policy content matches the built source after excluding
  Cloudflare's observed appended security script. Mail DNS is unchanged.
- The signed archive/export is 1.0 (35), bundle `com.nmarkspdx.tresfort`, iPhone
  only, with the required-reason manifest and no synthetic fixture markers.
  All 279 tracked iOS/upload inputs match the release source; code signing
  verifies. IPA SHA-256:
  `33dd3018a83a05d00afee9522a3139c2dc34212204a2de24b401570d73ca66a8`.
  The 23:49:32 UTC pre-upload App Store Connect read confirmed 35 was unused.
  Upload returned zero with `UPLOAD SUCCEEDED with no errors`; delivery UUID and
  Apple build ID are `b1532d4f-ac87-4a46-a2c3-5ae5fc241000`. The 23:56:53 UTC
  read confirms version 1.0, build 35, VALID processing and IN_BETA_TESTING.
  Internal Testers includes it; external Alpha Testers does not.
- Authenticated production REST authoring/date/set/finish/discard checks and the
  canary observation were **deferred by the owner**, not passed or inferred from
  public reads or simulator tests. No production training records were modified
  by the upload workflow. The signed upload proceeded under that explicit exception. The version remains
  PREPARE_FOR_SUBMISSION with no selected build, empty listing copy and release
  type AFTER_APPROVAL; the contact write was rejected before mutation.
- Private recovery information and sanitized release receipts are retained on
  the release host under
  `~/.codex/visualizations/2026/09/10/01a08bad-3258-7500-9674-90839f24449a/release-35/`.
  The signed package and affirmative upload/processing receipts are retained
  there. The supplied review-contact phone and recovery bookmark are private;
  do not copy them into repository documentation.

## Notes / open questions

The preparation checkpoints below retain evidence from earlier source snapshots.
Their test counts and provider reads are historical; the current release source,
authorization, deployment state and remaining actions are in **Next step** above.

- Within this plan, P3 requires P0/P1, and P4 requires P2/P3. These are phase
  order requirements, not cross-plan dependency edges.
- Owner decision, 2026-09-10: **free, United States only**.
- P0 delivered in [PR #171](https://github.com/namarks/tres-fort/pull/171),
  reviewed head `3629ab656ba6b99d8a852d8fdf8473e71480431b`, merged as
  `95f90307deaf4993a2cadc4546480933d785a048`. Independent Codex review completed
  without findings; no unresolved threads; [all configured CI checks passed](https://github.com/namarks/tres-fort/actions/runs/34491716466).
  The merge and reviewed head have identical tree
  `122d8e9c537ad7e3fb15d2512b419432d2ae9a4c`. Build 35 is now selected and archived as recorded above;
  its completed upload and Apple processing are recorded above.
- Foundation implementation: privacy/support links, optional integration
  disclosures, UserDefaults required-reason manifest, marketing version 1.0,
  reliable transcript replacement assertions, and an explicitly selected
  version/build in the review-submission lane. That foundation checkpoint did
  not upload or submit an app.
- Local verification, 2026-09-10: TypeScript typecheck and all 967 backend tests
  passed; final OAuth checks passed (8 tests). On Xcode 26.3 / iOS 26.2 / iPhone
  17 simulator, all 448 unit tests and five feedback journeys passed; the final
  onboarding and affected feedback rerun passed all nine tests. The built app
  contained marketing version 1.0 and the UserDefaults `CA92.1` manifest.
  Release-lane boundary tests, verification-script tests, plan validation and
  whitespace checks passed. Exact-head independent review and remote CI passed
  as recorded above.
- A paired physical iPhone was unavailable on 2026-09-10; simulator evidence
  does not establish physical-device behavior. The later owner exception and
  remaining unverified coverage are recorded above.
- The [review package](review-package.md) is a draft. The owner approved group controls, the daily inbox / 24-hour response
  commitment and aggregate-only diagnostics on 2026-09-10, with an explicit
  preference against overengineering. The implementation passed exact-head
  independent review and CI and its backend is deployed, as recorded above. Persisted
  HealthKit records now use the candidate's protected, backup-excluded
  app-owned storage; physical-device verification remains in P1/P3.
- The group-safety candidate was merged in [PR #175](https://github.com/namarks/tres-fort/pull/175),
  using the existing Worker/D1 and Profile screens:
  mutual member blocking, reviewed email drafts with copyable references,
  conservative shared-text filtering and audited, reversible operator sharing
  restrictions. Additive migration `0048` was applied before the new Worker.
  The following local checks were preparation checkpoints before final review:
  TypeScript, plan checks and Wrangler 4.92 dry-run/type generation passed.
  Local backend verification passed 980 tests; the remaining assertion assumed
  a random group sort order. Selecting the intended group by ID corrected that
  test, and all 12 safety/export tests then passed. Export controls use the same
  D1 batch snapshot as the training projection. All 489 iOS unit tests completed
  without failures (one physical-protection test explicitly skipped), and both
  safety journeys passed on iPhone 17 / iOS 26.2. All 274 iOS input hashes matched;
  the synthetic report screen was visually inspected. Final independent review and
  remote CI subsequently passed as recorded above. The CI selection check now accounts for the added
  safety suite; all 11 verification-workflow checks, seven asset checks, six CI
  scope checks and two review-submission checks pass locally. An unsigned
  generic-iOS Release build at `03b50c043a0d239721038becacc3ce23c78c8162` passed:
  version 1.0, iPhone-only, embedded widget, `CA92.1` manifest and no synthetic
  fixture markers. Its build 29 is an unreserved placeholder, not an upload
  candidate. Independent review identified cached secondary groups on foreground;
  the app now invalidates every shared projection before authentication waits and
  reloads all rosters. A stale detail task cannot supersede that reload. All
  three safety unit tests and five safety/Intervals journeys passed after the
  correction, including background/foreground use. Rejected block requests now
  revalidate membership rather than leaving a false empty-group screen; an offline
  reload exposes retry while preserving the original block error. The regression
  reproduced both failures before the fix. Blocks and operator restrictions now
  share one recovery path that clears shared projections before either write and
  reconciles uncertain responses. The lost-restriction-response regression also
  failed before this correction; all five safety unit tests and both safety
  journeys pass afterward, with all 274 input hashes matching. Foreground recovery
  also reloads mounted safety settings; failed roster/feed/statistics/series
  refreshes use the existing retry screen instead of implying an empty group.
  Both additional review regressions reproduced before correction; all seven
  safety unit tests and both safety journeys pass on the corrected source, with
  274 matching input hashes. Account downloads apply the same masking to other
  members' group names inside the existing export snapshot, preserving a creator's
  own original. The unmasked-export regression reproduced before correction;
  all 13 safety/export tests and TypeScript checks pass afterward. Shared creator
  metadata and exported names now honor either-direction blocks and restrictions;
  unavailable creators use an empty string to retain older clients' wire shape.
  The app removes unavailable report targets and uses one complete group/safety
  reload after successful or rejected safety writes and foreground return. These
  metadata and lost-settings regressions also reproduced before correction. All
  14 safety/export tests, seven safety unit tests and five safety/Intervals UI
  journeys passed afterward, with 274 matching iOS input hashes. These preparation
  checks preceded the production release recorded above; no App Store write occurred.
- P1 protected-storage repository work was delivered in
  [PR #172](https://github.com/namarks/tres-fort/pull/172), reviewed head
  `9bdcbee7a3de96b2384a3c9de9e64cefa86f5df9`, merged as
  `310327b7a0d779b8a905e7b18588bda30f1bd808`. Independent Codex review found no
  remaining issues, all review threads were resolved, and
  [all eight configured checks passed](https://github.com/namarks/tres-fort/actions/runs/34518979841).
  The reviewed and merged tree is `c7dcfecfe6fddc69aee93a6e92532d6d0eb529e3`;
  remote-main ancestry and tree equality were verified after merge.
  Training blobs now use protected, backup-excluded storage with account/revision
  fences, durable-write gates, inactive-account migration and explicit recovery.
  Unreadable training queues remain intact; acknowledged deletion erases only
  the relevant account. Explicit Health disconnect can rebuild an unreadable
  cursor, preserves failed reset intent, and rejects stale sync checkpoints.
  Tab models have one lazy owner; invite retry has a full 44-point touch target.
  The final Health follow-up passed 96 focused authentication/storage tests with
  one explicit simulator protection skip; all 268 tested iOS source hashes
  matched. Earlier full/focused checks and failure diagnoses are retained in the
  [release audit](release-audit-2026-09-10.md). Physical-iPhone file protection,
  upgrade, lock/unlock and recovery verification remain P3 requirements.
  A rollback must retain the new storage reader or first reconcile pending work.
- The backend diagnostics fix was delivered in [PR #173](https://github.com/namarks/tres-fort/pull/173),
  reviewed head `528aa8c7f79d5624c89f9ac4e31a98f1b76afb74`, merged as
  `0f82e0ad045c21a5f0bda0215b9d1b8b07c020f8`. Independent Codex review completed
  without findings, all threads were resolved, and [required CI passed](https://github.com/namarks/tres-fort/actions/runs/34508210971).
  The reviewed and merged tree is `530be6e14b42dd6a50b127031e99e3282bd8f6a9`.
  Local verification included TypeScript, all 972 backend tests, then 85 focused
  tests for the validation-code follow-up. It removes raw unexpected error text from application logs and HTTP/MCP
  responses. Read-only provider metadata at 17:07:31 UTC confirmed persisted
  invocation logs with 100% sampling and URL query redaction disabled. Tracing
  is disabled; no tail consumers or export destinations were returned. Logpush
  is not exposed by the download path. No request logs were opened. The
  [diagnostics policy proposal](diagnostics-policy-proposal.md) is owner-approved; its production configuration is now deployed. Historical
  exports and final App Privacy declarations remain separate assessments.
- [Release audit, 2026-09-10](release-audit-2026-09-10.md): production version
  `c5a298d1-a72a-4fa8-a24f-bd2cf0e27a6b`, source annotation `ff512825779f90b630a4a5dfd11a68e6a113825a`,
  migration ledger through `0045`; at that earlier read, source migrations
  `0046` and `0047` were unapplied. The release above supersedes this state. Normal-browser checks successfully rendered both public marketing
  and privacy pages with support links; HTTP clients still returned 403.
  Mailbox delivery is untested. No production change was made.
  A SELECT-only refresh at 17:47–17:48 UTC confirmed the same deployment and ledger
  through `0045`, with zero rows written.
- P2 screenshot workflow was delivered in [PR #174](https://github.com/namarks/tres-fort/pull/174),
  refreshed onto the verified storage merge. The complete workflow passed on
  clean capture source `d1ef8111419cd0fcae0cf01c1df5a73881ef7acf`: both UI journeys
  passed, all 270 iOS source hashes matched, and five opaque RGB 1320 × 2868
  images were visually inspected. The framing follow-up also passed both
  journeys on CI's smaller iPhone 17. Build and capture now share source
  selection; added/removed/changed inputs and checkout changes abort capture.
  PNG checks cover structure, checksums, compression, pixels and transparency.
  Seven optimized-Python asset tests and 11 build-workflow tests passed; reported
  validation bypasses reproduced before the fixes. A generic-iOS unsigned
  Release build of the same iOS inputs passed with version 1.0, embedded widget,
  `CA92.1` manifest and no synthetic fixture markers. Build 29 remains an
  unreserved placeholder. Reviewed head `a3b5849f9035d71097119d8e319c545a13db60b9`
  merged as `efa16e84fcddc1ea44bd1082ea435b63b1d84a03`, with identical tree
  `88808504401105f61116e253a05700050fe2308b`. Independent review found no issues,
  all threads were resolved and all eight checks in run `34521185926` passed.
  Source ancestry and tree equality were verified after merge. Subsequent group
  changes require a fresh candidate build; the prior Release proof covers only
  its recorded source inputs.
  Final screenshots were subsequently captured and checked from reviewed head
  `88bb610352973a08d6d8dd9b9810adf86fbd1720`; the signed candidate is recorded above.
  Device verification was open at that capture checkpoint. The later signed
  upload and explicit test deferral are recorded above.
- Source baseline `bb4db9c40675ba6be6a0b8ff42f8cdbabcf14a4c`;
  [main CI](https://github.com/namarks/tres-fort/actions/runs/34486074011) passed.
  The preceding run failed transcript replacement: its helper could delete
  backward from an arbitrary cursor after missing the selection menu. A later
  pass does not explain that failure.
- App Store Connect read on 2026-09-10: app `6772375823`, version `1.0` in
  `PREPARE_FOR_SUBMISSION`, no selected build/screenshots and empty description,
  support/privacy URLs, category, review details and age answers. Latest build
  `0.1.0 (34)` was `VALID`, `APP_STORE_ELIGIBLE`, `IN_BETA_TESTING`. Re-read before
  writes. Existing API permissions did not allow pricing/availability reads;
  agreements and App Privacy answers remain unverified.
- Owner App Store Connect readback, 2026-09-10: after a phone screenshot showed
  unset pricing/availability, the owner confirmed saving **Free / United States
  only**. This is owner-confirmed configuration; direct API readback remains
  unavailable to the existing key. The owner deferred checking App Store
  agreements; agreement readiness remains pending.
- Website hosting was delivered by [PR #170](https://github.com/namarks/tres-fort/pull/170);
  the matching candidate privacy publication and public-URL evidence are recorded above.
- Repository work remains authorized through required review and merge.
  Candidate production deployment and internal TestFlight distribution are
  complete. The later owner shipment request and test exception supersede the
  former pre-upload gate; App Store editing access and unsatisfied submission
  fields are the current handoff, not a request to repeat release approval.
- Apple references checked 2026-09-10: [review guidelines](https://developer.apple.com/app-store/review/guidelines/),
  [required-reason APIs](https://developer.apple.com/documentation/bundleresources/app-privacy-configuration/nsprivacyaccessedapitypes/nsprivacyaccessedapitype),
  [App Privacy](https://developer.apple.com/help/app-store-connect/manage-app-information/manage-app-privacy).
