import Combine
import CreateMLComponents
import Foundation

enum StationPoseDetector: String, Codable {
    case appleVision, mediaPipe
}

/// Value-only camera input. Apple Pose is used only by the retained legacy
/// counter benchmark; MediaPipe live frames never synthesize an Apple Pose.
struct StationComparisonFrame {
    let sample: StationPoseSample
    let applePose: Pose?
    let inferenceMilliseconds: Double
    var imageAspectRatio: Double = 1
    var detector: StationPoseDetector = .appleVision

    // Compatibility for the original Apple counter benchmark and its fixtures.
    var visionMilliseconds: Double { inferenceMilliseconds }
    init(sample: StationPoseSample, applePose: Pose?, visionMilliseconds: Double,
         imageAspectRatio: Double = 1) {
        self.sample = sample
        self.applePose = applePose
        inferenceMilliseconds = visionMilliseconds
        self.imageAspectRatio = imageAspectRatio
    }

    init(sample: StationPoseSample, inferenceMilliseconds: Double,
         imageAspectRatio: Double, detector: StationPoseDetector) {
        self.sample = sample
        applePose = nil
        self.inferenceMilliseconds = inferenceMilliseconds
        self.imageAspectRatio = imageAspectRatio
        self.detector = detector
    }
}

enum StationComparisonState: Equatable {
    case idle, waitingForPose, warmingUp, collecting, finishing, finished
    case reacquiring(String), incomplete(String), failed(String)

    var isCollecting: Bool {
        switch self {
        case .waitingForPose, .reacquiring, .warmingUp, .collecting: return true
        default: return false
        }
    }
    var isFinishing: Bool { self == .finishing }
    var isTerminal: Bool {
        switch self {
        case .finished, .incomplete, .failed: return true
        default: return false
        }
    }
    var message: String {
        switch self {
        case .idle: return "Ready for a comparison trial"
        case .waitingForPose: return "Finding a stable view before counting"
        case .reacquiring(let reason): return "Reacquiring: \(reason) Earlier counts are partial."
        case .warmingUp: return "Collecting Apple's first 90 poses for this segment"
        case .collecting: return "Both counters are observing"
        case .finishing: return "Finishing Apple's pending estimates"
        case .finished: return "Trial finished"
        case .incomplete(let reason): return "Incomplete trial: \(reason)"
        case .failed(let reason): return reason
        }
    }
}

struct StationComparisonMetrics: Equatable {
    var acceptedFrames = 0
    var rejectedFrames = 0
    var acceptedFPS: Double?
    var appleCoveredFrames = 0
    var pendingFrames: Int { max(0, acceptedFrames - appleCoveredFrames) }
    var segmentAcceptedFrames = 0
    var interruptedSegments = 0
    var windowProgress: Int { min(segmentAcceptedFrames, windowFrames) }
    let windowFrames = StationAppleWindowBuilder.length
    var observedHistorySeconds: Double?
    var visionMilliseconds: Double?
    var appleProcessingMilliseconds: Double?
    /// Camera-time difference between newest shared input and newest Apple result.
    /// It does not include capture, display, or camera frame delivery latency.
    var appleSourceLagSeconds: Double?
}

@MainActor
final class StationComparisonModel: ObservableObject {
    @Published private(set) var customCount = 0
    @Published private(set) var customStatus: StationTrackingStatus = .seekingPosition
    @Published private(set) var appleCount: Float?
    @Published private(set) var state: StationComparisonState = .idle
    @Published private(set) var metrics = StationComparisonMetrics()
    @Published private(set) var hasIncompleteCoverage = false
    @Published private(set) var readinessMessage = "Show the moving arm or leg clearly."

    var selectedJoints: Set<StationJoint> {
        Set((selectedLimb ?? candidateLimb ?? []).map { $0.0 })
    }

    private let appleEngineFactory: @MainActor () -> any StationAppleCountingEngine
    private let readinessDuration: TimeInterval
    private var engine: (any StationAppleCountingEngine)?
    private var generation = UUID()
    private var counter = StationRepCounter(exercise: .squat)
    private var exercise: StationExercise = .squat
    private var selectedLimb: [(StationJoint, JointKey)]?
    private var candidateLimb: [(StationJoint, JointKey)]?
    private var candidateSince: TimeInterval?
    private var candidateLastTimestamp: TimeInterval?
    private var firstTimestamp: TimeInterval?
    private var lastTimestamp: TimeInterval?
    private var lastObservedTimestamp: TimeInterval?
    private var appleTimestamp: TimeInterval?
    private var customBase = 0
    private var appleBase: Float = 0
    private var coveredBase = 0
    private var segmentCoveredFrames = 0
    private var finishTimeout: Task<Void, Never>?

#if DEBUG
    weak var diagnostics: StationDiagnostics?
    private var diagnosticAdmission = "idle"
    private var diagnosticInputJoints: [String] = []
    private var diagnosticResetReason: String?
    private var diagnosticLastApple: StationAppleDiagnosticSnapshot?
    var diagnosticSnapshot: StationComparisonDiagnosticSnapshot {
        StationComparisonDiagnosticSnapshot(
            exercise: exercise.rawValue, state: state.diagnosticName,
            admission: diagnosticAdmission, resetReason: diagnosticResetReason,
            inputJoints: diagnosticInputJoints,
            candidateJoints: (candidateLimb ?? []).map { $0.0.rawValue },
            selectedJoints: (selectedLimb ?? []).map { $0.0.rawValue },
            readinessSeconds: candidateSince.flatMap { since in candidateLastTimestamp.map { max(0, $0 - since) } },
            accepted: metrics.acceptedFrames, rejected: metrics.rejectedFrames,
            segmentAccepted: metrics.segmentAcceptedFrames, interruptedSegments: metrics.interruptedSegments,
            appleCovered: metrics.appleCoveredFrames, appleWarmup: metrics.windowProgress,
            appleLagSeconds: metrics.appleSourceLagSeconds, appleMilliseconds: metrics.appleProcessingMilliseconds,
            customCount: customCount, appleCount: appleCount.map(Double.init),
            custom: counter.diagnosticSnapshot,
            apple: (engine as? StationAppleCounter)?.diagnosticSnapshot ?? diagnosticLastApple)
    }
#endif

    init(appleEngineFactory: @escaping @MainActor () -> any StationAppleCountingEngine = { StationAppleCounter() },
         readinessDuration: TimeInterval = 0.3) {
        self.appleEngineFactory = appleEngineFactory
        self.readinessDuration = max(0, readinessDuration)
    }

    func reset(exercise: StationExercise) {
#if DEBUG
        defer { diagnostics?.modelDidUpdate(self) }
#endif
        cancelEngine()
#if DEBUG
        diagnosticAdmission = "idle"
        diagnosticInputJoints = []
        diagnosticResetReason = nil
        diagnosticLastApple = nil
#endif
        counter.reset(exercise: exercise)
        self.exercise = exercise
        selectedLimb = nil
        clearCandidate()
        customCount = 0
        customBase = 0
        customStatus = .seekingPosition
        appleCount = nil
        appleBase = 0
        coveredBase = 0
        segmentCoveredFrames = 0
        metrics = StationComparisonMetrics()
        hasIncompleteCoverage = false
        firstTimestamp = nil
        lastTimestamp = nil
        lastObservedTimestamp = nil
        appleTimestamp = nil
        readinessMessage = "Show \(requiredJoints) clearly and hold the iPad still."
        state = .idle
    }

    func start(exercise: StationExercise) {
        reset(exercise: exercise)
        state = .waitingForPose
#if DEBUG
        diagnostics?.modelDidUpdate(self)
#endif
    }

    func process(_ frame: StationComparisonFrame) {
        guard state.isCollecting else { return }
#if DEBUG
        diagnosticAdmission = "checking"
        diagnosticInputJoints = (selectedLimb ?? candidateLimb ?? []).map { $0.0.rawValue }
        defer { diagnostics?.modelDidUpdate(self) }
#endif
        let sample = frame.sample
        guard sample.timestamp.isFinite, sample.timestamp >= 0 else {
#if DEBUG
            diagnosticAdmission = "invalid_timestamp"
#endif
            recover(reason: "The camera timestamp was invalid.")
            return
        }
        if let lastObservedTimestamp, sample.timestamp <= lastObservedTimestamp {
#if DEBUG
            diagnosticAdmission = "stale_timestamp"
#endif
            metrics.rejectedFrames += 1
            return
        }
        lastObservedTimestamp = sample.timestamp
        guard sample.personCount == 1 else {
#if DEBUG
            diagnosticAdmission = sample.personCount > 1 ? "multiple_people" : "no_person"
#endif
            customStatus = sample.personCount > 1 ? .multiplePeople : .trackingLost
            if sample.personCount > 1 {
                metrics.rejectedFrames += 1
                invalidate(reason: "More than one person entered view. Start a new comparison when alone.")
            } else {
                recover(reason: "No person detected. Show \(requiredJoints).")
            }
            return
        }
        let stableCandidate = candidateLimb.flatMap { Self.hasUsableJoints(sample, limb: $0) ? $0 : nil }
        let limb = selectedLimb ?? stableCandidate ?? usableLimb(in: sample)
#if DEBUG
        diagnosticInputJoints = (limb ?? []).map { $0.0.rawValue }
#endif
        guard let pose = frame.applePose, let limb, Self.hasUsableJoints(sample, limb: limb) else {
#if DEBUG
            diagnosticAdmission = frame.applePose == nil ? "missing_apple_pose" : "unclear_joints"
#endif
            customStatus = .trackingLost
            recover(reason: "Keep \(requiredJoints) visible and clear on one side.")
            return
        }
        if let lastTimestamp, sample.timestamp - lastTimestamp > 0.5 {
#if DEBUG
            diagnosticAdmission = "pose_gap"
#endif
            recover(reason: "Camera poses paused. Hold \(requiredJoints) in view.")
            return
        }
        if selectedLimb == nil {
#if DEBUG
            diagnosticAdmission = "readiness"
#endif
            // Do not admit a fleeting close-up while the person walks away from
            // the Start button. Readiness frames are not fabricated or replayed.
            let sameLimb = candidateLimb?.map { $0.0 } == limb.map { $0.0 }
            let continuous = candidateLastTimestamp.map { sample.timestamp - $0 <= 0.5 } ?? false
            if !sameLimb || !continuous { candidateSince = sample.timestamp }
            candidateLimb = limb
            candidateLastTimestamp = sample.timestamp
            readinessMessage = "Hold \(requiredJoints) clearly in view for a moment."
            guard let candidateSince, sample.timestamp - candidateSince >= readinessDuration else { return }
            selectedLimb = limb
            clearCandidate()
            let engine = appleEngineFactory()
            self.engine = engine
            let generation = generation
            engine.start { [weak self] event in self?.receive(event, generation: generation) }
            guard state.isCollecting else { return }
        }
        let selectedPose = JointsSelector(selectedJoints: limb.map { $0.1 }).applied(to: pose)
        let input = StationAppleInput(pose: selectedPose, timestamp: sample.timestamp,
                                      frameIndex: metrics.segmentAcceptedFrames + 1)
        guard engine?.append(input) == true else {
#if DEBUG
            diagnosticAdmission = "apple_admission_rejected"
#endif
            recover(reason: "Apple fell behind. Hold still while both counters restart.")
            return
        }
        // Both counters consume the same admitted stream in each segment. A gap
        // begins a fresh cycle/window, never a bridge across unseen movement.
        let jointNames = Set(limb.map { $0.0 })
        counter.process(StationPoseSample(timestamp: sample.timestamp,
                                          joints: sample.joints.filter { jointNames.contains($0.key) },
                                          personCount: sample.personCount))
#if DEBUG
        diagnosticAdmission = "accepted"
#endif
        customCount = customBase + counter.count
        customStatus = counter.status
        firstTimestamp = firstTimestamp ?? sample.timestamp
        lastTimestamp = sample.timestamp
        metrics.acceptedFrames += 1
        metrics.segmentAcceptedFrames += 1
        if let firstTimestamp, sample.timestamp > firstTimestamp {
            metrics.acceptedFPS = Double(metrics.acceptedFrames - 1) / (sample.timestamp - firstTimestamp)
        }
        metrics.visionMilliseconds = frame.visionMilliseconds.isFinite ? max(0, frame.visionMilliseconds) : nil
        if let appleTimestamp { metrics.appleSourceLagSeconds = max(0, sample.timestamp - appleTimestamp) }
        readinessMessage = "Tracking \(requiredJoints) on one side."
        state = segmentCoveredFrames == 0 ? .warmingUp : .collecting
    }

    /// Normal stop drains real queued windows. A trial stopped during readiness
    /// has no engine to drain and finishes immediately with an honest partial state.
    func stop() {
        guard state.isCollecting else { return }
#if DEBUG
        defer { diagnostics?.modelDidUpdate(self) }
#endif
        guard let engine else {
            state = .incomplete(hasIncompleteCoverage ? "Tracking was still reacquiring; counts are partial." :
                               "No stable pose segment was captured.")
            return
        }
        state = .finishing
        let generation = generation
        engine.finish()
        guard state == .finishing else { return }
        finishTimeout = Task { [weak self] in
            do { try await Task.sleep(nanoseconds: 5_000_000_000) } catch { return }
            guard let self, self.generation == generation, self.state == .finishing else { return }
            self.invalidate(reason: "Apple did not finish its pending windows in time.")
        }
    }

    /// Rotation, scene changes and ambiguous identity require an explicit restart.
    func invalidate(reason: String) {
        guard state.isCollecting || state.isFinishing else { return }
#if DEBUG
        diagnosticResetReason = reason
        defer { diagnostics?.modelDidUpdate(self) }
#endif
        hasIncompleteCoverage = true
        cancelEngine()
        state = .incomplete(reason)
    }

    private func recover(reason: String) {
#if DEBUG
        diagnosticResetReason = reason
#endif
        metrics.rejectedFrames += 1
        clearCandidate()
        readinessMessage = reason
        guard metrics.segmentAcceptedFrames > 0 || selectedLimb != nil else {
            if hasIncompleteCoverage { state = .reacquiring(reason) }
            return
        }
        hasIncompleteCoverage = true
        metrics.interruptedSegments += 1
        cancelEngine()
        customBase = customCount
        appleBase = appleCount ?? 0
        coveredBase = metrics.appleCoveredFrames
        segmentCoveredFrames = 0
        metrics.segmentAcceptedFrames = 0
        metrics.appleSourceLagSeconds = nil
        metrics.appleProcessingMilliseconds = nil
        metrics.observedHistorySeconds = nil
        counter.reset(exercise: exercise)
        customStatus = .trackingLost
        selectedLimb = nil
        lastTimestamp = nil
        appleTimestamp = nil
        state = .reacquiring(reason)
    }

    private func receive(_ event: StationAppleCounterEvent, generation: UUID) {
        guard self.generation == generation, state.isCollecting || state.isFinishing else { return }
#if DEBUG
        defer { diagnostics?.modelDidUpdate(self) }
#endif
        switch event {
        case .estimate(let estimate):
            guard estimate.cumulativeCount.isFinite, estimate.cumulativeCount >= 0,
                  estimate.throughFrame > segmentCoveredFrames,
                  estimate.throughFrame <= metrics.segmentAcceptedFrames,
                  estimate.throughTimestamp.isFinite,
                  let lastTimestamp, estimate.throughTimestamp <= lastTimestamp,
                  estimate.windowDuration.isFinite, estimate.windowDuration >= 0,
                  estimate.processingMilliseconds.isFinite, estimate.processingMilliseconds >= 0 else {
                fail("Apple returned an invalid estimate. Start a new trial.")
                return
            }
            appleCount = appleBase + estimate.cumulativeCount
            appleTimestamp = estimate.throughTimestamp
            segmentCoveredFrames = estimate.throughFrame
            metrics.appleCoveredFrames = coveredBase + estimate.throughFrame
            metrics.observedHistorySeconds = estimate.windowDuration
            metrics.appleProcessingMilliseconds = estimate.processingMilliseconds
            metrics.appleSourceLagSeconds = max(0, lastTimestamp - estimate.throughTimestamp)
            if state.isCollecting { state = .collecting }
        case .finished:
            guard state == .finishing else {
                fail("Apple's counter stopped before the trial ended.")
                return
            }
            finishTimeout?.cancel()
            finishTimeout = nil
            engine = nil
            if hasIncompleteCoverage {
                state = .incomplete("Tracking restarted during this trial. Counts cover only the observed segments.")
            } else if metrics.segmentAcceptedFrames < metrics.windowFrames {
                state = .incomplete("Apple needs at least 90 clear poses before its first estimate.")
            } else if metrics.pendingFrames > 0 {
                state = .incomplete("Apple did not cover the last \(metrics.pendingFrames) poses; shown estimates are partial.")
            } else {
                state = .finished
            }
        case .failed(let message):
            fail(message)
        }
    }

    private func cancelEngine() {
#if DEBUG
        if let engine = engine as? StationAppleCounter { diagnosticLastApple = engine.diagnosticSnapshot }
#endif
        generation = UUID()
        finishTimeout?.cancel()
        finishTimeout = nil
        engine?.cancel()
        engine = nil
    }

    private func fail(_ message: String) {
        hasIncompleteCoverage = true
        cancelEngine()
        state = .failed(message)
    }

    private func clearCandidate() {
        candidateLimb = nil
        candidateSince = nil
        candidateLastTimestamp = nil
    }

    private var requiredJoints: String {
        exercise == .squat ? "hip, knee and ankle" : "shoulder, elbow and wrist"
    }

    private func usableLimb(in sample: StationPoseSample) -> [(StationJoint, JointKey)]? {
        let candidates: [[(StationJoint, JointKey)]]
        if exercise == .squat {
            candidates = [[(.leftHip, .leftHip), (.leftKnee, .leftKnee), (.leftAnkle, .leftAnkle)],
                          [(.rightHip, .rightHip), (.rightKnee, .rightKnee), (.rightAnkle, .rightAnkle)]]
        } else {
            candidates = [[(.leftShoulder, .leftShoulder), (.leftElbow, .leftElbow), (.leftWrist, .leftWrist)],
                          [(.rightShoulder, .rightShoulder), (.rightElbow, .rightElbow), (.rightWrist, .rightWrist)]]
        }
        var selected: [(StationJoint, JointKey)]?
        var bestConfidence: Float = -1
        for limb in candidates where Self.hasUsableJoints(sample, limb: limb) {
            let confidence = limb.compactMap { sample.joints[$0.0]?.confidence }.min() ?? 0
            if confidence > bestConfidence { selected = limb; bestConfidence = confidence }
        }
        return selected
    }

    private static func hasUsableJoints(_ sample: StationPoseSample, limb: [(StationJoint, JointKey)]) -> Bool {
        limb.allSatisfy { joint, _ in
            guard let point = sample.joints[joint] else { return false }
            return point.x.isFinite && point.y.isFinite && point.confidence.isFinite
                && point.confidence >= 0.6 && point.confidence <= 1
        }
    }

    deinit { finishTimeout?.cancel() }
}
