# Run detail charts

Slug: run-detail-charts · Status: active · Updated: 2026-11-06 · Theme: connected-training

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
- [ ] **P1 — Charts in the app**
  - The run's map sheet becomes its detail: map, then pace, heart rate and
    elevation charts (Swift Charts) sharing one moving-time axis, with a
    shared scrub line reading all three at once. Pace in the member's
    units (min/mi or min/km), speed for a ride; a stopped stretch draws no
    pace. A run with no GPS (treadmill) opens the same detail from its card.
  - Loading, no-data and intervals.icu-unavailable states; nothing is
    cached beyond the open sheet.
- [ ] **P2 — Charts on the web**
  - The same three charts under the web run's route map, as inline SVG with
    a hover read-out, following the Ink palette.
- [ ] **P3 — Heart rate for recorded and Apple Health runs**
  - A new migration adds a private per-activity heart-rate series table in
    a compact delta encoding, filled from the recorder's TCX upload, `.fit`
    imports and the Apple Health stream push, which today keep only
    summaries. Account export includes it; account and activity deletion
    remove it. The endpoint merges it with the stored route.
  - The app re-sends the last year of Apple Health runs' heart-rate streams
    once, so past runs get the chart.
  - Privacy policy and App Store privacy answers updated for the stored
    heart-rate series.

## Execution frontier

- P1

## Dependencies

| Local phase | Relationship | Target | Reason |
|---|---|---|---|
| P3 | coordinates_with | plan:run-recorder | The recorder's upload and summary screen are changing in the same release window; P3 takes the next free migration number after theirs. |
| P3 | coordinates_with | plan:app-store-submission | Storing a heart-rate series changes the App Privacy answers. |

P1 and P2 draw the series P0 serves; P3 adds heart rate to the same
series, so it can follow P1 or run beside it.

## Next step

**Now (@agent):** Build P1, the charts in the app's run detail. P0 reaches
production with the next API deploy, on the owner's written go-ahead.

## Verification evidence

- P0: `test/activity_streams.test.ts` covers steady pace, heart rate and
  elevation; a pause cut from the clock; a short route segment break; the
  500-point cap; heart-rate-only activities; impossible heart rates and GPS
  jumps; elevation gain noise; route and provider sample conversion; the
  endpoint for an intervals.icu run (stores nothing), for an Apple Health
  run's stored route, 404 for another member, 404 with nothing to chart and
  502 when intervals.icu is down.

## Notes / open questions

- Grade-adjusted pace, splits on the chart and heart-rate zones bands are
  later ideas, not in this plan.
- Opening an intervals.icu run asks intervals.icu twice (route and
  streams); fine at a member's pace of use, revisit if it rate-limits.
