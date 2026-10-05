import Foundation

/// Which part of the body the planned exercise moves. A hint, never a camera
/// requirement: it only limits which 3D joint angles may become the counted signal.
enum StationBodyRegion: Equatable {
    case lowerBody, upperBody, wholeBody
}

enum StationBodySide: String, Equatable {
    case left, right
}

/// One MediaPipe frame in hip-centred 3D model coordinates. `landmarks` is nil
/// unless exactly one person was detected.
struct StationWorldPoseSample {
    /// Monotonic capture time in seconds, not wall-clock time.
    let timestamp: TimeInterval
    let landmarks: [StationMediaPipeWorldLandmark]?
    let personCount: Int
}

/// A 3D joint angle the generic counter may follow, named after its vertex.
struct StationAngleSignal: Equatable {
    let name: String
    let region: StationBodyRegion
    let side: StationBodySide
    /// MediaPipe pose landmark indices; the angle is measured at `vertex`.
    let first: Int
    let vertex: Int
    let last: Int

    static let all: [StationAngleSignal] = [
        StationAngleSignal(name: "leftKnee", region: .lowerBody, side: .left, first: 23, vertex: 25, last: 27),
        StationAngleSignal(name: "rightKnee", region: .lowerBody, side: .right, first: 24, vertex: 26, last: 28),
        StationAngleSignal(name: "leftHip", region: .lowerBody, side: .left, first: 11, vertex: 23, last: 25),
        StationAngleSignal(name: "rightHip", region: .lowerBody, side: .right, first: 12, vertex: 24, last: 26),
        StationAngleSignal(name: "leftElbow", region: .upperBody, side: .left, first: 11, vertex: 13, last: 15),
        StationAngleSignal(name: "rightElbow", region: .upperBody, side: .right, first: 12, vertex: 14, last: 16),
        StationAngleSignal(name: "leftShoulder", region: .upperBody, side: .left, first: 13, vertex: 11, last: 23),
        StationAngleSignal(name: "rightShoulder", region: .upperBody, side: .right, first: 14, vertex: 12, last: 24)
    ]

    static func candidates(region: StationBodyRegion, side: StationBodySide?) -> [StationAngleSignal] {
        all.filter { signal in
            (region == .wholeBody || signal.region == region) && (side == nil || signal.side == side)
        }
    }

    /// The angle in degrees, or nil when any landmark is missing, non-finite,
    /// below the confidence cutoff, or the limb segments are degenerate.
    func angle(in landmarks: [StationMediaPipeWorldLandmark], minimumConfidence: Float) -> Double? {
        guard [first, vertex, last].allSatisfy({ $0 < landmarks.count }) else { return nil }
        let points = [landmarks[first], landmarks[vertex], landmarks[last]]
        guard points.allSatisfy({ point in
            let score = min(point.visibility ?? 0, point.presence ?? 0)
            return point.x.isFinite && point.y.isFinite && point.z.isFinite
                && score.isFinite && score >= minimumConfidence
        }) else { return nil }
        let a = (Double(points[0].x - points[1].x), Double(points[0].y - points[1].y), Double(points[0].z - points[1].z))
        let b = (Double(points[2].x - points[1].x), Double(points[2].y - points[1].y), Double(points[2].z - points[1].z))
        let lengthA = (a.0 * a.0 + a.1 * a.1 + a.2 * a.2).squareRoot()
        let lengthB = (b.0 * b.0 + b.1 * b.1 + b.2 * b.2).squareRoot()
        guard lengthA.isFinite, lengthB.isFinite, lengthA > 0.000001, lengthB > 0.000001 else { return nil }
        let cosine = (a.0 * b.0 + a.1 * b.1 + a.2 * b.2) / (lengthA * lengthB)
        return acos(min(1, max(-1, cosine))) * 180 / .pi
    }
}

/// Experimental exercise-agnostic counter for saved-clip replay. It follows every
/// 3D joint angle in the hinted region. When the first clear out-and-back cycle
/// completes, the largest cycle completed within a short window becomes the
/// set's signal; it also sets the reference amplitude and direction for later
/// cycles. There is no per-exercise
/// angle threshold and no required camera view. Counts are advisory estimates;
/// this type has no logging, rest or completion behavior.
struct StationGenericCounter {
    /// Includes a first cycle whose signal choice is still pending.
    var count: Int { completedCycles + (pendingLock == nil ? 0 : 1) }
    private(set) var status: StationTrackingStatus = .seekingPosition
    /// The signal chosen by the first completed cycle, if any. While that choice
    /// is pending it is the current best candidate, so a count is never shown
    /// without its signal, even when a clip ends inside the lock window.
    var lockedSignal: String? { chosen.map { trackers[$0].signal.name } }
    /// True when joints were missing on a frame where the person was otherwise
    /// tracked: the chosen signal's joints once there is one, else any candidate's,
    /// so an unobservable movement is never shown as a reliable zero.
    var missedSignalData: Bool {
        if let chosen { return trackers[chosen].missedData }
        return trackers.contains { $0.missedData }
    }

    private var trackers: [Tracker]
    private var locked: Int?
    private var completedCycles = 0
    /// Joints that move together (knee and hip in a squat) finish their first
    /// cycles a few frames apart. Wait briefly so the largest one is chosen.
    private var pendingLock: (since: TimeInterval, completed: Set<Int>)?
    private var lastTimestamp: TimeInterval?

    static let minimumConfidence: Float = 0.6
    static let maximumSampleGap: TimeInterval = 0.5
    static let minimumCycleDuration: TimeInterval = 0.55
    static let maximumCycleDuration: TimeInterval = 12
    static let restDwell: TimeInterval = 0.18
    static let restStillness = 8.0
    /// Before calibration a cycle must move at least this far from rest.
    static let minimumAmplitude = 30.0
    /// After calibration a cycle must reach this share of the first cycle's amplitude.
    static let calibratedAmplitudeShare = 0.6
    /// Shorter than the minimum cycle, so no candidate can finish twice inside it.
    static let lockWindow: TimeInterval = 0.3

    init(region: StationBodyRegion, side: StationBodySide? = nil) {
        trackers = StationAngleSignal.candidates(region: region, side: side).map { Tracker(signal: $0) }
    }

    mutating func process(_ sample: StationWorldPoseSample) {
        guard sample.timestamp.isFinite, sample.timestamp >= 0 else {
            loseTracking(.trackingLost)
            return
        }
        if let lastTimestamp, sample.timestamp <= lastTimestamp { return }
        let gap = lastTimestamp.map { sample.timestamp - $0 }
        lastTimestamp = sample.timestamp
        guard sample.personCount == 1, let landmarks = sample.landmarks else {
            loseTracking(sample.personCount > 1 ? .multiplePeople : .trackingLost)
            return
        }
        guard gap.map({ $0 <= Self.maximumSampleGap }) ?? true else {
            // Skipped frames must never bridge a cycle.
            loseTracking(.trackingLost)
            return
        }

        if let locked {
            guard let angle = trackers[locked].signal.angle(in: landmarks, minimumConfidence: Self.minimumConfidence) else {
                // Keep the chosen signal and its calibration, but restart the cycle.
                trackers[locked].markMissing()
                status = .trackingLost
                return
            }
            if trackers[locked].process(angle: angle, at: sample.timestamp) { completedCycles += 1 }
            status = trackers[locked].status
            return
        }

        var visible = false
        var completed: [Int] = []
        for index in trackers.indices {
            guard let angle = trackers[index].signal.angle(in: landmarks, minimumConfidence: Self.minimumConfidence) else {
                // Other candidates may still be visible, so overall status can stay
                // tracked; remember the gap in case this candidate becomes the signal.
                trackers[index].markMissing()
                continue
            }
            visible = true
            if trackers[index].process(angle: angle, at: sample.timestamp) { completed.append(index) }
        }
        if !completed.isEmpty {
            let since = pendingLock?.since ?? sample.timestamp
            pendingLock = (since: since, completed: (pendingLock?.completed ?? []).union(completed))
        }
        if let pendingLock, sample.timestamp - pendingLock.since >= Self.lockWindow {
            finishLock()
        }
        if let locked {
            status = trackers[locked].status
            return
        }
        guard visible else {
            status = .trackingLost
            return
        }
        let statuses = trackers.map(\.status)
        status = statuses.contains(.moving) ? .moving : statuses.contains(.ready) ? .ready : .seekingPosition
    }

    private mutating func loseTracking(_ status: StationTrackingStatus) {
        // A cycle that already completed still counts; settle its signal now.
        finishLock()
        self.status = status
        for index in trackers.indices { trackers[index].reset() }
    }

    /// The locked signal, or the largest candidate completed in the pending lock window.
    private var chosen: Int? {
        if let locked { return locked }
        return pendingLock?.completed.max { left, right in
            let leftAmplitude = trackers[left].amplitude ?? 0
            let rightAmplitude = trackers[right].amplitude ?? 0
            return leftAmplitude == rightAmplitude ? left > right : leftAmplitude < rightAmplitude
        }
    }

    private mutating func finishLock() {
        guard pendingLock != nil else { return }
        let best = chosen
        pendingLock = nil
        guard let best else { return }
        locked = best
        completedCycles += 1
    }

    private struct Tracker {
        let signal: StationAngleSignal
        private(set) var amplitude: Double?
        private(set) var missedData = false
        private var direction: Double?
        /// The resting angle of the first completed cycle. Reacquisition returns
        /// to it, so a pause at the far end of a rep can never become the rest.
        private var calibratedRest: Double?
        private var smoothed: Double?
        private var rest: Double?
        private var restCandidate: (value: Double, since: TimeInterval)?
        private var excursion: (startedAt: TimeInterval, sign: Double, extreme: Double)?

        init(signal: StationAngleSignal) { self.signal = signal }

        var status: StationTrackingStatus {
            if excursion != nil { return .moving }
            return rest == nil ? .seekingPosition : .ready
        }

        /// Restarts the current cycle and rest position. Calibration survives,
        /// so a member who steps out of view keeps the set's reference rep and
        /// resumes only once back near its resting angle.
        mutating func reset() {
            smoothed = nil
            rest = nil
            restCandidate = nil
            excursion = nil
        }

        /// A reset caused by this signal's own joints going missing.
        mutating func markMissing() {
            reset()
            missedData = true
        }

        private var departure: Double { max(12, 0.25 * (amplitude ?? 0)) }
        private var returnTolerance: Double { max(10, 0.25 * (amplitude ?? 0)) }
        /// The absolute floor applies only until the first cycle sets the reference.
        private var requiredAmplitude: Double {
            amplitude.map { StationGenericCounter.calibratedAmplitudeShare * $0 }
                ?? StationGenericCounter.minimumAmplitude
        }

        /// Returns true when this sample completes a valid cycle.
        mutating func process(angle raw: Double, at timestamp: TimeInterval) -> Bool {
            let value = smoothed.map { 0.5 * $0 + 0.5 * raw } ?? raw
            smoothed = value
            guard let rest else {
                if let calibratedRest {
                    if abs(value - calibratedRest) <= returnTolerance { self.rest = calibratedRest }
                } else if let candidate = restCandidate, abs(value - candidate.value) <= StationGenericCounter.restStillness {
                    if timestamp - candidate.since >= StationGenericCounter.restDwell { self.rest = candidate.value }
                } else {
                    restCandidate = (value: value, since: timestamp)
                }
                return false
            }
            let offset = value - rest
            guard let current = excursion else {
                // The rest angle stays fixed: following it would absorb a slow rep.
                if abs(offset) >= departure {
                    excursion = (startedAt: timestamp, sign: offset > 0 ? 1.0 : -1.0, extreme: value)
                }
                return false
            }
            if timestamp - current.startedAt > StationGenericCounter.maximumCycleDuration {
                // Too long to be one repetition: find a new resting position.
                reset()
                return false
            }
            if current.sign * offset > current.sign * (current.extreme - rest) {
                excursion = (startedAt: current.startedAt, sign: current.sign, extreme: value)
            }
            guard current.sign * offset <= returnTolerance else { return false }
            let reached = abs(current.extreme - rest)
            excursion = nil
            guard reached >= requiredAmplitude,
                  direction.map({ $0 == current.sign }) ?? true,
                  timestamp - current.startedAt >= StationGenericCounter.minimumCycleDuration else { return false }
            if amplitude == nil {
                // The first completed cycle is the set's fixed reference. Later
                // reps never move it, so a drift of short reps cannot lower the bar.
                direction = current.sign
                amplitude = reached
                calibratedRest = rest
            }
            return true
        }
    }
}

/// Maps the three prototype exercises to region hints. Curls count each arm
/// separately and never sum them, matching the angle-rule counter.
struct StationGenericMovementCounter {
    private let exercise: StationExercise
    private var single: StationGenericCounter
    private var left = StationGenericCounter(region: .upperBody, side: .left)
    private var right = StationGenericCounter(region: .upperBody, side: .right)

    static let version = "generic-3d-v1"

    init(exercise: StationExercise) {
        self.exercise = exercise
        single = StationGenericCounter(region: exercise == .squat ? .lowerBody : .upperBody)
    }

    /// Compatibility value only: max(left, right) for curls, never their sum.
    var count: Int { exercise == .curl ? max(left.count, right.count) : single.count }
    var leftCount: Int? { exercise == .curl ? left.count : nil }
    var rightCount: Int? { exercise == .curl ? right.count : nil }

    var hasTrackingLoss: Bool {
        exercise == .curl
            ? Self.hasTrackingLoss(left) || Self.hasTrackingLoss(right)
            : Self.hasTrackingLoss(single)
    }

    private static func hasTrackingLoss(_ counter: StationGenericCounter) -> Bool {
        counter.status == .trackingLost || counter.missedSignalData
    }

    var signalDescription: String? {
        guard exercise == .curl else { return single.lockedSignal }
        let names = [left.lockedSignal, right.lockedSignal].compactMap { $0 }
        return names.isEmpty ? nil : names.joined(separator: ", ")
    }

    mutating func process(_ sample: StationWorldPoseSample) {
        if exercise == .curl {
            left.process(sample)
            right.process(sample)
        } else {
            single.process(sample)
        }
    }
}
