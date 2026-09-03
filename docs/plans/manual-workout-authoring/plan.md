# Manual Workout Authoring

Slug: manual-workout-authoring · Status: planned · Updated: 2026-09-02 · Theme: gym-floor

## Goal

Let a member create, schedule, and edit strength workouts entirely in iOS,
without asking an AI. Manual and AI changes operate on the same active
`plans` / `day_templates` / `template_exercises` tree and recurring schedule,
so a workout built by the member is immediately runnable in Today and readable
or editable by the coach.

## Phases

- [ ] **P0 — Build and schedule one workout without AI**
  - From the no-plan state, create an active plan only when none exists, then
    let the member add one day, select catalog exercises, set targets, and add,
    edit, remove, or reorder slots using the existing plan services and editor
    endpoints.
  - If a retry, stale screen, or concurrent Claude setup finds that an active
    plan now exists, return or reload that current plan and version. Never
    archive or replace it implicitly; replacement remains a separate explicit
    action. The existing `POST /api/plan` route calls `createPlan`, which
    archives any active plan unconditionally, so iOS must not use it as the
    create path: add an ensure-active-plan service call that returns the
    existing plan and version when one exists, and keep archive-and-replace as
    its own explicit endpoint.
  - Append new days densely. `POST /api/days` defaults `order_index` to 0, so
    every day the app adds would collide at the top; use the same next-index
    rule the MCP `add_day` tool already uses.
  - Add a thin authenticated schedule-write path for iOS over the existing
    versioned `plans.meta.schedule` service, then let the member assign the day
    to a recurring weekday or leave it unscheduled.
  - Reload through `/api/state` and verify that assigning the day to the current
    weekday makes it appear in Today and runnable. An unscheduled day remains
    available in the routine but does not appear in Today by itself.
  - Prove the same workout is readable through MCP and subsequently editable by
    either iOS or Claude.
  - Record iOS as the actor in the same audit trail used by other plan writes.
    Today only the slot routes write an `actor='ios'` audit row; day create
    and day patch write none, so those routes need the same call before P0's
    trail is complete.
  - Verify with a bodyweight-only routine as a second acceptance walkthrough
    (for example pull-ups 3×5–8, push-ups 3×12, plank 3×45 s on three
    weekdays) in addition to a loaded barbell day. It exercises rep ranges,
    timed holds, and zero-load logging that a barbell walkthrough never
    touches, and it needs only the existing catalog.
- [ ] **P1 — Manage a recurring routine**
  - Create, rename, reorder, and remove multiple workout days; edit existing
    exercise targets; and map each weekday to a day or rest from one compact
    routine screen.
  - Edit sets, reps, rep range (`target_reps_max`), rest, and hold seconds on
    an existing slot from the editor. Today iOS calls the slot PATCH route
    only to reorder, and the configure screen has no rep-range field.
  - [ ] **(a) Day removal detaches history**
    - Before exposing day removal, make `deleteDayTemplate` null out
      `sessions.day_template_id` and `set_logs.template_exercise_id` in the
      same batch as its deletes, matching what delete-exercise and the
      full-tree rebuild already do. The current function deletes without
      detaching and, under D1's strict foreign keys, fails on any day that has
      ever been trained; the only test deletes a never-run day. Add a test
      that removes a day with a completed session.
  - State clearly that day and schedule edits recur, preserve historical logs,
    and refresh on a version conflict instead of silently replacing a newer
    coach or member edit.
  - Cover the shared version, schedule-remap, and calendar-projection contracts
    with focused backend and iOS tests rather than a second planning engine.
- [ ] **P2 — Add optional date-specific exceptions**
  - From the calendar, assign an existing day template or rest to one concrete
    date using the existing planned-session and skip semantics.
  - Keep the recurring schedule unchanged and keep these rows outside the plan
    version; a one-off exception is not a copied workout or a hidden week plan.

## Next step

**Now (@owner):** Activate P0 to ship the narrow create-to-Today path; do not
wait for one-off overrides or a starter-plan policy decision.

## Notes / open questions

- Tres Fort already supports creating plans and days through REST and editing
  day exercise slots in iOS. P0 completes the missing no-plan, target-edit, and
  recurring-schedule experience instead of replacing those paths.
- Manual authoring reuses the plan-version and write-validation boundary
  completed in [Server Mutation Integrity](../completed/server-mutation-integrity/plan.md);
  no unresolved dependency remains.
- There is no manual-mode schema, weeks table, duplicate calendar projection,
  or client-only workout store. The existing versioned plan tree remains the
  source of truth for both the member and Claude.
- Custom exercises, workout marketplaces, template libraries, and arbitrary
  per-session workout copies are out of scope. P2 reuses existing one-date
  overrides only after the recurring workflow works.
- Whether Tres Fort also offers a default starter plan belongs to
  `member-activation-and-adherence#P2`; it cannot gate manual creation.
- The bodyweight walkthrough depends only on the existing catalog. Added load,
  assistance, rep-based history, and the missing gymnastic movements belong to
  [Bodyweight training support](../bodyweight-training-support/plan.md), not
  to this plan.
