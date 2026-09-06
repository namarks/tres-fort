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
  - Release: `npm run release` runs the migration before the deploy, so the
    old Worker serves renamed tables for the seconds between the two steps
    and every plan read 500s in that window. Ship this as one off-peak
    release with the down-migration (reverse renames) checked in beside the
    forward one, and verify the local sequence
    `db:migrate:local` → `dev` → smoke before running it remotely.
- [ ] **P1 — Ordered sessions per date**
  - Migration: add `sessions.slot INTEGER NOT NULL DEFAULT 0`; drop
    `ux_session_user_date`; create `UNIQUE (user_id, date, slot)`. Every
    existing row is slot 0. Slot 0 is the **primary** session and keeps
    every current rule unchanged: the attempt CAS, discard revival, the
    `legacy`/`attempt-v1` write protocol, the `0032` trigger (per row, so it
    needs no change), and the `(user, date)` recovery checkpoint.
  - Service layer: every `(user_id, date)` session lookup in `src/db.ts`
    (about eleven) takes an explicit slot and defaults to 0, so existing
    callers and released clients see no behavior change. `getOrCreateSession`
    gains a `nextSlot` mode that inserts at `MAX(slot)+1` for the date;
    slots are assigned once and never reused. A slot above 0 can be
    discarded or skipped like the primary; there is no rule that slot 1
    requires slot 0 to be complete.
  - REST: `POST /api/sessions` accepts `slot` (an exact retry) or
    `additional: true` (allocate the next slot); `PUT /api/calendar/{date}`
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
    the date; `log_set`, `log_workout_complete`, `set_planned_session`, and
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
  - iOS acknowledgement merges become session-scoped.
    `SyncModel.mergingSetAcknowledgement` and
    `mergingTerminalAcknowledgement` today collect every cached session on
    the acknowledged date, drop them all, and re-point their sets at the
    acknowledged session id; with two sessions on a date that collapses the
    other workout and misattributes its sets. Match on session id (or
    `(date, slot)` when the server reassigns an id), leave sibling slots
    untouched, and cover the two-session case in `SetOutboxTests` and
    `WorkoutTerminalOutboxTests`.
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
TestFlight cycle with dual keys) and schedule the rename as an off-peak
release. P1 waits on P0 and on a member who actually needs two strength
sessions in a day; keep it planned until then.

## Notes / open questions

- Source: owner request (2026-09-05) following the workout-library plan,
  which recorded both items as constraints it did not address.
- Rejected for P0: a compatibility `VIEW day_templates` over `workouts`.
  Views do not accept the old Worker's writes, so it would not close the
  release window; the window is seconds and a tested down-migration is the
  cheaper safeguard.
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
