# iPad Workout Station

Slug: ipad-workout-station · Status: active · Updated: 2026-10-03 · Theme: gym-floor

## Goal

Let a member use a stationary iPad as a readable workout display and movement
tracker while their main phone remains free. First establish camera placement
and counting quality in an observation-only trial; only validated later slices
may turn detections into durable workout actions.

## Phases

- [ ] **P0 — Deliver the observation-only Station Mode prototype**
  - Enable native iPad support and a responsive landscape/portrait display.
  - Enter from Today on iPad; request camera access only on explicit action.
  - Process the front camera locally with Vision and experimental angle-cycle
    counters for squat, curl and bench press. Do not record or upload frames.
  - Keep trials isolated from SyncModel writes, outboxes, rest and progression.
  - Stop/invalidate tracking across missing joints, additional people, camera
    interruption, rotation, backgrounding and view exit. Never infer completion
    from target reps or lost tracking.
  - Verify deterministic counting/loss scenarios, iPad navigation/layout and
    iPhone regressions; complete exact-head review and repository checks.
- [ ] **P1 — Compare existing counters and validate the mounted iPad**
  - Treat the custom angle counter as a baseline, not the selected production
    algorithm. Compare Apple HumanBodyActionCounter and a MediaPipe-based
    reference pipeline before adding assisted logging.
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
| P1 | gated_by | external:owner-ipad-station-device-build | Distribution and physical camera/placement testing require an authorized device build and owner participation. |
| P2 | gated_by | external:owner-ipad-station-write-contract | Confirm the supported movements, correction UX and multi-device controller policy before enabling workout writes. |
| P3 | gated_by | external:owner-ipad-station-automation-criteria | Automation needs explicit measured quality criteria and activation authority. |

## Next step

**Now (@agent):** Complete P0 in the coherent implementation branch, including
simulator verification and exact-head independent review. Then implement the
P1 comparison below before selecting a production counter. Preserve the P1
device/distribution gate and the later workout-write/automation gates.

## Implementation evidence

- Native iPad layout, opt-in local capture and isolated trial counters are
  implemented. Independent local review found no remaining actionable issues.
- iPad A16 / iOS 26.2 simulator: 17 counter tests and three interface journeys
  passed after permission, camera-unavailable and landscape-control fixes.
  Synthetic screenshots cover landscape and large-text portrait.
- CI now includes a dedicated iPad Station job in the existing aggregate gate.
  Coverage selection and verification-harness checks pass (7 and 12 tests).
- iPhone 17 / iOS 26.2: all 696 unit cases completed (695 passed, one skipped),
  plus three navigation/set-logging journeys passed.
- Remote exact-head review/checks remain part of P0 delivery. No physical
  camera accuracy is established yet.

## Acceptance and verification

- Entering Station Mode does not start a workout or request camera access.
- Exercise selection, trial start/stop and all detections cannot write a set.
- A valid observed cycle requires a stable extended position, flexion and return
  to extension on one visible side. The thresholds are experimental counting
  heuristics, not a form, depth, safety or training-quality assessment.
- Low-confidence joints, multiple people and camera gaps cannot bridge a rep.
- Rotation invalidates the current trial; returning to the foreground requires
  explicit camera/trial restart. Exiting releases camera and idle-timer policy.
- All station controls remain reachable at accessibility sizes and in portrait.
- Unit fixtures and simulator journeys prove logic/layout only. Real camera
  accuracy, performance, interruptions and exercise coverage remain P1 evidence.

## Algorithm comparison before assisted logging

The prototype reuses Apple Vision for pose estimation but implements its own
exercise-specific angle-cycle counter. No comparison has established that this
counter, or Vision, is the best available choice. The following are candidates
for a measured comparison, not selected dependencies:

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
- No backend, database, provider, video-retention or client distribution change
  is part of P0. Do not store account emails, receipts or purchase identifiers in
  repository evidence.
- Sources: [Apple Vision body pose](https://developer.apple.com/documentation/vision/detecting-human-body-poses-in-images),
  [Apple repetition sample](https://developer.apple.com/documentation/CreateMLComponents/counting-human-body-action-repetitions-in-a-live-video-feed),
  [iPad A16 specifications](https://support.apple.com/en-us/122240).
