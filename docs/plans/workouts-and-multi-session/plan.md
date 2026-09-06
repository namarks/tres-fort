# Workouts and Multi-Session Days

Slug: workouts-and-multi-session · Status: planned · Updated: 2026-09-05 · Theme: gym-floor

## Goal

Two model corrections that the workout library exposed:

1. The reusable workout is stored as `day_templates` and referenced as
   `day_template_id`, a name from the original weekly-split design where a
   template was "a training day". Storage, service layer, REST, MCP, and iOS
   should all call it a **workout**, with a bounded compatibility window for
   clients already in the field.
2. `ux_session_user_date` (migration `0029`) makes one strength session per
   member per civil date a hard invariant. A member who lifts in the morning
   and does a second workout in the evening cannot record both. Done means a
   date can hold an ordered list of sessions, every existing single-session
   behavior is unchanged for the first one, and the calendar, Today, MCP, and
   group feed present the extra sessions without a second projection engine.

## Phases

- [ ] **P0 — Rename `day_templates` to `workouts` end to end**
  - Migration: `ALTER TABLE day_templates RENAME TO workouts`; rename
    `template_exercises.day_template_id` and `sessions.day_template_id` to
    `workout_id`; recreate `ix_te_day` under the new column. SQLite rewrites
    foreign-key references on `RENAME TABLE`; add a test that
    `PRAGMA foreign_key_check` is clean and that `session_aliases`,
    `set_logs.template_exercise_id`, and the `0032` attempt trigger still
    behave after the rename. `template_exercises` keeps its name: it is the
    slot table and "template" is accurate there.
  - Service layer: rename `DayTemplateRow`, `getDayTemplateInPlan`,
    `addDayTemplate*`, `patchDayTemplate*`, `deleteDayTemplate`, and the
    `days` key of `PlanTree` to workout terms. This is a mechanical rename
    across `src/db.ts` (about 160 references), `src/types.ts`, and
    `src/routes/api.ts`; `test/` follows.
  - Wire compatibility for the released iOS app, one release cycle: REST
    responses emit both `workout_id` and `day_template_id`, and the plan tree
    carries both `workouts` and `days`; requests accept either key.
    `/api/workouts...` routes are added and `/api/days...` stay mounted as
    aliases to the same handlers. Record the removal in this plan and remove
    both after the next TestFlight build has been the minimum for one cycle.
  - MCP: add `add_workout`, `update_workout`, `delete_workout`; keep
    `add_day` and `update_day` registered with a deprecation sentence in their
    descriptions for the same cycle so existing Claude conversations keep
    working. `audit_log.tool` keeps historical names; do not rewrite history.
    Update `coach://state/current`, `AGENTS.md`, and `docs/DESIGN.md` §3–§5.
  - The `plans.meta.schedule` contract is unchanged: weekday → workout id,
    `null` = rest. Only the prose describing the value changes.
  - iOS: rename `DayTemplate`, `dayTemplateID`, `RoutineDayTarget`, and the
    `days` decoding path; decode the new key with fallback to the old one so
    a new build works against a Worker that has not yet been released.
  - Release: expand-contract, because `npm run release` runs the migration
    before the deploy and the deployed Worker hard-codes the old
    identifiers, so a single release would fail every plan-tree request
    from migration completion until the new deployment propagates. SQLite
    cannot carry both table names for writes, so the compatibility layer is
    in the Worker: release A deploys a schema-adaptive Worker that probes
    `PRAGMA table_info(sessions)` once per isolate for `workout_id` and
    templates the affected SQL on the detected identifiers; release B runs
    the rename migration while that Worker keeps serving; release C removes
    the dual-schema code. Keep the down-migration beside the forward one and
    verify the sequence locally (`db:migrate:local` → `dev` → smoke) with
    the release A Worker against both schemas before running it remotely.
- [ ] **P1 — Ordered sessions per date**
  - Migration: add `sessions.slot INTEGER NOT NULL DEFAULT 0`; drop
    `ux_session_user_date`; create `UNIQUE (user_id, date, slot)`. Every
    existing row is slot 0. This ships as two releases because the deployed
    Worker inserts sessions with `ON CONFLICT(user_id, date) DO NOTHING`
    (`getOrCreateSession`, `setPlannedSession`, `skipPlannedSession`) and
    SQLite rejects that clause once the named index is gone: release A
    deploys a compatibility Worker whose inserts use a targetless
    `ON CONFLICT DO NOTHING`, valid under either index; release B runs the
    migration and deploys the slot-aware Worker. A test asserts no
    `ON CONFLICT(user_id, date)` remains in `src/db.ts` before release B. Slot 0 is the **primary** session and keeps
    every current rule unchanged: the attempt CAS, discard revival, the
    `legacy`/`attempt-v1` write protocol, the `0032` trigger (per row, so it
    needs no change), and the `(user, date)` recovery checkpoint.
  - Service layer: every `(user_id, date)` session lookup in `src/db.ts`
    (about eleven) takes an explicit slot and defaults to 0, so existing
    callers see no behavior change. Released iOS builds have no slot field
    and pick an arbitrary same-date session for Today, so once another
    device or Claude creates slot 1 they could display, log against, or
    finish the wrong workout. Under the shared compatibility rule below, a
    client that does not declare the `slots` capability receives only
    slot-0 sessions and their sets from `/api/state`, `/api/today`, and the
    session routes, and cannot address a slot above 0. `getOrCreateSession`
    gains a `nextSlot` mode that inserts at `MAX(slot)+1` for the date,
    keyed by a client-generated session `id` that is the idempotency key:
    a retry with the same `id` returns the committed row and its slot
    instead of allocating again, so a lost response cannot create a
    duplicate workout. Slots are assigned once and never reused. A slot
    above 0 can be
    discarded or skipped like the primary; there is no rule that slot 1
    requires slot 0 to be complete.
  - REST: `POST /api/sessions` accepts `slot` (an exact retry of a known
    slot) or `additional: true` with a required client-generated `id`
    (allocate the next slot, idempotent on that id); `PUT /api/calendar/{date}`
    keeps its current meaning for slot 0 and gains `PUT
    /api/calendar/{date}/{slot}`. Set writes are unchanged because they
    already address a session id.
  - Projection: `projectCalendar` groups real sessions per date instead of
    keeping the first. `CalendarCell.status` stays a single coarse value so
    released clients are unaffected, derived across the date's sessions by a
    fixed precedence: any `in_progress` → `in_progress`; else any
    `completed` → `completed`; else any `planned` → `planned`; else
    `skipped`. A new `sessions[]` array on the cell lists each slot with its
    status and workout. `discarded` rows vanish per slot exactly as today.
    `CalendarProjection.swift` mirrors the grouping and the precedence, and
    `test/calendar.test.ts` plus `CalendarProjectionTests.swift` add the
    two-session truth table so parity stays byte-for-byte.
  - MCP: `get_today_workout` and `get_session_log` return every session for
    the date, and `get_current_session` returns every in-progress session
    (its `getInProgressSession` query is `LIMIT 1` today) with an optional
    `slot` selector, so Claude can see both active workouts and their sets; `log_set`, `log_workout_complete`, `set_planned_session`, and
    `skip_planned_session` accept an optional `slot` (default 0) and, for
    `log_set`, resolve an omitted slot to the single in-progress session
    when exactly one exists, otherwise to slot 0. The coach brief names
    additional sessions explicitly.
  - iOS: Today lists the date's sessions in slot order with one runner per
    session and an "Add another workout" action (library picker or
    freestyle) that allocates the next slot. The calendar cell shows the
    coarse status with a count badge when more than one session exists; the
    agenda lists each. `WorkoutRecoveryStore` keys its checkpoint by
    `(date, slot)`.
  - Retire the one-session-per-date assumption systematically rather than
    helper by helper. Acceptance for this phase is an audit with zero
    unreviewed hits, recorded in the plan: backend, every
    `WHERE user_id = ?1 AND date = ?2` and every `LIMIT 1` over `sessions`
    in `src/db.ts` (`getSessionByDate`, `getOwnedSessionByDate`,
    `getInProgressSession`, `getLastCompletedSession`, `getRecentSessions`,
    the calendar `byDate` map, group feed and stats, `exportUserData`,
    account deletion, and the sync delta) plus their nineteen call sites in
    the routes and MCP tools; iOS, every `sessionsByDate`, `sessionByDate`,
    `todaySession`, and `.date ==` session comparison in `SyncModel.swift`
    (forty-seven references today), the outboxes, recovery store, and
    projection. Each hit is classified as slot-0-only, all-slots, or
    session-id, and the classification is what the tests assert.
  - Every local session merge becomes session-scoped.
    `SyncModel.mergingSetAcknowledgement`, `mergingTerminalAcknowledgement`,
    `mergingSessionResolution`, `applyTerminalAcknowledgementLocally`, and
    `adoptSessionAliasLocally` today collect every cached session on the
    acknowledged date, drop them all, and re-point their sets at the
    acknowledged session id; with two sessions on a date that collapses the
    other workout and misattributes its sets, and creating slot 1 goes
    through the resolution path, so it would erase slot 0 locally. Match on
    session id (or `(date, slot)` when the server reassigns an id), leave
    sibling slots untouched, audit `SyncModel` for any other same-date
    collection before closing the phase, and cover additional-session
    creation plus the two-session case in `SetOutboxTests` and
    `WorkoutTerminalOutboxTests`.
  - The durable write machinery is also date-scoped today and must move to
    session scope in the same slice: `WorkoutTerminalOutbox` allows one
    intent per date, `SetOutboxStore.remove(date:)` drops every same-date
    set, and `supersedeSetIntentsForDiscardBarriers` treats a discard as a
    date-wide barrier. With two sessions on a date, finishing or discarding
    one would suppress the sibling's terminal action or delete its queued
    sets. Intent envelopes, discard barriers, drain predicates, and
    reconciliation all key on session id (or `(date, slot)`), and the
    two-session tests above cover finish and discard of one slot while the
    other has queued sets.
  - Group feed and stats: each session is one feed item; the daily
    consistency count still counts a date once.
  - Sync: `/api/state` session deltas already carry whole rows, so `slot`
    rides along; `data-storage-scalability` incremental sync must include it
    in its cursor shape if that lands first.

## Execution frontier

- P0

## Dependencies

| Local phase | Relationship | Target | Reason |
|---|---|---|---|
| P0 | coordinates_with | plan:workout-library#P1 | Both add or rename columns on the same table; whichever lands second rebases onto the other's migration and serializer. |
| P0 | coordinates_with | plan:reversible-plan-management#P0 | Snapshot serialization must use one set of names; agree on `workouts`/`workout_id` before either ships. |
| P1 | blocked_by | plan:workouts-and-multi-session#P0 | Slot-aware routes and the cell `sessions[]` array should be born with the new names rather than renamed a release later. |
| P1 | coordinates_with | plan:gym-runner-depth#P0 | Both change the Today runner surface; share the slice, do not fork the runner. |
| P1 | coordinates_with | plan:data-storage-scalability#P0 | The `(user_id, date, slot)` index replaces the one incremental sync and the hot-path index work rely on. |
| P1 | feeds | plan:workout-library#P2 | A freestyle session is the most common second session of a day; P2 should allocate a slot rather than fail on the primary. |

## Next step

**Now (@owner):** Confirm the wire-compatibility window for P0 (one
TestFlight cycle with dual keys) and accept the three-release
expand-contract rollout for the rename. P1 waits on P0 and on a member who actually needs two strength
sessions in a day; keep it planned until then.

## Notes / open questions

- Source: owner request (2026-09-05) following the workout-library plan,
  which recorded both items as constraints it did not address.
- Shared rule, released-client compatibility (applies to this plan,
  `workout-library`, and `supersets-and-circuits`): a new field or new
  meaning on an object the released app already decodes must define what a
  client that does not understand it receives. Clients declare
  capabilities in one request header, `X-TresFort-Capabilities`, a
  comma-separated list (`slots`, `groups`, `freestyle`, `archive`),
  alongside the existing `X-TresFort-Write-Protocol`; `readCapabilities`
  parses it next to `readAttemptProtocolHeader`. Each plan lists, per new
  field, the view a non-declaring client gets. The server never trusts a
  declaring client less than a non-declaring one; the header only widens
  what is returned.
- Shared rule, schema changes under `npm run release` (migration first,
  deploy second): an additive nullable column with a default is safe in one
  release; anything the deployed Worker names in SQL (an index used as a
  conflict target, a table or column rename, a dropped column) needs
  expand-contract with a compatibility Worker deployed first. In these
  plans: `tags`, `archived_at`, `sessions.kind`, `sessions.slot`, and the
  three group columns are additive; the `(user_id, date)` index swap and the
  `workouts` rename are expand-contract and are written up as such above.
- Shared rule, creation under retries: every operation that creates a row
  takes a client-generated id as its idempotency key, matching `set_logs`
  and `sessions`. In these plans that is the additional-session id, the
  workout id in save-as-workout, and the group id in `setGroup`.
- Rejected for P0: a compatibility `VIEW day_templates` over `workouts`.
  Views do not accept the old Worker's writes, so it cannot close the
  release window. The schema-adaptive Worker in release A is the
  expand-contract equivalent for SQLite.
- Rejected for P1: a separate `session_groups` or "training day" table.
  Sessions already carry `date`; an ordinal column is the smallest change
  that preserves every existing single-session guarantee for slot 0.
- Rejected for P1: making `date` plus a start time the key. Civil date is
  the client-owned boundary and the attempt CAS depends on a stable key;
  a time-based key would move on edits.
- Open: whether the weekly schedule should ever map one weekday to two
  workouts (AM/PM split). The `plans.meta.schedule` contract stores one id
  per weekday. Out of scope here; a member who trains twice on Mondays
  schedules the first and adds the second from the library. Revisit only if
  members ask.
- Open: the group feed's "streak" and daily-count semantics count dates,
  not sessions, so two sessions in one day do not double a streak. Confirm
  that is the desired reading before P1 ships.
