# Runs on Apple Watch

Slug: apple-watch · Status: paused · Updated: 2026-11-06 · Theme: connected-training

## Goal

A member with an Apple Watch can follow and record a run from the wrist. The
rest timer and the run recorder's stats show on the Watch laid out for it. A
planned run can be sent to Apple's Workout app with its steps and pace or
heart rate alerts, and the finished run comes back to Tres Fort with its
route and marks the planned run done. A Tres Fort Watch app then records the
run itself, with GPS, wrist heart rate and the planned steps as haptic and
spoken cues, while the iPhone shows the same run live. Every part works
without AI, and the run reaches Tres Fort through the same paths as a run
recorded on the iPhone.

## Phases

- [x] **P0 — Rest timer and run stats laid out for the Watch**
  - The rest timer and run recorder Live Activities already appeared in the
    Watch's Smart Stack (watchOS 11 with iOS 18 and later), shrunk from the
    Dynamic Island's compact views. Both now declare the small supplemental
    family on iOS 18 and later (`TresFortWidgets/WatchActivityLayout.swift`)
    and draw a wrist layout for it: the rest or timed-set countdown, what's
    next and End rest (Stop & log for a timed set), and the run's time,
    distance and pace with Pause, or Resume and Finish while paused.
    Buttons run the existing intents on the iPhone.
  - No Watch app, no new permission, no server change. iOS 17, the Lock
    Screen and the Dynamic Island are unchanged.
- [ ] **P1 — Planned runs in Apple's Workout app**
  - A planned run's details offer "Send to Apple Watch" when a Watch is
    paired. The app turns the slot's `run_steps` into a WorkoutKit custom
    workout: warm-up and cool-down steps, work and recovery steps, repeat
    groups as interval blocks with their count, each step's duration or
    distance as its goal, and its pace range or heart rate range as an
    alert. It schedules the workout for the slot's date through
    `WorkoutScheduler`, after the member allows it. Steps the format can
    hold but WorkoutKit can't are reported before sending, never dropped
    silently.
  - When the member finishes that run in the Workout app, Apple Health holds
    it. The app matches it to the sent plan (by the workout plan's id where
    Health records it, else the slot's date and an outdoor run started after
    sending) and turns it into a recorded run: route, heart rate, moving time
    and distance from Health. It then saves it through the recorder's
    existing path (`RunRecordingStore`, the recordings upload with its route,
    and `SyncModel.logRecordedRun`), so the planned run is marked done and the
    record shows it against the plan. The Health import's copy of the same
    workout yields to the recording, as dedup already ranks recordings above
    Apple Health.
  - Unplanned Workout-app runs keep arriving through the existing Apple
    Health import, unchanged.
- [ ] **P2 — Record runs with the Tres Fort Watch app**
  - [ ] **(a) Watch app and its build**
    - A watchOS app target embedded in the iPhone app (`project.yml`), built
      and unit tested on a Watch simulator in the PR's iOS job. Pure recorder
      logic (`RunPlan`, `RunPlanProgress`, `RunTargetCoach`, `RecordedRun`,
      `RecordedRunTCX`) moves to `ios/Shared` and compiles into both apps.
    - The start screen shows today's planned run, sent from the iPhone over
      WatchConnectivity with its steps and unit preference, or Start an
      unplanned run. The Watch never signs in or calls the Worker.
  - [ ] **(b) Record on the Watch**
    - The Watch runs the `HKWorkoutSession` with GPS and wrist heart rate,
      shows time, distance, pace and heart rate, and pauses and resumes
      (including auto-pause, as on the iPhone). It mirrors the session to the
      iPhone, which shows the run in its recorder screen and Live Activity
      and can pause or end it.
    - A run interrupted by a Watch restart resumes through workout recovery,
      as the iPhone recorder does.
    - Heart rate after the stop (plan:run-recorder P7): the wrist sensor
      streams only during a workout session, so End stops the activity
      (`stopActivity`, session state `stopped`) and ends the builder's
      collection at the stop, while the session stays open for the two-minute
      cool-down and the live summary. The session ends at Done, after five
      minutes or when the run is saved, so the extra minutes never change
      duration, distance or load. The readings at one and two minutes go
      with the run exactly as a strap's do. Apple's own Cardio Recovery
      (`heartRateRecoveryOneMinute`) is written only for workouts recorded
      in Apple's Workout app, so it is never a source for these runs.
  - [ ] **(c) Planned steps on the wrist**
    - The current step, what's left of it and the target show on the Watch.
      Each new step and each off-target or back-on-target moment gets a
      haptic, with the same margins and 30-second spacing as the iPhone's
      spoken cues, which also play through the Watch speaker or connected
      headphones when the member turns them on.
  - [ ] **(d) Save the run through the iPhone**
    - The finished run (route, heart rate, pauses, moving time and distance)
      goes to the iPhone as a file transfer and is saved exactly as an
      iPhone recording: Apple Health already holds the Watch's workout, Tres
      Fort keeps the run and its route, intervals.icu gets a copy when
      connected, and a planned slot is marked done. A run stays on the Watch
      until the iPhone confirms it has it.
- [ ] **P3 — Real runs on an Apple Watch**
  - A member who runs with an Apple Watch records runs on a TestFlight build:
    the wrist layouts (P0), a planned run through the Workout app (P1), and
    planned and unplanned runs with the Watch app (P2), including a pause,
    a recovered session and a run saved while the iPhone was out of range.

## Dependencies

| Local phase | Relationship | Target | Reason |
|---|---|---|---|
| P1 | coordinates_with | plan:planned-runs | Reads the planned-run step format and marks the slot done through planned-runs P7's path. |
| P2 | coordinates_with | plan:run-recorder | Moves pure recorder logic into `ios/Shared` and saves Watch runs through the recorder's store and upload. |
| P2 | coordinates_with | plan:app-store-submission | A Watch app ships only in a version after 1.0 and needs the App Store project file and review notes updated. |
| P1 | gated_by | external:apple-watch-device-verification | The owner paused after P0: P1 onward waits for a member who runs with an Apple Watch to test it (P3) on an authorized TestFlight build. |

## Next step

**Paused (owner, 2026-11-03):** The owner has no Apple Watch, and no
member is known to run with one, so P1 and P2 could only be checked on the
Watch simulator. The owner chose to stop after P0's wrist layouts. Resume
with P1 when a member who runs with an Apple Watch will test it (P3).

## Verification evidence

- P0: layout only, so no unit test; the PR's iOS job compiles the widget
  extension for the iPhone and App Store builds. How the wrist layouts look
  and whether their buttons reach the iPhone is checked on a real Watch in
  P3.

## Notes / open questions

- The owner asked on 2026-11-03 whether Tres Fort could have an Apple Watch
  app, and chose "Full Watch app, runs first" from a phased proposal. Logging
  lifting sets from the wrist and a Today screen with a watch-face
  complication were proposed as later phases and stay candidates.
- Apple's Workout app has no sets or reps, so lifting on the wrist needs the
  Watch app; it would drive the iPhone runner the way the iPad Station link
  does. A Watch that trains with no iPhone nearby (its own sign-in, outbox
  and offline rules) is not planned.
- P1 and P2 overlap for planned runs. P1 is quick and uses Apple's own
  recorder; P2 keeps the whole run in Tres Fort with its own cues. Both stay,
  since P1 also serves members who prefer the Workout app.
- WorkoutKit custom workouts and scheduling need iOS 17, which the app
  already requires. Whether Health records the workout plan's id on the
  finished workout is checked in P1; the date-and-type match is the
  fallback.
- No migration or Worker change is expected; P1 and P2 use the existing
  recordings endpoint and the Apple Health import.
- App Store 1.0 stays on build 55. Merging any phase doesn't authorize a
  TestFlight build or an App Store submission.
