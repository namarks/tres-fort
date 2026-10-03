# iPad Workout Station

Slug: ipad-workout-station · Status: active · Updated: 2026-10-03 · Theme: gym-floor

## Goal

Let a member use a stationary iPad as a readable workout display and movement
tracker while their main phone remains free. First establish camera placement
and counting quality in an observation-only trial; only validated later slices
may turn detections into durable workout actions.

## Phases

- [ ] **P0 — Deliver the observation-only Station Mode comparison**
  - Enable native iPad support and a responsive landscape/portrait display.
  - Enter from Today on iPad; request camera access only on explicit action.
  - Process the front camera locally with Vision and experimental angle-cycle
    counters for squat, curl and bench press. Do not record or upload frames.
  - Feed each accepted Vision pose and timestamp to the custom baseline and
    Apple HumanBodyActionCounter. Show both counts, Apple warm-up/coverage and
    reporting timing, with optional manual ground truth after the trial.
  - Bound queued work, fence late results by trial identity and make incomplete
    coverage or inference failure visible. Stop and reset both together.
  - Keep trials isolated from SyncModel writes, outboxes, rest and progression.
  - Stop/invalidate tracking across missing joints, additional people, camera
    interruption, rotation, backgrounding and view exit. Never infer completion
    from target reps or lost tracking.
  - Verify deterministic counting/loss scenarios, iPad navigation/layout and
    iPhone regressions; complete exact-head review and repository checks.
- [ ] **P1 — Compare existing counters and validate the mounted iPad**
  - Treat the custom angle counter as a baseline, not the selected production
    algorithm. Compare it with Apple HumanBodyActionCounter in the first
    device build. Consider the MediaPipe reference pipeline if pose quality
    limits the results; it is not part of the first comparison build.
  - On an authorized device build, compare counts to manual ground truth for
    all three modes, including slow/paused/partial reps and obstructed views.
  - Evaluate landscape camera placement, screen readability, tracking recovery,
    a workout-length thermal/power trial and continued use of the main phone.
  - Record count errors, corrections and setup/repositioning effort. Select the
    supported movements/angles from observed evidence, not assumed accuracy.
- [ ] **P2 — Add assisted set completion and correction**
  - Define one authoritative workout controller, stale-event rejection and a
    stable event identity before observations can enter the existing set path.
  - Add confirmed set completion, rest and progression with easy correction;
    choose a hands-free confirmation mechanism based on the physical trial.
- [ ] **P3 — Enable measured automatic progression**
  - Establish explicit acceptance thresholds for premature completion, exact
    counts and required corrections; validate them before enabling auto-log.
  - Preserve manual recovery, device takeover and offline/reconnect integrity.

## Dependencies

| Local phase | Relationship | Target | Reason |
|---|---|---|---|
| P1 | gated_by | external:owner-ipad-station-device-build | Internal build 45 is verified available to Testers; physical evaluation still requires owner participation. |
| P2 | gated_by | external:owner-ipad-station-write-contract | Confirm the supported movements, correction UX and multi-device controller policy before enabling workout writes. |
| P3 | gated_by | external:owner-ipad-station-automation-criteria | Automation needs explicit measured quality criteria and activation authority. |

## Next step

**Now (@agent):** Complete P0 repository delivery after all configured CI and
review of the current PR head pass. Internal TestFlight build 1.0 (45) is
verified available to Testers; that upload does not satisfy repository merge
gates. P1 physical evaluation remains behind
`external:owner-ipad-station-device-build` until the owner can participate; the
build-availability portion of that gate is satisfied. Support that trial when
the owner is ready. The later workout-write and automation gates remain in force.

## Approved comparison scope

- On 2026-10-03 the owner approved making the first device-test build compare
  the custom counter and Apple counter side by side on the same movements.
- This authorizes comparison implementation and the internal device-test build.
  It does not authorize public App Store release, backend deployment, workout
  logging, automatic progression or video storage/upload.
- The owner subsequently requested TestFlight upload while the Mac checks were
  queued. The independently reviewed source was uploaded as an internal branch
  build; repository merge still requires its configured checks and review.
- MediaPipe remains a later candidate, not an included dependency.

## Implementation evidence

- Native iPad layout, opt-in local capture and both isolated trial counters are
  implemented. Each trial locks the initially visible exercise-relevant limb
  (hip/knee/ankle or shoulder/elbow/wrist) for both counters. Confidence 0.6 and
  this joint subset are prototype policies, not vendor-calibrated thresholds.
- Independent local review of the comparison found no blocking issues.
- iPad A16 / iOS 26.2 simulator: 17 custom-counter cases, 15 comparison lifecycle
  and window cases, and three interface journeys passed. Synthetic screenshots
  show both readouts in landscape and reachable controls at accessibility size.
  Results: `.artifacts/ios/tres-fort-ios.BGHY55/Tests.xcresult`.
- A temporary macOS smoke harness exercised the actual Apple model and received
  a result for a synthetic 90-pose window. This checks API invocation and output
  pairing, not A16 performance or movement accuracy.
- CI now includes a dedicated iPad Station job in the existing aggregate gate.
  Coverage selection and verification-harness checks pass (7 and 12 tests).
- iPhone 17 / iOS 26.2: 710 unit tests passed, one skipped. Results:
  `.artifacts/ios/tres-fort-ios.ZcoJKY/Tests.xcresult`. Three navigation/set-logging
  journeys also passed in `.artifacts/ios/tres-fort-ios.JygNuE/Tests.xcresult`.
- All 16 comparison cases passed in a focused native XCTest run after adding
  populated-pose parity coverage. The assertion uses Apple's documented zero-
  masking for unselected joints and requires selected coordinates/confidence to
  remain exact. Production code was unchanged after the simulator checks.
- All 16 comparison cases also passed on the iPad A16 simulator from exact
  source `cfcdf87a6c663f2f4d678e09422ed424cc181ae1`. Results:
  `.artifacts/ios/tres-fort-ios.uInGdt/Tests.xcresult`.
- [Independent GitHub review](https://github.com/namarks/tres-fort/pull/228#issuecomment-5973527266)
  found no major issues at that exact source. Backend/plan CI passed; seven Mac
  jobs were queued at upload, and PR #228 remains unmerged.
- Apple validation and upload of 1.0 (45) succeeded on 2026-10-03. At
  `2026-10-03T21:18:16.656Z`, Apple confirmed VALID / IN_BETA_TESTING and internal
  Testers assignment; see the [build receipt](../app-store-submission/release-45.md).
  No physical camera accuracy is established yet.

## Acceptance and verification

- Entering Station Mode does not start a workout or request camera access.
- Exercise selection, trial start/stop and all detections cannot write a set.
- The custom counter requires a stable extended position, flexion and return
  to extension on one visible side. Apple supplies a separate fractional
  estimate from temporal pose windows. Neither result is a form, depth, safety
  or training-quality assessment.
- Apple's first window needs 90 poses and then advances every five. Normal stop
  drains queued windows for up to five seconds; an uncovered final 1–4 poses,
  tracking loss or engine failure leaves the trial visibly incomplete. No
  synthetic poses fill the tail and no missing estimate is presented as zero.
- Low-confidence joints, multiple people and camera gaps cannot bridge a rep.
- Rotation invalidates the current trial; returning to the foreground requires
  explicit camera/trial restart. Exiting releases camera and idle-timer policy.
- All station controls remain reachable at accessibility sizes and in portrait.
- Unit fixtures and simulator journeys prove logic/layout only. Real camera
  accuracy, performance, interruptions and exercise coverage remain P1 evidence.

## Algorithm comparison before assisted logging

The prototype reuses Apple Vision for pose estimation but implements its own
exercise-specific angle-cycle counter. No comparison has established that this
counter, or Vision, is the best available choice. Apple is approved as the first
comparison engine. MediaPipe and RepNet remain candidates for later evaluation;
no production winner is selected:

1. **Apple HumanBodyActionCounter:** pretrained repetition counting and an
   official native sample; test its temporal-window latency and treatment of
   slow reps, pauses and partial cycles. The framework is proprietary even
   though Apple supplies reusable sample source.
2. **MediaPipe Pose Landmarker plus Google's reference pose classifier/counter:**
   the primary open-source mobile alternative. Native iOS live-stream support
   and estimated 3D landmarks are available; the pose model itself does not
   count reps. The published classifier example covers push-ups and squats and
   needs representative pose examples for other movements. The reference
   counting implementation is Android/Python; native Swift needs adaptation.
3. **RepNet:** a secondary research comparator for general video periodicity.
   Do not assume an iPad-ready implementation or that generic repetition counts
   identify valid exercise cycles and set completion.

Compare complete-set exact counts, false counts during setup/rest/partial reps,
slow and paused lifts, bench/rack occlusion, tracking loss and recovery, latency,
thermal/power cost and camera placement effort. Use permitted labeled inputs and
live manual ground truth; the current no-recording/no-upload behavior remains.
Evaluate pose tracking separately from repetition logic so a better detector is
not confused with a better counter. Selection must follow results on the A16
station and supported exercises, not generic pose benchmarks or demo claims.

Sources checked 2026-10-03:

- [Apple counting sample](https://developer.apple.com/documentation/createmlcomponents/counting-human-body-action-repetitions-in-a-live-video-feed)
- [MediaPipe native iOS guide](https://developers.google.com/edge/mediapipe/solutions/vision/pose_landmarker/ios)
- [Google pose classification and counting reference](https://developers.google.com/ml-kit/vision/pose-detection/classifying-poses)
- [Google RepNet research](https://research.google/blog/repnet-counting-repetitions-in-videos/)

## Notes / open questions

- Approved prototype target: 11-inch iPad (A16). Use its built-in front camera
  first; external UVC input is deferred until placement evidence requires it.
- The counter and view receive no workout mutation capability. A workout title
  is read-only context, not an armed prescription or automatic exercise match.
- Current runner ownership protects a process/local persistence namespace.
  Distinct set UUIDs from two devices can represent one physical set twice;
  existing idempotency is not a cross-device controller lock.
- No backend, database, provider or video-retention change is part of this
  work. Client distribution is limited to the approved internal comparison
  build. Do not store account emails, receipts or purchase identifiers in
  repository evidence.
- Sources: [Apple Vision body pose](https://developer.apple.com/documentation/vision/detecting-human-body-poses-in-images),
  [Apple repetition sample](https://developer.apple.com/documentation/CreateMLComponents/counting-human-body-action-repetitions-in-a-live-video-feed),
  [iPad A16 specifications](https://support.apple.com/en-us/122240).
