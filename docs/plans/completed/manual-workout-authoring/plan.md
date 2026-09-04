# Manual Workout Authoring

Slug: manual-workout-authoring · Status: done · Archived: completed · Updated: 2026-09-04 · Theme: gym-floor

## Goal

Let a member create, schedule, and edit strength workouts entirely in iOS,
without asking an AI. Manual and AI changes operate on the same active
`plans` / `day_templates` / `template_exercises` tree and recurring schedule,
so a workout built by the member is immediately runnable in Today and readable
or editable by the coach.

## Phases

- [x] **P0 — Build and schedule one workout without AI**
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
    Among plan-tree writes, today only the slot routes write an `actor='ios'`
    audit row; day create and day patch write none, so those routes need the
    same call before P0's trail is complete.
  - Verify with a bodyweight-only routine as a second acceptance walkthrough
    (for example pull-ups 3×5, push-ups 3×12, plank 3×45 s on three
    weekdays) in addition to a loaded barbell day. It exercises timed holds
    and zero-load logging that a barbell walkthrough never touches, and it
    needs only the existing catalog and editor. Rep ranges are not
    prescribable from iOS until `bodyweight-training-support#P0` lands, so
    the P0 walkthrough does not use one.
- [x] **P1 — Manage a recurring routine**
  - Create, rename, reorder, and remove multiple workout days; edit existing
    exercise targets; and map each weekday to a day or rest from one compact
    routine screen.
  - Edit sets, reps, rep range (`target_reps_max`), rest, and hold seconds on
    an existing slot from the editor. Today iOS calls the slot PATCH route
    only to reorder, and the configure screen has no rep-range field.
  - [x] **(a) Day removal detaches history**
    - Before exposing day removal, make `deleteDayTemplate` null out
      `sessions.day_template_id` and `set_logs.template_exercise_id` in the
      same batch as its deletes: detach set logs the way delete-exercise
      already does, and detach sessions the way the full-tree rebuild already
      does. The current function deletes without
      detaching and, under D1's strict foreign keys, fails on any day that has
      ever been trained; the only test deletes a never-run day. Add a test
      that removes a day with a completed session.
  - State clearly that day and schedule edits recur, preserve historical logs,
    and refresh on a version conflict instead of silently replacing a newer
    coach or member edit.
  - Cover the shared version, schedule-remap, and calendar-projection contracts
    with focused backend and iOS tests rather than a second planning engine.
- [x] **P2 — Add optional date-specific exceptions**
  - From the calendar, assign an existing day template or rest to one concrete
    date using the existing planned-session and skip semantics.
  - Keep the recurring schedule unchanged and keep these rows outside the plan
    version; a one-off exception is not a copied workout or a hidden week plan.

## Next step

No further executable step. Manual creation, recurring routine management, and
date-specific exceptions are complete in the shared plan model; deployment and
TestFlight distribution remain separate release actions and were not performed.

## Notes / open questions

- Completion evidence (2026-09-04): iOS now creates or returns the one active
  plan without replacing it, provides a compact routine editor for workout
  days, catalog slots, targets, and the weekly schedule, and exposes one-date
  workout/rest exceptions in the calendar. Worker routes reuse the existing
  plan, schedule, and planned-session services, record `actor='ios'`, reload on
  version conflicts, and preserve session/set history when a day is removed.
  Planned overrides become explicit rest when their day is removed; an
  in-progress day cannot be removed, including when a null-template session
  resolves through the recurring schedule, and a started date cannot be retagged.
  First-day creation is pinned to the exact plan identity/version returned by
  the ensure call, explicit replacement is atomic with creation, and schedule
  writes bind both identity and version. Target-save and conflict-refresh
  failures stay visible, including in the calendar agenda, while overlapping
  routine edits serialize. The calendar fence also covers a locally running or
  recovered workout before its first set reaches the server; the same fence
  protects its workout day from deletion. Archived-plan sessions do not affect
  current-plan deletion, unrelated plan reloads preserve an unsaved weekly schedule draft,
  stale day identities refresh even when the replacement reused a version, and
  valid high-rep prescriptions remain editable without an invalid Swift range.
  App and MCP day creation/patching now share one atomic plan-version writer,
  and concurrent no-plan bootstrap keeps one stable winning plan identity.
  One-date workout/rest choices use attempt zero as the no-row CAS token; the
  first assignment and every changed choice advance the token, while an
  identical retry remains idempotent, so a stale screen or queued set cannot
  cross into a replacement assignment; a nonzero token cannot create a row
  when no assignment exists. Removing a planned workout day also
  advances that date token, and workout/rest insert and update statements prove
  the captured plan identity and version are still active at commit time, so a
  concurrent plan replacement cannot bind a date to archived plan state.
  History detachment advances the session sync cursor so incremental clients
  do not retain a removed day identifier. Hard
  travel blackouts suppress the date
  editor and model write, target sheets stay open when post-write state refresh
  fails, and overlapping routine mutations suspend behind the active request
  without spinning on the main actor.
  The route-level acceptance test covers loaded barbell work plus a pull-up,
  push-up, and timed-plank routine from REST writes through Today projection
  and MCP read/edit. Verification passed TypeScript typecheck, all 515 Worker
  tests, iOS build-for-testing, and all 242 iOS tests.

- Tres Fort already supports creating plans and days through REST and editing
  day exercise slots in iOS. P0 completes the missing no-plan, target-edit, and
  recurring-schedule experience instead of replacing those paths.
- Manual authoring reuses the plan-version and write-validation boundary
  completed in [Server Mutation Integrity](../server-mutation-integrity/plan.md);
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
  [Bodyweight training support](../../bodyweight-training-support/plan.md), not
  to this plan.
