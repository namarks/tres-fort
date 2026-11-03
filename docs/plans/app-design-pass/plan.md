# App design pass

Slug: app-design-pass · Status: active · Updated: 2026-11-03 · Theme: member-experience

## Goal

Make the iOS app feel less clunky in everyday use. Common actions take fewer
taps and fewer stacked screens, unplanned training is as easy to start as
planned training, every feature works without an AI coach, and screens share
one visual system. The owner asked for the whole ranked list from the
2026-11-01 design review to be built, plus easier unplanned activities.
On 2026-11-02 the owner found the Plan tab unclear on landing, above all its
Active/Archived toggle, which P6 addresses.
On 2026-11-03 the owner found changing a day of the week unintuitive: tapping
a day didn't let them change it, and a day couldn't become something that
isn't a workout yet (soccer every Monday). P7 addresses that.
Later that day the owner asked to rename the Progress tab Activity and make
it the place to look at past workouts and runs, which P8 addresses.

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
  - The owner found the tab unclear on landing, then found that it mixed
    planning the week with making workouts. After three rounds of mocks on
    2026-11-02, the tab has two sides behind a Schedule | Workouts switch.
  - Schedule (the default) is when you train: "Your week" lists each weekday
    with its workout or Rest, a day with a workout opens it, and one primary
    button, Edit weekly schedule (Choose your training days when nothing is
    scheduled), sits under it. Calendar and Away dates follow as rows. With
    no workouts it points to the Workouts side instead.
  - Workouts is what you do: the saved workouts, Add workout, the tag filter
    and reordering. Plan changes move to a toolbar button.
  - The Active/Archived toggle is gone. An Archived workouts row with a
    count, shown only when something is archived, opens its own screen to
    restore or delete them. The tag filter lists tags of active workouts.
  - Unit test for the week rows; UI journeys for both sides and the archive
    screen. Needs the owner's look on a TestFlight build like P5.

- [ ] **P7 — Change a day from Your week**
  - Every weekday in Your week, rest days too, opens that day: pick Rest or a
    saved workout and only that weekday changes, carrying the plan version on
    screen. "Edit all days" keeps the seven-picker editor.
  - From the same day, New activity names something without sets (Soccer,
    a class, a hike), saves it as a workout with no exercises and puts it on
    that weekday. A name that matches an existing workout reuses it. New
    workout opens the exercise picker and puts the result on that day once
    its editor closes.
  - On its day Today shows an activity with "Log <name>", which opens Log
    activity on that name (its type when the app knows one, else Other), and
    shows it as logged once an activity with that name is logged that day.
    The library, calendar and date picker call it an activity.
  - The owner asked (2026-11-03) to stop showing the plan change log: the
    Plan changes button and the library's recent-changes card are gone and
    the history screen with them. History stays on the server, and the coach
    still reads and restores it over MCP.
  - No backend change: `POST /api/workouts` already takes a workout without
    exercises, and `PUT /api/plan/schedule` takes the whole week.
  - Unit tests for one-day week changes, activity naming, kind and logged
    checks; a UI journey adds Soccer to Monday from the Plan tab and sets it
    back to rest. Needs the owner's look on a TestFlight build like P5.

- [ ] **P8 — An Activity tab for past workouts and runs**
  - The Progress tab becomes Activity, with a History | Progress switch.
    History (the default) lists everything the member has done, newest first
    and by month: workouts finished in the app, runs, rides and swims from the
    recorder, Apple Health, intervals.icu and .fit files, and activities
    logged by hand, such as soccer. A finished run workout shows once, as its
    run. Filter chips (All, Workouts, Runs, Rides, Swims, Walks, Other) list
    only the kinds the member has done.
  - Tapping an entry opens that date's record, the same one the calendar
    opens: the logged sets, a recorded run's route map and its delete, logged
    activities and their notes.
  - Progress keeps the consistency, strength, endurance and weight cards
    unchanged. Copy that pointed to Progress → Weight now says Activity →
    Progress → Weight, the privacy page included.
  - No backend change: `/api/state` already carries the full history.
  - Unit tests for the history rules (order, statuses, the run workout,
    deleted and trip-hidden rows, filters and months); UI journeys for
    History, its filters and records, and a run logged on Today appearing in
    History. Needs the owner's look on a TestFlight build like P5.

## Execution frontier

- P5
- P6
- P7
- P8

## Dependencies

| Local phase | Relationship | Target | Reason |
|---|---|---|---|
| P5 | gated_by | external:owner-design-pass-release | A Worker deploy and a TestFlight build each need the owner's own go-ahead, and the visual check needs a real device. |

## Next step

**Now (@agent):** Land P8 (the Activity tab) with green CI and a clean Codex
review.

**Then (@owner):** TestFlight build 63 (main 21f0f3f) carries P0 to P7. Try
them on the iPhone. P8 reaches the phone with the next TestFlight build, which
needs its own go-ahead.

## Notes / open questions

- Repository delivery does not authorize a TestFlight or App Store build. App
  Store 1.0 stays on build 55.
- The review read the code without screenshots. Visual checks need the Mac
  mini or a TestFlight build, each with the owner's go-ahead.
- P3 adds a REST route over `src/services/intervalsActivityWrite.ts`. A
  provider failure stays an error, never a local fallback, as for the coach.
