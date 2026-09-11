# Activity Integration Integrity

Slug: activity-integration-integrity · Status: paused · Updated: 2026-09-11 · Theme: connected-training

## Goal

Make a connected workout appear once, on the athlete's correct local day, and
keep it consistent when its source is connected, corrected, or deleted.

Done means:

- a native Tres Fort strength session that is also observed as a HealthKit
  strength workout is represented once across calendar, history, statistics,
  and group surfaces, while the existing intervals.icu-to-HealthKit dedup rule
  remains intact;
- travel, daylight-saving changes, and UTC-boundary timestamps do not move a
  workout to the wrong civil day;
- connecting or reconnecting intervals.icu performs an initial reconciliation
  and exposes an actionable authentication state without discarding prior
  activity history;
- source corrections and deletions converge through the incremental sync
  surfaces; and
- Tres Fort writing completed strength sessions to HealthKit is either
  explicitly declined or separately approved and proven opt-in and idempotent.

## Phases

- [x] **P0 — One canonical activity on the correct local day**
  - Extend the existing source-reconciliation rule just enough to associate a
    HealthKit strength workout with the same user's native completed Tres Fort
    session, keep the native session canonical, and prevent double counting.
    Do not replace the shipped intervals.icu-to-HealthKit dedup path.
  - Establish the workout's civil date from its source timestamp and available
    timezone once; preserve the original instant and avoid recomputing old
    workouts from the device's current timezone.
  - Cover same-source retries, native-session-plus-HealthKit strength
    duplicates, the existing intervals-plus-HealthKit regression, UTC
    boundaries, and one daylight-saving transition in the existing activity,
    state, calendar, statistics, and group contracts.
- [x] **P1 — Connect, reconnect, and initial reconciliation**
  - After a successful intervals.icu connection, reconcile the user's recent
    activities immediately instead of waiting for the webhook or hourly cron.
  - Expose expired or revoked credentials as a reconnect action while keeping
    previously imported history readable; disconnect removes credentials and
    stops future sync without silently erasing history.
  - Verify that one user's connect, reconnect, or disconnect cannot affect
    another user's credentials or activity rows.
- [ ] **P2 — Corrections and deletions converge**
  - Apply upstream edits to the canonical activity, including changed duration,
    load, title, or local date, without creating another visible row.
  - Propagate upstream deletion as a tombstone through `/api/state`, calendar,
    history, and group feeds; reconcile a HealthKit sample that disappears with
    the same user-visible result.
  - Prove retry and out-of-order delivery with focused fixtures rather than a
    general event-processing framework.
- [ ] **P3 — Decide optional HealthKit write-back**
  - Record the owner decision on whether a completed Tres Fort strength session
    should be saved to HealthKit. A recorded decision not to build it completes
    this phase with no implementation.
  - If selected, write only after explicit HealthKit permission and successful
    workout completion, attach a stable Tres Fort session identity, and prove a
    retry cannot create a duplicate workout.
  - Keep correction or deletion limited to the workout Tres Fort created; do
    not add broad HealthKit editing or background orchestration.

## Dependencies

| Local phase | Relationship | Target | Reason |
|---|---|---|---|
| P3 | gated_by | external:owner-healthkit-writeback-decision | Writing workouts into a user's health record is an optional product and privacy decision, not an implied extension of read access. |

## Next step

**Now (@owner):** Choose whether to activate P2, the next core-product
candidate. No additional implementation phase is active. P1 is complete for
repository delivery; its implementation PR carries the exact-head review and CI
evidence. Rollout and HealthKit write-back remain separate owner decisions.

## Notes / open questions

- P0 regression repair: Intervals and HealthKit dedup now compares their stored
  source instants when both are available. Local clock values can differ after
  travel even for one physical workout; identical wall clocks during the fall
  DST transition can also represent different workouts. Legacy rows retain the
  local-clock fallback only when an instant is missing. Absolute matches take
  precedence, with deterministic time/id ties. Native-session discard uses the
  same rule, and bounded reconciliation includes the two-date difference
  possible across the date line. Existing provenance and tombstone deltas
  retire duplicates and restore surviving copies without deleting source data.
  Regression fixtures cover both ingestion orders, retries, deletion recovery,
  time boundaries and user isolation. This is a focused repair to shipped
  matching, not activation or completion of P2.
- The owner-approved matching repair was deployed on 2026-09-11 from PR #185
  source `1b596a19cadc308cdf7ec7380b9d133360a2bea9`, tree
  `651ec8500b5c2af99dd48b776962cc660ac70af5`. Worker version
  `a02cc743-bf51-43eb-ba42-9176e7ac07e6` serves 100% of traffic; `/health`
  passed. The prior version is `aed5a37a-3c18-4b62-8bf2-c4c3a1b66c9f`.
  No migration, configuration change or iOS distribution was needed. The
  deployed service function was previewed and then run for the affected account
  and recent date window through a temporary remote D1 binding. Verification
  confirmed source rows were preserved, Intervals rows were unchanged, duplicate
  tombstones reached incremental state and were absent from full state. This
  proves explicit reconciliation, not a natural cron tick or a physical-device
  refresh; the device must still receive its normal state pull. P2 remains paused.

- P1 adds immediate 90-day activity reconciliation after API-key or OAuth
  connect, using the member's stored timezone and existing source fences. A
  saved credential is acknowledged before its background import. The app
  observes status for a bounded period using the acknowledged freshness watermark;
  identical-credential reconnects require a newer successful sync. Failed
  imports can retry with the server's current credential generation; auth
  rejection follows existing recovery, and auth failure/disconnect retain
  imported history. Planned-event ingestion keeps its existing webhook/cron.
- Migration `0047` binds OAuth states to their creation generation and cancels
  them on credential changes. State insertion and the consumed callback's token
  write both claim that original generation, so neither can cross disconnect.
  Unbound states created by an older Worker require a fresh connect attempt.
  Apply this additive migration before a later authorized Worker release. No production migration, deployment, client distribution or provider
  write occurred in this slice.
- iOS displays current server connection authority, pending import, retry and
  reconnect actions. Old persisted mirrors and late profile/import/OAuth
  responses cannot restore a disconnected account. Successful imports notify
  the account-scoped activity bridge so calendar/history refresh immediately.
- P1 validation covers the full backend suite and 15 focused connection cases,
  Swift unit tests including acknowledgement, watermark and account-boundary
  regressions, synthetic connect/retry/reconnect-disconnect calendar journeys, the iOS
  verification-script tests, typecheck and plan compilation. The implementation
  PR records terminal CI and independent review against its final source head.
- P1 was activated by the owner's explicit goal from verified main `86dd9b6`
  (P0 PR #167), using `codex/activity-integration-p1` in the isolated worktree.

- P0 activated (2026-09-09) after the owner chose continued core-product work
  before rollout. Remote main and fetched source are `ef21188a39d59627c9610fd33ba09d41d03e9ad4`;
  its CI is green. Work uses the isolated `codex/activity-integration-p0` branch.
  No deployment, production migration, provider write, TestFlight distribution
  or new HealthKit permission is authorized by this repository slice.
- P0 stores the true source instant separately from the existing civil-clock
  ordering proxy (additive migration `0046`). HealthKit prefers recorded timezone
  metadata and freezes the first stored civil date/instant for a sample UUID.
  Missing historical timezone metadata remains unknown; its first observed
  civil day cannot be certified as the original travel timezone. Intervals keeps
  its source-local date and retains only explicitly zoned absolute timestamps.
- Matching requires exactly one same-user completed native session with recorded
  start and end both within two minutes of the HealthKit strength workout.
  Missing or ambiguous timing stays visible. Source upsert, native completion
  and discard reconcile the pair atomically; tombstones/restorations advance the
  existing state cursor. A discarded native session restores HealthKit or
  repoints it to an existing Intervals winner. Native-to-Intervals identity and
  three-source collapse are not established by P0.
- Verification covers both arrival orders, unchanged retries, discard recovery,
  ambiguity, user isolation, rollback on reconciliation failure, existing
  Intervals precedence/source fences, and state/calendar/history/group parity.
  Shared Swift/Worker fixtures cover UTC boundaries, travel and both DST
  transitions. Full local and CI evidence is recorded with the implementation PR.
- Later authorized rollout must apply additive migration `0046` before deploying
  this Worker, then distribute the compatible iOS client. Old pushes without
  source timing remain valid and unmatched to native sessions. Physical-device
  HealthKit validation remains a release check; this slice performs no provider
  writes, permission changes or HealthKit write-back.
- Use the current `external_activities` model, source-scoped reconciliation,
  tombstones, and incremental state cursor. Add a new abstraction only if a
  focused fixture proves those mechanisms cannot express the required result.
- Reuse the user-scoping and validation rules completed in
  [Server Mutation Integrity](../completed/server-mutation-integrity/plan.md);
  they are historical foundation rather than an unresolved dependency.
- Reuse the account-scoped authentication and credential-recovery contracts in
  [Identity and Account Lifecycle](../completed/identity-account-lifecycle/plan.md)
  as historical foundation for P1 reconnect work.
- The intervals.icu-to-HealthKit deduplication rule is existing behavior and a
  regression boundary, not a new subsystem in this workstream.
- The intervals.icu endurance write bridge documented as M5 in
  [`MULTISPORT.md`](../../MULTISPORT.md) is not part of this plan. It remains a
  separate candidate with its existing live-provider and value gates.
- This plan does not authorize production integration changes, new HealthKit
  permissions, or release.
