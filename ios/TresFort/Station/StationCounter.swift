import Foundation

enum StationExercise: String, CaseIterable, Identifiable {
    case squat, curl, benchPress

    var id: String { rawValue }

    var title: String {
        switch self {
        case .squat: return "Squat"
        case .curl: return "Curl"
        case .benchPress: return "Bench press"
        }
    }

    var guidance: String {
        switch self {
        case .squat: return "Keep your hips, knees and ankles visible. Stand tall, then squat and stand. Try front-facing and side views in separate tests."
        case .curl: return "Keep your shoulder, elbow and wrist visible. Lower each arm, then curl and lower. Each arm counts separately; a side view can make the elbow bend clearer."
        case .benchPress: return "Show your shoulder, elbow and wrist from the side. Start with arms extended, then lower and press."
        }
    }
}

enum StationJoint: String, CaseIterable {
    case leftShoulder, rightShoulder, leftElbow, rightElbow, leftWrist, rightWrist
    case leftHip, rightHip, leftKnee, rightKnee, leftAnkle, rightAnkle
}

/// Upright image coordinates with equal units on both axes, origin bottom-left.
/// The camera scales Vision's normalized x by image width / height; landscape x
/// may exceed 1. Angles would be distorted if raw normalized x and y were used.
struct StationJointPoint: Equatable {
    let x: Double
    let y: Double
    let confidence: Float
}

struct StationPoseSample {
    /// Monotonic capture time in seconds, not wall-clock time.
    let timestamp: TimeInterval
    let joints: [StationJoint: StationJointPoint]
    let personCount: Int
}

enum StationTrackingStatus: Equatable {
    case seekingPosition, ready, moving, trackingLost, multiplePeople

    var message: String {
        switch self {
        case .seekingPosition: return "Step into view"
        case .ready: return "Ready"
        case .moving: return "Tracking"
        case .trackingLost: return "Reposition to resume"
        case .multiplePeople: return "One person at a time"
        }
    }
}

/// Experimental 2D angle cycles, not an assessment of form or range of motion.
/// A count is advisory only. This type has no set-completion or logging behavior.
struct StationRepCounter {
    private(set) var count = 0
    private(set) var status: StationTrackingStatus = .seekingPosition

    private var exercise: StationExercise
    private var lastTimestamp: TimeInterval?
    private var selectedSide: Side?
    private var phase: Phase = .seekingStart
    private var endpointCandidate: EndpointCandidate?
    private var standingSideCandidate: (side: Side, since: TimeInterval)?

#if DEBUG
    private var diagnosticTimestamp: TimeInterval?
    private var diagnosticAngle: Double?
    private var diagnosticConfidence: Float?

    var diagnosticSnapshot: StationCounterDiagnosticSnapshot {
        let phaseName: String
        switch phase {
        case .seekingStart: phaseName = "seeking_start"
        case .armed(let startedAt): phaseName = startedAt == nil ? "armed" : "descending"
        case .returning: phaseName = "returning"
        }
        let endpoint = endpointCandidate.map { $0.endpoint == .extended ? "extended" : "flexed" }
        return StationCounterDiagnosticSnapshot(
            timestamp: diagnosticTimestamp, angle: diagnosticAngle,
            minimumConfidence: diagnosticConfidence.map(Double.init), phase: phaseName,
            endpoint: endpoint,
            endpointDwell: endpointCandidate.flatMap { candidate in
                diagnosticTimestamp.map { max(0, $0 - candidate.since) }
            })
    }
#endif

    private static let minimumConfidence: Float = 0.6
    private static let endpointDwell: TimeInterval = 0.18
    private static let minimumCycleDuration: TimeInterval = 0.55
    private static let maximumSampleGap: TimeInterval = 0.5
    private static let maximumStandingSideAngleDifference = 10.0

    init(exercise: StationExercise) {
        self.exercise = exercise
    }

    mutating func reset(exercise: StationExercise) {
        self = StationRepCounter(exercise: exercise)
    }

    mutating func process(_ sample: StationPoseSample) {
#if DEBUG
        diagnosticTimestamp = sample.timestamp.isFinite ? sample.timestamp : nil
        diagnosticAngle = nil
        diagnosticConfidence = nil
#endif
        guard sample.timestamp.isFinite, sample.timestamp >= 0 else {
            loseTracking(.trackingLost)
            return
        }
        if let lastTimestamp, sample.timestamp <= lastTimestamp {
            // An out-of-order callback cannot advance dwell or alter newer state.
            return
        }
        let gap = lastTimestamp.map { sample.timestamp - $0 }
        lastTimestamp = sample.timestamp

        guard sample.personCount == 1 else {
            loseTracking(sample.personCount > 1 ? .multiplePeople : .trackingLost)
            return
        }
        guard gap.map({ $0 <= Self.maximumSampleGap }) ?? true else {
            // Frames skipped during a suspension must never bridge a rep.
            loseTracking(.trackingLost)
            return
        }

        let measurement: Measurement
        if let selectedSide {
            guard let current = measure(sample, side: selectedSide) else {
                // Do not substitute the other arm/leg halfway through a cycle.
                loseTracking(.trackingLost)
                return
            }
            measurement = standingMeasurement(sample, current: current)
        } else {
            let candidates = Side.allCases.compactMap { measure(sample, side: $0) }
            guard let best = candidates.max(by: { $0.confidence < $1.confidence }) else {
                loseTracking(.trackingLost)
                return
            }
            selectedSide = best.side
            measurement = best
        }

        let thresholds = thresholds
#if DEBUG
        diagnosticAngle = measurement.angle
        diagnosticConfidence = measurement.confidence
#endif
        let endpoint = stableEndpoint(angle: measurement.angle, timestamp: sample.timestamp)
        switch phase {
        case .seekingStart:
            status = .seekingPosition
            if endpoint?.endpoint == .extended {
                phase = .armed(startedAt: nil)
                status = .ready
            }
        case .armed(let startedAt):
            if endpoint?.endpoint == .extended {
                // Returning from a partial movement starts a fresh attempt.
                phase = .armed(startedAt: nil)
                status = .ready
            } else if measurement.angle < thresholds.extendedRetain {
                let start = startedAt ?? sample.timestamp
                phase = endpoint?.endpoint == .flexed
                    ? .returning(startedAt: start)
                    : .armed(startedAt: start)
                status = .moving
            } else {
                status = startedAt == nil ? .ready : .moving
            }
        case .returning(let startedAt):
            status = .moving
            if let endpoint, endpoint.endpoint == .extended {
                // Use arrival, not confirmation time: holding still after a
                // too-fast cycle cannot turn it into a valid repetition.
                if endpoint.since - startedAt >= Self.minimumCycleDuration {
                    count += 1
                }
                phase = .armed(startedAt: nil)
                status = .ready
            }
        }
    }

    private mutating func loseTracking(_ status: StationTrackingStatus) {
        self.status = status
        selectedSide = nil
        phase = .seekingStart
        endpointCandidate = nil
        standingSideCandidate = nil
    }

    private mutating func standingMeasurement(_ sample: StationPoseSample,
                                              current: Measurement) -> Measurement {
        // A turn can hide the selected limb. Change sides only between cycles,
        // while both limbs independently show a matching, sustained extension.
        // Missing selected joints still take the loss path above.
        guard case .armed(startedAt: nil) = phase,
              current.angle >= thresholds.extendedEnter,
              let alternate = measure(sample, side: current.side == .left ? .right : .left),
              alternate.confidence > current.confidence,
              alternate.angle >= thresholds.extendedEnter,
              abs(alternate.angle - current.angle) <= Self.maximumStandingSideAngleDifference else {
            standingSideCandidate = nil
            return current
        }
        if standingSideCandidate?.side != alternate.side {
            standingSideCandidate = (alternate.side, sample.timestamp)
        }
        guard let candidate = standingSideCandidate,
              sample.timestamp - candidate.since >= Self.endpointDwell else { return current }
        selectedSide = alternate.side
        standingSideCandidate = nil
        endpointCandidate = EndpointCandidate(endpoint: .extended, since: candidate.since)
        return alternate
    }

    private mutating func stableEndpoint(angle: Double, timestamp: TimeInterval) -> EndpointCandidate? {
        let limits = thresholds
        if let candidate = endpointCandidate {
            let retained = candidate.endpoint == .extended
                ? angle >= limits.extendedRetain
                : angle <= limits.flexedRetain
            if !retained { endpointCandidate = nil }
        }
        if endpointCandidate == nil {
            if angle >= limits.extendedEnter {
                endpointCandidate = EndpointCandidate(endpoint: .extended, since: timestamp)
            } else if angle <= limits.flexedEnter {
                endpointCandidate = EndpointCandidate(endpoint: .flexed, since: timestamp)
            }
        }
        guard let candidate = endpointCandidate,
              timestamp - candidate.since >= Self.endpointDwell else { return nil }
        return candidate
    }

    private func measure(_ sample: StationPoseSample, side: Side) -> Measurement? {
        let names: [StationJoint]
        switch (exercise, side) {
        case (.squat, .left): names = [.leftHip, .leftKnee, .leftAnkle]
        case (.squat, .right): names = [.rightHip, .rightKnee, .rightAnkle]
        case (_, .left): names = [.leftShoulder, .leftElbow, .leftWrist]
        case (_, .right): names = [.rightShoulder, .rightElbow, .rightWrist]
        }
        let points = names.compactMap { sample.joints[$0] }
        guard points.count == 3,
              points.allSatisfy({
                  $0.x.isFinite && $0.y.isFinite && $0.confidence.isFinite
                      && $0.confidence >= Self.minimumConfidence && $0.confidence <= 1
              }) else { return nil }
        let a = (x: points[0].x - points[1].x, y: points[0].y - points[1].y)
        let b = (x: points[2].x - points[1].x, y: points[2].y - points[1].y)
        let lengthA = hypot(a.x, a.y)
        let lengthB = hypot(b.x, b.y)
        guard lengthA.isFinite, lengthB.isFinite, lengthA > 0.000001, lengthB > 0.000001 else {
            return nil
        }
        let cosine = (a.x / lengthA) * (b.x / lengthB) + (a.y / lengthA) * (b.y / lengthB)
        let angle = acos(min(1, max(-1, cosine))) * 180 / .pi
        return Measurement(side: side, angle: angle, confidence: points.map(\.confidence).min()!)
    }

    private var thresholds: Thresholds {
        switch exercise {
        case .squat:
            return Thresholds(extendedEnter: 160, extendedRetain: 150, flexedEnter: 110, flexedRetain: 120)
        case .curl:
            return Thresholds(extendedEnter: 150, extendedRetain: 140, flexedEnter: 65, flexedRetain: 75)
        case .benchPress:
            return Thresholds(extendedEnter: 155, extendedRetain: 145, flexedEnter: 100, flexedRetain: 110)
        }
    }

    private enum Side: CaseIterable { case left, right }
    private enum Phase {
        case seekingStart
        case armed(startedAt: TimeInterval?)
        case returning(startedAt: TimeInterval)
    }
    private enum Endpoint { case extended, flexed }
    private struct EndpointCandidate {
        let endpoint: Endpoint
        let since: TimeInterval
    }
    private struct Measurement {
        let side: Side
        let angle: Double
        let confidence: Float
    }
    private struct Thresholds {
        let extendedEnter: Double
        let extendedRetain: Double
        let flexedEnter: Double
        let flexedRetain: Double
    }
}
