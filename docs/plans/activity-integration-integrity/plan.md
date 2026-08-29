# Activity Integration Integrity

Slug: activity-integration-integrity · Status: planned · Updated: 2026-08-28 · Theme: connected-training

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

- [ ] **P0 — One canonical activity on the correct local day**
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
- [ ] **P1 — Connect, reconnect, and initial reconciliation**
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
| P0 | coordinates_with | plan:server-mutation-integrity | Reuse its user-scoping and mutation-validation rules without waiting for unrelated server work. |
| P1 | coordinates_with | plan:identity-account-lifecycle | Connection recovery and app authentication share state, but neither plan should become a blanket prerequisite for the other. |
| P3 | gated_by | external:owner-healthkit-writeback-decision | Writing workouts into a user's health record is an optional product and privacy decision, not an implied extension of read access. |

## Next step

**Now (@owner):** None — keep this plan `planned`; when activated, start with P0
and leave HealthKit write-back gated until the explicit P3 decision.

## Notes / open questions

- Use the current `external_activities` model, source-scoped reconciliation,
  tombstones, and incremental state cursor. Add a new abstraction only if a
  focused fixture proves those mechanisms cannot express the required result.
- The intervals.icu-to-HealthKit deduplication rule is existing behavior and a
  regression boundary, not a new subsystem in this workstream.
- The intervals.icu endurance write bridge documented as M5 in
  [`MULTISPORT.md`](../../MULTISPORT.md) is not part of this plan. It remains a
  separate candidate with its existing live-provider and value gates.
- This plan does not authorize production integration changes, new HealthKit
  permissions, or release.
