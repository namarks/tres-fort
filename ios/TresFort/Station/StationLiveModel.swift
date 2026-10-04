import Combine
import Foundation

/// MediaPipe poses feed the same advisory cycle rule used by saved replay.
/// No Apple engine, artificial warm-up window, or workout write is involved.
@MainActor
final class StationLiveModel: ObservableObject {
    enum State: Equatable {
        case idle, collecting, finished, incomplete(String)
        var isCollecting: Bool { self == .collecting }
        var isTerminal: Bool {
            switch self { case .finished, .incomplete: return true; default: return false }
        }
        var message: String {
            switch self {
            case .idle: return "Ready for a tracking test"
            case .collecting: return "MediaPipe is tracking"
            case .finished: return "Test finished"
            case .incomplete(let reason): return reason
            }
        }
    }

    @Published private(set) var count = 0
    @Published private(set) var leftCount: Int?
    @Published private(set) var rightCount: Int?
    @Published private(set) var leftStatus: StationTrackingStatus?
    @Published private(set) var rightStatus: StationTrackingStatus?
    @Published private(set) var status: StationTrackingStatus = .seekingPosition
    @Published private(set) var state: State = .idle
    @Published private(set) var hasIncompleteCoverage = false
    @Published private(set) var observedFrames = 0
    @Published private(set) var observedFPS: Double?
    @Published private(set) var inferenceMilliseconds: Double?
    private var counter = StationMovementCounter(exercise: .squat)
    private var exercise: StationExercise = .squat
    private var firstTimestamp: TimeInterval?
    private var lastTimestamp: TimeInterval?

    func reset(exercise: StationExercise) {
        self.exercise = exercise
        counter.reset(exercise: exercise)
        count = 0
        leftCount = counter.leftCount
        rightCount = counter.rightCount
        leftStatus = counter.leftStatus
        rightStatus = counter.rightStatus
        status = .seekingPosition
        state = .idle
        hasIncompleteCoverage = false
        observedFrames = 0
        observedFPS = nil
        inferenceMilliseconds = nil
        firstTimestamp = nil
        lastTimestamp = nil
    }

    func start(exercise: StationExercise) {
        reset(exercise: exercise)
        state = .collecting
    }

    func process(_ frame: StationComparisonFrame) {
        guard state.isCollecting else { return }
        guard frame.detector == .mediaPipe else {
            invalidate(reason: "Tracking source changed. Start a new test.")
            return
        }
        let sample = frame.sample
        guard sample.timestamp.isFinite, sample.timestamp >= 0 else {
            invalidate(reason: "Camera timing changed. Start a new test.")
            return
        }
        if let lastTimestamp, sample.timestamp <= lastTimestamp { return }
        // Ambiguous identity requires an explicit restart, not a new person
        // inheriting the first person's accumulated count.
        guard sample.personCount <= 1 else {
            status = .multiplePeople
            invalidate(reason: "More than one person entered view. Start a new test when alone.")
            return
        }
        if let lastTimestamp, sample.timestamp - lastTimestamp > 0.5 { hasIncompleteCoverage = true }
        counter.process(sample)
        count = counter.count
        leftCount = counter.leftCount
        rightCount = counter.rightCount
        leftStatus = counter.leftStatus
        rightStatus = counter.rightStatus
        status = counter.status
        if status == .trackingLost || leftStatus == .trackingLost || rightStatus == .trackingLost {
            hasIncompleteCoverage = true
        }
        observedFrames += 1
        firstTimestamp = firstTimestamp ?? sample.timestamp
        lastTimestamp = sample.timestamp
        if let firstTimestamp, sample.timestamp > firstTimestamp {
            observedFPS = Double(observedFrames - 1) / (sample.timestamp - firstTimestamp)
        }
        inferenceMilliseconds = frame.inferenceMilliseconds.isFinite ? max(0, frame.inferenceMilliseconds) : nil
    }

    func stop() {
        guard state.isCollecting else { return }
        state = observedFrames == 0 ? .incomplete("No camera poses were captured.") : .finished
    }

    func invalidate(reason: String) {
        guard state.isCollecting else { return }
        hasIncompleteCoverage = true
        state = .incomplete(reason)
    }

#if DEBUG
    var diagnosticSnapshot: StationComparisonDiagnosticSnapshot {
        StationComparisonDiagnosticSnapshot(
            exercise: exercise.rawValue, state: state.isCollecting ? "collecting" : "stopped",
            admission: status == .trackingLost ? "unclear_joints" : "observed",
            accepted: observedFrames, customCount: count, custom: counter.diagnosticSnapshot ?? StationCounterDiagnosticSnapshot(),
            detector: StationPoseDetector.mediaPipe.rawValue,
            leftCount: leftCount, rightCount: rightCount,
            leftCounter: counter.leftDiagnosticSnapshot, rightCounter: counter.rightDiagnosticSnapshot)
    }
#endif
}
