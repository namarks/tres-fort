# Workout Write Reliability

Slug: workout-write-reliability · Status: done · Archived: completed · Updated: 2026-08-30 · Theme: training-trust

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
- [x] **P1 — Durable workout finish and discard**
  - Persist terminal intents instead of swallowing request failures.
  - Finish only after that session's queued sets settle; make discard supersede
    its pending set/finish intents so a locally discarded workout cannot return.
  - Retry the existing idempotent endpoints and keep the UI truthful until the
    server acknowledges the terminal state.
- [x] **P2 — Recover the workout and last known state**
  - Persist the minimal runner checkpoint and last successful state snapshot,
    then offer resume when today's server session is still in progress.
  - Refresh and drain on foreground, show cached plan data with an offline label
    on cold launch, and end stale rest Live Activities left by process death.
  - Update the server and iOS calendar projections so a real logged session stays
    visible on a blackout-trip date, and keep their truth table covered by the
    shared parity verification.
  - Verify relaunch recovery without introducing a second plan projection or a
    general-purpose sync framework.

## Next step

No further repository-executable step. Any production rollout is a separately
authorized, ordered operation: first run the existing Worker release path so
migration 0032 lands before the compatibility Worker; only after that Worker is
live may the attempt-aware iOS app be released. App-first rollout is unsupported.
Retire the tokenless `legacy` mode only after a separately chosen minimum-app-
version or adoption gate. No migration, deploy, App Store/TestFlight release,
or legacy-mode retirement was performed during closeout.

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
  auth-integrity error-label fix. A production endpoint regression now also
  proves stale day-template recovery returns the permanent 422 contract the
  outbox uses before retrying without the removed association. TypeScript
  typecheck, all 435 Worker tests, and direct source compilation pass.
- P1 is complete in the same coherent work wave. An account-scoped terminal
  outbox persists finish/discard before any network await and shares one
  serialized drain with set intents: all queued or failed sets for a date settle
  before finish, while discard durably replaces finish, removes older set
  intents, masks late acknowledgements, and stays as an acknowledged barrier
  until the user explicitly starts that date again. The Worker makes discard
  final for stale session-addressed writes with conditional updates and ordered
  D1 batches, returns a stable `409 session_discarded`, preserves exact set-UUID
  retry semantics, and emits one discard audit under concurrent retries. The
  P1 initially retained a no-migration restart boundary: starting the date
  cleared the acknowledged barrier, while discarded history remained available
  for projection but could not become the runner's live `todaySession`.
  Verification passed TypeScript typecheck, all 441 Worker tests, 82/82 iOS
  tests from clean derived data, a full simulator app build, and independent
  backend and iOS review. P2 superseded P1's initial no-migration restart seam
  with an explicit generation contract so a delayed write from an older workout
  cannot attach to a later restart of the same civil date.
- P2 completes recovery and the cross-surface write contract. Migration 0032
  assigns every session an attempt generation plus a persisted write protocol.
  The compatibility Worker accepts released tokenless writes only while that
  generation is `legacy`; the first attempt-scoped create, set, finish, discard,
  or reopen atomically claims `attempt-v1`, after which tokenless mutation is a
  visible conflict. The migration trigger advances a legacy restart made by the
  old Worker during the migration-before-deploy window, and an idempotent new-app
  retry claims that already-advanced winner. REST and MCP mutations carry the
  generation they observed across awaits and return structured current-session
  conflicts. Exact set UUID retries remain idempotent across a discard/restart,
  while stale work is retired rather than retargeted; public undelete is rejected
  so old-attempt tombstones cannot rejoin a later workout. The account-scoped iOS
  snapshot store uses local revision tickets so stale full-state pulls cannot
  overwrite acknowledgements from another model, and durable runner checkpoints
  retain session/restart identity across process death. Cached state stays
  browse-only until live validation; successful deletion invalidates it,
  authoritative conflicts still repair the mounted model, and terminal precedence
  normalizes legacy nil attempts to generation zero. Explicit skipped overrides
  reopen a fresh attempt pinned to the user's chosen day before the runner starts,
  clearing timestamps, fatigue, and notes. Server and iOS blackout-trip projections
  share the rule that only real logged sessions survive a hard blackout, without
  manufacturing ride conflicts.
- Final verification passed TypeScript typecheck, the complete Workers/D1 suite
  (`38` files, `472` tests), and the complete iOS simulator suite (`141` tests)
  from clean derived data on an iPhone 17 Pro simulator (iOS 26.3.1). Focused
  compatibility, MCP observation, exact-UUID concurrency, recovery,
  calendar-parity, selected-day reopen, legacy-attempt, and persistence
  regressions also passed. Migration 0032 was authored and locally exercised
  but was not applied remotely.
- Independent exact-head review is a delivery gate for the final tree. The
  initial review of commit `a90fd118d00df22b21c33dab9bb6ab415084219e`
  surfaced six attempt-rollout and concurrency findings; this follow-up addresses
  all six with the compatibility protocol and focused regressions above. Do not
  reuse that earlier review after the head changes; require a fresh exact-head
  review before any delivery action.
- Set bodies, retry state, and drain behavior remain owned here. Coordinate only
  the user-keyed namespace and account-switch boundary with the completed P0
  contracts in [Identity and Account Lifecycle](../../identity-account-lifecycle/plan.md).
- Store only the pending request bodies and small UI checkpoint needed for
  recovery. Do not build event sourcing, background-server infrastructure, or a
  new synchronization protocol for this workstream.
