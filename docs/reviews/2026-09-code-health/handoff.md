# Code health sweep — September 2026

Reviewed: 2026-09-14 · Base: `3f4c927` · Working branch: `claude/amazing-volta-6a6u1d`

A provider-neutral record of a code-health sweep across the Worker backend and
the iOS app. It exists so the work can be resumed by any agent or person, in any
AI app, without the originating chat session.

`AGENTS.md` remains the durable repository contract; this file is a temporary
work record, not guidance. Delete it once the packages below land.

## Why this file exists

Chat sessions are not portable between AI apps. Findings and work briefs held
only in a conversation die with it. Everything needed to finish this sweep is
therefore written down here: what was found, what landed, what remains, and how
to verify. Any compatible coding agent reads `AGENTS.md` on entry and can pick
up from the sections below.

## Scope and method

Four read-only discovery passes covered `src/db.ts`, the REST routes, the MCP
server and shared modules, the iOS sync layer, and the iOS view layer. A
mechanical unused-export scan (`npx ts-prune`) cross-checked the TypeScript
findings. Every claim below was verified against the code rather than against
existing documentation.

Baseline before any change: `tsc --noEmit` clean; 78 test files, 1102 tests
passing in about seven minutes under the Workers pool.

This sweep deliberately changes no behaviour. It removes dead code, collapses
duplication, and cuts redundant round trips. Defects found along the way are
recorded separately and are not fixed here.

## Landed

| Commit | Change |
|---|---|
| `bc18fe0` | Delete the dead legacy plan-write cluster and `accountDeletionReceiptMatches` |
| `c36ffda` | Extract `loadPlanTree` so `getState` and `deleteWorkout` reuse the plan row they already hold |
| `aed7a7e` | `deleteWorkoutAtVersion` takes the plan row the REST route already read |
| `314cb48` | Batch the five `getState` collection reads; drop the ownership join on the full sets reload |
| `672a61d` | Beta-feedback mirror dedupes against both issue marker syntaxes and every label |

The dead plan-write cluster mattered beyond tidiness. `addWorkout`,
`patchWorkout`, `bumpPlanVersion`, `bumpPlanVersionByDay` and
`dedupePlanDayOrderIndexes` predate migration `0040` and bumped `plans.version`
without going through `preparePlanWriteStart` / `preparePlanWriteFinish`. Any
future caller would have written a plan mutation with no audit row, no coaching
note and no snapshot, violating the one-atomic-writer rule. They had no callers
and are now gone.

`314cb48` was committed without a suite run because its author stopped mid-item.
Verifying it is the first task of the backend package below.

## Remaining work

Three independent packages. Each item is its own commit so a failing CI job can
be bisected.

### Package A — backend, `db.ts` and routes

1. **Bind the interpolated fence values.** `updateExercise` interpolates
   `plan.id`, `plan.version` and the write nonce into SQL text, and
   `restorePlanSnapshot` interpolates the nonce. Roughly two dozen other fence
   sites bind them. The values are server-generated, so this is consistency
   rather than an injection fix.
2. **Collapse the duplicate date helpers.** `todayLocal` in `intervals.ts`
   equals `todayInTz(null)` in `db.ts`, and a second `addDays` there duplicates
   the exported one. Check for an import cycle first.
3. **Extract `fetchIntervalsArray`.** `fetchPlannedEvents` and
   `fetchCompletedActivities` share about forty-five identical lines of fetch,
   timeout, status and parse handling. Every failure reason string must survive.
4. **Route-level D1 access that duplicates helpers.** The today route
   re-implements `getSetsForSession`; two handlers repeat a group-existence
   probe that `requireGroupMembership` already wraps; three sites repeat the
   Apple-subject user lookup.
5. **Memoise the schema rewriter.** `workoutSchema.ts` runs a full regex
   tokenisation of every SQL statement on every execution, even once the cached
   schema is `workouts`. Cache per query string and mode in a bounded map.
   Probe timing, the sixty-second cache lifetime and retry-once semantics must
   not change; the rename compatibility window depends on them.
6. **Optional.** `getRideConflicts` projects the calendar twice, each projection
   re-reading five tables. Pre-read the inputs once. The projection algorithm
   must not change: it is in byte-for-byte parity with `CalendarProjection.swift`
   and `test/calendar.test.ts` is the contract.

### Package B — backend, MCP and shared modules

1. **Remove the unreachable `note` hooks.** Tools declared `atomicWrite: true`
   carry a `note` hook the dispatcher can never call, because it only runs in
   the non-atomic branch. Fourteen tools are affected. Tighten the `Tool` type
   so the two are mutually exclusive.
2. **Dead exports.** `assertOwner`, `emptySchedule`, and five symbols exported
   but used only in their own file.
3. **Stop re-reading the plan.** `get_current_plan` and `get_today_workout`
   resolve schedule names through a database call that re-reads the plan and
   workouts already held in the tree in memory. `buildStateBrief` already
   derives the same map purely. Extract that and reuse it in all three.
4. **Fix the N+1 in the coach brief.** `buildStateBrief` fetches sets one
   session at a time for up to eight sessions.
5. **De-duplicate MCP against REST.** Two parallel sets of field validators,
   an inline tonnage calculation that re-implements `positiveSetTonnage`,
   trip-type and race normalisation, weekday literals, today-resolution, and a
   coach projection expression written out twice.
6. **Move raw SQL out of tool handlers.** Two MCP handlers query `workouts`
   directly, against the rule that all D1 access goes through `db.ts`. Preserve
   the existing `LIMIT 1` semantics, including its behaviour on duplicate names.
7. **Stop pretty-printing tool results.** The dispatcher serialises with
   two-space indentation, roughly doubling the tokens sent to the coaching
   model, on top of the deprecated-key duplication `workoutWire` already adds.
   Keep this in its own revertable commit.

### Package C — iOS

No Swift toolchain exists in a Linux session, so this package is restricted to
mechanical, grep-verified edits and is validated by CI on macOS.

1. **Stop the duplicate launch pulls.** The tab view's task block and its
   foreground scene-phase branch both call the write-recovery path, which always
   forces a fresh state pull and a catalog fetch. A cold launch therefore pulls
   two to three times. Route the empty-outbox case through the joining load
   instead of the freshness-bumping one.
2. **Stop the starter-availability refetch.** Its task identity includes the
   loading flag, so it flips on every pull and re-issues the request.
3. **Stop refetching the whole exercise catalog** after every successful pull.
4. **Cache the date formatters.** The today-string accessor builds a
   `DateFormatter` on every read across roughly eighty-three references,
   including view bodies; the calendar projection already has a cached one with
   identical configuration. A further nine inline formatter allocations sit in
   view bodies, three of them per feed row.
5. **Hoist repeated work in view builders**, only where both evaluations sit in
   one scope with no state mutation between them.
6. **Delete ten verified-unused symbols**, and fix two stale doc comments.
7. **Collapse duplication**: three private weight formatters that duplicate the
   canonical one, four identical identifiable-string wrappers, join-code error
   copy written three times with drifted wording, an invite alphabet in four
   files, a duplicated activity glyph switch, a widget predicate repeated six
   times, and three different ways of computing today's working sets.

An earlier pass wrongly flagged the rides-by-date helper as dead. It is used in
three files. Treat every candidate with the same suspicion and grep first.

## Verification

```bash
npm run typecheck                  # fast
npx vitest run                     # 78 files, 1102 tests, about 7 minutes
npx vitest run test/calendar.test.ts    # calendar parity contract
npm run plans:check                # planning conventions
```

iOS builds and tests need macOS with Xcode:

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

`db.ts` is roughly 12.8k lines and `SyncModel.swift` roughly 6.9k, carrying at
least seven concerns. The plan fence predicate appears about twenty-five times
in `db.ts` and is the natural seam for a split along the two consistency
classes. That is a structural change and should not ride along with a sweep
whose whole claim is that nothing behaves differently.
