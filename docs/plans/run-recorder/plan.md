# Run recorder on iPhone

Slug: run-recorder · Status: active · Updated: 2026-11-02 · Theme: connected-training

## Goal

Let a member record an outdoor run in the Tres Fort iPhone app instead of
Strava. The run gets live time, distance and pace and a GPS route, is saved
to Apple Health, and is kept by Tres Fort itself, route included, so the app
and web can show it without any other service. When the member has
intervals.icu, it also reaches intervals.icu as a full activity file, so the
coach sees it in the same place as Garmin runs.

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
    `external_activities`. (P5 changes this: Tres Fort keeps the run itself
    and accepts only the recorder's TCX.)
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
    Finish on one discards it without a Health workout or upload. In
    TestFlight build 59 (2026-10-31).

- [ ] **P5 — Keep recorded runs in Tres Fort**
  - The owner decided on 2026-11-02 that the recorder saves runs straight to
    Tres Fort, GPS route included, so the app and web can show maps. This
    reverses the earlier rule that Tres Fort keeps no GPS streams and leaves
    recorded runs to intervals.icu
    ([MULTISPORT.md §11](../../MULTISPORT.md) records the exception).
    intervals.icu becomes an optional copy.
  - [x] **(a) Keep the run and its route** (PR #322)
    - `POST /api/activities/recordings` reads the recorder's TCX
      (`src/tcxFile.ts`) and keeps the run as an `external_activities` row
      with `source='recording'`, id `recording:activity:<user>:<recording
      id>`. Moving time, distance, elapsed time, average and maximum heart
      rate come from the file. Heart rate on moving time gives the same
      stream summary a .fit import keeps, so the run's load is scored from
      the member's thresholds.
    - The GPS route goes to `activity_routes` (migration 0063), one row per
      recording, in `src/activityRoute.ts`'s encoding: delta-coded
      milliseconds, micro-degrees and decimeter altitudes, one segment per
      track between pauses. Every fix is kept up to 12 hours at one a
      second; a longer route keeps each segment's ends and an even share of
      the points between them.
    - Then the file goes to intervals.icu as before when the member has a
      connection. Without one the answer is 201 with
      `intervals.status = "not_connected"`. A provider failure keeps its
      error status and adds `stored: true`, so the app keeps the file and
      retries only the intervals.icu copy; the retry finds the run already
      kept. A recording the member deleted is never kept or sent again.
    - Dedup: an intervals.icu copy of the run wins over the recording, as
      it does over a .fit import, and the recording wins over Apple
      Health's copy. `GET /api/activities/:id/route` serves the route for
      the recording or for the activity it is hidden behind, only to its
      member. `DELETE /api/activities/recordings/:id` deletes the run with
      every copy the app made (P5(d)).
    - Routes are private: group views and the coach never read them. The
      account export includes them and account deletion removes them. The
      privacy policy says the app records location during a run, writes the
      workout to Apple Health and keeps the route in Tres Fort.
    - The recorder says where the run went: "Saved in Tres Fort and sent to
      intervals.icu.", "Saved in Tres Fort with its route." without a
      connection, or that only the intervals.icu copy retries later.
  - [x] **(b) Show the route in the app** (PR #323)
    - A run's card in the day view, and a planned run's record, show its
      route on a map when the run was recorded in the app, either as the
      recording itself or as the intervals.icu copy it was matched to.
      Each segment between pauses is its own line, framed to fit. Tapping
      the map opens it full screen to move and zoom.
    - The app reads `GET /api/activities/:id/route` only for runs from the
      recorder or intervals.icu, once per route and account in memory; "no
      route" is remembered for ten minutes, and a failed read is retried.
  - [x] **(c) Show the route on the web**
    - The owner chose Apple Maps on 2026-11-02, as in the app. The web day
      panel shows a recorded run's route under the run, each segment its
      own line in the accent color, framed to fit, for the same activities
      as the app.
    - The page loads MapKit JS 6 (map and overlay libraries only) when a day
      with a route is opened, with the site's domain-restricted MapKit JS
      token from the gateway's `/maps/token` (pages of this site whose
      session the API accepts; the `MAPKIT_TOKEN` secret of
      `tres-fort-web`). Without a token
      it asks Apple for nothing; then, or when MapKit fails to load or
      refuses the token, it draws the route's shape without a map.
  - [x] **(d) Delete a recorded run in the app**
    - The owner chose on 2026-11-02 that deleting removes every copy the
      app made: the run and its route in Tres Fort, its intervals.icu
      upload and the Apple Health workout the recorder saved.
    - A run recorded in the app shows "Delete run" on its card in the day
      view and on a planned run's record, for the recording itself or the
      intervals.icu copy it was matched to (known from its route's
      `recording_id`). It asks first; the answer says where the run was
      deleted from, or why nothing was.
    - The app finds the recorder's Health workouts by their
      `tresfort:recording:<id>` external UUID and names them in
      `DELETE /api/activities/recordings/:id?health_workout_id=`. The
      server deletes the intervals.icu upload first (external_id
      `tresfort:recording:<id>`, from the activity cache or a day either
      side of the run on intervals.icu). When intervals.icu can't delete it
      the answer is its error with `deleted: false` (502, 409 for a missing
      write scope, 422) and nothing changes. Then one batch tombstones the
      recording, deletes its route, and tombstones the cached intervals.icu
      copy and the named Health copies of this run (matched to the run, or
      starting within two minutes of it), so dedup never brings them back.
      A named workout Apple Health hasn't synced yet gets a tombstone too,
      and a Health push never revives a workout the member deleted, so a
      late or revised push doesn't bring the run back. A Health copy the app
      doesn't name, such as another app's, comes back as the run, the way
      deleting a .fit import brings one back.
    - The app deletes the Health workouts, with the route and strap heart
      rate it saved, only after the server succeeded, or when the server
      says the run is already deleted (a retry after a lost answer). When
      Health keeps one, the answer says so. A run with no connection or
      never uploaded answers `intervals.status` `not_connected` or
      `not_found`.

## Execution frontier

- P3
- P4
- P5

## Dependencies

| Local phase | Relationship | Target | Reason |
|---|---|---|---|
| P3 | gated_by | external:owner-run-recorder-device-verification | Real GPS runs on the owner's iPhone need an authorized device build. |
| P1 | coordinates_with | plan:app-store-submission | New location and Health write permissions change the App Privacy answers and review notes. |
| P5 | coordinates_with | plan:app-store-submission | Keeping GPS routes in Tres Fort adds precise location, linked to the member, to the App Privacy answers. |

Phases run in order: P1 needs P0's upload path, and P2's Live Activity
mirrors P1's session.

## Next step

**Now (@owner):** Record the remaining P3 runs on TestFlight build 60
(main 2832d0c), which carries auto-pause, the running layout, planned runs
and planning them in the app.

**Next (@owner):** Approve applying migration 0063 in production and
deploying the API Worker, which P5 needs, and give the MapKit JS token as
`tres-fort-web`'s `MAPKIT_TOKEN` when the web app is deployed. Deleting a
recorded run (P5(d)) then needs an app build. P5 is done in the repository
once these are verified on a device.

P3 runs on the owner's iPhone. P1 and P2 are delivered in the repository;
their HealthKit, location, ActivityKit and speech calls
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
- P5(a): `test/activity_route.test.ts` covers the route encoding (round
  trip, dropped points, thinning past 12 hours, refused stored text) and the
  TCX reader (laps, tracks, heart rate on moving time, missing positions,
  refused files). `test/run_recording.test.ts` covers keeping the run and
  its route and uploading the file, a retry, a member without a connection,
  provider failures with the run kept, file validation, dedup against Apple
  Health and intervals.icu copies with the route served through the
  intervals.icu copy, another member getting 404, and deleting a recording
  and its route. `account_deletion.test.ts` and
  `account_export_service.test.ts` cover routes leaving and joining the
  account. `RunRecordingTests` and `RunRecorderTests` cover reading the
  intervals.icu copy's status and the recorder's three outcomes.
- P5(b): `ActivityRouteTests` covers decoding the served route into
  segments, drawing only lines of two or more points, refusing mismatched
  arrays and unknown versions, framing every point, which activities can
  have a route, reading a route once per account, remembering "no route"
  for ten minutes, retrying a failed read, and the client's request path
  with a 404 read as no route.
- P5(c): `web/test/routeMap.test.ts` covers decoding the served route into
  lines (lone points, malformed routes and invalid coordinates draw
  nothing), which activities can have a route, the shape drawn without a
  map (fitted inside its margin, not stretched, north up), reading a route
  and the map token with a 404 read as none, and loading MapKit JS only
  with a token, with only the map and overlay libraries. `web/test/gateway.test.ts`
  covers `/maps/token`: the token for a signed-in page of this site once
  the API accepts its session, 404 without one, and refusals for other
  sites, a missing page header, signed-out or app sessions, and a session
  the API refuses. In Chromium against stubbed API answers, a
  site without a token showed the route's shape and loaded nothing from
  Apple; a stand-in MapKit received two lines in the theme's accent color;
  a failed script and a refused token fell back to the shape, the latter
  destroying the map. MapKit JS itself can't be reached from the build
  environment, so the real map is first seen on `app.tresfort.app`.
- P5(d): `test/run_recording.test.ts` covers deleting a recording with its
  route and the Health copy the app names (never taken again), a named Health
  workout pushed late or revised after the delete staying deleted, a Health
  copy the app doesn't name coming back, deleting the intervals.icu upload first
  from the cache or from intervals.icu, a run never uploaded, and nothing
  deleted when intervals.icu fails (502) or refuses (409).
  `RecordedRunDeletionTests` covers the order (server, then Health), no
  Health change when the server refuses, deleting the Health workout when the
  server already deleted the run, the messages for each outcome, which
  activities can be deleted, forgetting the deleted route, and the request
  naming the Health workouts. The HealthKit calls are compiled only; deleting
  the Health workout is first seen on a device.
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
- Until P5, intervals.icu was the store of record for recorded runs and
  Tres Fort kept no GPS streams in D1. Since planned-runs P7 the connection
  was optional, with Apple Health keeping the route. P5 has Tres Fort keep
  the run and its route itself; intervals.icu stays the store of record for
  the activities it syncs.
- Heart rate on iPhone comes only from what Health provides during the
  session (a paired watch or supported headphones). Direct Bluetooth chest
  straps and an Apple Watch app are possible later slices, not part of this
  plan.
- Recovering the Sep 4 to Oct 27, 2026 Strava runs is an owner task (Strava
  export uploaded to intervals.icu), not part of this plan.
- `delete_activity` deletes only `tresfort:activity:` activities, so it can't
  remove a recorded run's intervals.icu copy. Deleting a recorded run in the
  app (P5(d)) removes that copy too, since the owner chose that it removes
  every copy the app made.
- Merging any phase doesn't authorize a Worker deploy or an iOS distribution.
