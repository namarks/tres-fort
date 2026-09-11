# Gym Runner Usability

Slug: gym-runner-usability · Status: active · Updated: 2026-09-10 · Theme: gym-floor

## Goal

Let a member browse during a timed warm-up, recognize and execute a superset
as one group, enter the weights available at the gym in lb or kg, and reuse
each exercise's chosen load in subsequent rounds of the same workout.

## Phases

- [x] **P0 — Workout navigation and load entry**
  - Keep the executing timed set and its original logging identity alive
    while Previous, Next, or the exercise strip opens a workout preview.
  - Show superset/circuit membership, current member, round progress and
    both rest intervals together; preserve automatic member advancement.
  - Offer lb/kg input, including exact-value entry and set corrections.
    Convert into each exercise's existing stored unit. Switching units or
    saving an untouched rounded display must not change the original load.
  - Retain per-slot drafts in the existing account/session/attempt-scoped
    runner checkpoint across alternating rounds, navigation and recovery.
    Changed prescriptions invalidate their drafts; a new workout starts
    from its prescription. No recurring plan or logged-data rewrite.
  - Verify conversion, offline rounds, cold resume, prescription changes,
    new attempts, grouped UI, and all timer regression journeys.
- [ ] **P1 — Reviewed repository delivery**
  - Publish the coherent branch and require independent review of its exact
    head, all configured CI checks, and post-merge evidence.
- [ ] **P2 — App distribution**
  - Release the reviewed iOS source under separate owner authority, with
    the repository's device checks and distribution procedure.

## Execution frontier

- P1

## Dependencies

| Local phase | Relationship | Target | Reason |
|---|---|---|---|
| P2 | gated_by | external:owner-ios-distribution | Local implementation does not authorize an app release. |

## Next step

**Now (@agent):** Complete exact-head review and configured CI for
[PR #179](https://github.com/namarks/tres-fort/pull/179), then merge and verify
the integration result. Nick explicitly authorized this repository delivery
on 2026-09-10. The source-publication gate is resolved.
App distribution remains a separate gate.

## Evidence and scope

The original timer-only change was committed as `806c080`. Before refreshing
against current main, the combined source passed the unsigned iPhone 17 /
iOS 26.2 build, all 456 unit tests, six affected
UI journeys (timer navigation and completion, exact lb entry, kg switching,
correction, and complete alternating superset rounds), and four dedicated
accessibility audits. Earlier UI failures were isolated to synthetic test
setup and corrected; production source hashes match across these successful
checks. The initial combined invocation was not a full green suite; required
remote CI and independent review remain pending. The branch now includes
main's protected local storage and newer synthetic fixtures; input drafts
retain the existing protected checkpoint storage and ownership guards.
Only the lb/kg setting uses the preference store. Reverification of this
integrated source is required. No app has been distributed by this workstream.

Independent review identified an upgrade regression: checkpoints predating
the unit field lost edited inputs despite unchanged prescriptions. The
regression reproduced before correction. Missing legacy units now retain
the exercise's existing stored-unit interpretation while all known fields
must still match; explicit unit changes still invalidate drafts. Tests cover
resuming an old-format checkpoint, navigation, persistence, and known-unit
invalidation. Fresh verification and review of the correction are pending.

Local evidence is retained in the task's `runner-feedback` artifact folder;
the final source manifest and result summaries identify the tested snapshot.
Superset execution uses the existing structured group metadata and scheduler;
this work does not infer groups from names or change the member's live plan.
