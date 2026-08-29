# Server Mutation Integrity

Slug: server-mutation-integrity · Status: done · Archived: completed · Updated: 2026-08-29 · Theme: training-trust

## Goal

Make the confirmed high-risk Worker and MCP write paths reject foreign,
malformed, stale, or genuinely duplicate mutations without losing valid
training data. Completion means the reviewed authorization, concurrency,
validation, date, and correction failures have focused regression coverage and
return stable client-visible outcomes.

## Phases

- [x] **P0 — Independent confirmed write-path fixes**
  - [x] **(a) Scope and validate REST writes**
    - Resolve exercise additions only through a day in the caller's active plan.
    - Validate set and session fields before D1 writes, return typed 4xx
      responses, and prove malformed values cannot poison a later `/api/state`
      decode.
    - Cover the confirmed foreign-day, archived-day, and malformed-set cases
      with route-level tests.
  - [x] **(b) Preserve intended MCP straight and timed sets**
    - Make MCP `log_set` distinguish intended sets by source, set index, and
      duration from a true cross-channel duplicate while retaining an explicit
      confirmation override.
    - Prove a same-weight straight-set series and repeated timed efforts all log,
      while immediate iOS narration remains protected from duplication.
- [x] **P1 — Make concurrent plan and session writes deterministic**
  - [x] Gate `updatePlanTree`'s committing update on the version it read and return
    the existing conflict shape when the write loses a race.
  - [x] Enforce one session per `(user_id, date)`, reconcile any existing duplicate
    rows in the migration, and make concurrent creation re-read the winner.
  - [x] Exercise both races against the Workers/D1 test runtime.
- [x] **P2 — Correct coaching-facing write semantics**
  - [x] Use the established user/device date boundary for `/api/today` and defaulted
    session dates; expose the existing set correction path, including duration.
  - [x] Correct the confirmed per-hand volume and unknown-muscle response semantics
    so coaching reads do not turn bad inputs into plausible numbers.

## Next step

No further executable step. The implementation and local migration replay are
complete; applying migration 0029 remotely or deploying remains outside this
workstream's authority and was not performed during closeout.

## Notes / open questions

- Source: the August 2026 functionality review at commit `91fd622`; verify each
  named path against current code before editing.
- P0 completed with focused route/MCP regressions and the repository typecheck;
  no schema migration or broader authorization rewrite was needed.
- P1 and P2 completed with migration 0029's exact duplicate-session replay,
  plan/session/set race coverage, the repository typecheck, and the complete
  Workers/D1 suite (`33` files, `384` tests). The authorized migration preserves
  the canonical session identity and creation time, ranks lifecycle state as
  completed > in-progress > skipped > planned > discarded/other, promotes the
  winning row's coherent plan/day/status/timestamps/fatigue/notes/update tuple,
  preserves every set and the best usable export ledger, then removes redundant
  loser shells. Per-hand tonnage now uses
  the same independent side/implement multipliers in server, MCP, and iOS
  rollups. Migration 0029 was authored and locally tested but not applied remotely.
- Independent pre-integration review found no remaining actionable findings;
  repository delivery still requires the ordinary exact-head review and CI
  gates before merge.
- This plan is not a blanket authorization audit or a data-layer rewrite. Reuse
  the user-scoped lookup, validation, conflict, and D1 transaction patterns that
  already work on sibling routes.
