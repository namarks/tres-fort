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

    func isComplete(_ steps: [RunPlan.ExpandedStep]) -> Bool { stepIndex >= steps.count }

    /// Moves past every step the run has finished. Returns true when the
    /// step changed. A finished step's exact end becomes the next step's
    /// start, so a late update doesn't shorten the next step.
    mutating func advance(_ steps: [RunPlan.ExpandedStep], movingSeconds: Double, meters: Double) -> Bool {
        var changed = false
        while stepIndex < steps.count {
            let step = steps[stepIndex].step
            if let duration = step.durationSeconds {
                let end = stepStartSeconds + Double(duration)
                guard movingSeconds >= end else { break }
                stepStartSeconds = end
                stepStartMeters = meters
            } else if let distance = step.distanceMeters {
                let end = stepStartMeters + distance
                guard meters >= end else { break }
                stepStartMeters = end
                stepStartSeconds = movingSeconds
            } else {
                stepStartSeconds = movingSeconds
                stepStartMeters = meters
            }
            stepIndex += 1
            changed = true
        }
        return changed
    }

    /// Ends the current step now and starts the next.
    mutating func skip(_ steps: [RunPlan.ExpandedStep], movingSeconds: Double, meters: Double) {
        guard stepIndex < steps.count else { return }
        stepIndex += 1
        stepStartSeconds = movingSeconds
        stepStartMeters = meters
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
