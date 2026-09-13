# Apple Health Weight

Slug: apple-health-weight · Status: gated · Updated: 2026-09-12 · Theme: member-experience

## Goal

Let a member view their Apple Health weight in Tres Fort, including Withings
measurements already shared with Health, with a dated latest reading and a
30/90-day trend. Weight access is a separate opt-in from workout uploads.

## Phases

- [x] **P1 — Implement and verify the private weight view**
  - Request only read access to body mass when the member connects weight.
  - Display kilograms or pounds, source, measurement date, daily latest
    measurements and a trailing seven-calendar-day average of measured days.
  - Replace the in-memory projection on refresh, clear it on disconnect or
    account teardown, and keep permission intent scoped to the signed-in user.
  - Verify calculations, empty/denied reads, deletion refresh, unit switching,
    disconnect races, account isolation, and the native view using synthetic data.
- [ ] **P2 — Verify on an authorized device build**
  - After authorized iOS distribution, connect Weight from Calendar or
    Profile → Connections → Apple Health → Weight on an iPhone with readings.
  - Verify Apple's weight permission sheet, a real dated measurement and its
    source, relaunch/foreground refresh, permission revocation and reconnect.
  - Verify a Withings measurement after it arrives in Apple Health; this does
    not establish that Withings background delivery is immediate or reliable.

## Dependencies

| Local phase | Relationship | Target | Reason |
|---|---|---|---|
| P2 | gated_by | external:owner-ios-distribution | A merged feature is not an installed device build; distribution and personal Health access need their own authority. |

## Next step

**Now (@owner):** After the implementation passes PR review/CI and merges,
authorize an iOS distribution containing it and complete P2 on an iPhone.

## Verification evidence

- `npm run plans:check` passes: 8 current plans, 16 edges, 2 initiatives.
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
  meaning; the separate weight disconnect only clears weight from this view.
- Server/coach access or Intervals weight import would require a separate
  product decision about collection, provenance and consent.
