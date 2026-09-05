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
    today-or-future date, reusing the existing `PUT /api/calendar/{date}`
    attempt-CAS path and the agenda picker. Verify a library workout dropped
    on a scheduled weekday shows as that date's workout in Today, the
    calendar, and `get_today_workout`, and that the recurring schedule is
    unchanged.
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
    `sessions.day_template_id` and `set_logs.template_exercise_id`
    reference. Archiving a scheduled workout clears its weekday entries in
    the same write (reuse the `deleteDayTemplate` schedule-scrub helper).
    `update_plan`'s rebuild must carry both fields through the day remap.
  - Expose both fields through `get_current_plan`, `add_day`, `update_day`,
    and `PATCH /api/days/{id}`; `/api/state` carries them in the plan tree.
  - When a date falls inside a `plans.meta.trips` range, the calendar and
    Today pickers surface `travel`-tagged workouts first. This is ordering,
    not a rule engine.
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
  - The runner starts a freestyle session from the rest-day CTA and from the
    calendar for today. Exercises are added from the catalog as you go; the
    prescription shown is the member's last comparable actuals for that
    exercise (existing history query), not a stored target. Sets log through
    the same idempotent `POST /api/sessions/{id}/sets` with
    `template_exercise_id = NULL`.
  - **Save as workout** converts a completed freestyle session into a library
    workout: one `add_day` call with slots derived from the logged sets
    (distinct exercises in first-logged order, `target_sets` = sets logged,
    `target_reps` = median reps, `target_weight` = top working weight). The
    new workout is unscheduled and, on the same write, the session is
    re-pointed at it so history attaches to the library entry. This is a
    plan-tree write and audits normally.
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
- `sessions.kind` is the one new session-log column. It is set at creation
  and never changes, so it does not disturb the attempt CAS or the
  `(user_id, date)` uniqueness rule.
