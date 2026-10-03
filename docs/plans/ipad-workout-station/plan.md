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
  - Reset both counters' movement history after missing joints or a pose gap;
    reacquire a stable view and keep the whole trial visibly partial. Additional
    people, camera interruption, rotation, backgrounding and view exit require
    an explicit restart. Never infer completion from target reps or lost tracking.
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
  - Treat front-facing squats as a primary wall-mounted use case. Evaluate
    calibrated hip movement and inferred 3D knee angles using live evidence;
    the current side-view 2D angle counter cannot establish frontal coverage.
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
| P1 | gated_by | external:owner-ipad-station-device-build | Corrective internal build 46 is verified available to Testers; the owner must evaluate framing and counting on the actual iPad. |
| P2 | gated_by | external:owner-ipad-station-write-contract | Confirm the supported movements, correction UX and multi-device controller policy before enabling workout writes. |
| P3 | gated_by | external:owner-ipad-station-automation-criteria | Automation needs explicit measured quality criteria and activation authority. |

## Next step

**Now (@agent):** Complete P0 review and repository checks, addressing the camera
request-reuse finding and preserving the verified diagnostic setup below.
**Next physical trial (@owner):** Participate in a controlled pose-reliability
comparison before tuning frontal rep counting; P1 cannot run unattended.
The Debug build is signed, verified, installed in place and launched with its
console attached. iPadOS 26.7.1, enabled Developer Mode and usable developer
services are verified. The existing App Store Connect release key refreshed
both development profiles without another Apple account login; both signatures
match the pre-existing development certificate. The owner confirmed the existing
account/workout is visible and enabled the Station camera and measurement stream.
Live numeric output is working. The owner completed five front-facing squats and
confirmed the whole body, including both feet, stayed inside the preview.
Standing samples isolate ankles below the prototype's 0.6 cutoff; movement
samples also include low-confidence hips and no-person detections. The trial
ran with counting stopped to inspect raw input, so there is no counter score.
Preserve every emitted diagnostic sample for the next controlled comparison;
the first host filter decimated the app's 2 Hz output to about 0.5 Hz and cannot
establish an exact movement-by-movement trajectory. Assess a side-view control
and alternative pose estimation if frontal losses persist before choosing a
frontal counter or relaxing admission. No further reps are currently requested.
The owner reports improved but still inadequate tracking in internal build
1.0 (46). Use opt-in
numeric diagnostics to inspect rejected poses, counter phases and repeated
Apple warm-up resets during manually counted movements, including front-facing
squats. Counting quality and any frontal algorithm remain unvalidated.
Follow the [direct-device procedure](device-debugging.md); the existing
development identity and refreshed profiles are verified for this iPad.
Complete P0 repository delivery only after configured CI and exact-head review
pass; an internal TestFlight upload does not satisfy merge gates. The later
workout-write and automation gates remain in force.

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
- The owner requested direct iPad debugging to shorten iteration and identified
  front-facing squat support as a needed use case. Developer diagnostics stay
  opt-in and Debug-only: bounded numerical summaries on the local console,
  with no images, video, account identifiers, network sink or workout writes.

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
- The owner installed build 45 and reported repeated new-member setup after
  using the same Apple account, insufficient full-body framing and no useful
  tracking from either counter. The lack of a skeleton was expected in that
  build; it did not distinguish failed pose detection from failed counting.
- The corrective client slice reads existing server training before offering
  setup on a fresh installation, retains unfinished local setup receipts and
  shows retry after a failed read. This does not create or merge server accounts.
- Camera selection now prefers front Ultra Wide, chooses bounded video formats
  by reported vertical coverage, disables dynamic cropping during capture and
  restores the prior Center Stage setting on exit. A joint overlay and explicit
  visibility guidance expose the shared pose input to the tester.
- Brief tracking loss now fences the old engine and starts a fresh stable
  segment for both counters. Reported earlier counts remain partial; no cycle
  or Apple window can span missing movement. A16 format availability, overlay
  alignment, sustained inference and actual count accuracy still need a device trial.
- A sustained native-model probe reproduced a framework trap on the second
  overlapping window: our adapter used capture-time ticks where Apple's
  `SlidingWindowTransformer` emits pose-index ranges. The adapter now uses
  those index ranges and keeps actual capture timestamps separately for measured
  rate, history and lag. The prior one-window smoke could not expose this bug.
- The corrected production engine completed a native 180-pose probe with 19
  estimates and no admission failures. Synthetic zero-count input proves
  sustained API execution, not counting accuracy or A16 performance. Evidence:
  `.artifacts/station-recovery-smoke/result-fixed-production.json`.
- Three fresh-iPad sign-in journeys pass, including existing-training restore,
  failed-read retry and confirmed-empty setup. Results:
  `.artifacts/ios/tres-fort-ios.RD8r7z/Tests.xcresult`. Wider-format selection,
  overlay projection, segmented recovery and the three Station interface
  journeys also passed in the initial focused iPad run. The iPhone run passed
  740 unit tests with one existing skip and 25 UI journeys, including all 23
  activation cases. Results: `.artifacts/ios/tres-fort-ios.XueYM6/Tests.xcresult`.
  After the final Apple adapter correction, all 23 comparison cases including
  real multi-window inference passed against the exact candidate's iOS source
  set on iPad: `.artifacts/ios/tres-fort-ios.QSDi8b/Tests.xcresult`.
- Apple validation and upload of corrective build 1.0 (46) succeeded from
  independently reviewed source `5989bce81942e18b53e9ba35918986b595408411`.
  At `2026-10-03T21:55:28.607Z`, Apple confirmed VALID / IN_BETA_TESTING and
  internal Testers assignment. See the [build receipt](../app-store-submission/release-46.md).
- The direct-device diagnostic slice adds opt-in Debug UI and at most two
  numeric console summaries per second, retaining up to 60 seconds in memory.
  It observes input before admission and reports the same frame's decision,
  confidence, angle/phase, resets and Apple queue/coverage. Raw hip/shoulder
  heights and torso scale support investigation of front-facing movement;
  repetition rules are unchanged. All 47 focused unit cases and three Station
  interface journeys passed on the A16 simulator in
  `.artifacts/ios/tres-fort-ios.AsQAYn/Tests.xcresult`. An unsigned device Release
  build passed and its binary excludes the diagnostic UI/output markers;
  evidence: `.artifacts/station-device/release-diagnostics-exclusion.json`.
  The initial unsigned Debug device build also passed with Xcode 26.3. After
  the host updated to Xcode 27.0 and the owner accepted its license, the same
  application source compiled successfully with the new SDK; evidence:
  `.artifacts/station-device/debug-build-xcode27-result.json`. Device preparation
  initially required the owner to unlock the iPad. After unlocking, developer
  services became usable, the signed build passed, and both app/widget signatures
  and profiles were independently verified against the existing certificate,
  required capabilities and this iPad. In-place installation and console launch
  succeeded with version 1.0/build 46; evidence: `signed-build-verification.json`,
  `install-result.json` and `app-after-install.json` under
  `.artifacts/station-device/`. No video was recorded or uploaded. The owner
  confirmed account/workout continuity and enabled the diagnostic stream.
- Direct console output now verifies camera/Vision delivery at approximately
  15 frames per second. Initial setup output includes person detections with
  zero-confidence hips, knees and ankles, and repeated comparison reacquisition.
  The first comparison started before streaming and later became incomplete;
  no manually counted movement or viewing angle has been confirmed for it.
  These observations identify input-quality failures, not counter accuracy.
  The host filter now exposes all raw joint confidences/missing joints and
  labels terminal-trial admission as not collecting. The app's empty selected
  joint list must not be interpreted as evidence that all joints are clear.
- In a subsequent stationary front-facing interval, all 14 host samples had
  hips and knees above 0.6, while the left ankle exceeded that cutoff in only
  four samples and the right ankle in none. This is a sampled diagnostic
  interval, not a frame-level detection rate or calibrated confidence measure.
  The owner then reported five front-facing squats with the entire body visible.
  Raw hip height dropped and returned, with low-confidence hips and no-person
  detections also present in the surrounding stream. Because the host retained
  only the latest pose about every two seconds and the comparison was stopped,
  no exact five-cycle reconstruction, per-rep errors or counter accuracy is
  established. The next host run preserves the app's full 2 Hz summaries.
  The Debug panel now names weak/missing joints on each alternative limb and
  labels a terminal trial's admission as a historical decision; counting rules
  and raw JSON are unchanged. All 10 diagnostic tests pass in
  `.artifacts/ios/tres-fort-ios.rYh7lV/Tests.xcresult`. The incremental signed
  Debug device build, both bundle signature/profile checks, in-place install
  and console relaunch also passed. Local independent review found no blocking
  issues. The updated diagnostic display is installed; frontal tracking is
  still unvalidated. See `diagnostic-display-tests.log`,
  `diagnostic-display-build.log` and `diagnostic-display-install.json` under
  `.artifacts/station-device/`.

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
- Missing joints and camera gaps reacquire with fresh cycle/window state after
  a stable pose. The trial remains incomplete even after counting resumes;
  multiple people still require an explicit new comparison.
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
