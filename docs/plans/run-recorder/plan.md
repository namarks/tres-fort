# Run recorder on iPhone

Slug: run-recorder · Status: active · Updated: 2026-10-30 · Theme: connected-training

## Goal

Let a member record an outdoor run in the Tres Fort iPhone app instead of
Strava. The run gets live time, distance and pace and a GPS route, is saved
to Apple Health, and reaches intervals.icu as a full activity file, so the coach
sees it in the same place as Garmin runs. Recorded distance and pace stay
within the agreed tolerance of a Garmin watch on the same run.

## Phases

- [ ] **P0 — Upload a recorded run to intervals.icu**
  - Add an app-JWT endpoint that accepts one recorded run (a FIT or GPX file
    and its client UUID) and uploads it to the member's intervals.icu account
    through `src/intervals.ts` with external_id `tresfort:recording:<uuid>`.
  - Make retries idempotent on that external_id: a retry that finds the
    activity already there returns it instead of uploading again.
  - Pass the file through without storing the GPS stream in D1. The existing
    activity sync then brings the run into `external_activities`, like any
    other intervals.icu activity.
  - Provider failure is an error with no local fallback. A write 401/403 never
    disconnects the read credential, the same as `log_activity`.
  - Verify with injected-fetcher tests for success, retry, duplicate,
    disconnected, write-forbidden and oversized files. Confirm the
    intervals.icu upload request shape and external_id handling against the
    live API before release.
- [ ] **P1 — Record a run on iPhone**
  - Requires iOS 26 or later, which supports `HKWorkoutSession`,
    `HKLiveWorkoutBuilder` and `HKWorkoutRouteBuilder` on iPhone. On older
    iOS the entry point stays hidden. The app's iOS 17 minimum doesn't change.
  - Start, pause, resume and end an outdoor run. Show elapsed time, distance,
    current and average pace, and a route map. Distance comes from the
    workout builder (Apple's own fusion), never from summing raw GPS points.
  - Ask for When In Use location access and permission to write workouts and
    routes to Apple Health. Both are new permissions, and the Health update
    string must stop saying the app never writes.
  - Save the finished run to Apple Health as an `HKWorkout` with its route.
    The existing Apple Health sync then pushes the summary, and intervals.icu
    wins the 2-minute duplicate match once the uploaded run arrives.
  - Checkpoint the run on the device as it records. A crash or relaunch
    resumes or finishes it without losing samples, and the upload waits in an
    account-scoped outbox until the server acknowledges it.
  - Encode the run (route, timestamps, distance, and heart rate when Health
    has it) into the P0 upload format.
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

## Dependencies

| Local phase | Relationship | Target | Reason |
|---|---|---|---|
| P3 | gated_by | external:owner-run-recorder-device-verification | Real GPS runs on the owner's iPhone need an authorized device build. |
| P1 | coordinates_with | plan:app-store-submission | New location and Health write permissions change the App Privacy answers and review notes. |

Phases run in order: P1 needs P0's upload path, and P2's Live Activity
mirrors P1's session.

## Next step

**Now (@agent):** Build P0 behind injected-fetcher tests, confirm the
intervals.icu upload request shape, and open its PR.

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
- Merging any phase doesn't authorize a Worker deploy or an iOS distribution.
