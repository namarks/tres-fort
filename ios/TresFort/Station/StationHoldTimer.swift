import Foundation

enum StationHoldKind: String {
    case plank, wallSit
    var title: String { self == .plank ? "Forearm plank" : "Wall sit" }
    var guidance: String {
        switch self {
        case .plank:
            return "Use a level side view. Keep your shoulder, elbow, wrist, hip, knee and ankle visible. Rest on your forearms with your legs extended."
        case .wallSit:
            return "Use a level side view beside a wall. Keep your shoulder, hip, knee and ankle visible. Sit against the wall with your thighs roughly horizontal."
        }
    }
}

/// Observation-only countdown. Time comes exclusively from consecutive camera
/// samples in a recognized position, never a wall clock or the workout timer.
struct StationHoldTimer {
    enum State: Equatable {
        case idle, seeking, stabilizing, holding, paused, reached, stopped, invalidated
        var message: String {
            switch self {
            case .idle: return "Ready for a hold test"
            case .seeking: return "Get into the hold position"
            case .stabilizing: return "Hold steady to start the timer"
            case .holding: return "Hold detected · counting down"
            case .paused: return "Timer paused · return to the hold with clear joints"
            case .reached: return "Time reached · test complete"
            case .stopped: return "Hold test stopped"
            case .invalidated: return "View interrupted · start a new hold test"
            }
        }
    }
    let kind: StationHoldKind
    let targetSeconds: Int
    private(set) var elapsed: TimeInterval = 0
    private(set) var state: State = .idle
    private(set) var wasInterrupted = false
    private var lastTimestamp: TimeInterval?
    private var acquisitionPose: StationPoseSample?
    private var selectedSide: Side?
    private enum Side: CaseIterable { case left, right }
    var remaining: TimeInterval { max(0, Double(targetSeconds) - elapsed) }
    var isActive: Bool { [.seeking, .stabilizing, .holding, .paused].contains(state) }

    init(kind: StationHoldKind, targetSeconds: Int) {
        self.kind = kind
        self.targetSeconds = min(3600, max(1, targetSeconds))
    }

    mutating func start() {
        self = Self(kind: kind, targetSeconds: targetSeconds)
        state = .seeking
    }
    mutating func stop() { if isActive { state = .stopped } }
    mutating func invalidate() {
        guard isActive else { return }
        state = .invalidated
        wasInterrupted = true
        acquisitionPose = nil
        selectedSide = nil
    }

    mutating func process(_ sample: StationPoseSample) {
        guard isActive else { return }
        guard sample.timestamp.isFinite, sample.timestamp >= 0, sample.personCount <= 1 else {
            invalidate()
            return
        }
        if let lastTimestamp, sample.timestamp <= lastTimestamp { return }
        let previous = lastTimestamp
        lastTimestamp = sample.timestamp
        guard sample.personCount == 1,
              previous.map({ sample.timestamp - $0 <= 0.5 }) ?? true else {
            pause()
            return
        }
        if selectedSide == nil {
            selectedSide = Side.allCases.first { recognizes(sample, side: $0) }
        }
        guard let side = selectedSide, recognizes(sample, side: side) else {
            pause()
            return
        }
        if state == .holding, let previous {
            elapsed = min(Double(targetSeconds), elapsed + sample.timestamp - previous)
            if remaining <= 0 { state = .reached }
            return
        }
        // Compare with the start of the dwell, not the preceding frame: slow
        // movement through otherwise valid geometry must restart acquisition.
        if acquisitionPose.map({ isSteady(sample, relativeTo: $0, side: side) }) != true {
            acquisitionPose = sample
        }
        // The one-second setup dwell is not credited as observed hold time.
        state = sample.timestamp - acquisitionPose!.timestamp >= 1 ? .holding : .stabilizing
    }

    private mutating func pause() {
        if state == .holding || elapsed > 0 { wasInterrupted = true }
        state = elapsed > 0 || wasInterrupted ? .paused : .seeking
        acquisitionPose = nil
        selectedSide = nil
    }

    private func requiredJoints(for side: Side) -> [StationJoint] {
        let names: [StationJoint] = side == .left
            ? [.leftShoulder, .leftHip, .leftKnee, .leftAnkle, .leftElbow, .leftWrist]
            : [.rightShoulder, .rightHip, .rightKnee, .rightAnkle, .rightElbow, .rightWrist]
        return kind == .plank ? names : Array(names.prefix(4))
    }

    private func isSteady(_ sample: StationPoseSample, relativeTo anchor: StationPoseSample, side: Side) -> Bool {
        let required = requiredJoints(for: side)
        guard let shoulder = anchor.joints[required[0]], let hip = anchor.joints[required[1]] else { return false }
        // Experimental, body-scaled jitter allowance, fixed for this dwell.
        let tolerance = distance(shoulder, hip) * 0.05
        return required.allSatisfy { joint in
            guard let point = sample.joints[joint], let reference = anchor.joints[joint] else { return false }
            return distance(point, reference) <= tolerance
        }
    }

    private func recognizes(_ sample: StationPoseSample, side: Side) -> Bool {
        let required = requiredJoints(for: side)
        let points = required.compactMap { sample.joints[$0] }
        guard points.count == required.count, points.allSatisfy({
            $0.x.isFinite && $0.y.isFinite && $0.confidence.isFinite
                && $0.confidence >= 0.6 && $0.confidence <= 1
        }) else { return false }
        let shoulder = points[0], hip = points[1], knee = points[2], ankle = points[3]
        let torso = distance(shoulder, hip), thigh = distance(hip, knee), shin = distance(knee, ankle)
        guard torso > 0.04, thigh > 0.04, shin > 0.04 else { return false }
        switch kind {
        case .plank:
            let elbow = points[4], wrist = points[5]
            let length = distance(shoulder, ankle)
            guard let hipAngle = angle(shoulder, hip, knee), let kneeAngle = angle(hip, knee, ankle),
                  let elbowAngle = angle(shoulder, elbow, wrist), length > 0.2 else { return false }
            return hipAngle >= 155 && kneeAngle >= 155 && (65...115).contains(elbowAngle)
                && abs(shoulder.y - ankle.y) < length * 0.4
                && shoulder.y - elbow.y > length * 0.1
                && hip.y > elbow.y && hip.y > ankle.y
                && abs(shoulder.x - elbow.x) < torso * 0.35
                && abs(elbow.y - wrist.y) < length * 0.1
        case .wallSit:
            guard let hipAngle = angle(shoulder, hip, knee), let kneeAngle = angle(hip, knee, ankle) else { return false }
            return (70...115).contains(hipAngle) && (70...115).contains(kneeAngle)
                && shoulder.y - hip.y > torso * 0.85
                && knee.y - ankle.y > shin * 0.85
                && abs(hip.y - knee.y) < thigh * 0.3
        }
    }

    private func distance(_ a: StationJointPoint, _ b: StationJointPoint) -> Double { hypot(a.x - b.x, a.y - b.y) }
    private func angle(_ a: StationJointPoint, _ b: StationJointPoint, _ c: StationJointPoint) -> Double? {
        let first = distance(a, b), second = distance(b, c)
        guard first > 0.01, second > 0.01 else { return nil }
        let dot = ((a.x - b.x) * (c.x - b.x) + (a.y - b.y) * (c.y - b.y)) / (first * second)
        return acos(min(1, max(-1, dot))) * 180 / .pi
    }
}
