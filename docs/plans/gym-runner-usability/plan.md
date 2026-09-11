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
- [x] **P1 — Reviewed repository delivery**
  - Publish the coherent branch and require independent review of its exact
    head, all configured CI checks, and post-merge evidence.
- [ ] **P2 — App distribution**
  - Release the reviewed iOS source under separate owner authority, with
    the repository's device checks and distribution procedure.

## Execution frontier

- P2

## Dependencies

| Local phase | Relationship | Target | Reason |
|---|---|---|---|
| P2 | gated_by | external:owner-ios-distribution | Local implementation does not authorize an app release. |

## Next step

**Now (@owner):** Authorize iOS distribution of the integrated source using
the existing release procedure and device checks. Repository delivery is
complete; this workstream has not distributed an app build.

## Evidence and scope

[PR #179](https://github.com/namarks/tres-fort/pull/179) merged as
`adcba1d08a4181a95100f31c4853859e1c9dc320`. Its exact reviewed head was
`a5dd7e26f2331af0abfa9fc73c2fe588352dd92e`; fresh independent review found no
remaining issues, its one review thread was resolved, and all eight configured
checks passed in [CI run 34557345674](https://github.com/namarks/tres-fort/actions/runs/34557345674).
The merge retained the reviewed tree
`1590c9c0f5aef25e1c88745d7fdc590ea7692dce`, and ancestry on remote main was verified.

Final local verification used an unsigned iPhone 17 / iOS 26.2 build: 503 unit
tests passed, with one existing physical-device-only file-protection test
skipped, and all four core timer/superset/kg UI journeys passed. The broader
integrated run also passed all 21 workout UI checks, including four
accessibility audits. The final source manifest matches every tested iOS input.

Independent review identified an upgrade regression in checkpoints without
unit metadata. The regression reproduced before correction and now passes
through resume, navigation and persistence. Missing legacy units preserve the
exercise's existing stored-unit interpretation when all known prescription
fields match; explicit unit changes still invalidate stale drafts. Per-slot
inputs retain the protected checkpoint storage and account/session/attempt
ownership guards. Only the lb/kg setting uses the preference store.

Circuit and superset execution uses existing structured group metadata and
automatic progression. This work does not infer groups from names or change
the member's live plan. No deployment, migration, or app distribution occurred
in this workstream.
