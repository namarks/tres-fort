# Plan without an AI coach

Slug: coach-free-planning · Status: active · Updated: 2026-11-01 · Theme: gym-floor

## Goal

Every change to the training plan that the coach can make through MCP can
also be made by the member in the iOS app, with no AI involved. The owner's
rule (2026-11-01): a feature that only the coach can use is a gap. Each
in-app path writes through the same `db.ts` function the coach's tool uses,
with the reviewed plan version, and is audited as `actor='ios'`.

Already closed elsewhere: target weight, reps and RPE per slot
([app design pass](../app-design-pass/plan.md)), the weekly schedule and date
assignments, and planned run steps ([planned runs](../planned-runs/plan.md)
P5).

## Phases

- [ ] **P0 — Away dates**
  - Members add, edit and remove away dates (`plans.meta.trips`): a range
    of days with a reason (travel, rest, injury, other), whether they can
    still train, and a note. These are the ranges the coach writes with
    `add_trip`, `update_trip` and `remove_trip`.
  - REST: `POST /api/plan/trips`, `PATCH /api/plan/trips/:id` and
    `DELETE /api/plan/trips/:id?expected_version=`. Each needs the reviewed
    plan version, rejects unknown or invalid fields before writing, and goes
    through `addTrip` / `updateTrip` / `removeTrip`. A stale version is a
    409 with `{conflict, current_version}`; a missing range is a 404.
  - iOS: the Plan tab's Calendar section has an "Away dates" row that shows
    the next range and opens a list of coming-up and past ranges. The editor
    picks the first and last day (the last day can't come before the
    first), the reason, "I can still train" and a note. An edit sends only
    the fields that changed. Saving and removing carry the plan version the
    editor opened with and go through the routine write queue. If the plan
    has moved on, the write is a conflict: the app reloads, closes the
    editor and asks the member to review.
  - The calendar already reads trips: a range where the member can't train
    blocks the days, and one where they can pauses the weekly schedule.
- [ ] **P1 — Race goal and training phases**
  - Set, change and clear the race goal (`set_race`) and the training phase
    blocks (`set_periodization`) in the app.
- [ ] **P2 — Deload or lighten a week**
  - The member can make the change `adjust_today` makes: scale target
    weights or sets for one workout or the whole plan.
- [ ] **P3 — Smaller coach-only edits**
  - Exercise cues and the progression rule on a slot, notes on a workout,
    and deleting an intervals.icu activity that Tres Fort created.

## Dependencies

| Local phase | Relationship | Target | Reason |
|---|---|---|---|
| P0 | coordinates_with | plan:app-design-pass#P5 | Both change the Plan tab and ship in the same TestFlight build. |

## Next step

**Now (@agent):** Drive the P0 pull request to ready to merge. Its new REST
routes need a Worker deploy, with the owner's go-ahead, before a TestFlight
build that shows the Away dates row reaches members.

## Verification evidence

- P0: `test/plan_trips.test.ts` covers add, edit and remove with version
  bumps, a stale version's 409, the stored ranges, `actor='ios'` audit rows,
  missing and invalid fields including unknown keys, an inverted range from
  a POST and a PATCH, a long note, the default reason, a missing range and a
  DELETE without a version. `AwayDatesTests` covers reading ranges in date
  order, the fields a new range and an edit send, keeping the last day on
  or after the first, the note limit and the row text. `SetOutboxTests`
  covers saving and removing with the reviewed plan version, a stale save
  reloading, and a save or removal keeping the reviewed version after the
  live plan has moved on.

## Notes / open questions

- The app needs no migration for P0: trips already live in `plans.meta`.
- Adding away dates doesn't delete anything already on those dates. The
  calendar's existing rules decide what each day shows: a workout started
  or done still shows, and a no-training range hides a workout only
  planned for that day.
