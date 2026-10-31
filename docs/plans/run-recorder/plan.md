# Run recorder on iPhone

Slug: run-recorder · Status: active · Updated: 2026-10-31 · Theme: connected-training

## Goal

Let a member record an outdoor run in the Tres Fort iPhone app instead of
Strava. The run gets live time, distance and pace and a GPS route, is saved
to Apple Health, and reaches intervals.icu as a full activity file, so the coach
sees it in the same place as Garmin runs.

## Phases

- [x] **P0 — Upload a recorded run to intervals.icu**
  - `POST /api/activities/recordings` (app JWT, multipart `id`, `date`,
    optional `name`, `file`) uploads one recorded run to the member's
    intervals.icu account through `uploadActivityFile` in `src/intervals.ts`
    with external_id `tresfort:recording:<uuid>`.
  - Retries are idempotent on that external_id: a retry that finds the
    activity a day either side of the run date returns it instead of
    uploading again, and a file intervals.icu already had answers 200.
  - Only `.fit`, `.gpx` and `.tcx` files up to 10 MB whose first bytes match
    the extension are accepted. The file passes through and is never stored
    in D1; the existing activity sync brings the run into
    `external_activities`.
  - Provider failure is an error with no local fallback. A write 401/403
    never disconnects the read credential, the same as `log_activity`.
- [x] **P1 — Record a run on iPhone**
  - [x] **(a) Keep and upload recorded runs on the device**
    - `RecordedRun` holds the route, heart-rate samples, pauses, the workout
      builder's distance and moving time, and the device-local civil date.
    - `RecordedRunTCX` encodes it as TCX, not GPX, so the upload keeps the
      builder's totals: the lap carries moving time and distance, and each
      track point a cumulative distance scaled to that total. Each pause
      starts a new track and paused distance never counts. Heart rate is
      attached only within 5 seconds of a point.
    - `RunRecordingStore` keeps one file per run in an account-scoped,
      backup-excluded directory until the server acknowledges the upload.
      Files use `completeUntilFirstUserAuthentication` so checkpoints still
      save with the phone locked mid-run. Account deletion removes them.
    - `RunRecordingUploader` sends finished runs to P0's endpoint as
      multipart TCX, removes each only after a 200/201, keeps failures for
      the next attempt and stops on a rejected bearer.
  - [x] **(b) Record with a workout session**
    - "Record a run" in Today's "+" menu opens a full-screen recorder on
      iOS 26 or later on iPhone, which supports `HKWorkoutSession`,
      `HKLiveWorkoutBuilder` and `HKWorkoutRouteBuilder`. On older iOS, on
      iPad and in the App Store build the entry stays hidden. The app's iOS 17
      minimum doesn't change.
    - Start, pause, resume and end (save or discard) an outdoor run. The
      screen shows time, miles, current pace over the last 30 seconds,
      average pace, heart rate when Health has a recent sample, and the route
      on a map. Distance comes from the workout builder (Apple's own fusion),
      never from summing raw GPS points.
    - `RunRecorderModel` owns the run; `HealthRunWorkoutEngine` and
      `CoreLocationRunSource` sit behind protocols so the logic is tested
      without HealthKit or GPS. Fixes less precise than 50 m, older than the
      start, or implying more than 12 m/s are dropped.
    - It asks for When In Use location (precise) and permission to write
      workouts and routes to Apple Health. Updates continue with the phone
      locked through the `location` background mode and a background
      activity session. The beta's Health update string now says runs are
      saved; the App Store build keeps its read-only string and removes the
      location keys from its processed Info.plist, checked by
      `test/app-store-packaging.test.py` and a runtime test in both App Store
      shards.
    - The finished run is saved to Apple Health as an `HKWorkout` with its
      route and the recording's external_id. The existing Apple Health sync
      pushes its summary, and the server retires that copy once the
      intervals.icu upload arrives (intervals wins the start-time match).
    - The run is checkpointed into (a)'s store at the start, on every pause
      or resume and every 10 seconds of route. On launch, a run whose Health
      session survived is reattached with its route refilled; otherwise it
      finishes at its last point or pause and uploads. Finished runs upload
      on finish, launch and foreground. If the Health session fails mid-run,
      or Health doesn't save the workout, the run still uploads.
- [x] **P2 — Run from the Lock Screen**
  - Show a Live Activity with time, distance and pace, plus pause and end
    controls, from the existing widget extension.
  - Give optional spoken split announcements per kilometre or mile.
  - Delivered: the widget extension's `RunActivityWidget` shows the moving
    time (a system timer from the start shifted by pauses, frozen while
    paused), distance and current pace on the Lock Screen and in the Dynamic
    Island. Distance and pace update at most every 5 seconds; pause and
    resume update at once. Its buttons run `RunRecorderControlIntent` in the
    app: Pause while running, Resume and Finish while paused, so finishing
    takes two taps and a pocket tap can't end the run. Only the run being
    recorded answers. The activity ends when the run is saved, discarded or
    lost, and a relaunch picks a recovered run's activity back up.
  - The recorder offers miles or kilometers for its screen, Lock Screen and
    splits, and an optional announcement of each whole unit (split time and
    average pace), off by default and mutable from the header mid-run. Both
    choices stay on the device. Speech ducks other audio, which needs the
    `audio` background mode; the App Store build removes it with the other
    background modes.
- [ ] **P3 — Verify accuracy and reliability on a real device**
  - Record at least three outdoor runs on the owner's iPhone (open sky,
    trees or buildings, and a run with pauses), and check that distance,
    moving time and pace look right to the owner. The owner dropped the
    side-by-side comparison with the Garmin Forerunner 945 on 2026-10-31,
    so there is no measured tolerance.
  - Verify a locked phone for the whole run, a force-quit mid-run, no network
    at the end, and that the upload and Health save each land once.
  - Confirm against the live intervals.icu API that the first real upload
    creates one activity carrying the recording external_id and name, and
    that a retry returns it. P0's request shape (query-string `name` and
    `external_id`, multipart `file`, 201 created or 200 duplicate) comes
    from intervals.icu's API conventions and has only been tested against
    mocks.
- [ ] **P4 — Auto-pause and a running display**
  - Auto-pause, on by default and switchable before the run: pause when GPS
    speed stays under a walking threshold for a few seconds, and resume
    when it rises again, using the same pause records as a manual pause so
    the builder, splits and Lock Screen agree. A manual pause stays paused
    until the member resumes it. The resume and pause are spoken when
    announcements are on.
  - A glanceable running layout: a few large numbers chosen by the member
    (time, distance, current pace, average pace, heart rate), in place of
    the map. Keep the screen awake while it shows.
  - Don't upload a run too short to analyze (under a minute or 100 m): ask to
    discard it instead. The first P3 session left a zero-length run on
    intervals.icu.
  - Delivered in the repository: "Pause when I stop" (on by default) pauses
    after 5 seconds under 0.8 m/s of GPS speed and resumes after 2 seconds
    over 1.4 m/s, saying "Run paused." and "Run resumed." when announcements
    are on; the title reads "Auto-paused". A header button swaps the map for
    four large numbers (pace, distance, time and heart rate by default); a
    tap on a number picks what it shows, and the choices stay on the
    device. The screen stays on while that layout shows during a run. End
    on a run under a minute or 100 m offers only Discard, and a Lock Screen
    Finish on one discards it without a Health workout or upload. Awaiting
    an authorized TestFlight build to try on a run.

## Execution frontier

- P3
- P4

## Dependencies

| Local phase | Relationship | Target | Reason |
|---|---|---|---|
| P3 | gated_by | external:owner-run-recorder-device-verification | Real GPS runs on the owner's iPhone need an authorized device build. |
| P1 | coordinates_with | plan:app-store-submission | New location and Health write permissions change the App Privacy answers and review notes. |

Phases run in order: P1 needs P0's upload path, and P2's Live Activity
mirrors P1's session.

## Next step

**Now (@owner):** Authorize a TestFlight build with the recorder and the
Worker deploy that carries P0, then record the P3 runs.

P3 needs a TestFlight build on the owner's iPhone, which needs separate
authority, as does the Worker deploy that carries P0. P1 and P2 are delivered
in the repository; their HealthKit, location, ActivityKit and speech calls
have only been compiled and run against fakes, so P3 is their first real
test, including the Lock Screen controls, splits heard with the phone
locked and a Bluetooth heart rate strap. Launch-time recovery runs
when the app next opens; handling the system's workout-recovery relaunch in
the scene delegate is left to P3's force-quit check.

## Verification evidence

- P0: `test/run_recording.test.ts` covers format detection, upload with the
  recording external_id and name, retry by external_id, provider duplicate,
  write rejection with the read credential kept, provider 5xx/4xx and lookup
  failure, a member without a connection, form validation and the 10 MB
  limit, all against mocked intervals.icu responses.
- P1(a): `ios/TresFortTests/RunRecordingTests.swift` covers civil dates,
  TCX builder totals, scaled point distances, GPS fallback, pause tracks,
  elevation and heart-rate matching, the
  multipart body, per-account storage, checkpoint replacement, damaged
  files, account deletion, and upload acknowledgement, failure and 401.
- P1(b): `ios/TresFortTests/RunRecorderTests.swift` covers the GPS filter,
  pace and formatting, pause-aware moving time, recording with checkpoints
  and pause/resume, upload on end, denied and approximate location, a Health
  save failure, an empty run, a rejected bearer and retry, no bearer,
  discard, a failed Health session, recovery of a surviving session and of
  an orphaned checkpoint, all with fake engine, GPS and uploader.
  `RunRecorderPackagingTests` checks the built Info.plist in the beta and in
  both App Store shards.
- P2: `RunRecorderTests` also covers kilometer distance and pace, the split
  tracker (whole units, jumps, a recovered run), the spoken split text, Live
  Activity state through start, throttled updates, pause, resume and end,
  ending it on discard, launch and a lost run, reattaching it on recovery,
  Lock Screen controls for this run only, and split announcements with the
  persisted unit and toggle, with fake activity and speech.
- P4: `RunRecorderTests` covers auto-pause and resume from GPS speed with
  their spoken cues, a manual pause that moving doesn't resume, turning
  auto-pause off and keeping that choice, a run too short to save (no Health
  workout, upload or checkpoint), and the kept running-layout choices.
- P3 feedback: `RunRecorderTests` covers GPS warm-up when the recorder
  opens, and strap readings joining the run and the Health workout without
  the builder's echo counting twice. `HeartRateMonitorTests` covers parsing
  the Heart Rate Measurement, no Bluetooth until a strap is set up, choosing,
  remembering, switching and forgetting a strap, reconnecting after a drop
  and Bluetooth problems in the status, with a fake central.

## Notes / open questions

- First P3 run (build 58, 2026-10-30 evening, Pacific): the recorder upload
  reached intervals.icu as a run of 2.04 km in 8:32 moving, average heart
  rate 149 from the strap (max 162). A second, empty activity (no distance,
  zero moving time, heart rate 77) was uploaded from a start-and-end test.
  The Forerunner's copy never reached intervals.icu, and on 2026-10-31 the
  owner dropped the Garmin comparison altogether. The owner asked for auto-pause, a
  glanceable running display, and planned runs with pace or heart rate
  targets and spoken on/off-pace cues. P4 covers the first two; planned runs
  are [their own plan](../planned-runs/plan.md).
- First P3 feedback (build 57, 2026-10-30): finding the runner took too long
  because GPS and the location prompt only started on Start. The recorder now
  asks for location and starts foreground GPS when it opens, shows "Finding
  GPS…" or "GPS ready" (a fix within 20 m), and hands that GPS to the run;
  closing the screen without a run stops it.
- Second P3 feedback (2026-10-30): heart rate came only from whatever the
  Health workout session picked up, with no sign in the app of a strap or
  how to connect one. The recorder now connects a Bluetooth heart rate strap
  itself (the standard Heart Rate service, so Polar, Wahoo, Garmin HRM and
  similar). Its start screen shows the strap and live reading, or "No heart
  rate monitor" with Set up. The setup screen finds straps nearby, remembers
  the one picked on this iPhone and can forget it. The strap reconnects while
  the recorder is open or a run records, including after a drop. Its
  readings join the run's upload and are added to the Health workout when
  Health allows saving heart rate. Bluetooth permission is asked only on
  setup. The beta adds `NSBluetoothAlwaysUsageDescription` and the
  `bluetooth-central` background mode; the App Store build removes both. A
  watch that broadcasts heart rate only over ANT+ can't connect, because
  iPhone has no ANT+ radio.

- Nick chose on 2026-10-30 to bypass Strava for runs he records on his
  iPhone. Strava's API terms stop Strava-sourced activities from reaching Tres
  Fort through intervals.icu, and its social features aren't worth keeping to
  him. Garmin runs already reach intervals.icu directly and are unaffected.
- No machine learning is involved. Accuracy is set by the phone's GPS and
  Apple's sensor fusion, which Strava's iPhone app also relies on. Strava's
  extras (segments, social feed, heatmaps, elevation correction) are out of
  scope.
- intervals.icu stays the store of record for endurance activities, as
  [MULTISPORT.md §11](../../MULTISPORT.md) requires. Tres Fort uploads files
  and never keeps a second writable cardio store or GPS streams in D1.
- Heart rate on iPhone comes only from what Health provides during the
  session (a paired watch or supported headphones). Direct Bluetooth chest
  straps and an Apple Watch app are possible later slices, not part of this
  plan.
- Recovering the Sep 4 to Oct 27, 2026 Strava runs is an owner task (Strava
  export uploaded to intervals.icu), not part of this plan.
- `delete_activity` deletes only `tresfort:activity:` activities, so it can't
  remove a recorded run. Whether it should is open.
- Merging any phase doesn't authorize a Worker deploy or an iOS distribution.
