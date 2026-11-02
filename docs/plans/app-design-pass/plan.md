# App design pass

Slug: app-design-pass · Status: active · Updated: 2026-11-02 · Theme: member-experience

## Goal

Make the iOS app feel less clunky in everyday use. Common actions take fewer
taps and fewer stacked screens, unplanned training is as easy to start as
planned training, every feature works without an AI coach, and screens share
one visual system. The owner asked for the whole ranked list from the
2026-11-01 design review to be built, plus easier unplanned activities.
On 2026-11-02 the owner found the Plan tab unclear on landing, above all its
Active/Archived toggle, which P6 addresses.

## Phases

- [x] **P0 — Quick wins and exercise targets**
  - Readable dates, a Units and sounds section in Profile, body weight that
    follows the lb/kg choice, the weekly schedule reachable from the library
    and clearer finish copy. The exercise editor sets target weight, its unit
    and RPE, which before only the coach could change.
  - Merged in PR #287 with model tests and CI.
- [x] **P1 — Today and the set runner**
  - Today shows unplanned training directly: a freestyle lift, a run to record
    and an activity to log, on idle, rest and completed days. The + menu keeps
    the same choices and the occasional ones.
  - The iPad display button leaves the toolbar until this phone turns the
    display on. Before that it sits in the + menu, or the workout menu during
    a workout.
  - A menu beside the exercise name swaps or adds an exercise, opens the
    plates guide and skips, in one tap instead of three.
  - The runner footer shows the rest row and the last-set row only when they
    have something to show, so the inputs keep that room.
  - Finish workout before the last set lands on the same finish screen as the
    last set, with the same summary, feedback and Finish action.
  - Merged in PR #288 with UI journeys for the Today shortcuts, the iPad
    display entry, the exercise menu, the footer and both finish routes.
- [x] **P2 — Workout navigation**
  - Library, workout details, editing and adding an exercise use one
    navigation stack with Back, and Edit is a mode of the details screen.
  - A Plan tab holds the library, the calendar and the weekly schedule.
    Groups appear only in the Group tab. Start on the Plan tab continues a
    workout already on the runner and never replaces it.
  - Adding an exercise sets its target weight too.
  - Merged in PR #289.
- [x] **P3 — Endurance without AI**
  - Log a run, ride or swim in the app with distance and time. It goes to
    intervals.icu through the same provider write the coach uses, and other
    activities stay local.
  - Progress shows an Endurance card with weekly distance and time and recent
    runs.
  - Merged in PR #290. `POST /api/activities/endurance` needs no migration.
- [x] **P4 — One visual system**
  - Display type only for big numbers and exercise names, mono type only for
    numbers, and one primary button style across the app.
  - Merged in PR #291.
- [ ] **P5 — Release and device check**
  - Deploy the Worker so the app can reach `POST /api/activities/endurance`,
    then distribute a TestFlight build from main.
  - On the owner's iPhone, check the Today shortcuts, the exercise menu, the
    finish screen, the Plan tab, logging a run with distance and time, the
    Endurance card and the new type and buttons.

- [ ] **P6 — A Plan tab with a clear first action**
  - The tab opens on "Your week": each weekday with its workout or Rest, and
    one primary button, Edit weekly schedule (Choose your training days when
    nothing is scheduled). The calendar and away dates follow as rows.
  - A plan with no workouts shows one step, Create your first workout.
  - The Active/Archived toggle is gone. The library lists active workouts,
    and an Archived workouts row with a count, shown only when something is
    archived, opens its own screen to restore or delete them. The tag filter
    lists tags of active workouts only.
  - Unit test for the week rows; UI journeys for the Plan tab and the archive
    screen. Needs the owner's look on a TestFlight build like P5.

## Execution frontier

- P5
- P6

## Dependencies

| Local phase | Relationship | Target | Reason |
|---|---|---|---|
| P5 | gated_by | external:owner-design-pass-release | A Worker deploy and a TestFlight build each need the owner's own go-ahead, and the visual check needs a real device. |

## Next step

**Now (@agent):** Land P6 (Plan tab) with green CI and a clean Codex review.

**Then (@owner):** The Worker is deployed and TestFlight build 61 (main
1b273fa, uploaded 2026-11-02) carries P0 to P4. Try them on the iPhone. P6
reaches the phone with the next TestFlight build, which needs its own
go-ahead.

## Notes / open questions

- Repository delivery does not authorize a TestFlight or App Store build. App
  Store 1.0 stays on build 55.
- The review read the code without screenshots. Visual checks need the Mac
  mini or a TestFlight build, each with the owner's go-ahead.
- P3 adds a REST route over `src/services/intervalsActivityWrite.ts`. A
  provider failure stays an error, never a local fallback, as for the coach.
