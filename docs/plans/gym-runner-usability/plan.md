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
| P1 | gated_by | external:owner-source-publication | Automatic approval review rejected the initial GitHub push; publication approval remains pending. |
| P2 | gated_by | external:owner-ios-distribution | Local implementation does not authorize an app release. |

## Next step

**Now (@owner):** Authorize publication of the combined local
`fix/timer-survives-exercise-preview` branch. Then obtain independent review
of the exact current head and terminal-green required CI before merging.
App distribution remains a separate gate.

## Evidence and scope

The timer-only change is locally committed as `806c080`. The combined source
passes the unsigned iPhone 17 / iOS 26.2 build, all 456 unit tests, six affected
UI journeys (timer navigation and completion, exact lb entry, kg switching,
correction, and complete alternating superset rounds), and four dedicated
accessibility audits. Earlier UI failures were isolated to synthetic test
setup and corrected; production source hashes match across these successful
checks. The initial combined invocation was not a full green suite; required
remote CI and independent review remain pending. No source has been published
or app distributed.

Local evidence is retained in the task's `runner-feedback` artifact folder;
the final source manifest and result summaries identify the tested snapshot.
Superset execution uses the existing structured group metadata and scheduler;
this work does not infer groups from names or change the member's live plan.
