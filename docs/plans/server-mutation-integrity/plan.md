# Server Mutation Integrity

Slug: server-mutation-integrity · Status: active · Updated: 2026-08-28 · Theme: training-trust

## Goal

Make the confirmed high-risk Worker and MCP write paths reject foreign,
malformed, stale, or genuinely duplicate mutations without losing valid
training data. Completion means the reviewed authorization, concurrency,
validation, date, and correction failures have focused regression coverage and
return stable client-visible outcomes.

## Phases

- [ ] **P0 — Independent confirmed write-path fixes**
  - [ ] **(a) Scope and validate REST writes**
    - Resolve exercise additions only through a day in the caller's active plan.
    - Validate set and session fields before D1 writes, return typed 4xx
      responses, and prove malformed values cannot poison a later `/api/state`
      decode.
    - Cover the confirmed foreign-day, archived-day, and malformed-set cases
      with route-level tests.
  - [ ] **(b) Preserve intended MCP straight and timed sets**
    - Make MCP `log_set` distinguish intended sets by source, set index, and
      duration from a true cross-channel duplicate while retaining an explicit
      confirmation override.
    - Prove a same-weight straight-set series and repeated timed efforts all log,
      while immediate iOS narration remains protected from duplication.
- [ ] **P1 — Make concurrent plan and session writes deterministic**
  - Gate `updatePlanTree`'s committing update on the version it read and return
    the existing conflict shape when the write loses a race.
  - Enforce one session per `(user_id, date)`, reconcile any existing duplicate
    rows in the migration, and make concurrent creation re-read the winner.
  - Exercise both races against the Workers/D1 test runtime.
- [ ] **P2 — Correct coaching-facing write semantics**
  - Use the established user/device date boundary for `/api/today` and defaulted
    session dates; expose the existing set correction path, including duration.
  - Correct the confirmed per-hand volume and unknown-muscle response semantics
    so coaching reads do not turn bad inputs into plausible numbers.

## Execution frontier

- P0(a)
- P0(b)

## Next step

**Now (@agent):** Implement P0(a) and P0(b) as independently reviewable fixes,
then run their affected route/MCP tests plus the repository typecheck.

## Notes / open questions

- Source: the August 2026 functionality review at commit `91fd622`; verify each
  named path against current code before editing.
- This plan is not a blanket authorization audit or a data-layer rewrite. Reuse
  the user-scoped lookup, validation, conflict, and D1 transaction patterns that
  already work on sibling routes.
