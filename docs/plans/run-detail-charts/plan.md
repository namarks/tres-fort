# Run detail charts

Slug: run-detail-charts · Status: active · Updated: 2026-11-07 · Theme: connected-training

## Goal

A member opening one of their runs (or rides) in the app or on the web sees
how it went over time: pace, heart rate and elevation charts beside the map,
with the value at any point a tap or drag away, and the climb in meters or
feet. It works without AI and without intervals.icu: a run recorded in the
app or saved to Apple Health by another app has all three charts from data
Tres Fort keeps, and an intervals.icu activity is charted from intervals.icu
without storing its streams. A series the activity has no data for is left
out, never made up. Charts are private to the member, like routes: never in
group views or coach tools.

## Evidence (2026-11-06)

- intervals.icu serves per-second `time`, `distance`, `heartrate`,
  `altitude` and `latlng` streams; the route map (run-recorder P6) already
  reads `time,latlng,altitude` live without storing them.
- `activity_routes` (migration 0063) keeps every GPS fix's time and altitude
  for runs recorded in the app and for Apple Health runs from other apps, so
  pace and elevation can be derived from it.
- No source keeps per-sample heart rate. The recorder's TCX, `.fit` files
  and Apple Health streams are reduced to summaries (migration 0061), and
  the app's local copy of a recording is deleted once the upload is
  acknowledged.
- The owner chose on 2026-11-06 (decision card in thread "Show pace, HR and
  elevation charts for runs") to keep a compact heart-rate series for the
  member's own runs, so recorded and Apple Health runs get a heart-rate
  chart too (P3).

## Phases

- [x] **P0 — Chart series endpoint**
  - `GET /api/activities/:id/streams` (app JWT) returns
    `{ activity_id, source, streams }`, the shape in
    `src/activityStreams.ts`: moving seconds, cumulative meters, speed
    (pace is its inverse), heart rate and smoothed elevation, at most 500
    evenly spaced points of at least five seconds, plus moving time, total
    distance and elevation gain (rises under 3 m ignored).
  - Pauses are cut out of the clock: a route segment break, or a recording
    gap over 30 seconds, adds no time, so the pace either side is true.
  - An intervals.icu activity is read from intervals.icu (heart rate
    included) and not stored. When intervals.icu can't give one, or for a
    recorded or Apple Health run, the stored route gives pace and
    elevation. 404 when there is nothing to chart; 502 when intervals.icu is
    unavailable and there is no stored route.
- [x] **P1 — Charts in the app**
  - Every activity card with series (any intervals.icu activity, every run
    with a route) and a planned run's record show pace, heart rate and
    elevation charts (Swift Charts) below the map, on one axis: distance in
    the member's miles or kilometers, else moving minutes. Touching a chart
    reads its value at that point and marks the same point on the others.
    Pace in min/mi or min/km (faster is up), speed for a ride, elevation in
    feet with miles; standing still or missing data breaks the line, and
    one GPS hiccup is held to the 2nd to 98th percentile.
  - Series load when the card appears and are kept in memory per account
    (`ActivityStreamsStore`); "nothing to chart" is remembered for ten
    minutes and a failed read is tried again. A chart with no data is left
    out.
  - Fix (2026-11-07): on device no card ever showed charts. The read was a
    `.task` on the charts view, which is empty until series arrive, and
    SwiftUI never runs a task on an empty view. `WithActivityStreams` now
    reads them from the whole card, like `WithActivityRoute`.
- [x] **P2 — Charts on the web**
  - The same charts under each completed activity in the web day panel
    (`web/src/ActivityChartsView.tsx`, pure series and paths in
    `web/src/activityCharts.ts`), as inline SVG in the Ink palette for light
    and dark. Pointing at or touching any chart reads all of them at that
    point; with no pointer each shows its average.
- [x] **P3 — Heart rate kept for the member's own workouts**
  - Migration 0068 adds `activity_heart_rates`, one private row per
    workout in the encoding of `src/heartRateSeries.ts`: one whole-bpm
    reading per second of moving time, delta-coded, with the epoch time
    its clock starts at. It is filled from the recorder's TCX upload and
    `.fit` imports (a retry or re-upload can add it to a workout stored
    without one, never replace it) and from an Apple Health workout's
    heart-rate stream push (a later push replaces it, streams with no
    heart rate clear it, a push without streams keeps it). The owner first
    approved runs, then on 2026-11-06 chose every workout with heart rate.
    Account export includes it; account deletion, deleting a recorded run
    (with its Apple Health copies) or a `.fit` import remove it.
  - The endpoint charts it with the stored route, or alone over moving
    time for a workout with no route. Both sources already take pauses
    out of its clock, so it is laid on the route's moving time, shifted
    by the time between the series' start and the route's first GPS fix.
    The app and the web ask for charts on any Apple Health, `.fit` or
    recorded workout with an average heart rate.
  - The app now reads heart rate for every Apple Health workout (only
    runs, rides and heart-rate-scored sports get load from it; others
    keep their load) and re-sends the last year's workouts once (a third
    one-time streams pass), so past workouts get the chart. Runs recorded
    in the app before this release keep no series: the app deleted their
    files once the upload was acknowledged.
  - Privacy policy (website and the Worker's `/privacy`) and the app's
    Apple Health settings text say workouts' heart-rate readings are kept,
    private, and how they are deleted. The App Privacy label already
    declares Health and Fitness data linked to the member for app
    functionality, so its answers don't change.
- [ ] **P4 — Release and check on device**
  - On the owner's written go-ahead for each: apply migration 0068 and
    deploy the API, deploy `tres-fort-web` and the website (privacy
    policy), and upload a TestFlight build after the release check passes
    on its commit.
  - On device: an intervals.icu run, a run recorded in the app and an
    Apple Health run each show their charts, heart rate included, and an
    Apple Health sport (soccer) shows its heart-rate chart; then
    archive this plan. TestFlight 66 and 67 show no charts at all (see the
    P1 fix), so this check needs a build with that fix.

## Execution frontier

- P4

## Dependencies

| Local phase | Relationship | Target | Reason |
|---|---|---|---|
| P3 | coordinates_with | plan:run-recorder | The recorder's upload and summary screen changed in the same release window; P3 took migration 0068, after their 0067. |
| P4 | gated_by | external:owner-release-approval | Production migration, deploys and client distribution each need the owner's written go-ahead. |
| P3 | coordinates_with | plan:app-store-submission | Storing a heart-rate series changes the App Privacy answers. |

P1 and P2 draw the series P0 serves; P3 adds heart rate to the same
series, so it can follow P1 or run beside it.

## Next step

**Now (@owner):** The server side is live (migration 0068 and the API,
web and website deploys went out with the 0dc0ef8 release). Approve in
writing a TestFlight build that carries the P1 loading fix, then check a
recorded run, an intervals.icu run and an Apple Health run show their
charts on device, and archive this plan.

## Verification evidence

- P0: `test/activity_streams.test.ts` covers steady pace, heart rate and
  elevation; a pause cut from the clock; a short route segment break; the
  500-point cap; heart-rate-only activities; impossible heart rates and GPS
  jumps; elevation gain noise; route and provider sample conversion; the
  endpoint for an intervals.icu run (stores nothing), for an Apple Health
  run's stored route, 404 for another member, 404 with nothing to chart and
  502 when intervals.icu is down.
- P1: `ios/TresFortTests/ActivityChartsTests.swift` covers the server's
  series in miles and kilometers, line breaks at standing still and missing
  points, speed for a ride, heart-rate-only activities over moving time,
  the percentile clamp, the scrub read-out, the per-account store and which
  activities ask for series; `testACardOnScreenAsksForItsSeries` hosts a
  card in a window and checks its series are asked for.
- P3: `test/activity_heart_rates.test.ts` covers the encoding, readings on
  moving time lined up with a route across a pause, heart rate alone, an
  route whose first fix came after the start, an Apple Health run's
  series with and without its route (404 for another member), replacing,
  keeping and clearing it on later pushes, another sport's heart-rate
  chart, a `.fit` workout's series and its removal, and the export; `test/run_recording.test.ts` covers a recorded run's
  series, its chart and its removal with the run;
  `test/account_deletion.test.ts` covers account deletion.
- P2: `web/test/activityCharts.test.ts` covers kilometers and miles, speed
  for a ride, heart rate over moving time, nothing to draw, line breaks and
  reversed pace, the percentile clamp, the read-out and which activities
  are charted. A browser render with mocked series was checked in light and
  dark.

## Notes / open questions

- Grade-adjusted pace, splits on the chart and heart-rate zones bands are
  later ideas, not in this plan.
- Opening an intervals.icu run asks intervals.icu twice (route and
  streams); fine at a member's pace of use, revisit if it rate-limits.
