# Real training load for endurance workouts

Slug: endurance-training-load · Status: active · Updated: 2026-11-01 · Theme: connected-training

## Goal

Every run, ride and swim in Tres Fort carries a real training load, derived
from the athlete's own thresholds, whichever source it came from, without
requiring intervals.icu or an AI coach. Done means:

- a member can set FTP, threshold heart rate and threshold run pace in the app,
  with a history so older workouts keep the threshold that applied then;
- one load engine in the Worker computes power-based load (normalized power,
  intensity, load), heart-rate load and pace load, and labels which method
  produced each number;
- workouts from Apple Health, the Tres Fort run recorder, uploaded `.fit` files
  and (once approved) Garmin get a load from that engine; a load already
  computed by intervals.icu is kept as the provider's figure; and
- a workout with no usable data shows no load, or an effort-based estimate
  that is clearly labeled as one, never a fabricated number.

## Evidence (2026-11-01)

The owner's Apple Health export (May to November 2026) holds no power,
cadence or FTP from any app. Zwift writes heart rate about once every ten
minutes and no workouts; Strava writes workout totals with no heart rate;
Garmin Connect wrote only two of the year's workouts, with heart rate every
two minutes. The run recorded by Tres Fort itself carries heart rate twice a
second, a route and pauses. intervals.icu supplies average and normalized
power, intensity and load for Zwift rides and heart-rate load for Garmin runs.
So Apple Health is a zero-setup floor for "trained, for how long", rich only
for Apple Watch and Tres Fort recordings; power-based load needs files or a
provider connection.

## Phases

- [x] **P0 — Athlete thresholds and the load engine (Worker)**
  - Migration `0059` adds append-only `athlete_thresholds` rows (client UUID,
    sport, metric, value, effective date, source, soft delete): ride FTP and
    threshold heart rate, run threshold heart rate and threshold pace.
  - `GET /api/me/thresholds`, `POST /api/me/thresholds` (idempotent on the
    row id) and `DELETE /api/me/thresholds/:id`; the threshold in effect on a
    date is the latest row on or before it, and the earliest row applies to
    dates before it.
  - `src/trainingLoad.ts` holds pure functions for normalized power, power
    load, heart-rate load from samples (refusing sparse data), pace load and
    average-based fallbacks, plus one selector that applies the order
    provider > power > heart rate > pace and reports the method.
  - Unit tests pin the formulas against hand-computed fixtures; route tests
    cover validation, idempotency, soft delete and per-user isolation.
- [x] **P1 — Apply load to imported workouts**
  - Migration `0060` adds `effective_load`, `effective_intensity` and
    `load_method` to `external_activities`; `training_load` / `intensity`
    stay the provider's figures. Existing provider loads are backfilled.
  - `refreshActivityLoads` computes the rest from the member's thresholds in
    effect on each workout date, writing only changed rows and advancing
    `synced_at` so `/api/state` deltas carry them. It runs after an Apple
    Health push, after each intervals.icu activity sync (whose upsert writes
    provider loads directly, so unchanged rows are never rewritten) and after a
    threshold is added or deleted. Apple Health copies hidden as duplicates
    of an intervals.icu activity are kept current without a new `synced_at`,
    so restoring one shows the right load.
  - `get_recent_activities` and the coach brief report `load` and
    `load_method` beside the provider's `training_load`.
- [x] **P2 — Thresholds and load in the app**
  - Profile → Training thresholds shows the cycling and running values in
    effect today and any value already set for a later date, and lists the
    history. A member adds a value from a chosen date, corrects one (the new
    row is added, then the old one removed) or removes one. Pace is typed per
    mile or kilometer, following the recorder's unit, and stored per
    kilometer. Every change refreshes the app, since the Worker has already
    rescored activities.
  - `ExternalActivity` decodes `effective_load`, `effective_intensity` and
    `load_method`; the day agenda shows the load with its method, and
    Progress → Endurance shows weekly load, per-activity load and a prompt to
    add thresholds when activities have none. An older Worker's provider load
    still shows.
  - Covered by `AthleteThresholdsTests.swift` (history rules matching the
    Worker, pace conversion, validation, request body, correction order,
    failures) and load display and weekly totals tests.
- [x] **P3 — Detail streams from Apple Health and the run recorder**
  - The Apple Health import reads the heart-rate samples inside each run and
    ride, and cycling power for rides, including each reading inside Apple
    Watch series samples. It keeps one writing app's samples (the workout's
    own app when it recorded enough), averages them into whole seconds and
    sends `streams` on `POST /api/activities/healthkit` when at least 30 seconds
    remain. Runs from the Tres Fort recorder reach Apple Health with the
    strap's heart rate, so they take the same path.
  - The Worker validates the streams and reduces them with
    `src/trainingLoad.ts` to threshold-independent summaries (migration
    `0061`: `stream_np_w`, `stream_hr_rms`, `stream_hr_sec`), so a threshold
    change rescores a workout without keeping its samples. A summary scores
    exactly as its stream; a sparse stream (Zwift's heart rate every ten
    minutes) stores nothing and the workout falls back to pace or average heart
    rate. A push without `streams` keeps the stored summaries; an empty one
    clears them.
  - Members connected before this release are asked once for cycling power,
    and runs and rides from the last 365 days are pushed again, once, with
    their streams.
  - Cadence does not change load, and running power is not used because there
    is no running-power threshold; both are left out.
  - Covered by `test/training_load.test.ts` (summary parity, sparse streams,
    selector order), `test/activity_load.test.ts` (scoring, rescoring,
    omitted and empty streams, validation) and
    `HealthWorkoutStreamsTests.swift`.
- [ ] **P4 — `.fit` file import**
  - Upload a `.fit` file (Zwift, any bike computer or watch); the Worker
    parses power, heart rate and speed, computes load, and deduplicates
    against the same workout from other sources.
- [ ] **P5 — Garmin activity files**
  - With Garmin's Starter API approval, receive activity files directly and
    run them through the same engine.
- [ ] **P6 — Effort fallback**
  - A one-tap "How hard was it?" (1 to 10) on imported workouts with no usable
    data gives a session-RPE load, labeled as an estimate.
- [ ] **P7 — Starting values from intervals.icu**
  - When intervals.icu is connected, offer its sport settings (FTP, threshold
    heart rate, threshold pace) as suggestions on the thresholds screen; the
    member confirms each one, and the saved row records `source='intervals'`.

## Dependencies

| Local phase | Relationship | Target | Reason |
|---|---|---|---|
| P5 | gated_by | external:garmin-starter-api-approval | Garmin's Activity API needs the Starter access requested on 2026-10-31. |
| P1 | coordinates_with | plan:activity-integration-integrity | Both change `external_activities` rows and their resync; dedup rules stay owned there. |

## Next step

**Now (@agent):** P4, `.fit` file import, so Zwift rides and other bike
computer or watch files get power load without intervals.icu. P0 to P3 are in
the repository. Migrations `0059`, `0060` and `0061` and the Worker need the
owner's separate go-ahead to reach production, and the app's thresholds
screen needs that Worker before it can load.

## Notes / open questions

- The calendar's scheduling heuristic still reads only planned events'
  provider load; using effective load there would change the Swift parity
  contract and is left for a separate decision.
- The owner chose on 2026-11-01 that endurance workouts need real load
  ("otherwise a serious athlete won't use my app"). This plan is outside the
  [Connected Training](../../initiatives/connected-training.md) initiative,
  whose priority policy keeps missing load unknown rather than adding a
  physiology engine; that rule still holds for workouts with no usable data.
- Heart-rate load uses (heart rate / threshold heart rate)² per second, so one
  hour at threshold is 100, matching the power and pace scales. It is not
  identical to intervals.icu's TRIMP-based figure; when intervals.icu supplies
  a load, Tres Fort shows that instead.
- Zwift has no public API; until Zwift approves partner access, Zwift power
  arrives through intervals.icu or a `.fit` upload.
- Strava's API terms forbid feeding its data to AI, which conflicts with the
  coach; no direct Strava connection is planned.
- Production migration, Worker deployment and client distribution need the
  owner's separate go-ahead.
