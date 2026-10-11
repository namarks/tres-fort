# Progress and Apple Health Weight

Slug: apple-health-weight · Status: gated · Updated: 2026-10-11 · Theme: member-experience

## Goal

Let a member view their Apple Health weight in Tres Fort, including Withings
measurements already shared with Health, with a dated latest reading and a
30/90-day trend. Bring strength, optional weight and completed-workout
consistency together in a Progress tab. Weight access stays an optional data
permission under the existing Apple Health connection, separate from workout
upload permission.

## Phases

- [x] **P1 — Implement and verify the private weight view**
  - Request only read access to body mass when the member connects weight.
  - Display kilograms or pounds, source, measurement date, daily latest
    measurements and a trailing seven-calendar-day average of measured days.
  - Replace the in-memory projection on refresh, clear it on disconnect or
    account teardown, and keep permission intent scoped to the signed-in user.
  - Verify calculations, empty/denied reads, deletion refresh, unit switching,
    disconnect races, account isolation, and the native view using synthetic data.
- [x] **P3 — Bring training trends into Progress**
  - Add a Progress tab with recent lifts, per-exercise trends/best sets,
    completed-workout consistency and optional Apple Health weight.
  - Keep Calendar focused on dates, recorded training and weekly scheduling.
  - Manage Read weight in Profile → Connections → Apple Health, with a shortcut
    from Progress to the same settings. Do not add a second provider connection.
  - Verify civil-week boundaries, completed-state filtering, cached history,
    navigation, permission changes and accessibility text using synthetic data.
- [x] **P4 — Make weight connection failures recoverable in place**
  - Show a specific explanation for locked Health data, access requests,
    restrictions and unavailable Health; do not describe every read failure as
    a locked phone or infer permission denial from an empty result.
  - Offer Reconnect Apple Health on the Weight and Apple Health settings
    screens without requiring an off/on toggle; retry a locked read directly.
  - Keep permission help collapsed until needed, preserve account-scoped
    intent, and reject recovery callbacks after disconnect or sign-out.
- [x] **P5 — Lead Progress with consistency**
  - Open Progress on a consistency card instead of the recent-lift list: the
    current weekly streak, this week's completed workouts against the recurring
    schedule when one is set, and a Monday–Sunday day grid of completed
    workouts (16 weeks on iPhone, 52 on iPad). Strength and Weight follow.
  - A streak counts consecutive weeks with at least one completed native
    workout; an empty current week keeps it until Sunday ends. The detail view
    adds the best streak, days trained and the same grid for 8, 16 or 26 weeks.
  - Keep the existing projection rules: civil dates, current completed records
    only, no imported activities and no new storage. Verify streaks, day grid,
    schedule count and the Progress order with model tests and journeys.
- [ ] **P2 — Verify on an authorized device build**
  - After authorized iOS distribution, enable Read weight in Profile →
    Connections → Apple Health, then open Progress → Weight on an iPhone with readings.
  - Verify Apple's weight permission sheet, a real dated measurement and its
    source, relaunch/foreground refresh, permission revocation and reconnect.
  - After P4 is merged and included in an authorized distribution, verify its
    inline recovery on the device; simulator fixtures do not prove that a real
    HealthKit failure or permission change is repaired.
  - Verify a Withings measurement after it arrives in Apple Health; this does
    not establish that Withings background delivery is immediate or reliable.

## Dependencies

| Local phase | Relationship | Target | Reason |
|---|---|---|---|
| P2 | gated_by | external:owner-apple-health-device-verification | Build 42 carries the merged feature to internal TestFlight testers; enabling personal Health access and observing real readings on the owner's iPhone need their own authority. |

## Next step

**Now (@owner):** Complete P2 on an iPhone running TestFlight 1.0 (42) or a
later build: enable Read weight in Profile → Connections → Apple Health, open
Progress → Weight, and record the permission sheet, a real dated measurement
and its source, relaunch/foreground refresh, revocation/reconnect and a
Withings-sourced reading. P4's recovery is implemented in this branch but has
not been distributed; its real-device recovery check requires a later authorized
build containing the change.

P1 merged in [PR #196](https://github.com/namarks/tres-fort/pull/196) on
2026-09-12 and P3 in [PR #197](https://github.com/namarks/tres-fort/pull/197) on
2026-09-13, both Pacific dates. Both are
ancestors of build 42's source `5df9208fc01219f298866ee4528cda533b86d33d`, which
the [release 42 receipt](../app-store-submission/release-42.md) records as VALID
and assigned to internal Testers on 2026-09-14 Pacific. That distribution
satisfies only the installed-build precondition; Health permissions, readings
and Withings delivery on a real device remain unverified.

## Verification evidence

- P5 came from Nick's 2026-10-11 report that Progress opened on a plain list of
  exercises with no sign of progress, and that a consistency visual should come
  first. Its delivering PR carries the model tests, the updated Progress journey
  and exact-head CI; it is not in an authorized distribution yet.

- P4 was prompted by the owner's 2026-10-04 report that switching Read weight
  off and on seemed to restore readings. The earlier screen used an unlock
  instruction for every read error, so that report does not identify the
  underlying HealthKit error or complete P2's device matrix.
- P4 local verification passed 21 unit tests, seven Weight journeys and five
  Progress regression journeys using synthetic data on a disposable iPhone 16e /
  iOS 26.2 simulator on 2026-10-04. Recovery tests cover repeated authorization, read-only retry,
  failed initial authorization, preserved opt-in, opaque empty reads and late
  callbacks after disconnect or account replacement. Source manifests, native
  screenshots and test results are retained with the local verification evidence;
  exact-head review and required CI remain recorded on the implementation PR.

- P3 passed a disposable iPhone 17 / iOS 26.2 unsigned build and 30 focused
  checks on 2026-09-13: 22 calculation/lifecycle tests and eight UI journeys.
  These cover civil-week boundaries, current completed records, weight
  permission/refresh/removal, five-year cached exercise history, sparse trend
  selection, all Progress drill-downs, empty history and accessibility text.
  The three Progress journeys passed again after final heading/date-label
  refinements. Its source manifest is retained with the local build evidence.
  A review correction makes Apple Health settings read current workout-sharing
  status on every entry instead of inferring false from an unloaded Profile.
  Missing or failed reads stay unknown with retry; existing sharing remains
  removable when workout sync is disconnected. Three sharing-read model tests
  and five Progress journeys cover recovery, account boundaries and saved
  opt-out. The final source manifest and exact-head review/CI evidence are
  retained with the implementation PR and local verification artifacts.

- `npm run plans:check` passed on 2026-09-18: 8 current plans, 23 edges, 2 initiatives.
- Disposable iPhone 17 / iOS 26.2 build and focused tests passed on 2026-09-12:
  78 account/auth tests, 13 weight calculation/lifecycle tests, and 2 weight UI
  journeys (93 total, zero failures). The UI journeys exercise connection,
  kilograms/pounds, 30/90-day selection, removal of visible source data,
  disconnect and the empty state at accessibility text sizes.
- Local command: `IOS_KEEP_RESULTS=1 npm run ios:verify -- --runtime
  com.apple.CoreSimulator.SimRuntime.iOS-26-2 --device
  com.apple.CoreSimulator.SimDeviceType.iPhone-17 --only-testing
  TresFortTests/BodyWeightHistoryTests --only-testing
  TresFortTests/BodyWeightModelTests --only-testing TresFortTests/AuthModelTests
  --only-testing TresFortUITests/BodyWeightJourneyTests`.
- These are synthetic simulator results. Actual Health permissions, real
  Withings delivery and installed-device behavior remain P2 evidence.

## Notes / open questions

- Nick selected Apple Health weight on 2026-09-12 after considering direct
  Withings and Intervals ingestion. This slice reads Health on the iPhone;
  it does not add a provider account, server collection, AI access, group
  sharing, manual entry or Health write-back.
- Health remains the measurement store. Samples are held in memory only;
  the sole new persisted value is an account-scoped connection preference,
  removed by account-deletion cleanup. Account JSON exports contain no weight.
- The view reads the last 96 calendar days plus the latest historical sample.
  An older measurement retains its date and is excluded from current averages.
  Daily selection uses the latest timestamp, not a sum across Health sources;
  source priority selection is not part of this slice.
- Apple conceals read-denial status. Finishing the permission sheet records
  intent only. Empty results explain both missing data and permission checks.
- Workout-sync connection and group-sharing controls retain their existing
  meaning; turning off Read weight clears the private weight projection.
- Server/coach access or Intervals weight import would require a separate
  product decision about collection, provenance and consent.

- On 2026-09-13 Nick approved a dedicated Progress tab after clarifying that
  Apple Health already supplies the connection. P3 reuses exercise metrics and
  load/mode cohorts. Its consistency chart counts completed native workout
  records by civil date, uses Monday–Sunday weeks and labels the partial current
  week. Imported and separately logged activities remain in Calendar; the chart
  does not claim an all-sport completion rate or compare against a scheduled goal.
