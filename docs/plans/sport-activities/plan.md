# Capture every sport properly

Slug: sport-activities · Status: active · Updated: 2026-11-04 · Theme: connected-training

## Goal

Every session a member does, not only lifts, runs and rides, lands in Tres
Fort as the sport it was, with the details that matter for that sport and a
load the member can trust, whether it came from Apple Health, intervals.icu,
a `.fit` file or the member's own hand entry, and without an AI coach. Done
means:

- a soccer match, tennis set, climbing session or swim shows as that sport
  (name and icon) in Today, the Activity tab, the day view and the group feed,
  never as "Workout" or "Other";
- a planned activity on the week ("Soccer every Monday") is marked done when
  the watch recorded that sport that day, whatever the watch called it;
- any sport with heart rate gets a heart-rate load, and any sport without
  data can get a clearly labeled effort estimate from one tap or from Apple
  Watch's effort score;
- a member can log a sport by hand with the fields that sport needs, and it
  is kept in Tres Fort whether or not intervals.icu is connected; and
- a swim keeps its pool, length count, distance, pace per 100, strokes per
  length and stroke types when the source has them, and can be entered by hand
  as pool length plus lengths.

## Evidence (2026-11-03)

What Tres Fort does today:

- Every importer reduces a workout to a coarse `kind` (ride, run, swim, walk,
  hike, row, ski, yoga, elliptical, strength, other): `kindOf` in
  `src/intervals.ts`, `fitKind` in `src/fitFile.ts` and
  `HealthKitSyncModel.kind(for:)`. Soccer, basketball, tennis, pickleball,
  climbing and every other sport become `other`, and an Apple Health import
  of one is titled "Workout". Cross-source dedup matches on `kind` plus start
  time, so `kind` cannot simply grow finer without changing all three
  importers and older app builds in lockstep.
- Apple Health imports keep the HealthKit activity type number in `raw`
  (`hk_activity_type`), and intervals.icu rows keep the provider's JSON, so
  the real sport of existing rows can be recovered.
- Today's "Log Soccer" (app-design-pass P7) counts as done only when an
  activity on that date carries the same name, so an Apple Watch soccer
  workout ("Workout") or an intervals.icu one ("Evening Soccer") is missed.
- The hand-entry sheet offers ten types (pilates, cardio, yoga, walk, hike,
  run, ride, swim, lift, other). Run, ride, swim and walk go to intervals.icu
  only (`POST /api/activities/endurance`); without intervals.icu they fall
  back to the local `activities` log, which keeps type, title, minutes and
  notes but no distance, pool or heart rate.
- Load: `thresholdSportFor` scores only rides and runs; swims and other
  sports carry only a provider's load. The Apple Health import reads
  heart-rate samples only for runs and rides, so a soccer match recorded on a
  watch has average heart rate but no heart-rate load.

What the sources can give (to confirm against real rows in each phase):

| Source | Sport identity | Swim detail | Effort |
|---|---|---|---|
| Apple Health | About 80 `HKWorkoutActivityType`s (soccer, basketball, tennis, pickleball, climbing, hockey, rugby, …) | Pool length (`HKMetadataKeyLapLength`), pool or open water, lap and segment events with stroke style, stroke count and swim distance; Apple Watch writes them, Garmin Connect writes far less | Apple Watch effort score (iOS 18, 1 to 10) |
| intervals.icu | Strava-style `type` (Soccer, Tennis, Swim, OpenWaterSwim, …) | Pool length and length count on the activity; per-length strokes to be checked against a real synced swim | The member's own RPE and feel when entered there |
| `.fit` file | FIT `sport` and `sub_sport` (soccer, tennis, basketball, lap or open-water swimming, …) | Session pool length, active lengths and strokes; one length message per length with stroke type and stroke count | None |

## Phases

- [x] **P0 — Name every sport**
  - `src/sports.ts` holds the sport list (id and label) and the maps from
    Apple Health activity types, intervals.icu `type` and FIT sport and
    sub-sport. `ios/TresFort/Sports.swift` mirrors it with icons; both are
    pinned to `ios/TresFortTests/Fixtures/Sports.json`
    (`test/sports.test.ts`, `SportsTests.swift`).
  - Migration `0064` adds `external_activities.sport` beside `kind`, which
    stays coarse so dedup and older app builds are unchanged. The
    intervals.icu sync, Apple Health push, `.fit` import and run recorder set
    it. The Worker derives an Apple Health workout's sport from the activity
    type the app keeps in `raw`, so older builds get named sports too, and an
    Apple Health workout an older app called "Workout" takes its sport's
    name. The migration backfills existing rows the same way (its lookup
    tables are tested against `src/sports.ts`) and moves live rows' cursor so
    installed apps receive the sport.
  - The app names and draws each activity by its sport in the Activity tab,
    day view, Today and the group feed; the log sheet offers every sport
    (local `activities.type` uses the same ids); a planned activity named for
    a sport ("Soccer") counts as done when a workout of that sport was
    recorded that day, whatever the watch called it.
  - `get_recent_activities`, the coach brief, the group feed and the web
    calendar report or show the sport.
- [x] **P1 — Heart-rate load for any sport**
  - `HEART_RATE_THRESHOLDS` in `src/sports.ts` (pinned to `Sports.json`,
    mirrored as `Sports.heartRateScored`) names whose threshold heart rate
    scores each sport: on-foot and court, field, racquet, snow and combat
    sports use the run one, rides the ride one. Swims, strength, mind-body,
    rowing, paddling, golf and other sports get none.
  - `refreshActivityLoads` (`thresholdSetFor`) gives those sports only the
    threshold heart rate, never pace or power, so a match's distance or a
    hike's pace never decides its load. Heart-rate samples win over the
    average; sparse samples still store nothing, as in
    endurance-training-load P3. The compare-and-swap also checks `sport`.
  - The Apple Health import reads heart-rate samples for those sports, and a
    second one-time pass pushes the last 365 days of them again with
    samples (`healthSportStreamsBackfillKey`). Heart rate is already an
    allowed Apple Health read, so no new permission is asked. Existing rows
    from other sources are rescored on their next sync or threshold change.
- [x] **P2 — Effort when there is no data**
  - Delivers endurance-training-load P6 for every sport. Migration `0065`
    adds `external_activities.effort`, the member's own 1 to 10 "How hard was
    it?", and widens `load_method` to include `effort` (SQLite can't change
    a CHECK in place, so the column is replaced; values and `synced_at` are
    unchanged).
  - The scale is fixed in `src/trainingLoad.ts` (`EFFORT_SCALE`,
    `effortLoad`): session effort, minutes × rating, scaled so one hour at
    effort 7 ("very hard", about an hour at threshold) is 100; intensity
    stays unknown. `selectLoad` uses it last, so a provider, power,
    heart-rate or pace load always wins, and moving time falls back to
    elapsed time. Covered by `test/training_load.test.ts`.
  - `PUT /api/activities/:id/effort` (`setActivityEffort`) rates a live
    workout or clears it with null, writing the row and the copies hidden as
    its duplicates, then rescores the day. Importers never send or
    overwrite the rating. A shown copy without a rating takes a hidden
    copy's, and a hidden copy without one takes the shown copy's, so a
    rating survives whichever source delivers the same workout later and
    a restore when the shown copy goes away. Covered by
    `test/activity_load.test.ts` ("effort rating").
  - The day view shows ten one-tap buttons on any workout without a measured
    load (and keeps them once the rating scores it, to change or clear); the
    load is labeled "effort estimate" in the app and "estimated from your
    effort rating" on the web (`EffortRating.swift`,
    `EffortRatingTests.swift`).
  - The coach's `rate_activity` records a rating the member gives, and
    `get_recent_activities` reports `effort`, so app and coach stay at
    parity.
- [ ] **P3 — Log any sport by hand, kept in Tres Fort**
  - The log sheet gets a searchable sport list (the member's recent and
    planned sports first) and shows each sport's fields: time and effort
    always; distance for distance sports; pool or open water, pool length and
    lengths for swims; optional average heart rate.
  - Hand-entered sessions are stored in Tres Fort (proposed: an
    `external_activities` row with `source='manual'`, so load, dedup, the
    Activity tab and the group feed treat them like any workout). When
    intervals.icu is connected, runs, rides, swims and walks are also copied
    there under the existing `tresfort:activity:` marker and the copy is
    hidden as a duplicate. The owner chose this on 2026-11-03 ("In Tres
    Fort, copy to intervals"), replacing today's intervals.icu-only route for
    hand-entered endurance.
  - The coach's `log_activity` takes the same fields, so app and coach stay at
    parity.
- [ ] **P4 — Swimming detail**
  - Import pool or open water, pool length, lengths, distance, strokes and
    stroke types from Apple Health, `.fit` files and intervals.icu, kept as a
    swim summary plus one row per length or interval (new migration).
  - A swim threshold (critical swim speed, per 100 m or 100 yd) joins
    Training thresholds, and swims get a pace load from it.
  - The day view shows a swim's distance, pace per 100, lengths, strokes
    per length, SWOLF and a stroke breakdown; Activity history lists swims
    with distance and pace.
- [ ] **P5 — Apple Watch's effort score**
  - Split from P2 on 2026-11-04 because it needs a new Apple Health
    permission. Read Apple Watch's workout effort score (iOS 18, 1 to 10)
    from Apple Health when the member allows it, as the provider's rating
    beside the member's own, which wins when both exist; either gives the
    `effort` load. Needs the owner's go-ahead on the permission.

## Dependencies

| Local phase | Relationship | Target | Reason |
|---|---|---|---|
| P0 | coordinates_with | plan:activity-integration-integrity | Both change `external_activities` rows; dedup rules stay owned there and keep matching on `kind`. |
| P2 | coordinates_with | plan:endurance-training-load#P6 | This phase delivers that phase for every sport; it closes there when this merges. |
| P5 | gated_by | external:owner-new-health-permission | Reading Apple Watch's effort score is a new Apple Health permission. |
| P4 | gated_by | external:owner-new-health-permission | Swim stroke counts are a new Apple Health permission. |

## Next step

**Now (@agent):** P3, logging any sport by hand and keeping it in Tres Fort
(intervals.icu an optional copy, owner's choice of 2026-11-03), with the
effort rating among its fields. P0, P1 and P2 are in the repository; P0 and
P1 are live on the API and the web app (see Release), and their app build
waits for the release check. P2's migration `0065`, its Worker deploy and an
app build each need the owner's separate go-ahead, in that order (`0065`
before the Worker). P5, Apple Watch's effort score, waits for the owner's
go-ahead on that Apple Health permission.

## Release

- 2026-11-04, with the owner's written go-ahead, from main `110e5f4` (P0
  and P1): migration `0064` applied to `tres-fort-db` (nothing left
  pending), the API Worker deployed as version `5823c2a3` (rollback
  `7c97d561`) and `tres-fort-web` as `bd5ae050` (rollback `b3223134`).
  After the backfill, production rows named 15 sports, among them soccer
  (13), squash (12), yoga (12), hiit (121) and other (122).
- The app build (TestFlight) follows once the release check passes on
  `110e5f4`; App Store 1.0 stays on build 55.

## Notes / open questions

- Not in this plan: planning other sports with targets (a planned swim set
  or a 90-minute match with an effort goal), team or match stats (goals,
  scores, positions) and Garmin's direct API (endurance-training-load P5).
  Each can follow if the owner wants it.
- App Store 1.0 stays on build 55. Each phase's Worker deploy, migration and
  app build needs the owner's separate go-ahead, and the new Apple Health
  permissions change the App Store privacy answers for the next version.
- Older app builds keep sending `kind` only; the Worker derives `sport` from
  the HealthKit type in `raw`, so they still get named sports.
- Older app builds can't rate a workout, and show a rated workout's load
  without the "effort estimate" label (an intervals.icu one as
  "intervals.icu").
- The rating is the member's own and stays out of the group feed, which
  lists only the provider's load.
- intervals.icu's swim and per-length fields are checked against the owner's
  own synced rows before P4 relies on them; anything missing stays unknown,
  never estimated.
