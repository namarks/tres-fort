# Workout Library

Slug: workout-library · Status: planned · Updated: 2026-09-05 · Theme: gym-floor

## Goal

Let a member keep a library of reusable workouts that exist independently of
any weekly routine, drop one onto any date (today or future) in one gesture,
and run a genuinely unplanned session when life or travel breaks the pattern.
The recurring weekly schedule becomes one optional way to use the library, not
the frame every workout must fit into.

## Why this is a framing change, not a new data model

The backend already stores what a library needs:

- `day_templates` are reusable workouts. Nothing about a row ties it to a
  weekday; `plans.meta.schedule` is a separate weekday → `day_template_id`
  map, and a day with no schedule entry is already valid and runnable
  (manual-workout-authoring P0 verified "an unscheduled day remains available
  in the routine but does not appear in Today by itself").
- One-date assignment already exists: `PUT /api/calendar/{date}` /
  `set_planned_session` binds any day template to a concrete date without
  touching the schedule or the plan version. Today's rest-day "Start a
  workout" CTA and the "train a different day" override reuse the same path.
- `projectCalendar` already prefers a real session over the schedule, so a
  library workout dropped on a scheduled day simply wins for that date.

What is missing is the product framing and three capabilities the framing
exposes:

1. **The UI names everything "Routine."** The `RoutineView` add flow says
   "adds a reusable workout to your routine", deletion says "recurring
   weekdays using this workout become rest days", and a workout with no
   weekday has no visible identity of its own. A member reads this as "every
   workout must be a routine day."
2. **No library metadata.** A member with a hotel workout, a 20-minute
   bodyweight session, and three gym days has no way to tag, group, or retire
   workouts. The only exit is delete, which is framed around the schedule.
3. **No true one-off session.** A session with `day_template_id = NULL` today
   is not "freestyle": `deleteDayTemplate`'s scope predicate and the runner
   both resolve a null-template session through the weekly schedule. There is
   no way to walk into a gym, log whatever the equipment allows, and
   optionally save what you did as a new library workout.

The design stays on the versioned plan tree and the append-only session log.
No second editor, no per-session template copies, no weeks table.

## Phases

- [ ] **P0 — Present the library as the primary object**
  - Rename the routine surface to **Workouts**. Each workout card shows its
    own identity plus a schedule badge ("Mon · Thu" or "On demand"). The
    schedule becomes a section of that screen, not its frame.
  - Split the destructive action: **Unschedule** clears weekday entries only
    (existing `PUT /api/plan/schedule`); **Delete workout** keeps the current
    `DELETE /api/days/{id}` semantics and copy. The add flow stops implying
    that a new workout must be scheduled.
  - Make "put this workout on a date" a first-class calendar gesture for any
    today-or-future date that is not inside a `can_train_light=false` trip,
    reusing the existing `PUT /api/calendar/{date}` attempt-CAS path and the
    agenda picker. Hard-blackout dates keep their current behavior: the iOS
    guard rejects the assignment and the projection suppresses a planned
    session there. Lifting that is a projection-parity change and is out of
    P0. Verify a library workout dropped on a scheduled weekday shows as that
    date's workout in Today, the calendar, and `get_today_workout`, and that
    the recurring schedule is unchanged.
  - No schema or Worker change. Update `docs/DESIGN.md` §4 and §9 wording so
    "day template" is described as a library workout that the schedule may
    reference.
- [ ] **P1 — Library metadata: tags and archive**
  - Add `day_templates.tags` (JSON array of short strings such as `travel`,
    `quick`, `bodyweight`, `hotel`) and `day_templates.archived_at`
    (nullable epoch-ms) in one migration. Both are plan-tree fields: every
    write goes through the existing atomic plan-version writer, bumps
    `plans.version`, and audits as the calling actor.
  - Archiving hides a workout from pickers and Today while preserving every
    completed or in-progress `sessions.day_template_id` and
    `set_logs.template_exercise_id` reference. In the same write it clears
    the workout's weekday entries and resolves its future dated assignments
    the way `deleteDayTemplate` already does: a `planned` session pointing
    at the workout becomes explicit rest with its attempt advanced, because
    `projectCalendar` gives a real session precedence over the schedule and
    would otherwise keep showing the archived workout. Archiving is rejected
    while the workout has an in-progress session, matching delete.
  - Every assignment resolver rejects an archived workout, not only the
    updated pickers: `setPlanSchedule`, `setPlannedSession`,
    `getDayTemplateInPlan` as used by `POST /api/sessions` and
    `PUT /api/calendar/{date}`, and the MCP day-ref lookup all treat
    `archived_at IS NOT NULL` as unknown. Otherwise an older iOS build that
    ignores the field, or any caller still holding the id, can reassign it
    and the resulting real session wins projection and restores it in
    Today. Add a test that each path returns the same not-found result for
    an archived id.
    `update_plan`'s rebuild must carry both fields through the day remap.
  - Expose both fields through `get_current_plan`, `add_day`, `update_day`,
    and `PATCH /api/days/{id}`; `/api/state` carries them in the plan tree.
  - When a date falls inside a `plans.meta.trips` range, the calendar and
    Today pickers surface `travel`-tagged workouts first. This is ordering,
    not a rule engine.
  - Released-client compatibility (shared rule in
    `workouts-and-multi-session`): archived workouts stay in the plan tree
    for every client so completed history still renders its workout name;
    a client without the `archive` capability simply sees them in its
    pickers, and the resolver rule above turns any attempt to assign one
    into `unknown_day`, which the released app already handles as a
    permanent client error.
  - Extend `test/calendar.test.ts` so an archived workout referenced by the
    schedule projects as rest on both backend and iOS
    (`CalendarProjection.swift` already treats a dangling id as rest; make
    the archived case explicit and keep the two in parity).
- [ ] **P2 — Freestyle session and "save as workout"**
  - Add an explicit `sessions.kind` (`'planned' | 'freestyle'`, default
    `'planned'`) so a freestyle session with `day_template_id = NULL` never
    resolves through the weekly schedule. Update the scope predicate in
    `deleteDayTemplate`, the runner's template inference, and
    `projectCalendar` (a freestyle session is a real session and wins for its
    date; it renders with its logged exercises rather than a template name).
    Released-client compatibility: the current runner infers a template from
    the schedule for any null-template session, so a client without the
    `freestyle` capability receives freestyle sessions only once they are
    completed (as history with their sets) and never as Today's session;
    an in-progress freestyle session is invisible to it. Per the shared
    rule, invisible means fenced: while a date holds a live (`planned` or
    `in_progress`) freestyle session, `POST /api/sessions`,
    `PUT /api/calendar/{date}`, `PATCH /api/sessions/{id}` status changes,
    and the MCP session-by-date resolvers return `session_kind_conflict`
    (409) to a non-`freestyle` client rather than reusing the null-template
    row and pinning it to a workout, which the current date-scoped
    `getOrCreateSession` would otherwise do.
  - The runner starts a freestyle session from the rest-day CTA and from the
    calendar for today. Exercises are added from the catalog as you go; the
    prescription shown is the member's last comparable actuals for that
    exercise (existing history query), not a stored target. Sets log through
    the same idempotent `POST /api/sessions/{id}/sets` with
    `template_exercise_id = NULL`.
  - **Save as workout** converts a completed freestyle session into a library
    workout: one `add_day` call with slots derived from the logged sets
    (distinct exercises in first-logged order, `target_sets` = working sets
    logged). Derivation branches on the logged shape: sets with `is_timed`
    produce a timed slot with `target_duration_s` = median `duration_s` and
    no rep target; rep sets produce `target_reps` = median reps and
    `target_weight` = top working weight; a cardio-modality exercise follows
    the timed branch. Warm-up sets are excluded from the derivation. The
    new workout is unscheduled and, on the same write, the session is
    re-pointed at it so history attaches to the library entry. The client
    supplies the new workout's id, so a retry after a lost response returns
    the same workout instead of creating a second one. This is a plan-tree
    write and audits normally.
  - MCP: `log_set` on a date with no session creates a freestyle session
    when the date has no scheduled workout, instead of a null-template
    planned session, and the coach brief names it as such.

## Execution frontier

- P0

## Dependencies

| Local phase | Relationship | Target | Reason |
|---|---|---|---|
| P0 | coordinates_with | plan:member-activation-and-adherence#P0 | Both edit the no-plan and Today entry surfaces; do not run concurrently on the same iOS files. |
| P1 | coordinates_with | plan:reversible-plan-management#P0 | Snapshots must serialize `tags` and `archived_at`; land whichever ships second against the other's serializer. |
| P1 | coordinates_with | plan:workouts-and-multi-session#P0 | Both touch `day_templates` columns and serializers; whichever lands second rebases onto the other's migration. |
| P2 | coordinates_with | plan:gym-runner-depth#P0 | Both change the runner's exercise list and value entry; share the runner slice rather than fork it. |
| P2 | feeds | plan:coaching-feedback-loop | Freestyle sessions and save-as-workout give the coach evidence of what a member actually does when the plan breaks. |

## Next step

**Now (@owner):** Decide whether P0 enters the backlog ahead of
`gym-runner-depth#P0`. P0 is iOS copy, navigation, and one calendar gesture
over existing endpoints; it can ship in one slice with no migration.

## Notes / open questions

- Source: owner observation (2026-09-05) that everything in the app is framed
  around the routine or block day, which is too rigid for travel and ad-hoc
  adjustment. The backend already treats days as reusable and the schedule as
  optional; the gap is presentation plus tags, archive, and freestyle.
- Rejected: a separate `workouts` table beside `day_templates`. It would fork
  the versioned tree, force every editor and MCP tool to handle two shapes,
  and break `set_logs.template_exercise_id` history for one of them.
  `day_templates` is the library.
- Rejected: per-session copies of a template for one-off edits. Editing
  today's slot in `EditWorkoutSheet` already edits the library workout, which
  is the right default for a coach-owned plan; a member who wants a
  variation adds a second library workout. Freestyle (P2) covers the
  genuinely unplanned case without a copy.
- Open: whether `archived_at` should also apply to `template_exercises`
  (retire a slot without detaching history). Defer until a member asks;
  delete-with-detach exists today.
- Open: freestyle sessions and group feeds. A freestyle session has no
  template name for `get_group_feed`; show "Freestyle · N exercises" and
  revisit with `group-experience-and-governance`.
- Naming and one-session-per-date are both real constraints this plan works
  within: `day_templates` is a historical name for what is really a workout,
  and `ux_session_user_date` (migration `0029`) forbids two strength sessions
  on one civil date. Both are addressed by
  [Workouts and multi-session days](../workouts-and-multi-session/plan.md);
  P0 here uses "workout" in every member- and coach-facing string but keeps
  the storage and API names until that plan's rename lands.
- `sessions.kind` is the one new session-log column. It is set at creation
  and never changes, so it does not disturb the attempt CAS or the
  `(user_id, date)` uniqueness rule.
