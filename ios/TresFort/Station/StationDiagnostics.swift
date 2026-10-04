#if DEBUG
import Combine
import Foundation

struct StationCounterDiagnosticSnapshot: Codable, Equatable {
    var timestamp: TimeInterval?
    var angle: Double?
    var minimumConfidence: Double?
    var phase = "seeking_start"
    var endpoint: String?
    var endpointDwell: Double?
}

struct StationAppleDiagnosticSnapshot: Codable, Equatable {
    var bufferedPoses: Int
    var queuedWindows: Int
    var inFlightWindows: Int
    var droppedWindows: Int
    var terminatedWindows: Int
}

struct StationComparisonDiagnosticSnapshot: Codable, Equatable {
    var exercise = "squat"
    var state = "idle"
    var admission = "idle"
    var resetReason: String?
    var inputJoints: [String] = []
    var candidateJoints: [String] = []
    var selectedJoints: [String] = []
    var readinessSeconds: Double?
    var accepted = 0
    var rejected = 0
    var segmentAccepted = 0
    var interruptedSegments = 0
    var appleCovered = 0
    var appleWarmup = 0
    var appleLagSeconds: Double?
    var appleMilliseconds: Double?
    var customCount = 0
    var appleCount: Double?
    var custom = StationCounterDiagnosticSnapshot()
    var apple: StationAppleDiagnosticSnapshot?
    var detector: String?
    var leftCount: Int?
    var rightCount: Int?
    var leftCounter: StationCounterDiagnosticSnapshot?
    var rightCounter: StationCounterDiagnosticSnapshot?
}

extension StationComparisonState {
    var diagnosticName: String {
        switch self {
        case .idle: return "idle"
        case .waitingForPose: return "waiting_for_pose"
        case .warmingUp: return "warming_up"
        case .collecting: return "collecting"
        case .finishing: return "finishing"
        case .finished: return "finished"
        case .reacquiring: return "reacquiring"
        case .incomplete: return "incomplete"
        case .failed: return "failed"
        }
    }
}

/// Numeric digest only: never retains a frame, Pose, image or account identity.
struct StationDiagnosticPose: Codable, Equatable {
    var timestamp: TimeInterval?
    var personCount: Int
    var confidences: [String: Double]
    var missingJoints: [String]
    var unclearJoints: [String]
    var visionMilliseconds: Double?
    var detector: String?
    var inferenceMilliseconds: Double?
    // Exploratory frontal-view signals, not an alternative repetition counter.
    // Heights are relative to the upright image; torso scale uses image-height units.
    var hipHeight: Double?
    var shoulderHeight: Double?
    var torsoScale: Double?

    init(frame: StationComparisonFrame) {
        let sample = frame.sample
        timestamp = sample.timestamp.isFinite ? sample.timestamp : nil
        personCount = sample.personCount
        confidences = [:]
        missingJoints = []
        unclearJoints = []
        for joint in StationJoint.allCases {
            guard let point = sample.joints[joint], point.x.isFinite, point.y.isFinite,
                  point.confidence.isFinite, (0...1).contains(point.confidence) else {
                missingJoints.append(joint.rawValue)
                continue
            }
            confidences[joint.rawValue] = Double(point.confidence)
            if point.confidence < 0.6 { unclearJoints.append(joint.rawValue) }
        }
        detector = frame.detector.rawValue
        inferenceMilliseconds = frame.inferenceMilliseconds.isFinite ? frame.inferenceMilliseconds : nil
        visionMilliseconds = frame.detector == .appleVision ? inferenceMilliseconds : nil
        func clearPoint(_ point: StationJointPoint) -> Bool {
            let confident = point.confidence.isFinite && point.confidence >= 0.6 && point.confidence <= 1
            let validX = point.x.isFinite && point.x >= 0 && point.x <= frame.imageAspectRatio
            let validY = point.y.isFinite && point.y >= 0 && point.y <= 1
            return confident && validX && validY
        }
        func midpoint(_ a: StationJoint, _ b: StationJoint) -> (x: Double, y: Double)? {
            guard sample.personCount == 1,
                  let first = sample.joints[a], let second = sample.joints[b],
                  clearPoint(first), clearPoint(second) else { return nil }
            return ((first.x + second.x) / 2, (first.y + second.y) / 2)
        }
        let hips = midpoint(.leftHip, .rightHip)
        let shoulders = midpoint(.leftShoulder, .rightShoulder)
        hipHeight = hips?.y
        shoulderHeight = shoulders?.y
        if let hips, let shoulders { torsoScale = hypot(hips.x - shoulders.x, hips.y - shoulders.y) }
    }
}

struct StationDiagnosticSample: Codable, Equatable {
    var elapsedSeconds: Double
    var observedFrames: Int
    var pose: StationDiagnosticPose?
    var comparison: StationComparisonDiagnosticSnapshot
    var angleMinimum: Double?
    var angleMaximum: Double?
    var changes: [String]
}

/// Explicit opt-in developer instrumentation. Output is numeric JSON on stdout
/// for an attached console, never a file, network request, video or image log.
@MainActor
final class StationDiagnostics: ObservableObject {
    @Published var isEnabled = false {
        didSet {
            guard oldValue != isEnabled else { return }
            clear()
            timer?.cancel()
            timer = nil
            if isEnabled { startTimer() }
        }
    }
    @Published private(set) var latest: StationDiagnosticSample?
    @Published private(set) var latestSummary = "Live diagnostics are off."
    private(set) var history: [StationDiagnosticSample] = []

    private let now: () -> TimeInterval
    private let emit: (String) -> Void
    private weak var model: StationComparisonModel?
    private var pose: StationDiagnosticPose?
    private var snapshot = StationComparisonDiagnosticSnapshot()
    private var startedAt: TimeInterval?
    private var lastEmission: TimeInterval?
    private var lastObservation: TimeInterval?
    private var observedFrames = 0
    private var angleMinimum: Double?
    private var angleMaximum: Double?
    private var changes: [String] = []
    private var lastSignature: String?
    private var pending = false
    private var timer: Task<Void, Never>?

    init(now: @escaping () -> TimeInterval = { ProcessInfo.processInfo.systemUptime },
         emit: @escaping (String) -> Void = { print($0) }) {
        self.now = now
        self.emit = emit
    }

    /// Call before the view's collection guard. The model hook then supplies
    /// post-admission state for the same frame, including rejected input.
    func observe(frame: StationComparisonFrame?, model: StationComparisonModel) {
        self.model = model
        guard isEnabled else {
            if model.diagnostics === self { model.diagnostics = nil }
            return
        }
        model.diagnostics = self
        pose = frame.map(StationDiagnosticPose.init)
        if frame != nil { observedFrames += 1 }
        if !model.state.isCollecting || frame == nil { modelDidUpdate(model) }
    }

    func observeLive(frame: StationComparisonFrame?, snapshot: StationComparisonDiagnosticSnapshot) {
        guard isEnabled else { return }
        if frame != nil { observedFrames += 1 }
        record(pose: frame.map(StationDiagnosticPose.init), snapshot: snapshot)
    }

    func modelDidUpdate(_ model: StationComparisonModel) {
        guard isEnabled, self.model === model else { return }
        record(pose: pose, snapshot: model.diagnosticSnapshot)
    }

    /// Value-only seam for deterministic rate, retention and redaction tests.
    func record(pose: StationDiagnosticPose?, snapshot: StationComparisonDiagnosticSnapshot) {
        guard isEnabled else { return }
        var snapshot = snapshot
        if snapshot.custom.timestamp != pose?.timestamp {
            snapshot.custom.angle = nil
            snapshot.custom.minimumConfidence = nil
        }
        if snapshot.leftCounter?.timestamp != pose?.timestamp {
            snapshot.leftCounter?.angle = nil
            snapshot.leftCounter?.minimumConfidence = nil
        }
        if snapshot.rightCounter?.timestamp != pose?.timestamp {
            snapshot.rightCounter?.angle = nil
            snapshot.rightCounter?.minimumConfidence = nil
        }
        self.pose = pose
        self.snapshot = snapshot
        let time = now()
        guard time.isFinite else { return }
        startedAt = startedAt ?? time
        lastObservation = time
        if let angle = snapshot.custom.angle, angle.isFinite,
           snapshot.custom.timestamp == pose?.timestamp {
            angleMinimum = min(angleMinimum ?? angle, angle)
            angleMaximum = max(angleMaximum ?? angle, angle)
        }
        var signature = "\(snapshot.state):\(snapshot.admission):\(snapshot.custom.phase)"
        if let left = snapshot.leftCounter, let right = snapshot.rightCounter {
            signature += ":left=\(left.phase):right=\(right.phase)"
        }
        if signature != lastSignature {
            changes.append(signature)
            if changes.count > 8 { changes.removeFirst(changes.count - 8) }
            lastSignature = signature
        }
        pending = true
        flush()
    }

    func flush() {
        guard isEnabled, let startedAt else { return }
        let time = now()
        guard time.isFinite else { return }
        let elapsed = max(0, time - startedAt)
        history.removeAll { elapsed - $0.elapsedSeconds > 60 }
        if let lastObservation, time - lastObservation > 60 {
            latest = nil
            pose = nil
            snapshot = StationComparisonDiagnosticSnapshot()
            angleMinimum = nil
            angleMaximum = nil
            changes = []
            lastSignature = nil
            self.lastObservation = nil
            latestSummary = "Waiting for a camera frame."
            pending = false
        }
        guard pending, lastEmission.map({ time - $0 >= 0.5 }) ?? true else { return }
        let sample = StationDiagnosticSample(elapsedSeconds: elapsed, observedFrames: observedFrames,
                                            pose: pose, comparison: snapshot,
                                            angleMinimum: angleMinimum, angleMaximum: angleMaximum, changes: changes)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        guard let data = try? encoder.encode(sample), let json = String(data: data, encoding: .utf8) else { return }
        lastEmission = time
        pending = false
        angleMinimum = nil
        angleMaximum = nil
        changes = []
        history.append(sample)
        if history.count > 240 { history.removeFirst(history.count - 240) }
        latest = sample
        let angle = sample.comparison.custom.angle.map { String(format: "%.0f°", $0) } ?? "—"
        let joints = sample.comparison.selectedJoints.isEmpty
            ? sample.comparison.candidateJoints : sample.comparison.selectedJoints
        let checkedJoints = snapshot.inputJoints.isEmpty ? joints : snapshot.inputJoints
        let quality = jointQualitySummary(checkedJoints: checkedJoints)
        let collecting = ["waiting_for_pose", "warming_up", "collecting", "reacquiring"].contains(snapshot.state)
        let decision = collecting ? snapshot.admission
            : "not collecting · last decision: \(snapshot.admission)"
        let hip = pose?.hipHeight.map { String(format: "%.2f", $0) } ?? "—"
        let scale = pose?.torsoScale.map { String(format: "%.2f", $0) } ?? "—"
        let engineDetail = snapshot.detector == "mediaPipe" ? "MediaPipe live" : "Apple \(snapshot.appleWarmup)/90 · restarts \(snapshot.interruptedSegments)"
        latestSummary = "\(snapshot.state) · \(decision)\n\(checkedJoints.joined(separator: ", "))\n\(quality)\nAngle \(angle) · \(snapshot.custom.phase) · accepted \(snapshot.accepted), rejected \(snapshot.rejected)\n\(engineDetail)\nHip y \(hip) · torso scale \(scale)"
        if let left = snapshot.leftCounter, let right = snapshot.rightCounter {
            func arm(_ name: String, _ value: StationCounterDiagnosticSnapshot, _ count: Int?) -> String {
                let angle = value.angle.map { String(format: "%.0f°", $0) } ?? "—"
                let confidence = value.minimumConfidence.map { String(format: "%.2f", $0) } ?? "—"
                return "\(name): \(count ?? 0) · \(angle) · \(value.phase) · score \(confidence)"
            }
            latestSummary = "\(snapshot.state) · MediaPipe live\n\(quality)\n"
                + arm("Left arm", left, snapshot.leftCount) + "\n"
                + arm("Right arm", right, snapshot.rightCount)
        }
        emit("STATION_DIAGNOSTIC " + json)
    }

    private func jointQualitySummary(checkedJoints: [String]) -> String {
        func quality(_ names: [String], removeSide: Bool = false) -> String {
            let weak = names.compactMap { name -> String? in
                let label = removeSide
                    ? name.replacingOccurrences(of: "left", with: "")
                        .replacingOccurrences(of: "right", with: "").lowercased() : name
                guard let confidence = pose?.confidences[name] else { return "\(label) missing" }
                return confidence < 0.6 ? "\(label) \(String(format: "%.2f", confidence))" : nil
            }
            if !weak.isEmpty { return weak.joined(separator: ", ") }
            let minimum = names.compactMap { pose?.confidences[$0] }.min() ?? 0
            return "clear (minimum \(String(format: "%.2f", minimum)))"
        }
        if !checkedJoints.isEmpty { return "Checked joints: \(quality(checkedJoints))" }
        // Show both alternatives before selection or when neither trio passes
        // admission. An empty selected set is not evidence that joints are clear.
        let leg = snapshot.exercise == StationExercise.squat.rawValue
        let parts = leg ? ["Hip", "Knee", "Ankle"] : ["Shoulder", "Elbow", "Wrist"]
        let limb = leg ? "leg" : "arm"
        let left = quality(parts.map { "left" + $0 }, removeSide: true)
        let right = quality(parts.map { "right" + $0 }, removeSide: true)
        return "Either \(limb) is enough; all three joints on that side must be clear.\nLeft \(limb): \(left)\nRight \(limb): \(right)"
    }

    func clear() {
        history = []
        latest = nil
        latestSummary = isEnabled ? "Waiting for a camera frame." : "Live diagnostics are off."
        pose = nil
        snapshot = StationComparisonDiagnosticSnapshot()
        startedAt = nil
        lastEmission = nil
        lastObservation = nil
        observedFrames = 0
        angleMinimum = nil
        angleMaximum = nil
        changes = []
        lastSignature = nil
        pending = false
        if !isEnabled, model?.diagnostics === self { model?.diagnostics = nil }
    }

    private func startTimer() {
        timer = Task { [weak self] in
            while !Task.isCancelled {
                do { try await Task.sleep(nanoseconds: 500_000_000) } catch { return }
                guard let self else { return }
                self.flush()
            }
        }
    }

    deinit { timer?.cancel() }
}
#endif
