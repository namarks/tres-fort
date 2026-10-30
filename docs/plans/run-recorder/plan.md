# Run recorder on iPhone

Slug: run-recorder · Status: active · Updated: 2026-10-30 · Theme: connected-training

## Goal

Let a member record an outdoor run in the Tres Fort iPhone app instead of
Strava. The run gets live time, distance and pace and a GPS route, is saved
to Apple Health, and reaches intervals.icu as a full activity file, so the coach
sees it in the same place as Garmin runs. Recorded distance and pace stay
within the agreed tolerance of a Garmin watch on the same run.

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
- [ ] **P1 — Record a run on iPhone**
  - [x] **(a) Keep and upload recorded runs on the device**
    - `RecordedRun` holds the route, heart-rate samples, the workout
      builder's distance and moving time, and the device-local civil date.
    - `RecordedRunGPX` encodes it as GPX 1.1 with heart rate in the Garmin
      TrackPointExtension, attached only within 5 seconds of a point.
    - `RunRecordingStore` keeps one file per run in an account-scoped,
      backup-excluded directory until the server acknowledges the upload.
      Files use `completeUntilFirstUserAuthentication` so checkpoints still
      save with the phone locked mid-run. Account deletion removes them.
    - `RunRecordingUploader` sends finished runs to P0's endpoint as
      multipart GPX, removes each only after a 200/201, keeps failures for
      the next attempt and stops on a rejected bearer.
  - [ ] **(b) Record with a workout session**
    - Requires iOS 26 or later, which supports `HKWorkoutSession`,
      `HKLiveWorkoutBuilder` and `HKWorkoutRouteBuilder` on iPhone. On older
      iOS the entry point stays hidden. The app's iOS 17 minimum doesn't
      change. Keep it out of the App Store build until P3 passes.
    - Start, pause, resume and end an outdoor run. Show elapsed time,
      distance, current and average pace, and a route map. Distance comes
      from the workout builder (Apple's own fusion), never from summing raw
      GPS points.
    - Ask for When In Use location access and permission to write workouts
      and routes to Apple Health. Both are new permissions, and the Health
      update string must stop saying the app never writes.
    - Save the finished run to Apple Health as an `HKWorkout` with its
      route. The existing Apple Health sync then pushes the summary, and
      intervals.icu wins the 2-minute duplicate match once the uploaded run
      arrives.
    - Checkpoint the run into (a)'s store as it records. A crash or relaunch
      resumes or finishes it without losing samples, and finished runs
      upload on finish, launch and foreground.
- [ ] **P2 — Run from the Lock Screen**
  - Show a Live Activity with time, distance and pace, plus pause and end
    controls, from the existing widget extension.
  - Give optional spoken split announcements per kilometre or mile.
- [ ] **P3 — Verify accuracy and reliability on a real device**
  - Record at least three outdoor runs on the owner's iPhone at the same time
    as the Garmin Forerunner 945 (open sky, trees or buildings, and a run with
    pauses). Record distance, moving time and average pace from both.
  - Accept when distance is within 2% of the Garmin on the open-sky run and
    within 4% on the others, unless the owner sets a different tolerance.
  - Verify a locked phone for the whole run, a force-quit mid-run, no network
    at the end, and that the upload and Health save each land once.
  - Confirm against the live intervals.icu API that the first real upload
    creates one activity carrying the recording external_id and name, and
    that a retry returns it. P0's request shape (query-string `name` and
    `external_id`, multipart `file`, 201 created or 200 duplicate) comes
    from intervals.icu's API conventions and has only been tested against
    mocks.

## Dependencies

| Local phase | Relationship | Target | Reason |
|---|---|---|---|
| P3 | gated_by | external:owner-run-recorder-device-verification | Real GPS runs on the owner's iPhone need an authorized device build. |
| P1 | coordinates_with | plan:app-store-submission | New location and Health write permissions change the App Privacy answers and review notes. |

Phases run in order: P1 needs P0's upload path, and P2's Live Activity
mirrors P1's session.

## Next step

**Now (@agent):** Build P1(b), the iOS 26 workout-session recorder and its
screen, writing into P1(a)'s store and uploader, behind simulator tests.

P0 is delivered in the repository by the PR that checked it. Its Worker
deploy needs separate authority, and its live upload check is part of P3.

## Verification evidence

- P0: `test/run_recording.test.ts` covers format detection, upload with the
  recording external_id and name, retry by external_id, provider duplicate,
  write rejection with the read credential kept, provider 5xx/4xx and lookup
  failure, a member without a connection, form validation and the 10 MB
  limit, all against mocked intervals.icu responses.
- P1(a): `ios/TresFortTests/RunRecordingTests.swift` covers civil dates,
  GPX track points, elevation, heart-rate matching and escaping, the
  multipart body, per-account storage, checkpoint replacement, damaged
  files, account deletion, and upload acknowledgement, failure and 401.

## Notes / open questions

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
