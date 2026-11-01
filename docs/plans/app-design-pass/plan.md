# App design pass

Slug: app-design-pass · Status: active · Updated: 2026-11-01 · Theme: member-experience

## Goal

Make the iOS app feel less clunky in everyday use. Common actions take fewer
taps and fewer stacked screens, unplanned training is as easy to start as
planned training, every feature works without an AI coach, and screens share
one visual system. The owner asked for the whole ranked list from the
2026-11-01 design review to be built, plus easier unplanned activities.

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
- [ ] **P2 — Workout navigation**
  - Library, workout details, editing and adding an exercise use one
    navigation stack with Back, and Edit is a mode of the details screen.
  - A Plan tab holds the library, the calendar and the weekly schedule.
    Groups appear only in the Group tab.
  - Adding an exercise sets its target weight too.
- [ ] **P3 — Endurance without AI**
  - Log a run, ride or swim in the app with distance and time. It goes to
    intervals.icu through the same provider write the coach uses, and other
    activities stay local.
  - Progress shows an Endurance card with weekly distance and time and recent
    runs.
- [ ] **P4 — One visual system**
  - Display type only for big numbers and exercise names, mono type only for
    numbers, and one primary button style across the app.

## Next step

**Now (@agent):** Take P2 through CI and Codex review to ready to merge, then
open P3 and P4, which are built and apply cleanly on top of it.

## Notes / open questions

- Repository delivery does not authorize a TestFlight or App Store build. App
  Store 1.0 stays on build 55.
- The review read the code without screenshots. Visual checks need the Mac
  mini or a TestFlight build, each with the owner's go-ahead.
- P3 adds a REST route over `src/services/intervalsActivityWrite.ts`. A
  provider failure stays an error, never a local fallback, as for the coach.
