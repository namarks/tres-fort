import Foundation

/// One lap of a planned run as the recorder saves it (docs/plans/planned-runs
/// P9): a step the run finished, skipped or stopped in, or the stretch run
/// after the plan finished, with its moving time, distance and heart rate.
struct RunLapSummary: Equatable {
    enum End: String {
        case completed, skipped, stopped
    }

    /// The step's index in `RunPlan.expandedSteps`; nil after the plan.
    var stepIndex: Int?
    var step: RunPlan.ExpandedStep?
    /// Moving seconds from the run's start to the lap's start.
    var startSeconds: Double
    var movingSeconds: Double
    var meters: Double
    var averageHeartRate: Int?
    var maxHeartRate: Int?
    var end: End
}

/// A planned run's laps, from the step marks its plan progress kept while it
/// recorded. They go to Tres Fort as the upload's `laps` field
/// (src/runLaps.ts) and to intervals.icu as the TCX file's laps, so both
/// show each interval on its own instead of only the whole run, whose
/// average a walk to cool down would drag down.
enum RunLaps {
    /// Heart rates outside this range are dropped, as the server would.
    static let heartRateRange = 20.0...250.0

    /// Empty for a run without a plan, or one saved before laps were kept.
    static func summaries(_ run: RecordedRun) -> [RunLapSummary] {
        guard let following = run.plan,
              let steps = RunPlan(json: following.runSteps)?.expandedSteps, !steps.isEmpty else { return [] }
        let progress = following.progress
        // A run checkpointed before laps were kept knows only its current step.
        guard let marks = progress.laps ?? (progress.stepIndex == 0 ? [] : nil) else { return [] }
        var laps: [RunLapSummary] = marks.compactMap { mark in
            guard steps.indices.contains(mark.stepIndex) else { return nil }
            return RunLapSummary(stepIndex: mark.stepIndex, step: steps[mark.stepIndex],
                                 startSeconds: mark.startSeconds,
                                 movingSeconds: max(0, mark.endSeconds - mark.startSeconds),
                                 meters: max(0, mark.endMeters - mark.startMeters),
                                 end: mark.skipped ? .skipped : .completed)
        }
        // From the last mark to the end: the step the run stopped in, or
        // what was run after the plan finished. The run's own totals close
        // it, so the laps add up to the run.
        let totalSeconds = run.movingSeconds > 0 ? run.movingSeconds : run.activeSeconds(at: run.endedAt ?? Date())
        let lastSeconds = max(0, totalSeconds - progress.stepStartSeconds)
        let lastMeters = max(0, run.distanceMeters - progress.stepStartMeters)
        if lastSeconds >= 1 || lastMeters >= 1 {
            let onStep = steps.indices.contains(progress.stepIndex)
            laps.append(RunLapSummary(stepIndex: onStep ? progress.stepIndex : nil,
                                      step: onStep ? steps[progress.stepIndex] : nil,
                                      startSeconds: progress.stepStartSeconds,
                                      movingSeconds: lastSeconds, meters: lastMeters, end: .stopped))
        }
        guard !laps.isEmpty else { return [] }
        addHeartRates(run, to: &laps)
        return laps
    }

    /// Each lap's average and maximum of the readings taken while it ran;
    /// readings during a pause count for none.
    private static func addHeartRates(_ run: RecordedRun, to laps: inout [RunLapSummary]) {
        var readings = Array(repeating: [Double](), count: laps.count)
        for sample in run.heartRates where heartRateRange.contains(sample.beatsPerMinute) {
            guard !isPaused(run, at: sample.timestamp) else { continue }
            let moving = movingSeconds(run, at: sample.timestamp)
            guard let index = laps.lastIndex(where: { $0.startSeconds <= moving }) else { continue }
            // Only the last lap runs on past its own time.
            if index < laps.count - 1, moving >= laps[index].startSeconds + laps[index].movingSeconds { continue }
            readings[index].append(sample.beatsPerMinute)
        }
        for index in laps.indices where !readings[index].isEmpty {
            let values = readings[index]
            laps[index].averageHeartRate = Int((values.reduce(0, +) / Double(values.count)).rounded())
            laps[index].maxHeartRate = Int((values.max() ?? 0).rounded())
        }
    }

    /// The run's moving seconds at `date`: time since the start, pauses
    /// taken out, the way the plan counted them while the run recorded.
    static func movingSeconds(_ run: RecordedRun, at date: Date) -> Double {
        let paused = run.pauses.reduce(0.0) { total, pause in
            let pauseEnd = min(pause.end ?? date, date)
            return total + max(0, pauseEnd.timeIntervalSince(max(pause.start, run.startedAt)))
        }
        return max(0, date.timeIntervalSince(run.startedAt) - paused)
    }

    static func isPaused(_ run: RecordedRun, at date: Date) -> Bool {
        run.pauses.contains { $0.start <= date && ($0.end.map { date < $0 } ?? true) }
    }

    /// When the run reached `seconds` of moving time.
    static func date(_ run: RecordedRun, atMoving seconds: Double) -> Date {
        var time = run.startedAt
        var left = max(0, seconds)
        for pause in run.pauses.sorted(by: { $0.start < $1.start }) {
            guard let end = pause.end else { break }
            if pause.start > time {
                let running = pause.start.timeIntervalSince(time)
                if running >= left { break }
                left -= running
            }
            time = max(time, end)
        }
        return time.addingTimeInterval(left)
    }

    // MARK: - Upload

    /// The `laps` field of the upload (src/runLaps.ts): JSON, seconds and
    /// meters to a tenth. Nil for a run without laps.
    static func uploadJSON(_ laps: [RunLapSummary]) -> String? {
        guard !laps.isEmpty else { return nil }
        let tenth = { (value: Double) in (value * 10).rounded() / 10 }
        let objects: [[String: Any]] = laps.map { lap in
            var object: [String: Any] = [
                "start_s": tenth(lap.startSeconds),
                "moving_s": tenth(lap.movingSeconds),
                "distance_m": tenth(lap.meters),
                "end": lap.end.rawValue,
            ]
            if let index = lap.stepIndex, let expanded = lap.step {
                object["step"] = index + 1
                object["kind"] = expanded.step.kind.rawValue
                if let round = expanded.round, let rounds = expanded.rounds {
                    object["round"] = round
                    object["rounds"] = rounds
                }
                if let seconds = expanded.step.durationSeconds {
                    object["planned_duration_s"] = seconds
                } else if let meters = expanded.step.distanceMeters {
                    object["planned_distance_m"] = meters
                }
                switch expanded.step.target {
                case .pace(let fastest, let slowest):
                    object["target"] = ["type": "pace", "fastest_s_per_km": fastest, "slowest_s_per_km": slowest]
                case .heartRate(let low, let high):
                    object["target"] = ["type": "heart_rate", "min_bpm": low, "max_bpm": high]
                case nil:
                    break
                }
            }
            if let bpm = lap.averageHeartRate { object["avg_hr"] = bpm }
            if let bpm = lap.maxHeartRate { object["max_hr"] = bpm }
            return object
        }
        guard let data = try? JSONSerialization.data(withJSONObject: objects, options: [.sortedKeys]) else {
            return nil
        }
        return String(data: data, encoding: .utf8)
    }
}
