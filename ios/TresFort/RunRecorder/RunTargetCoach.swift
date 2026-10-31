import Foundation

/// Decides when to say that a planned run's pace or heart rate has left its
/// target, and when it's back (docs/plans/planned-runs P3). Cues wait until
/// the step has settled, the change has held for a while and the last cue is
/// long enough ago, so GPS and heart rate noise don't chatter.
struct RunTargetCoach: Equatable {
    /// Where a reading sits against the target. For pace, `above` is
    /// slower than the slowest pace; for heart rate, higher than the top.
    enum Reading: Equatable {
        case onTarget, below, above
    }

    /// No target cue in a step's first seconds, while pace and heart rate
    /// settle.
    static let settleSeconds: Double = 20
    /// A change must hold this long before it's spoken.
    static let holdSeconds: Double = 10
    /// At most one target cue this often, counting the step's announcement.
    static let minimumGap: Double = 30
    /// Leaving the target needs this much margin; returning needs none.
    static let paceTolerance: Double = 5
    static let heartRateTolerance: Double = 2

    private(set) var announced: Reading?
    private var candidate: Reading?
    private var candidateSince: Double = 0
    private var lastCue: Double?

    /// A new step: nothing said about its target yet, and its announcement
    /// counts as the latest cue.
    mutating func startStep(at movingSeconds: Double) {
        announced = nil
        candidate = nil
        candidateSince = movingSeconds
        lastCue = movingSeconds
    }

    /// The reading for `value` (seconds per km, or bpm), or nil inside the
    /// margin just outside the range, where the last reading stands.
    static func reading(_ value: Double, target: RunPlan.Target) -> Reading? {
        let bounds: (low: Double, high: Double, tolerance: Double)
        switch target {
        case .pace(let fastest, let slowest):
            bounds = (Double(fastest), Double(slowest), paceTolerance)
        case .heartRate(let minimum, let maximum):
            bounds = (Double(minimum), Double(maximum), heartRateTolerance)
        }
        let (low, high, tolerance) = bounds
        if value >= low && value <= high { return .onTarget }
        if value > high + tolerance { return .above }
        if value < low - tolerance { return .below }
        return nil
    }

    /// What to say now, if anything. `value` is the smoothed pace in seconds
    /// per km or the heart rate; nil when there's none to judge.
    mutating func update(target: RunPlan.Target, value: Double?, stepSeconds: Double,
                         movingSeconds: Double) -> String? {
        guard let value, let reading = Self.reading(value, target: target) else { return nil }
        if reading != candidate {
            candidate = reading
            candidateSince = movingSeconds
        }
        guard stepSeconds >= Self.settleSeconds,
              movingSeconds - candidateSince >= Self.holdSeconds,
              reading != (announced ?? .onTarget),
              lastCue.map({ movingSeconds - $0 >= Self.minimumGap }) ?? true else { return nil }
        announced = reading
        lastCue = movingSeconds
        return Self.cue(reading, target: target)
    }

    static func cue(_ reading: Reading, target: RunPlan.Target) -> String {
        switch (target, reading) {
        case (.pace, .above): "Speed up."
        case (.pace, .below): "Ease off."
        case (.pace, .onTarget): "On pace."
        case (.heartRate, .above): "Heart rate high. Ease off."
        case (.heartRate, .below): "Heart rate low. Pick it up."
        case (.heartRate, .onTarget): "Heart rate on target."
        }
    }
}

extension RunPlanFormat {
    /// "Step 3 of 9. Rep 1 of 4. 800 meters at 6:34 to 6:50 per mile."
    static func spoken(_ step: RunPlan.ExpandedStep, index: Int, count: Int, unit: RunDistanceUnit) -> String {
        var parts = ["Step \(index + 1) of \(count)."]
        if let round = step.round, let rounds = step.rounds { parts.append("Rep \(round) of \(rounds).") }
        let amount: String
        if let meters = step.step.distanceMeters {
            amount = spokenDistance(meters, unit: unit)
        } else {
            amount = RunSplit.spoken(Double(step.step.durationSeconds ?? 0))
        }
        let kind: String
        switch step.step.kind {
        case .warmup: kind = " warm-up"
        case .work: kind = ""
        case .recovery: kind = " recovery"
        case .cooldown: kind = " cool-down"
        }
        var sentence = amount + kind
        if let target = step.step.target { sentence += " at " + spokenTarget(target, unit: unit) }
        parts.append(sentence + ".")
        return parts.joined(separator: " ")
    }

    /// "800 meters", "1 mile", "3.11 miles", "5 kilometers".
    static func spokenDistance(_ meters: Double, unit: RunDistanceUnit) -> String {
        if meters < 1_000 { return "\(Int(meters.rounded())) meters" }
        let text = distance(meters, unit: unit).replacingOccurrences(of: " " + unit.abbreviation, with: "")
        return text + " " + unit.spokenName + (text == "1" ? "" : "s")
    }

    /// "6:34 to 6:50 per mile", "130 to 145 beats per minute".
    static func spokenTarget(_ target: RunPlan.Target, unit: RunDistanceUnit) -> String {
        switch target {
        case .pace(let fastest, let slowest):
            let scale = unit.meters / 1_000
            let low = RunFormat.pace(Double(fastest) * scale)
            let high = RunFormat.pace(Double(slowest) * scale)
            return (low == high ? low : "\(low) to \(high)") + " per \(unit.spokenName)"
        case .heartRate(let low, let high):
            return (low == high ? "\(low)" : "\(low) to \(high)") + " beats per minute"
        }
    }
}
