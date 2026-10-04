import Foundation

/// Curls have independent arm cycles: a clearer resting arm must not hide the
/// working arm. Other exercises retain the existing single-limb counter.
struct StationMovementCounter {
    private var exercise: StationExercise
    private var single: StationRepCounter
    private var left = StationRepCounter(exercise: .curl)
    private var right = StationRepCounter(exercise: .curl)

    /// Compatibility value only. Curl UI and reports should show both arms;
    /// simultaneous curls must not become twice as many combined cycles.
    var count: Int { exercise == .curl ? max(left.count, right.count) : single.count }
    var leftCount: Int? { exercise == .curl ? left.count : nil }
    var rightCount: Int? { exercise == .curl ? right.count : nil }
    var leftStatus: StationTrackingStatus? { exercise == .curl ? left.status : nil }
    var rightStatus: StationTrackingStatus? { exercise == .curl ? right.status : nil }

    var status: StationTrackingStatus {
        guard exercise == .curl else { return single.status }
        let statuses = [left.status, right.status]
        if statuses.contains(.multiplePeople) { return .multiplePeople }
        if statuses.contains(.moving) { return .moving }
        if statuses.contains(.ready) { return .ready }
        if statuses.contains(.seekingPosition) { return .seekingPosition }
        return .trackingLost
    }

    init(exercise: StationExercise) {
        self.exercise = exercise
        single = StationRepCounter(exercise: exercise)
    }

    mutating func reset(exercise: StationExercise) {
        self = Self(exercise: exercise)
    }

    mutating func process(_ sample: StationPoseSample) {
        guard exercise == .curl else { single.process(sample); return }
        // Each counter can only acquire its own shoulder/elbow/wrist. Missing
        // joints reset that arm, while person and timestamp guards reach both.
        left.process(armSample(sample, joints: [.leftShoulder, .leftElbow, .leftWrist]))
        right.process(armSample(sample, joints: [.rightShoulder, .rightElbow, .rightWrist]))
    }

    private func armSample(_ sample: StationPoseSample, joints: Set<StationJoint>) -> StationPoseSample {
        StationPoseSample(timestamp: sample.timestamp,
                          joints: sample.joints.filter { joints.contains($0.key) },
                          personCount: sample.personCount)
    }

#if DEBUG
    /// There is no single representative arm phase for a curl trial.
    var diagnosticSnapshot: StationCounterDiagnosticSnapshot? {
        exercise == .curl ? nil : single.diagnosticSnapshot
    }
    var leftDiagnosticSnapshot: StationCounterDiagnosticSnapshot? {
        exercise == .curl ? left.diagnosticSnapshot : nil
    }
    var rightDiagnosticSnapshot: StationCounterDiagnosticSnapshot? {
        exercise == .curl ? right.diagnosticSnapshot : nil
    }
#endif
}
