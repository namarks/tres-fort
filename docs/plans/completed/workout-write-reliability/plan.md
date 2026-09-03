# Workout Write Reliability

Slug: workout-write-reliability · Status: done · Archived: completed · Updated: 2026-09-03 · Theme: training-trust

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

## Closeout and rollout evidence

On 2026-09-03, the owner-authorized combined release ran from exact merged
snapshot `c71e3f9aa1a101988120bb58dcc3357e685e8644`: remote migrations
`0029`–`0032` applied, the compatibility Worker deployed, and the subsequent
owner-managed Apple credential rotation left secret-change version
`0c764d79-6215-49ac-b27d-76920f6de77b` at 100% traffic. The non-destructive
owner exchange then succeeded under the detailed evidence in
[Identity and Account Lifecycle](../identity-account-lifecycle/plan.md), and a
post-proof status check confirmed `enabled=0`, `activated_at=null`, and zero
permits.

At `2026-09-03T16:11:17Z`, after an immediate readback again showed the
compatible Worker at 100% traffic and the fence at `0/null/0`, the owner
explicitly authorized the irreversible production activation. The activation
changed one row; the immediate readback reported `enabled=1`,
`activated_at=1788451877000`, and zero permits, while `/health` remained HTTP
200. A value-preserving direct update against one of nine existing session rows
was then rejected with `workout_write_fence_active`, proving a pre-fence writer
fails closed without exposing or changing workout contents.

The paired iPhone received an attempt-aware direct install of `0.1.0 (28)`
without publishing a new TestFlight/App Store build. During device validation,
SwiftUI cancelled the pull-to-refresh caller even though the Worker returned
HTTP 200, leaving the cached-state banner visible as `cancelled`. The local fix
makes a single account-scoped task own the full-state request, coalesces
concurrent callers, and lets validation finish when the initiating view task is
cancelled. A corrected build installed directly on the paired phone then
cleared the offline banner after a real pull-to-refresh.

The genuine-write proof window began at `2026-09-03T17:16:59Z`. Production
traces showed successful session creation, set writes, and full-state
reconciliation from the corrected build. A value-free D1 readback found one
session updated as `attempt-v1` and two non-deleted sets logged between
`2026-09-03T17:18:32Z` and `2026-09-03T17:18:41Z`; the session's latest update
was `2026-09-03T17:19:04Z`. The same readback reconfirmed the fence at
`enabled=1`, `activated_at=1788451877000`, with zero permits. No synthetic
workout data was created for this proof.

Continued live use exposed a second client boundary: the runner had durably
persisted the set intent but still awaited the complete server admission and
state-reconciliation round trip before advancing the exercise UI. The corrected
runner advances and starts rest immediately after the local enqueue, then lets a
model-owned task deliver and reconcile in the background. Its progress derives
from the union of acknowledged and retryable pending set IDs so one intent is
counted exactly once while a permanently rejected intent reopens its runner
slot. Transport activity no longer blocks entry of the next intentional set;
an in-memory slot guard still rejects an immediate duplicate tap. State pulls
now schedule a trailing fresh request after mutations or bearer renewal, and a
feature-session epoch prevents a pre-sign-out response from applying after a
same-user sign-in. Activity persistence signals ride an account-scoped
generation so a late pre-reauthentication writer refreshes the replacement
calendar. Each tap is bound to its rendered slot and set number, preventing a
queued duplicate from crossing into the next exercise. A delayed permanent
failure preserves any successor timed set already underway, then reopens the
failed slot at that timer's stable commit boundary. Live Activity up-next state
is refreshed from the same runner-aware progress calculation. The complete
simulator suite passed 157/157 tests, including the changed production paths for
immediate offline-first advancement, cross-slot duplicate taps, delayed
permanent rejection during a timed set, trailing refresh, identity ABA,
late-activity refresh, timeout recovery, and caller cancellation. A three-second
grace also suppresses the
normal transient pending-set banner while preserving immediate permanent-failure
feedback and visible prolonged queues. The pre-review Release build installed
directly on the paired iPhone without replacing its data; live workout use then
looked materially better and the owner accepted the behavior for this release.
The later adversarial-review repairs retain that interaction contract and add
the deterministic edge-case coverage above. Broader UI cleanup is deferred.

A later value-free production readback found two additional admitted sets and
one updated `attempt-v1` session after the first proof. The last set was logged
at `2026-09-03T18:26:53Z` and the session reconciled at
`2026-09-03T18:26:55Z`, explaining the screenshot that briefly showed one set
sending between those events rather than a stuck or lost write. The fence was
still `enabled=1`, `activated_at=1788451877000`, with zero permits. The rollback
boundary is permanent: never roll back to a Worker that lacks the permit
batches—forward-fix instead. TestFlight/App Store distribution and eventual
tokenless `legacy` retirement remain separate gates and were not performed
during this milestone.

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
  generation is `legacy`; expected-attempt checks are generation CAS tokens but
  do not themselves claim a protocol. Only a REST request that explicitly
  declares the iOS `attempt-v1` header can claim the generation, after which
  tokenless session creation, set logging, finish, discard, and other
  generation-scoped session mutations are visible conflicts; exact set-ID
  correction or soft-deletion remains tokenless-safe because it cannot retarget
  or undelete a prior attempt. MCP set, finish, and one-off calendar writes
  preserve `legacy`. The migration trigger advances a legacy restart made by the
  old Worker during the migration-before-deploy window, and an idempotent new-app
  retry can claim that already-advanced winner. Migration 0032 also lands
  a disabled, monotonic database fence: before activation it rejects premature
  `attempt-v1` rows; after activation it admits every `sessions`/`set_logs`
  insert or update only inside the compatibility Worker's transaction-local D1
  permit batch, so an old or rolled-back Worker fails closed. REST and MCP
  mutations carry the generation they observed across awaits and return
  structured current-session conflicts. Exact set UUID retries remain idempotent
  across a discard/restart, while stale work is retired rather than retargeted;
  public undelete is rejected so old-attempt tombstones cannot rejoin a later
  workout. The account-scoped iOS
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
  (`39` files, `482` tests), and the complete iOS simulator suite (`147` tests)
  from clean derived data on an iPhone 17 Pro simulator (iOS 26.3.1). Focused
  compatibility, MCP observation, exact-UUID concurrency, recovery,
  calendar-parity, selected-day reopen, legacy-attempt, and persistence
  regressions also passed. The exact `npm run release:preflight` command passed,
  including a repeat of the complete Workers/D1 suite and Wrangler's deploy
  dry-run build. At implementation closeout, migration 0032 was authored and
  locally exercised but had not yet been applied remotely; the later combined
  release recorded above applied it.
- The 2026-09-01 owner decision in the then-active identity plan replaces
  destructive live Apple deletion/revocation proof with a non-destructive owner
  authorization-code exchange plus explicit residual-risk acceptance. It does
  not by itself authorize deployment, workout-fence activation, TestFlight/App
  Store distribution, or deletion/revocation of the owner account.
- Independent exact-head review is a delivery gate for the final tree. The
  initial review of commit `a90fd118d00df22b21c33dab9bb6ab415084219e`
  surfaced six attempt-rollout and concurrency findings; the next review at
  `235621cf3afd4c69d8758641d8319ba5fa7a3ece` found five remaining protocol,
  stale-ACK, first-writer, duplicate-rejection, and rollout-cutover gaps. This
  follow-up separates generation CAS from explicit iOS protocol claims, makes
  stale outcomes authoritative, protects the null first-writer race, rejects
  MCP duplicates before mutation, and adds the one-way database fence. Do not
  reuse either earlier review after the head changes; require a fresh exact-head
  review before any delivery action.
- Delivery review of commit `48e1d05e5fa5915b34e4d58b4bcba42b96cbe942`
  found one remaining same-account renewal race: exact bearer equality could
  discard a valid in-flight group response after session renewal. The repaired
  tree scopes successful group and state reads plus exact-id activity-outbox
  finalization to the same account while retaining exact bearer equality for
  401 invalidation and mutation/scalar response mirroring.
  Activity-outbox persistence now reloads before exact-id mutation so an older
  same-user model cannot replace its successor's queue after reauthentication;
  six focused session and identity regressions plus the complete 147-test
  simulator suite are green.
- Set bodies, retry state, and drain behavior remain owned here. Coordinate only
  the user-keyed namespace and account-switch boundary with the completed P0
  contracts in [Identity and Account Lifecycle](../identity-account-lifecycle/plan.md).
- Store only the pending request bodies and small UI checkpoint needed for
  recovery. Do not build event sourcing, background-server infrastructure, or a
  new synchronization protocol for this workstream.
