import Foundation

extension RunPlan {
    /// One step as the runner meets it, with repeats unrolled.
    struct ExpandedStep: Equatable {
        var step: Step
        /// Which time through a repeat group this is, counting from 1, and
        /// how many times the group repeats. Nil outside a repeat.
        var round: Int?
        var rounds: Int?
    }

    var expandedSteps: [ExpandedStep] {
        items.flatMap { item -> [ExpandedStep] in
            switch item {
            case .step(let step):
                return [ExpandedStep(step: step, round: nil, rounds: nil)]
            case .repeated(let times, let steps):
                return (1...max(times, 1)).flatMap { round in
                    steps.map { ExpandedStep(step: $0, round: round, rounds: times) }
                }
            }
        }
    }
}

/// Where a recording run is in its plan (docs/plans/planned-runs P2). A step
/// ends when its moving time or distance is done, so pauses don't count, and
/// the member can skip one. Saved with the run's checkpoint, so a recovered
/// run picks up at the same step.
struct RunPlanProgress: Codable, Equatable {
    /// The index of the current step in `RunPlan.expandedSteps`; equal to
    /// their count once the plan is done.
    var stepIndex: Int = 0
    /// The run's moving seconds and meters when the current step started.
    var stepStartSeconds: Double = 0
    var stepStartMeters: Double = 0
    /// The moving seconds and meters of the previous update, so a step's end
    /// that falls between two updates can be placed between them.
    var lastSeconds: Double? = nil
    var lastMeters: Double? = nil

    func isComplete(_ steps: [RunPlan.ExpandedStep]) -> Bool { stepIndex >= steps.count }

    /// Moves past every step the run has finished. Returns true when the
    /// step changed. A step that ended between this update and the previous
    /// one ends where steady running between them would have crossed it, in
    /// both time and distance, so a late update doesn't shorten or stretch
    /// the next step.
    mutating func advance(_ steps: [RunPlan.ExpandedStep], movingSeconds: Double, meters: Double) -> Bool {
        // The last known point on the run, no earlier than the step's start.
        var fromSeconds = min(max(lastSeconds ?? stepStartSeconds, stepStartSeconds), movingSeconds)
        var fromMeters = min(max(lastMeters ?? stepStartMeters, stepStartMeters), meters)
        lastSeconds = movingSeconds
        lastMeters = meters
        var changed = false
        while stepIndex < steps.count {
            let step = steps[stepIndex].step
            if let duration = step.durationSeconds {
                let end = stepStartSeconds + Double(duration)
                guard movingSeconds >= end else { break }
                let at = Self.between(end, from: fromSeconds, to: movingSeconds,
                                      values: fromMeters, meters)
                stepStartSeconds = end
                stepStartMeters = at
            } else if let distance = step.distanceMeters {
                let end = stepStartMeters + distance
                guard meters >= end else { break }
                let at = Self.between(end, from: fromMeters, to: meters,
                                      values: fromSeconds, movingSeconds)
                stepStartMeters = end
                stepStartSeconds = at
            } else {
                stepStartSeconds = movingSeconds
                stepStartMeters = meters
            }
            fromSeconds = max(fromSeconds, stepStartSeconds)
            fromMeters = max(fromMeters, stepStartMeters)
            stepIndex += 1
            changed = true
        }
        return changed
    }

    /// The value at `point` on a straight line from (`from`, `low`) to
    /// (`to`, `high`), kept within the two.
    private static func between(_ point: Double, from: Double, to: Double,
                                values low: Double, _ high: Double) -> Double {
        guard to > from else { return high }
        let fraction = min(max((point - from) / (to - from), 0), 1)
        return low + (high - low) * fraction
    }

    /// Ends the current step now and starts the next.
    mutating func skip(_ steps: [RunPlan.ExpandedStep], movingSeconds: Double, meters: Double) {
        guard stepIndex < steps.count else { return }
        stepIndex += 1
        stepStartSeconds = movingSeconds
        stepStartMeters = meters
        lastSeconds = movingSeconds
        lastMeters = meters
    }

    /// What's left of the current step: "2:15 left", "420 m left" or
    /// "1.25 mi left". Nil once the plan is done.
    func remaining(_ steps: [RunPlan.ExpandedStep], movingSeconds: Double, meters: Double,
                   unit: RunDistanceUnit) -> String? {
        guard stepIndex < steps.count else { return nil }
        let step = steps[stepIndex].step
        if let duration = step.durationSeconds {
            let left = max(0, stepStartSeconds + Double(duration) - movingSeconds)
            return RunFormat.duration(left.rounded(.up)) + " left"
        }
        if let distance = step.distanceMeters {
            let left = max(0, stepStartMeters + distance - meters)
            return RunPlanFormat.distance(left, unit: unit) + " left"
        }
        return nil
    }
}

/// The plan a recording run follows, kept in its checkpoint.
struct RunPlanFollowing: Codable, Equatable {
    /// The slot's `run_steps` text when the run started.
    var runSteps: String
    var progress = RunPlanProgress()
}
