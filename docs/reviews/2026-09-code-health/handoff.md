# Code health sweep — September 2026

Reviewed: 2026-09-14 · Base: `3f4c927` · Working branch: `claude/amazing-volta-6a6u1d`

A provider-neutral record of a code-health sweep across the Worker backend and
the iOS app. It exists so the work can be resumed by any agent or person, in any
AI app, without the originating chat session.

`AGENTS.md` remains the durable repository contract; this file is a temporary
work record, not guidance. Delete it once the sweep lands.

## Scope and method

Four read-only discovery passes covered `src/db.ts`, the REST routes, the MCP
server and shared modules, the iOS sync layer, and the iOS view layer. A
mechanical unused-export scan (`npx ts-prune`) cross-checked the TypeScript
findings. Three implementation passes then ran in isolated worktrees, each
followed by an independent reviewer whose only job was to disprove the
no-behaviour-change claim. Every claim here was verified against the code rather
than against existing documentation.

Baseline before any change: `tsc --noEmit` clean; 78 test files, 1102 tests.

The final PR combines dead-code removal and consolidation with deliberate
performance improvements. Compact MCP result text and corrected cron copy are
intentional output changes; the feedback-mirror deduplication is a separate
bug fix. Parsed training values, write transactions and sync-watermark rules
remain the compatibility contract. Defects recorded at the end remain separate.
The follow-up measurements and scope are in [performance.md](performance.md).

## What the sweep did

**Backend, `db.ts` and routes.** Deleted the dead legacy plan-write cluster.
Extracted `loadPlanTree` so callers holding a plan row stop re-reading it.
`deleteWorkout` takes the plan row the route already read. Bound the plan fence
values that were being spliced into SQL text. Extracted `fetchIntervalsArray`
from the two intervals readers. Routed group and Apple-identity reads through
`db.ts` helpers. Memoised the legacy SQL rewrite per query and mode. Read the
calendar projection inputs once for both ride-conflict windows, initially
taking that call from eleven queries to six. The final conflict reader loads
only strength context and planned-event load: four queries. Pure civil-date,
calendar and conflict rules now live in `src/calendarProjection.ts`; D1
selection stays in `db.ts` and existing imports remain compatible.

**Backend, MCP and shared modules.** Dropped the unreachable `note` hooks from
fourteen atomic-write tools and made the type enforce it. Deleted unreferenced
helpers and unexported in-file-only symbols. Projected the weekly schedule from
the plan tree in hand instead of re-reading the database. Batched the coach
brief's per-session set reads. Shared one field-validation module between REST
and MCP. Reused the canonical tonnage metric, trip-type set and weekday list.
Resolved the member's today through one helper. Moved MCP day-reference lookups
into `db.ts`, as the architecture rule requires. Sent tool results as compact
JSON. Coaching summaries index the current invocation's catalog and sets once,
preserving catalog/cohort and logged-at/id ordering without persistent caches.

**iOS.** Deleted verified-unused accessors and two dead members. Routed three
private weight formatters through the canonical one. Replaced four identical
sheet-item wrappers with one. Folded a duplicated activity glyph switch into the
model. Read the Live Activity timer kind through one computed property. Hoisted
per-render date formatters out of view bodies and computed repeated per-render
values once.

## The three things worth knowing

**The dead plan-write cluster mattered beyond tidiness.** `addWorkout`,
`patchWorkout`, `bumpPlanVersion`, `bumpPlanVersionByDay` and
`dedupePlanDayOrderIndexes` predate migration `0040` and bumped `plans.version`
without going through `preparePlanWriteStart` / `preparePlanWriteFinish`. Any
future caller would have written a plan mutation with no audit row, no coaching
note and no snapshot, violating the one-atomic-writer rule. They had no callers.

**Batching the `getState` reads is not cleanup, and must not be re-attempted as
such.** An early commit batched the five collection reads into one D1 call. CI
caught it. `test/data_storage_p1.test.ts` proves the watermark contract by
proxying the sets statement's `.all()` to commit a write mid-read; a batch never
calls `.all()`, so the interleave never fires. Two independent passes reached the
same conclusion and reverted it. The change also replaces five independent reads
with a single read snapshot, which is a real semantic difference on the hottest
sync path. If those round trips are worth collapsing, it is a deliberate
performance change that must also re-point that test, not a cleanup.

The ownership half of that commit was orthogonal and survives: the full sets
reload selects on `set_logs.user_id` instead of joining `sessions`. Migration
`0034` backfills that column, asserts the backfill with a throwaway
CHECK-constrained table that fails the migration if any row is orphaned or
disagrees with its session, and maintains it by trigger for the old insert shape.

**The beta-feedback mirror was filing every submission repeatedly.** Its dedup
scan filtered on one label and matched one marker syntax. A second mirror outside
this repository used a different label and a different syntax, so each run
re-filed everything the other had captured. Several TestFlight submissions exist
as three separate issues.

## Rejected by review, deliberately not landed

An independent reviewer found two blocking defects and four behaviour changes in
the iOS package. All six are reverted in `e66740b`. They are recorded here so
they are not reintroduced.

| Change | Why it was rejected |
|---|---|
| Starter-availability task key | Kept two of the seven conjuncts the guard still tests, so the task could fire once while the guard was false and never re-fire, losing the starter entry point for the process. |
| Catalog fetch gating | `/api/state` returns the plan only when its version moved, so a member not editing their plan would never re-read the exercise catalog, across relaunches. A migration adding exercises or changing laterality would never reach them. |
| Write recovery joining an in-flight pull | On reconnect it could join the request already doomed by the outage and return having never fetched state. |
| `todayString` via the cached formatter | That formatter captures the time zone once at first use, and this is the device-local civil date the client owns for session attribution. `ManualActivitySheet.ymd` was restored for the same reason. |
| Shared join-error copy | The consolidation picked the typed-code wording, so a dead Universal Link told a member to check the characters of a code they never typed. |
| `FinishedView` sets from the index | Row membership is identical, but the index comparator is not a total order, so the set review list could reorder. That is the list a member taps to correct a set. |

The lesson generalises. Every one of these came from a brief that described a
redundancy accurately but missed what the redundant-looking code was actually
load-bearing for.

## Deliberately skipped during implementation

- **Similar date helpers in `intervals.ts`.** The initial sweep avoided a
  circular import from `db.ts`. A pure calendar module now exists, but the
  provider helper uses `Date.parse` rather than civil integer arithmetic;
  consolidating them still needs an explicit decision about invalid and
  out-of-range dates. It is not a mechanical deduplication.
- **Race normalisation.** The MCP tool and the shared normaliser disagree on
  empty strings, so sharing one would change which payloads are accepted.
- **Two iOS deletions from the brief were wrong.** A helper the brief called
  dead has seven test callers, and a fixture parameter it called unused is
  passed. Both were kept. Grep before deleting, including the test targets.

## Verification

```bash
npm run typecheck
npm run test:query-plans           # requires sqlite3 CLI
npx vitest run --shard=1/3
npx vitest run --shard=2/3
npx vitest run --shard=3/3
npm run plans:check
```

### A full local run aborts before it finishes, on `main` too

`npx vitest run` over the whole suite in one process stops around the 39th file
with `Isolated storage failed: Expected .sqlite, got <hash>.sqlite-shm`, and
whichever test is mid-flight when the worker dies reports a five-second timeout.

This is not caused by any change in this sweep. Unmodified `main` at `3f4c927`
produces a byte-identical result in the same environment: 38 files passed of 39,
one failed test, one error, and the same victim
(`test/mobile_coach.test.ts > mobile coach approval`). Verified by running the
suite in a detached worktree at that commit.

The assertion lives in the Workers pool's isolated-storage teardown, which
enumerates the D1 directory expecting only `.sqlite` files and trips over the
write-ahead-log `-shm` sidecar. Running other suites concurrently changes which
test dies but not the underlying failure.

CI does not hit it because it shards the backend tests across three jobs, so no
single process accumulates enough files. Until it is fixed, verify locally by
running suites in groups rather than all at once, and treat a green CI run as
the authoritative full-suite signal.

This was observed on Linux; a macOS developer machine may not reproduce it.

iOS builds and tests need macOS with Xcode, and CI is the only place they run:

```bash
cd ios && xcodegen generate
npm run ios:verify -- --runtime <sim runtime> --device <sim device>
```

## Found but deliberately not fixed here

These are defects, not code health, and each deserves its own change.

- **Starter and quick-add exercises store a target weight of zero** rather than
  null, and the runner treats zero as a real prescription. A new member's first
  workout prefills nothing useful and the last-time fallback never fires.
- **The rest timer starts after the final set** of a workout, so a full-screen
  overlay stands between the member and the finish screen.
- **A cold launch with no network cannot start or resume a workout**, because
  the runner checkpoint is only validated against a live state pull.
- **Plan-edit conflicts surface wrongly.** Adding an exercise against a stale
  version throws past an uncaught route and returns a server error; deleting one
  reports the slot as missing; the MCP slot tools take no expected version.
- **Mid-workout plan edits detach set history from its slot**, so the runner's
  last-time display for that lift goes blank the next session.

## Future work

The pure calendar boundary is extracted, but `db.ts` and `SyncModel.swift`
still own several other concerns. Further splits of versioned-plan writers,
account lifecycle or iOS recovery should each preserve their transaction and
ordering boundaries in a separately scoped change. Do not reintroduce the
rejected changes above or remove release-compatibility adapters merely to
reduce line count.
