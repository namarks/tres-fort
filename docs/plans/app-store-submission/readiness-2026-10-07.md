# App Store readiness audit — October 7, 2026

Dated evidence and a prepared submission package, not a release receipt. Live
phase state and authority remain in [plan.md](plan.md). The audited baseline is
`dbcbc4d65f7a6bb940ac325e0d14a71729bdc6ff`; this branch makes the preparation
changes described below. No Apple fields, production settings or training
records were changed by the audit.

## Verified provider state

Read October 7, 9:43–9:52 p.m. Pacific (October 8 UTC), using the existing
installed credentials. Responses are retained locally under
`.artifacts/app-store-readiness-2026-10-07/`, with credentials and review-contact
values excluded from the Apple summary.

| Surface | Observed result | Consequence |
|---|---|---|
| App Store 1.0 | REJECTED, MANUAL, build 40 selected | The old candidate remains incompatible with canonical workout writes; prepare a replacement before resubmission. |
| Latest uploaded build | 49, VALID, IN_BETA_TESTING | Internal beta availability does not establish the iPhone-only App Store candidate. |
| Beta group read | Both build group reads returned 403 | Current assignment was not independently refreshed; the [release-49 receipt](release-49.md) remains dated assignment evidence. |
| Beta feedback | Paginated native screenshot and crash reads; zero entries for build 49 | No reported build-49 feedback at this check; not physical acceptance. |
| Listing | Name/subtitle/category and policy/support URLs present; description and promotional text still mention only Claude | Replacement copy in [review-package.md](review-package.md) describes the current optional coach choices. |
| Review access | Sign in with Apple instructions, `demoAccountRequired=false`, contact fields populated; obsolete demo name/password fields remain populated | Clear the retired demo fields during the authorized metadata update; no credential values are retained here. |
| Screenshots | Five COMPLETE 1284 × 2778 images in the 6.5-inch set | These are the older set; replace with visually checked images from the final iPhone-only candidate. |
| Age declaration | Health/wellness, user-generated content and social-media features marked present; chat, ads, unrestricted web access and medical/treatment information absent; returned rating FOUR_PLUS | Existing answers are recorded, not a fresh operator attestation or a minimum-age product decision. |
| US price | One manual USD 0.0 price, no end date | Free pricing verified. Availability is verified separately. |
| Availability | All 175 territory records read; only USA enabled, new-territory availability off | US-only configuration verified; unreleased/rejected state still prevents sale. |
| Production | Version `5306d0d6-a4bf-4092-890b-55c4d6089000`, 100% traffic; provider annotation identifies source `cd3cf40` and tree `f7b139dd27cca100eae67cf32a6e5ded2df99436` | Matches the build-49 backend receipt. Public health alone does not expose the SHA. |
| Schema | SELECT-only ledger read: 56 migrations through 0056, `changed_db=false`, zero rows written | No migration is proposed for this preparation slice. Do not reapply 0048. |
| Worker logging | Settings GET: `logpush=false`, `tail_consumers=null`, `observability=null` | Exact returned settings; individual persisted-log flags were not returned. |
| Account logging inventories | Logpush jobs and Workers telemetry destinations each returned 403 | Independent account destinations and historical exports remain unverified. |

The homepage, support contact link, both policy URLs, Worker health and OAuth
discovery were reachable. Crucially, `https://tresfort.app/privacy` did **not**
match the audited source and lacked its newer recipient-specific AI disclosure.
The Worker policy did match baseline source, including the equal-protection
commitment. Publication of one host does not update the other. Both hosts will
need the final reviewed policy; no new attestation is inferred from deployment.

## Source findings and preparation changes

### iPhone-only packaging

The previous upload flag changed device families and hid the Station link but
still linked MediaPipe and its force-loaded graph library. The checksum-pinned
0.10.21 SDK packages contain no privacy manifest/signature resources and repackage
Abseil/Protobuf. Apple's [SDK requirements](https://developer.apple.com/support/third-party-SDK-requirements/)
therefore need explicit consideration before distributing that package publicly.

The iPhone-only project now excludes the camera SDK, graph libraries, model and
their notices; normal iPhone/iPad TestFlight keeps them. The adapter explicitly
rejects use in the iPhone-only build, and the public Today screen hides the
new partner setup that requires an iPad. Retained beta checkpoints keep their
recovery entry so an upgrade can cancel an unfinished setup and release Today. The separate Station beta retains its
device trials and dependency review; this change does not certify its SDK.

The app manifest also declares SystemBootTime reason `35F9.1` for elapsed-event
timing alongside UserDefaults `CA92.1`. Release app code uses `systemUptime` even
without MediaPipe. See Apple's [required-reason guidance](https://developer.apple.com/documentation/bundleresources/describing-use-of-required-reason-api)
and [reason categories](https://developer.apple.com/documentation/bundleresources/app-privacy-configuration/nsprivacyaccessedapitypes/nsprivacyaccessedapitype).

### Privacy and access

The policy now distinguishes optional Apple Health body-weight viewing from
workout imports. `BodyWeightModel` reads body mass into process memory for
Progress → Weight; it is not uploaded, exported or coach/group-shared. Turning
off Read weight clears this view and leaves source Health measurements intact.
Account instructions now match Profile → Account.

Intervals is a different data path: `src/intervals.ts` requests activities
without a field selector and retains full activity/event response JSON.
[The provider schema](https://intervals.icu/api/v1/docs) defines the activity
default as all fields, including optional weight, device name/power-meter serial,
gear/route references, attachment metadata and sync/analysis information. The
policy and worksheet disclose these retained categories. No personal payloads
were inspected. Raw JSON is included in authenticated sync/account export;
coach reads use explicit projections and do not expose it. Prospective data
minimization would not erase historical raw records, so no historical cleanup
or narrower collection claim is implied by this audit.

Existing controls were traced through implementation and regression suites:

| Control | Evidence anchors |
|---|---|
| AI permission before setup and authorization | `CoachConnectView.swift`, `CoachApprovalView.swift`, `src/oauth.ts`; member-activation UI journeys, `test/mobile_coach.test.ts`, `test/oauth.test.ts` |
| Caller-owned withdrawal, including unexchanged codes | `src/services/oauthGrants.ts`; `test/oauth_integrity.test.ts`, `test/mobile_coach.test.ts` |
| Account export and deletion | `src/routes/api.ts`, `src/db.ts`; `test/account_export_service.test.ts`, `test/account_deletion.test.ts` |
| Group filtering, mutual blocks and operator restrictions | `src/groupSafety.ts`, `src/db.ts`, `GroupSafety.swift`; `test/group_safety.test.ts` |
| Protected local training storage and backup exclusion | `LocalPersistence.swift`, `ProtectedTrainingStore.swift`; local-persistence/storage tests. Simulator coverage does not prove physical file protection. |
| On-device speech; saved text only | `OnDeviceFeedbackTranscriber.swift`, `WorkoutFeedbackView.swift`; feedback UI journeys. Real speech still needs a device/language-model check. |

No new backend functional defect was established. The audit does not claim
every log message is value-free: bounded OAuth refusal logs include client and
redirect information. Persistence/export settings and provider practices remain
the relevant diagnostics boundary.

## Prepared materials and verification

The [review package](review-package.md) contains replacement listing text,
reviewer navigation, a conditional rejection reply and explicit privacy/rating
answers for operator review. The screenshot workflow now selects the same
iPhone-only project as the release path, rather than showing beta-only partner
controls. It retains source hashes, two screenshot journeys and a beta-upgrade
recovery regression, producing five opaque 1206 × 2622 PNGs for Apple’s currently
required medium Dynamic Island display class. The dedicated iPhone App Store
CI shard also compiles this variant and checks that its camera adapter is unavailable.

The unsigned Release iPhoneOS archive built successfully with Xcode 27.0.
Both app and widget report `UIDeviceFamily=[1]`; the app embeds UserDefaults
`CA92.1` and SystemBootTime `35F9.1`. Inspection found no MediaPipe/model/notices
assets, SDK linker inputs, or linked MediaPipe/Abseil/Protobuf/MPP symbols.
The app binary SHA-256 is
`218a2f87cfd44d155ed5e890a652cd1c2621f3d152e025d051305413cace61e0`.
Local unsigned build number 29 is packaging evidence, not a reserved upload
number. Its complete iOS source manifest matches the final tested source,
including the beta-checkpoint recovery fix. Detailed inspection, source manifest, linker
commands and binary reports are retained under
`.artifacts/app-store-readiness/final-unsigned-device/`. The final screenshot
and recovery run passed all three UI tests with no failures. All five exported
images were visually checked; their hashes, source manifest and test log are
retained in `.artifacts/app-store-readiness-2026-10-07/final-screenshots/`.

Upload-script tests (12), offline project-generation tests (3), dependency tests
(7), verifier tests (14), screenshot-asset tests (7), website tests (3) and
TypeScript/plan validation passed. The real-D1 backend suite passed all 1,212
tests across 88 files. Final iOS and independent review results are recorded in
this change's pull request. An unsigned archive or simulator run proves only its stated
build/package properties; it is not a signed/uploaded candidate, real Apple
sign-in, authenticated production workout or physical-device acceptance.

## Remaining release decisions and evidence

1. Approve the policy text, including the existing third-party equal-protection
   commitment; verify provider practices and publish the identical reviewed
   policy to the website and Worker. The stale website is a concrete blocker.
2. Attest App Privacy, applicable agreements and final rating answers. Current
   credentials did not establish independent account logging inventories, and
   a reachable support link does not prove support-mail delivery or daily
   moderation coverage.
3. Build/sign/upload a fresh **iPhone-only** candidate after exact-head review
   and required CI. Recheck the next unused build number (49 was highest during
   this audit), inspect its app/widget families and embedded privacy manifests,
   and match screenshots to that exact candidate. Do not reuse build 49 as the
   public candidate.
4. Run the physical fresh-account consent/create/log/finish, export/deletion,
   Health/speech and protected-storage checks with designated test accounts.
   Existing internal-beta exceptions do not establish public readiness.
5. With App Review authority, replace build 40, update the prepared metadata and
   screenshots, clear obsolete demo fields, send the prepared reply and
   resubmit. Keep MANUAL release. Public release is a later explicit action.
