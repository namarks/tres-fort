import Combine
import CreateMLComponents
import Foundation

/// Two representations of one Vision result. Pose keeps Vision's original
/// normalized coordinates; the custom sample uses equal units on both axes.
/// Neither representation retains the source image or Vision observation.
struct StationComparisonFrame {
    let sample: StationPoseSample
    let applePose: Pose?
    let visionMilliseconds: Double
}

enum StationComparisonState: Equatable {
    case idle, waitingForPose, warmingUp, collecting, finishing, finished
    case incomplete(String), failed(String)

    var isCollecting: Bool {
        switch self {
        case .waitingForPose, .warmingUp, .collecting: return true
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
        case .waitingForPose: return "Show the moving arm or leg to start both counters"
        case .warmingUp: return "Collecting Apple's first 90 poses"
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
    var windowProgress: Int { min(acceptedFrames, windowFrames) }
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

    private let appleEngineFactory: @MainActor () -> any StationAppleCountingEngine
    private var engine: (any StationAppleCountingEngine)?
    private var generation = UUID()
    private var counter = StationRepCounter(exercise: .squat)
    private var exercise: StationExercise = .squat
    private var selectedLimb: [(StationJoint, JointKey)]?
    private var firstTimestamp: TimeInterval?
    private var lastTimestamp: TimeInterval?
    private var appleTimestamp: TimeInterval?
    private var finishTimeout: Task<Void, Never>?

    init(appleEngineFactory: @escaping @MainActor () -> any StationAppleCountingEngine = { StationAppleCounter() }) {
        self.appleEngineFactory = appleEngineFactory
    }

    func reset(exercise: StationExercise) {
        generation = UUID()
        finishTimeout?.cancel()
        finishTimeout = nil
        engine?.cancel()
        engine = nil
        counter.reset(exercise: exercise)
        self.exercise = exercise
        selectedLimb = nil
        customCount = 0
        customStatus = .seekingPosition
        appleCount = nil
        metrics = StationComparisonMetrics()
        firstTimestamp = nil
        lastTimestamp = nil
        appleTimestamp = nil
        state = .idle
    }

    func start(exercise: StationExercise) {
        reset(exercise: exercise)
        let generation = generation
        let engine = appleEngineFactory()
        self.engine = engine
        state = .waitingForPose
        engine.start { [weak self] event in self?.receive(event, generation: generation) }
    }

    func process(_ frame: StationComparisonFrame) {
        guard state.isCollecting else { return }
        let sample = frame.sample
        guard sample.timestamp.isFinite, sample.timestamp >= 0 else {
            reject(reason: "The camera timestamp was invalid.")
            return
        }
        if let lastTimestamp, sample.timestamp <= lastTimestamp {
            metrics.rejectedFrames += 1
            return
        }
        guard sample.personCount == 1 else {
            customStatus = sample.personCount > 1 ? .multiplePeople : .trackingLost
            reject(reason: sample.personCount > 1 ? "More than one person entered view." : "The person left view.")
            return
        }
        let limb = selectedLimb ?? usableLimb(in: sample)
        guard let pose = frame.applePose, let limb, Self.hasUsableJoints(sample, limb: limb) else {
            customStatus = .trackingLost
            reject(reason: "Body joints were no longer clear. Reposition and start a new trial.")
            return
        }
        if let lastTimestamp, sample.timestamp - lastTimestamp > 0.5 {
            reject(reason: "A gap in camera poses interrupted the comparison.")
            return
        }
        let selectedPose = JointsSelector(selectedJoints: limb.map { $0.1 }).applied(to: pose)
        let input = StationAppleInput(pose: selectedPose, timestamp: sample.timestamp, frameIndex: metrics.acceptedFrames + 1)
        guard engine?.append(input) == true else {
            reject(reason: "Apple's pending window buffer filled. Start a new trial.")
            return
        }
        // Only admitted inputs advance either side. Both counts refer to this
        // common stream; Apple may still be working on its most recent window.
        selectedLimb = limb
        let jointNames = Set(limb.map { $0.0 })
        let selectedSample = StationPoseSample(timestamp: sample.timestamp,
                                              joints: sample.joints.filter { jointNames.contains($0.key) },
                                              personCount: sample.personCount)
        counter.process(selectedSample)
        customCount = counter.count
        customStatus = counter.status
        firstTimestamp = firstTimestamp ?? sample.timestamp
        lastTimestamp = sample.timestamp
        metrics.acceptedFrames += 1
        if let firstTimestamp, sample.timestamp > firstTimestamp {
            metrics.acceptedFPS = Double(metrics.acceptedFrames - 1) / (sample.timestamp - firstTimestamp)
        }
        metrics.visionMilliseconds = frame.visionMilliseconds.isFinite ? max(0, frame.visionMilliseconds) : nil
        if let appleTimestamp { metrics.appleSourceLagSeconds = max(0, sample.timestamp - appleTimestamp) }
        state = appleCount == nil ? .warmingUp : .collecting
    }

    /// Normal stop closes admission and drains real queued windows. No repeated
    /// frames are fabricated to fill a tail shorter than the model window.
    func stop() {
        guard state.isCollecting else { return }
        state = .finishing
        let generation = generation
        engine?.finish()
        guard state == .finishing else { return }
        finishTimeout = Task { [weak self] in
            do { try await Task.sleep(nanoseconds: 5_000_000_000) } catch { return }
            guard let self, self.generation == generation, self.state == .finishing else { return }
            self.invalidate(reason: "Apple did not finish its pending windows in time.")
        }
    }

    /// Loss, rotation, scene changes and leaving the screen cancel the stream;
    /// late asynchronous predictions can never change this or a future trial.
    func invalidate(reason: String) {
        guard state.isCollecting || state.isFinishing else { return }
        generation = UUID()
        finishTimeout?.cancel()
        finishTimeout = nil
        engine?.cancel()
        engine = nil
        state = .incomplete(reason)
    }

    private func reject(reason: String) {
        metrics.rejectedFrames += 1
        if metrics.acceptedFrames > 0 { invalidate(reason: reason) }
    }

    private func receive(_ event: StationAppleCounterEvent, generation: UUID) {
        guard self.generation == generation, state.isCollecting || state.isFinishing else { return }
        switch event {
        case .estimate(let estimate):
            guard estimate.cumulativeCount.isFinite, estimate.cumulativeCount >= 0,
                  estimate.throughFrame > metrics.appleCoveredFrames,
                  estimate.throughFrame <= metrics.acceptedFrames,
                  estimate.throughTimestamp.isFinite,
                  let lastTimestamp, estimate.throughTimestamp <= lastTimestamp,
                  estimate.windowDuration.isFinite, estimate.windowDuration >= 0,
                  estimate.processingMilliseconds.isFinite, estimate.processingMilliseconds >= 0 else {
                fail("Apple returned an invalid estimate. Start a new trial.")
                return
            }
            appleCount = estimate.cumulativeCount
            appleTimestamp = estimate.throughTimestamp
            metrics.appleCoveredFrames = estimate.throughFrame
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
            if metrics.acceptedFrames < metrics.windowFrames {
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

    private func fail(_ message: String) {
        generation = UUID()
        finishTimeout?.cancel()
        finishTimeout = nil
        engine?.cancel()
        engine = nil
        state = .failed(message)
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
        // Apple's documented JointsSelector supports a subset. Both counters use
        // the same visible limb throughout the trial; far-side occlusion is fine.
        limb.allSatisfy { joint, _ in
            guard let point = sample.joints[joint] else { return false }
            return point.x.isFinite && point.y.isFinite && point.confidence.isFinite
                && point.confidence >= 0.6 && point.confidence <= 1
        }
    }

    deinit { finishTimeout?.cancel() }
}
