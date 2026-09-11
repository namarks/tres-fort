# Workout Library

Slug: workout-library · Status: active · Updated: 2026-09-10 · Theme: gym-floor

## Goal

Let a member keep a library of reusable workouts that exist independently of
any weekly routine, drop one onto any date (today or future) in one gesture,
and run a genuinely unplanned session when life or travel breaks the pattern.
The recurring weekly schedule becomes one optional way to use the library, not
the frame every workout must fit into.

## Library model

The shared versioned plan tree supplies the library. The coordinated rename
changes its vocabulary without creating a second workout store:

- `workouts` are reusable workouts. Nothing about a row ties it to a
  weekday; `plans.meta.schedule` is a separate weekday → `workout_id`
  map, and a day with no schedule entry is already valid and runnable
  (manual-workout-authoring P0 verified "an unscheduled day remains available
  in the routine but does not appear in Today by itself").
- One-date assignment already exists: `PUT /api/calendar/{date}` /
  `set_planned_session` binds any day template to a concrete date without
  touching the schedule or the plan version. Today's rest-day "Start a
  workout" CTA and the "train a different day" override reuse the same path.
- `projectCalendar` already prefers a real session over the schedule, so a
  library workout dropped on a scheduled day simply wins for that date.

The original gaps were product framing and three capabilities it exposes:

1. **The UI named everything "Routine."** The prior `RoutineView` add flow says
   "adds a reusable workout to your routine", deletion says "recurring
   weekdays using this workout become rest days", and a workout with no
   weekday has no visible identity of its own. A member reads this as "every
   workout must be a routine day."
2. **No library metadata.** A member with a hotel workout, a 20-minute
   bodyweight session, and three gym days has no way to tag, group, or retire
   workouts. The only exit is delete, which is framed around the schedule.
3. **No true one-off session.** A session with `workout_id = NULL` today
   is not "freestyle": `deleteWorkout`'s scope predicate and the runner
   both resolve a null-template session through the weekly schedule. There is
   no way to walk into a gym, log whatever the equipment allows, and
   optionally save what you did as a new library workout.

The design stays on the versioned plan tree and the append-only session log.
No second editor, no per-session template copies, no weeks table.

## Phases

- [x] **P0 — Present the library as the primary object**
  - Rename the routine surface to **Workouts**. Each workout card shows its
    own identity plus a schedule badge ("Mon · Thu" or "On demand"). The
    schedule becomes a section of that screen, not its frame.
  - Split the destructive action: **Unschedule** clears weekday entries only
    (existing `PUT /api/plan/schedule`); **Delete workout** keeps the current
    `DELETE /api/workouts/{id}` semantics and copy. The add flow stops implying
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
- [x] **P0.1 — Today and Calendar navigation**
  - Owner-approved design: Today has a compact scheduled/completed workout
    card, explicit View workout, Start/Continue workout, Choose a workout,
    Create a workout, and Log an activity actions. Remove the duplicate
    top-right Workouts entry and the idle plus/overflow menus.
  - The library opens a named workout before starting or editing it. Editors
    name their exact saved workout and distinguish saved prescriptions from
    completed records. Plan changes lives in the library; Training overview
    lives in Profile's Coach section. Keep runner recovery, feedback, timers,
    terminal actions, and the full completed record reachable.
  - Rename History to Calendar, retain exercise progress, and make date
    assignment/replacement/removal explicit. Keep weekly scheduling separate;
    moving a workout must preserve both dates under concurrent writes.
  - Create-from-Today opens a named saved-workout creator and editor, explicitly
    described as a library write. The preview's one-off creation and optional
    saving require a separate product decision and P2 compatibility work; the
    implementation question remains open in the design task.
  - Verify synthetic iOS journeys for every new route, ambiguous/null workout
    identity, compact completion, date scope, and preservation of recorded sets.
  - Delivered a receipt-backed atomic move endpoint without a migration. Both
    date attempts advance together; concurrent changes reject the whole move.
    Date notes/fatigue, weekly scheduling, and completed records are preserved.
    Acknowledged writes retain success when refresh fails; creation recovers
    through a read-only refresh and failed finishes retain the discard path.
  - Local evidence: the iOS smoke suite completed 499 unit tests (one skipped)
    and 28 UI journeys without failures. Focused navigation journeys additionally
    cover removal without a saved-workout identity, unresolved real-session
    records, first-workout creation recovery, and both terminal recovery paths.
    All 70 backend test files passed; the final calendar/dual-schema subset
    passed 112 tests. Typecheck, plan graph and verification-script checks passed.
    Final independent local review found no actionable regressions.
- [ ] **P1 — Library metadata: tags and archive**
  - Reuse prescription-integrity's validated atomic writer contract for every
    new metadata mutation, including conflicts and audit. P0 presentation work
    remains independent of this backend prerequisite.
  - Add `workouts.tags` (JSON array of short strings such as `travel`,
    `quick`, `bodyweight`, `hotel`) and `workouts.archived_at`
    (nullable epoch-ms) in one migration. Both are plan-tree fields: every
    write goes through the existing atomic plan-version writer, bumps
    `plans.version`, and audits as the calling actor.
  - Archiving hides a workout from pickers and Today while preserving every
    completed or in-progress `sessions.workout_id` and
    `set_logs.template_exercise_id` reference. In the same write it clears
    the workout's weekday entries and resolves its future dated assignments
    the way `deleteWorkout` already does: a `planned` session pointing
    at the workout becomes explicit rest with its attempt advanced, because
    `projectCalendar` gives a real session precedence over the schedule and
    would otherwise keep showing the archived workout. Archiving is rejected
    while the workout has an in-progress session, matching delete.
  - Every assignment resolver rejects an archived workout, not only the
    updated pickers: `setPlanSchedule`, `setPlannedSession`,
    `getWorkoutInPlan` as used by `POST /api/sessions` and
    `PUT /api/calendar/{date}`, and the MCP day-ref lookup all treat
    `archived_at IS NOT NULL` as unknown. Otherwise an older iOS build that
    ignores the field, or any caller still holding the id, can reassign it
    and the resulting real session wins projection and restores it in
    Today. Add a test that each path returns the same not-found result for
    an archived id.
    `update_plan`'s rebuild must carry both fields through the day remap.
  - Expose both fields through `get_current_plan`, `add_day`, `update_day`,
    and `PATCH /api/workouts/{id}`; `/api/state` carries them in the plan tree.
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
    `'planned'`) so a freestyle session with `workout_id = NULL` never
    resolves through the weekly schedule. Update the scope predicate in
    `deleteWorkout`, the runner's template inference, and
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
    workout: one `add_day` call with member-reviewed slots derived from
    compatible exercise, execution-mode and external-load cohorts in
    first-logged order. `target_sets` is the cohort's working-set count.
    A timed cohort defaults duration to its median observed duration, rounded
    to a valid positive integer number of seconds and shown for review, with no
    rep target; a rep cohort defaults reps to its median observed reps, rounded
    to a valid integer and shown for review. Load comes from that same cohort,
    never the maximum from incompatible sets. Cardio follows the timed branch.
    Separate mixed cohorts into slots or require an explicit member target
    selection before saving; do not merge them by exercise identity alone.
    Warm-up sets are excluded from the derivation. The
    new workout is unscheduled and, on the same write, the session is
    re-pointed at it so history attaches to the library entry. The re-point
    is an assignment change, so the same write advances `sessions.attempt`
    under the existing rule that every changed workout choice advances the
    generation; a delayed set intent carrying the old attempt is rejected
    instead of landing on the saved workout's history. The client supplies
    the new workout's id, so a retry after a lost response returns the same
    workout and the already-advanced attempt instead of creating a second
    workout or bumping again. This is a plan-tree write and audits normally.
  - Before saving, show an editable derived prescription with its provenance.
    Do not silently combine median reps from one load/assistance condition with
    the highest weight from a different set and present that pair as performed
    or recommended. Mixed timed/rep, assistance/strict/added-load and variation
    cases must remain separate or require an explicit target selection. Pass
    the chosen prescription through the same runtime validator as other writes.
  - MCP: `log_set` on a date with no session creates a freestyle session
    when the date has no scheduled workout, instead of a null-template
    planned session, and the coach brief names it as such.

## Execution frontier

- P1

## Dependencies

[Completed Gym Runner Depth](../completed/gym-runner-depth/plan.md) supplies
the shared prescription controls, durable corrections and runner presentation.
Reuse that delivered path when changing the runner.

P1 metadata and P2 save-as-workout reuse the completed [validated atomic writer](../completed/prescription-integrity/decisions.md), including prescription creation and session reassignment. Extend [canonical snapshots](../completed/reversible-plan-management/decisions.md) to retain `tags` and `archived_at`.

| Local phase | Relationship | Target | Reason |
|---|---|---|---|
| P0 | blocked_by | plan:workouts-and-multi-session#P0(a) | The selected goal establishes canonical workout terminology and compatible clients before the library UI. Production rollout and compatibility cleanup do not block this repository slice. |
| P0 | coordinates_with | plan:member-activation-and-adherence#P0 | Both edit the no-plan and Today entry surfaces; do not run concurrently on the same iOS files. |
| P1 | coordinates_with | plan:workouts-and-multi-session#P0 | Both touch `workouts` columns and serializers; whichever lands second rebases onto the other's migration. |


Freestyle sessions and save-as-workout will supply more logged evidence to the
[completed coaching context](../completed/coaching-feedback-loop/plan.md).

## Next step

**Now (@agent):** P1 library metadata remains planned and outside the completed
P0.1 navigation update. P2 freestyle creation and optional saving remain separate;
the implemented Create a workout action explicitly saves to the shared library.
The navigation design was approved in task
`01a08dee-930f-7763-9202-29872c440f26`. Exact-head independent review and required
CI gate repository integration. Deploy the compatible calendar-move Worker
before distributing this client; deployment and TestFlight distribution remain
separate owner actions. This repository change does not perform either release.

**Client rollout (@owner):** Complete the deferred legacy-route REST checks during the
separately authorized client rollout before distributing the first compatible
Workouts TestFlight build. Library P0 is merged and verified in
[PR #161](https://github.com/namarks/tres-fort/pull/161). The Workouts surface
includes schedule badges, separate Unschedule and Delete workout actions,
and a today-or-future date picker using the shared
assignment guard and attempt-CAS writer. The first build keeps released outgoing
request shapes and can ship during the rename's compatibility window after
separate TestFlight authorization. The compatibility Worker and migration 0045
are now released. The
[canonical rollout status](../workouts-and-multi-session/plan.md#next-step) records
the production evidence and the owner-approved deferral of live REST authoring,
date-assignment and session-write checks to the client rollout. Canonical-route
checks must pass before the later canonical-writing build is distributed.
Follow the [staged rollout](../workouts-and-multi-session/rollout.md).

Local/CI validation: [PR #161 CI](https://github.com/namarks/tres-fort/actions/runs/34371920505)
passed 404 iOS unit tests and 23 UI journeys; the full backend
suite passed 897 tests, including both physical schemas and old/new wire
contracts.
Those tests verified that Unschedule retains the workout and dated session while clearing its recurring
entries. The library-date assignment appears in Today and the coach's current
workout response without changing the recurring plan. Tags/archive (P1),
freestyle (P2), and multiple sessions per date remain unimplemented and outside
the completed goal's scope.

## Notes / open questions

- Source: owner observation (2026-09-05) that everything in the app is framed
  around the routine or block day, which is too rigid for travel and ad-hoc
  adjustment. The backend already treats days as reusable and the schedule as
  optional; the gap is presentation plus tags, archive, and freestyle.
- Rejected: a second workout table beside the old `day_templates` store. It would fork
  the versioned tree, force every editor and MCP tool to handle two shapes,
  and break `set_logs.template_exercise_id` history for one of them.
  The renamed `workouts` table is the same library.
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
  within: `day_templates` was the historical name for a reusable workout,
  and `ux_session_user_date` (migration `0029`) forbids two strength sessions
  on one civil date. Both are addressed by
  [Workouts and multi-session days](../workouts-and-multi-session/plan.md);
  The coordinated P0 delivery uses canonical workout terms while retaining
  the released aliases for the server-first rollout and compatibility cycle.
- `sessions.kind` is the one new session-log column. It is set at creation
  and never changes, so it does not disturb the attempt CAS or the
  `(user_id, date)` uniqueness rule.
