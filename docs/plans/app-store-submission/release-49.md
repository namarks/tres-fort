# Release 1.0 (49)

## Source and authority

On October 7 the owner requested the latest Tres Fort deployment and confirmed
both the backend and TestFlight. This release includes the required additive
migration 0056, the matching production Worker, and an internal iPhone/iPad beta.
It does not change App Review, external testing, or public App Store release.

The pinned source is main `cd3cf4057320daa474292b86f3ddbbca401d5099`, tree
`f7b139dd27cca100eae67cf32a6e5ded2df99436`. It includes manual partner training
([#243](https://github.com/namarks/tres-fort/pull/243)), static workout-preview
thumbnails ([#244](https://github.com/namarks/tres-fort/pull/244)), and the coach
documentation update ([#245](https://github.com/namarks/tres-fort/pull/245)).
The thumbnails retain the existing exercise photographs; Workout Guide remains
a replacement recommendation.

Fresh release checks confirmed each PR's required CI success and completed Codex
review on its final head: `45b3dbf`, `df7885b`, and `bbf242b`, respectively. No
review thread remained unresolved. Backend source, migrations, tests, dependencies
and Worker configuration match the reviewed #243 head exactly.

Local verification on the combined release source passed the Worker dry-run,
TypeScript check, plan graph and all **1,212 backend tests** across 88 files.
The iPhone 16e / iOS 26.2 simulator passed **411 targeted unit tests and two UI
journeys**, covering partner state, set outbox, runner recovery, Station link and
privacy, demo loading, grouped previews and Reduce Motion. This is targeted
release coverage, not a full native suite or physical-device acceptance.

## Production deployment

The preflight ledger contained migrations 0001–0055; only
`0056_partner_training.sql` was pending. Aggregate checks found no active sessions
and no duplicate partner-cancellation receipts. A D1 recovery bookmark was retained
locally before the change. Migration 0056 applied successfully, and readback
confirmed its session marker, nine triggers, one unique index and ledger entry.
No workout history was rewritten and no authenticated workout was performed.

Deployment `8e68bb87-2898-4155-8112-5c4a4f42c371`, created at
`2026-10-07T09:57:44.458803Z`, serves Worker
`5306d0d6-a4bf-4092-890b-55c4d6089000` at **100% traffic**. Both deployment and
version metadata identify the exact source and tree above. D1/R2 bindings,
compatibility settings, existing variables and the hourly schedule were retained.
The deployed source includes the Station link-key route needed by build 48 and
the new partner client.

At `2026-10-07T09:58:29.581Z`, public health returned HTTP 200 with the expected
service identity; unauthenticated state and MCP POST returned 401. Health does
not expose a source SHA, so provider metadata establishes source attribution.

For rollback, retain the additive schema and audit receipts. Before reverting
to a Worker unaware of partner markers, retire or continue any active partner
lanes as described in the [partner release boundary](../partner-training/validation.md).

## iOS package and Apple availability

App Store Connect showed 48 as the highest build before upload. The release used
`BUILD_NUMBER=49 APP_STORE_IPHONE_ONLY=0 npm run ios:testflight`; the project
version was not edited. Xcode 27.0 (27A266a), using the iPhoneOS 27.0 SDK,
archived and exported **1.0 (49)** for iPhone and iPad, minimum iOS 17.0.
The app and widget both carry build 49. The archive signature verified with
macOS trust services. The 26,567,160-byte IPA has SHA-256
`d64c8a7a862bdbfcbd5a7fc167f77023c89b1b0edb49382b3247972dc388cf44`.

Upload reported **UPLOAD SUCCEEDED with no errors**, delivery UUID and Apple
build ID `5a27e0f6-69bb-48eb-bd46-3e8666d8be00`, uploaded
`2026-10-07T10:01:44Z`. At `2026-10-07T10:04:54.775Z`, Apple reported **VALID**
and **IN_BETA_TESTING**. Complete paginated beta-group relationship reads
confirmed assignment to internal **Testers**
(`5df996bf-8c8b-471e-b79e-f626a4f98211`), with no external group assignment.
Fresh App Store Connect screenshot and crash feedback reads returned no
submissions for build 49. This is an initial feedback check, not evidence of
physical-device acceptance.

The October 7 App Store readback retains version 1.0 on **build 40**, **REJECTED**,
with **MANUAL** release. No candidate replacement or resubmission was made.

## Verification boundary

Authenticated workout compatibility, physical-iPhone/VoiceOver acceptance and
the linked Station/three-device partner trials remain unperformed. P0 in the
partner plan and P0.2(b) in the workout-library plan remain open. This internal
release does not establish public-readiness acceptance or camera accuracy.

Sanitized source, schema, provider, test, upload, package and Apple receipts are
retained in this task's release artifact directory. Temporary build outputs and
the disposable simulator are removed after verification; Apple retains the
uploaded build.
