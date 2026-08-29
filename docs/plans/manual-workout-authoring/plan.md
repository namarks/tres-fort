# Manual Workout Authoring

Slug: manual-workout-authoring · Status: planned · Updated: 2026-08-28 · Theme: gym-floor

## Goal

Let a member create, schedule, and edit strength workouts entirely in iOS,
without asking an AI. Manual and AI changes operate on the same active
`plans` / `day_templates` / `template_exercises` tree and recurring schedule,
so a workout built by the member is immediately runnable in Today and readable
or editable by the coach.

## Phases

- [ ] **P0 — Build and schedule one workout without AI**
  - From the no-plan state, let the member create an active plan and one day,
    select catalog exercises, set targets, and add, edit, remove, or reorder
    slots using the existing plan services and editor endpoints.
  - Add a thin authenticated schedule-write path for iOS over the existing
    versioned `plans.meta.schedule` service, then let the member assign the day
    to a recurring weekday or leave it unscheduled.
  - Reload through `/api/state` and verify that assigning the day to the current
    weekday makes it appear in Today and runnable. An unscheduled day remains
    available in the routine but does not appear in Today by itself.
  - Prove the same workout is readable through MCP and subsequently editable by
    either iOS or Claude.
  - Record iOS as the actor in the same audit trail used by other plan writes.
- [ ] **P1 — Manage a recurring routine**
  - Create, rename, reorder, and remove multiple workout days; edit existing
    exercise targets; and map each weekday to a day or rest from one compact
    routine screen.
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

## Dependencies

| Local phase | Relationship | Target | Reason |
|---|---|---|---|
| P0 | coordinates_with | plan:server-mutation-integrity#P1 | Both use the same plan-version and write-validation boundary; manual authoring is not blocked on unrelated hardening. |

## Next step

**Now (@owner):** Activate P0 to ship the narrow create-to-Today path; do not
wait for one-off overrides or a starter-plan policy decision.

## Notes / open questions

- Tres Fort already supports creating plans and days through REST and editing
  day exercise slots in iOS. P0 completes the missing no-plan, target-edit, and
  recurring-schedule experience instead of replacing those paths.
- There is no manual-mode schema, weeks table, duplicate calendar projection,
  or client-only workout store. The existing versioned plan tree remains the
  source of truth for both the member and Claude.
- Custom exercises, workout marketplaces, template libraries, and arbitrary
  per-session workout copies are out of scope. P2 reuses existing one-date
  overrides only after the recurring workflow works.
- Whether Tres Fort also offers a default starter plan belongs to
  `member-activation-and-adherence#P2`; it cannot gate manual creation.
