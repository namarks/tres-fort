# Workout Write Reliability

Slug: workout-write-reliability · Status: gated · Updated: 2026-08-30 · Theme: training-trust

## Goal

Ensure a set, workout completion, or discard initiated in the gym is eventually
applied exactly once or remains visibly queued for recovery across weak
connectivity, app suspension, and same-user reauthentication. The runner must
never present a failed write as completed or silently drop the user's intent.

## Phases

- [ ] **P0 — Durable, idempotent set intents**
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

- P0

## Dependencies

| Local phase | Relationship | Target | Reason |
|---|---|---|---|
| P0 | gated_by | external:ios-runtime-build-verification | The owner must install an iOS 26.2 simulator runtime or provide an iOS runner so the focused XCTest suite and full app build can execute. |

## Next step

**Now (@owner):** Install an iOS 26.2 simulator runtime (or provide an iOS
runner), then have the agent execute the focused set-outbox XCTest suite and a
full TresFort app build. The P0 implementation and source-level verification
are complete, but P0 remains open until those runtime gates pass.

## Notes / open questions

- Source: the August 2026 functionality review at commit `91fd622`; the server's
  client-UUID idempotency contract already exists and should remain the seam.
- P0 implementation is present on `codex/workout-write-reliability-p0`: an
  account-scoped durable set-intent queue persists the immutable UUID/body
  before network work, retries through serialized launch/foreground/connectivity
  drains, reconciles server acknowledgements, preserves lifecycle boundaries,
  and renders queued/failed state without counting it as completed. Direct
  production/module/XCTest source compilation, TypeScript typecheck, all 434
  Worker tests, and exact-diff review pass. The installed Xcode exposes the iOS
  SDK but no iOS runtime, so `xcodebuild` cannot select an iOS destination and
  asset compilation reports `supportedRuntimes=[]`; no XCTest assertion or full
  app build has executed yet.
- Set bodies, retry state, and drain behavior remain owned here. Coordinate only
  the user-keyed namespace and account-switch boundary with the completed P0
  contracts in [Identity and Account Lifecycle](../identity-account-lifecycle/plan.md).
- Store only the pending request bodies and small UI checkpoint needed for
  recovery. Do not build event sourcing, background-server infrastructure, or a
  new synchronization protocol for this workstream.
