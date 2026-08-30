# Workout Write Reliability

Slug: workout-write-reliability · Status: active · Updated: 2026-08-30 · Theme: training-trust

## Goal

Ensure a set, workout completion, or discard initiated in the gym is eventually
applied exactly once or remains visibly queued for recovery across weak
connectivity, app suspension, and same-user reauthentication. The runner must
never present a failed write as completed or silently drop the user's intent.

## Phases

- [x] **P0 — Durable, idempotent set intents**
  - Mint one UUID and request body per user tap, persist it before sending, and
    reuse it for every retry so the existing server deduplication can work.
  - Disable duplicate submission while a set is in flight, render queued and
    failed states in the runner, and drain pending sets on foreground/connectivity
    recovery.
  - Prove success, timeout, retry, double-tap, and relaunch behavior with focused
    model tests and an iOS build.
- [ ] **P1 — Durable workout finish and discard**
  - Persist terminal intents instead of swallowing request failures.
  - Finish only after that session's queued sets settle; make discard supersede
    its pending set/finish intents so a locally discarded workout cannot return.
  - Retry the existing idempotent endpoints and keep the UI truthful until the
    server acknowledges the terminal state.
- [ ] **P2 — Recover the workout and last known state**
  - Persist the minimal runner checkpoint and last successful state snapshot,
    then offer resume when today's server session is still in progress.
  - Refresh and drain on foreground, show cached plan data with an offline label
    on cold launch, and end stale rest Live Activities left by process death.
  - Update the server and iOS calendar projections so a real logged session stays
    visible on a blackout-trip date, and keep their truth table covered by the
    shared parity verification.
  - Verify relaunch recovery without introducing a second plan projection or a
    general-purpose sync framework.

## Execution frontier

- P1

## Next step

**Now (@agent):** Implement P1 by persisting workout-finish and discard intents,
ordering finish behind that session's queued sets, and making discard supersede
pending set/finish intents while the UI remains queued until server acknowledgement.

## Notes / open questions

- Source: the August 2026 functionality review at commit `91fd622`; the server's
  client-UUID idempotency contract already exists and should remain the seam.
- P0 is complete on `codex/workout-write-reliability-p0`: an
  account-scoped durable set-intent queue persists the immutable UUID/body
  before network work, retries through serialized launch/foreground/connectivity
  drains, reconciles server acknowledgements, preserves lifecycle boundaries,
  and renders queued/failed state without counting it as completed. Xcode 26.3
  runtime verification on an iPhone 17 Pro simulator (iOS 26.3.1) produced a
  successful full app build, 23/23 focused `SetOutboxTests`, and 61/61 complete
  `TresFortTests`; the broader run also exposed and verified a small pre-existing
  auth-integrity error-label fix. TypeScript typecheck, all 434 Worker tests,
  direct source compilation, and exact-diff review also pass.
- Set bodies, retry state, and drain behavior remain owned here. Coordinate only
  the user-keyed namespace and account-switch boundary with the completed P0
  contracts in [Identity and Account Lifecycle](../identity-account-lifecycle/plan.md).
- Store only the pending request bodies and small UI checkpoint needed for
  recovery. Do not build event sourcing, background-server infrastructure, or a
  new synchronization protocol for this workstream.
