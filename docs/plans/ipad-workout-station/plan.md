# iPad Workout Station

Slug: ipad-workout-station · Status: active · Updated: 2026-10-04 · Theme: gym-floor

## Goal

Let a member use a stationary iPad as a readable workout display and movement
tracker while their main phone remains free. First establish camera placement
and counting quality in an observation-only trial; only validated later slices
may turn detections into durable workout actions.

## Phases

- [ ] **P0 — Deliver the observation-only Station Mode comparison**
  - Enable native iPad support and a responsive landscape/portrait display.
  - Enter from Today on iPad; request camera access only on explicit action.
  - Process the front camera locally with MediaPipe Full and an experimental
    angle-cycle counter for squat, curl and bench press. Live capture remains
    transient unless the member explicitly starts a bounded local test recording.
  - Show the MediaPipe live count without an Apple temporal-window warm-up.
    Retain Apple Vision in saved-video comparison on identical frames.
  - Bound queued work, fence late results by trial and account session, and make
    incomplete coverage or inference failure visible.
  - Count curls independently for body-left and body-right arms in live mode
    and saved replay. Save actual counts per arm; never double bilateral reps
    into one displayed total or assign an old unspecified label to an arm.
  - Keep trials isolated from SyncModel writes, outboxes, rest and progression.
  - Audit every catalog ID into a reusable rep/hold candidate profile or an
    explicit manual fallback. Selecting a workout/catalog exercise resolves its
    profile; only explicitly implemented experiments can start tracking.
  - Add observation-only forearm-plank and wall-sit countdown experiments:
    stable pose acquisition, observed-time accumulation, pause/reacquisition,
    terminal interruption and no automatic set completion. See the
    [catalog audit and hold contract](catalog-tracking.md).
  - Reset movement history after missing joints or a pose gap. For curls only,
    allow one low-confidence observation between reliable measurements no more
    than 0.15 seconds apart; discard its angle and restart endpoint dwell.
    Sustained loss still resets the cycle. Always mark coverage incomplete;
    reacquire a stable view and keep the whole trial visibly partial. Additional
    people, camera interruption, rotation, backgrounding and view exit require
    an explicit restart. Never infer completion from target reps or lost tracking.
  - Add explicit silent local test recording (five-second countdown, at most
    45 seconds, no automatic upload/backup), aligned per-frame measurements,
    count labels, selected sharing and deletion. Replay the same decoded frames
    through Apple Vision and MediaPipe Full with synchronized frame inspection.
  - Verify deterministic counting/loss scenarios, iPad navigation/layout and
    iPhone regressions; complete exact-head review and repository checks.
- [ ] **P1 — Compare existing counters and validate the mounted iPad**
  - Evaluate broader reuse through PoseFit's exercise rules and a TransRAC
    counting benchmark before expanding custom detectors. The
    [source survey](catalog-tracking.md#existing-implementations-and-datasets)
    records model availability, mobile adaptation and FLAG3D's research-only
    terms, plus native SDK comparators. Keep the mapping independent of the
    selected engine; no external SDK or dataset is imported by this slice.
  - Treat the custom angle counter as a baseline, not the selected production
    algorithm. Compare it with Apple HumanBodyActionCounter in the first
    device build. Compare Apple Vision with MediaPipe Full on identical saved
    frames. The first owner clip supports MediaPipe as the next live prototype
    default; broader accuracy remains unproven. Score detection separately from
    repetition logic and measure live performance separately from offline replay.
  - On an authorized device build, compare counts to manual ground truth for
    all three modes, including slow/paused/partial reps and obstructed views.
  - Evaluate landscape camera placement, screen readability, tracking recovery,
    a workout-length thermal/power trial and continued use of the main phone.
  - Treat front-facing squats as a primary wall-mounted use case. Evaluate
    calibrated hip movement and inferred 3D knee angles using live evidence;
    the current side-view 2D angle counter cannot establish frontal coverage.
  - Record count errors, corrections and setup/repositioning effort. Select the
    supported movements/angles from observed evidence, not assumed accuracy.
  - Validate each mapped variant before expanding experiment availability.
    For holds, measure false starts during setup/lying/rest, target timing,
    interrupted holds and reacquisition; joint geometry cannot prove contact,
    load-bearing or form quality.
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

**Now (@agent):** Complete exact-head review and repository checks for
[PR #235](https://github.com/namarks/tres-fort/pull/235), including the review
corrections that make Station use today's resolved workout and hold duration
unless an active runner overrides it, and restart hold acquisition when the
person is still moving through accepted geometry. The owner explicitly approved publication
to `namarks/tres-fort` on 2026-10-04; Nick owns merge. The implementation is on
`codex/catalog-camera-profiles`. This branch incorporates the merged Today
calendar work (PR #233) and curl-confidence/replay-coverage fix (PR #234) through
`77eaa16` on `origin/main`.
The audit covers all 280 exercises: 193 rep candidates, 15 hold candidates and
72 manual fallbacks. Fifteen entries explicitly select a current experimental
mode; profile membership alone never enables a counter. Real accuracy remains
unvalidated, and no physical build installation is part of this slice.
The last recorded device installation is development build 48 from `e15d53b`;
the catalog slice has not been installed. The old test-readiness follow-up
`472221a` is separate. PR #228 merged before its full iOS gate passed.
**Next physical trial (@owner):** No additional repetitions are needed to
reproduce the simultaneous-curl failure. Actual arm totals in the latest clip
are awaiting owner clarification. After the candidate is reviewed and installed,
validate live behavior with owner-started tests. Sustained performance, other
movements, false positives and automatic workout actions remain unvalidated.
No unattended recording is requested.

## Approved comparison scope

- On 2026-10-04 the owner requested a full catalog tracking audit and reusable
  mappings, including pose-triggered hold countdowns. This adds an in-app
  coverage browser and local plank/wall-sit experiments. It does not activate
  workout writes, progression, background recording or distribution.
- On 2026-10-03 the owner approved making the first device-test build compare
  the custom counter and Apple counter side by side on the same movements.
- This authorizes comparison implementation and the internal device-test build.
  It does not authorize public App Store release, backend deployment, workout
  logging, automatic progression or video storage/upload in that first build.
- On 2026-10-04 the owner approved wireless debugging plus explicit short, silent
  local test recordings, manually selected transfer and deletion, and replay
  through Apple Vision and MediaPipe Full. This supersedes the initial no-storage
  boundary only for user-started test clips; no automatic upload or cloud backup
  is included. No backend or workout mutation authority is added.
- The owner subsequently requested TestFlight upload while the Mac checks were
  queued. The independently reviewed source was uploaded as an internal branch
  build; repository merge still requires its configured checks and review.
- On 2026-10-04 the owner approved making MediaPipe Full the default live
  tracker after the first matched native replay. Apple Vision remains a saved
  comparison option. This is a prototype choice, not general accuracy or
  automatic workout-action approval.
- The owner requested direct iPad debugging to shorten iteration and identified
  front-facing squat support as a needed use case. Developer diagnostics stay
  opt-in and Debug-only: bounded numerical summaries on the local console,
  with no images, video, account identifiers, network sink or workout writes.

## Implementation evidence

- Catalog mapping and hold countdowns: all 280 migrated IDs are covered exactly
  once, with 45 reusable profiles and explicit manual reasons. The local D1
  coverage contract, typecheck, plan graph and all 1,189 backend tests pass.
  A disposable iPad A16 simulator passed 38 Station unit tests and five UI
  journeys. After the target-control correction, the final build passed all
  ten new unit tests and the hold/catalog UI journey, including target editing
  and reset. Evidence: `.artifacts/catalog-backend-tests.log` and
  `.artifacts/ios/tres-fort-ios.m6qJsn/Tests.xcresult` (earlier regression suite:
  `.artifacts/ios/tres-fort-ios.WsMURa/Tests.xcresult`). These prove software
  behavior and layout, not physical camera accuracy. No iPad installation or
  workout writes occurred in this slice.
- The PR #235 review correction resolves Station context from today's displayed
  workout, retaining an active runner override. A disposable iPad simulator
  passed the schedule/override/rest-day regression, all ten hold/catalog unit
  tests and all five Station UI journeys. Evidence:
  `.artifacts/ios/tres-fort-ios.jH64VJ/Tests.xcresult`.
- After incorporating PR #233 and PR #234, the combined branch passed 87
  affected unit cases (one native-only Apple replay skip) and all five Station
  iPad UI journeys. Evidence: `.artifacts/ios/tres-fort-ios.JJEKvK/Tests.xcresult`.
- The hold-acquisition review fix compares each frame against the dwell's
  initial pose, restarting after movement beyond a body-scaled jitter tolerance.
  Slow descent through valid wall-sit geometry cannot start or resume timing.
  The disposable iPad simulator passed 13 focused unit tests and all five
  Station UI journeys, including slow descent, reacquisition and small jitter
  at different body scales. Evidence:
  `.artifacts/ios/tres-fort-ios.25IyGy/Tests.xcresult`.
- Exact-head remote review identified that saved comparisons lacked the live
  partial-coverage warning. Reports now persist optional per-detector coverage
  flags, latched on aggregate or either arm's tracking loss; newly produced
  reports always emit explicit booleans. The comparison screen shows partial
  tracking warnings, and absent legacy fields retain unknown coverage. Exported
  `comparison.json` preserves these flags. This does not add restoration of old
  comparisons when reopening a saved test. The coverage fix passed 22 affected
  unit cases (one native-only Apple replay skip) and all four Station UI journeys,
  with a fresh clean independent review. Current iOS source matches the tested
  snapshot in `.artifacts/ios/tres-fort-ios.SayK5A/`. The unchanged counter suites
  retain the prior verification below; a new exact-head remote review is required.
- The bounded confidence correction passed 60 unit cases, with one native-only
  Apple replay case skipped, plus all four Station iPad UI journeys. Plan
  validation and independent local review pass. Evidence is retained in this
  worktree's `.artifacts/ios/tres-fort-ios.n2lWUH/`; its temporary build and
  simulator were removed. Remote exact-head review and CI remain required.
- The next owner-shared build 48 curl clip contains 448 MediaPipe measurement
  frames over 29.8 seconds, one person throughout and no capture gaps above
  0.067 seconds. The exact installed counter replays to left 6 / right 7.
  During the final three visually observed simultaneous cycles it adds left 0 /
  right 1. Four isolated wrist-confidence dips below 0.6 reset in-flight cycles;
  tracking recovers on each following frame. The correction retains phase only
  across a single short confidence dip, without accepting its angle or bridging
  endpoint dwell; confidence, angle and minimum-cycle thresholds stay unchanged.
  Replaying all saved measurements with the candidate counts left 9 / right 9,
  including left 3 / right 3 in the simultaneous segment. This is a counter
  replay, not rerun inference or a new live-device result. An earlier left-arm
  cycle still fails the unchanged 0.55-second minimum-duration guard; neither
  the duration threshold nor the missing actual-rep labels were adjusted to fit.
  This transfer has no per-arm actual labels or paired Apple replay. Raw video,
  landmarks, source hashes and traces remain local and outside Git under the
  original worktree's `.artifacts/station-trials/0A98CBF8-0DDD-482D-90EC-2744F3BE99E5/`.
- On 2026-10-04 the owner authorized installing merged source `e15d53b` as local
  development build 48. Its verified 371-file iOS snapshot passed signed native
  compilation and app/widget signature/profile checks. The wired in-place
  installation preserved the owner's account, workouts and saved tests, as
  confirmed by the owner. Receipts remain in the original worktree's
  `.artifacts/station-device/merged-*`. No TestFlight upload or workout write
  occurred. The owner then supplied the curl recording analyzed above.
- Saved replay now rejects the entire comparison if either detector sees more
  than one person, before counting that frame. It cannot resume with another
  person or publish a completed total. A rerun removes its prior derived
  comparison first, so failure or cancellation cannot expose stale totals in
  sharing; raw video, measurements and labels remain unchanged.
- On 2026-10-04 the owner reported improved tracking but curls failing on one
  side. The exact counter reproduced zero counts for three curls when the
  opposite stationary arm had a higher confidence score; mirroring sides had
  the same result. This proves a software failure mode, not the precise cause
  of the owner's reported failure. No confidence or angle cutoff was lowered.
- `StationMovementCounter` now runs two independent fixed-arm counters for
  curls, sharing the existing endpoint, timing, person and tracking-loss rules.
  One arm cannot steal selection from, finish a cycle for, or reset the other.
  Squat and bench behavior use the unchanged baseline. Live/replay show each
  arm's count/status, and optional saved labels distinguish unknown from zero.
  Old single labels remain unspecified; old comparisons can be rerun for new
  per-arm results. The compatibility scalar is max(left, right), never a sum;
  curl displays use the per-arm fields. Replay metadata records counter version.

- Curl correction verification: 121 unit cases passed, one native-only Apple
  replay case skipped, and all four Station UI journeys passed on iPad A16.
  That tested Swift snapshot is retained at
  `.artifacts/ios/tres-fort-ios.GVIxvi/`. Signed native compilation and both
  signature/profile checks pass (`curl-independent-arms-build.log`,
  `curl-signed-verification.json` under `.artifacts/station-device/`). Independent
  local reviews found no blockers. This pre-merge build was not installed;
  the merged-source build 48 installation is recorded above. Broader physical
  curl accuracy remains unvalidated.
- First owner clip: 25.8 seconds, 388 paired frames, one person detected in every
  frame by both models. Original shared angle-rule counts were MediaPipe 9 and
  Apple Vision 1. The owner provisionally reported five front-facing plus five
  sideways squats; the exported manifest contained no actual-rep label. These
  are local numeric results, without independent visual ground-truth annotation.
- Replaying the actual Swift counter isolated a missed transition cycle: the
  locked right knee fell below the 0.6 admission cutoff at 13.600 seconds while
  all three left-leg joints remained clear. The new rule allows a better-scored
  limb only between cycles, after both limbs agree in extension for 0.18 seconds.
  It keeps the confidence threshold and rejects mid-cycle handoffs. The same
  clip now yields MediaPipe 10, Apple 1. This supports the diagnosis on one clip;
  it does not establish general frontal accuracy or form/depth assessment.
- Native offline median inference was 25.7 ms for MediaPipe and 6.3 ms for Apple.
  MediaPipe timing includes orientation. These timings do not establish live
  throughput, battery or thermal behavior. Raw videos/landmarks remain outside
  Git in ignored `.artifacts/station-trials/`; only aggregates are documented.
- Recordings now require an account namespace and revocable feature-session
  capability. Sign-out/account changes fence camera, recording completion,
  replay, still images and sharing; deletion erases only that account's clips.
  Unattributed clips from the earlier prototype are left untouched and hidden,
  never adopted by the next signed-in account. The owner's original exported
  test is preserved on the Mac. New measurement metadata names its detector;
  MediaPipe timing is never exported as Vision timing.
- Returning-account recognition now checks saved training profiles, group
  membership and explicit integration history when training is empty. A member
  who previously skipped everything has no durable server completion marker;
  after a successful empty-account read the welcome screen offers Continue to
  app. Failed reads and unfinished local drafts cannot use that bypass.

- Live-default source `23ef59f6bade9f464d79c9d59564badd97de5722` passed signed
  native compilation and app/widget signature/profile checks, then installed
  in place over verified `localNetwork` transport after the owner unlocked the
  iPad. No camera was started by the agent. Receipts:
  `.artifacts/station-device/mediapipe-live-build-source.json`,
  `mediapipe-live-signed-verification.json`, `mediapipe-live-install.json`.
- Focused checks cover 212 unit cases (211 pass and one native-only replay skip)
  and eight UI journeys across the broad and affected reruns. Two test-only
  failures were diagnosed: a synthetic rep was faster than the existing minimum,
  and one navigation assertion still expected the old Custom label. Both were
  corrected and reverified. The final current-Swift snapshot passed all 18
  affected unit and five UI cases in `.artifacts/ios/tres-fort-ios.Ixqtod/`;
  unchanged cases passed in `.artifacts/ios/tres-fort-ios.4VOANz/`. Auth's 109
  unit cases, direct-entry UI, counter's 22 cases and privacy's 12 cases pass.
  Plan, harness and CI-scope checks pass. Independent local reviews found no
  remaining blockers; remote exact-head review and CI remain required.

Earlier build evidence (historical, superseded where stated above):

- On 2026-10-04 the owner unplugged the iPad and CoreDevice verified an active
  `localNetwork` connection. Bounded silent recording, aligned measurement
  packages, count labels, deletion/sharing and same-frame Apple/MediaPipe replay
  are implemented. The shared angle rule remains a side-view baseline.
- MediaPipe Full float16 v1 is pinned with SDK 0.10.21 after an independent
  source/binary review. The current 1.0.0 binary contains a metrics uploader and
  is excluded. Project generation verifies download hashes, the six audited
  binaries and their runner/network symbols; see the
  [dependency rationale](../../../ios/Dependencies/README.md).
- Recording, replay, MediaPipe, existing counters and four Station interface
  journeys passed on the A16 simulator: 58 unit tests passed, one native-only
  test skipped, four UI tests passed. Evidence:
  `.artifacts/ios/tres-fort-ios.Ctq3qd/Tests.xcresult`. The iOS 26.2 simulator
  omits Apple's human-pose weights, so the pipeline test injects a clearly named
  Apple detector while executing real MediaPipe. A separate physical-device
  test exercises both real models. No native replay or movement accuracy result
  is inferred from the simulator checks. Seven dependency, 12 harness and seven
  CI-scope checks pass. Local independent review has no remaining blocking
  findings. The signed Debug device build and both identity/profile checks pass;
  see `.artifacts/station-device/record-replay-signed-build.log`.
- The same bundle/team was installed in place over the verified wireless
  connection from source `7e4941efe4d190be841472154309cebe309474dc`, without an
  uninstall, TestFlight upload or backend deployment. Exact app/debug-library
  and model hashes, signatures and installation receipt are retained in
  `.artifacts/station-device/record-replay-build-source.json`,
  `record-replay-signed-verification.json` and `record-replay-install.json`.
  No camera or recording was started by the agent. The owner subsequently
  recorded and replayed the clip summarized above.
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
- Review follow-up reuses one Vision request on the serial capture queue;
  no accuracy or measured performance gain is claimed. Main was merged while
  preserving both Station request evidence and the deterministic fixture clock.
  Exact local head `b37c648e283c91c3eba8bd1fe5388bfd830b077b` passed independent
  review, signed Debug compilation and 17 unit plus six iPad UI tests (Station
  navigation and fresh-device restoration/retry/empty-account journeys).
  Evidence: `.artifacts/ios/tres-fort-ios.SWgBMN/Tests.xcresult` and
  `.artifacts/station-device/post-merge-device-build.log`. Work paused before
  pushing these follow-ups or installing that latest device build.

## Acceptance and verification

- Entering Station Mode does not start a workout or request camera access.
- Exercise selection, trial start/stop and all detections cannot write a set.
- The live MediaPipe angle counter requires a stable extended position, flexion
  and return. It is an advisory count, not a form, depth or safety assessment.
- Saved replay feeds identical decoded frames to both pose detectors and uses
  the same cycle rule. The retained legacy Apple HumanBodyActionCounter code
  and its tests are not part of the live screen or saved pose-detector comparison.
- Low-confidence joints, multiple people and camera gaps cannot bridge a rep.
  Tracking loss starts a fresh cycle; counts remain visibly partial. A better
  limb may take over only while both limbs agree in a stable extended position.
  Multiple people require an explicit new test.
- Rotation invalidates the current trial; returning to the foreground requires
  explicit camera/trial restart. Exiting releases camera and idle-timer policy.
- All station controls remain reachable at accessibility sizes and in portrait.
- Unit fixtures and simulator journeys prove logic/layout only. Real camera
  accuracy, performance, interruptions and exercise coverage remain P1 evidence.

## Algorithm comparison before assisted logging

The prototype now uses MediaPipe Full for live pose estimation and its own
exercise-specific angle-cycle counter. The first matched owner clip favored
MediaPipe's joint tracking for this setup; it does not establish a universally
best detector or counter. Apple Vision remains available for saved comparison.
The following remain benchmark candidates before assisted logging:

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
live manual ground truth. Only explicitly started test clips are retained locally;
automatic upload remains absent.
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
- The counter and view receive no workout mutation capability. Workout/catalog
  selections carry immutable display values and an optional duration only.
  Choosing an exercise resolves a profile but does not arm the camera or trial.
- Current runner ownership protects a process/local persistence namespace.
  Distinct set UUIDs from two devices can represent one physical set twice;
  existing idempotency is not a cross-device controller lock.
- No backend, database or provider change is part of this work. Bounded local
  test retention is owner-approved; client distribution is limited to the internal comparison
  build. Do not store account emails, receipts or purchase identifiers in
  repository evidence.
- Sources: [Apple Vision body pose](https://developer.apple.com/documentation/vision/detecting-human-body-poses-in-images),
  [Apple repetition sample](https://developer.apple.com/documentation/CreateMLComponents/counting-human-body-action-repetitions-in-a-live-video-feed),
  [iPad A16 specifications](https://support.apple.com/en-us/122240).
