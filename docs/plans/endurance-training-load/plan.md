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
    threshold is added or deleted.
  - `get_recent_activities` and the coach brief report `load` and
    `load_method` beside the provider's `training_load`.
- [ ] **P2 — Thresholds and load in the app**
  - Profile screen to view, add and correct thresholds with their dates,
    offering the intervals.icu athlete's sport settings as starting values
    when connected; load and its method shown on activity rows and in
    Progress.
- [ ] **P3 — Detail streams from Apple Health and the run recorder**
  - The iOS import reads heart rate, cycling power, cadence and running power
    samples inside each workout, sends compact streams only when they are
    dense enough, and the Worker computes load from them.
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

## Dependencies

| Local phase | Relationship | Target | Reason |
|---|---|---|---|
| P5 | gated_by | external:garmin-starter-api-approval | Garmin's Activity API needs the Starter access requested on 2026-10-31. |
| P1 | coordinates_with | plan:activity-integration-integrity | Both change `external_activities` rows and their resync; dedup rules stay owned there. |

## Next step

**Now (@agent):** P2, the thresholds screen and load display in the app. P0
(PR #298) and P1 are in the repository; P1 is covered by
`test/activity_load.test.ts`. Migrations `0059` and `0060` and the Worker need
the owner's separate go-ahead to reach production.

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
