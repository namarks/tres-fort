import Foundation

/// The training load a recorded run gets on the Worker, worked out on the
/// iPhone so the summary shows it the moment the run stops
/// (docs/plans/run-recorder P7). It mirrors `src/trainingLoad.ts` for a
/// recording: heart rate on moving time against the run threshold heart
/// rate, then average pace against threshold pace, then average heart rate.
/// One hour at threshold is 100.
enum RunLoad {
    enum Method: Equatable {
        case heartRate
        case pace
        case averageHeartRate
    }

    struct Result: Equatable {
        let load: Int
        let method: Method
    }

    /// A gap longer than this is a pause in the stream (MAX_SAMPLE_GAP_SEC).
    static let maxSampleGap: TimeInterval = 10
    /// The stream must cover this share of moving time (MIN_STREAM_COVERAGE).
    static let minimumCoverage = 0.8
    /// And at least this many seconds.
    static let minimumCoveredSeconds: TimeInterval = 30

    static func estimate(_ run: RecordedRun, movingSeconds: Double,
                         thresholdHeartRate: Double?, thresholdPacePerKm: Double?) -> Result? {
        let moving = movingSeconds > 0 ? movingSeconds : nil
        if let threshold = positive(thresholdHeartRate),
           let summary = heartRateSummary(run, movingSeconds: moving) {
            let ratio = summary.rms / threshold
            return result(summary.seconds / 3600 * ratio * ratio * 100, .heartRate)
        }
        if let threshold = positive(thresholdPacePerKm), let moving, run.distanceMeters > 0 {
            let ratio = threshold / (moving / (run.distanceMeters / 1000))
            return result(moving / 3600 * ratio * ratio * 100, .pace)
        }
        if let threshold = positive(thresholdHeartRate), let moving, let average = run.averageHeartRate,
           average > 0 {
            let ratio = average / threshold
            return result(moving / 3600 * ratio * ratio * 100, .averageHeartRate)
        }
        return nil
    }

    /// Root mean square of the readings over the moving seconds they cover,
    /// as `heartRateStreamSummary` reduces them. Nil when the readings cover
    /// too little of the run.
    static func heartRateSummary(_ run: RecordedRun, movingSeconds: Double?) -> (rms: Double, seconds: Double)? {
        var samples: [(t: Double, v: Double)] = []
        for reading in run.heartRates.sorted(by: { $0.timestamp < $1.timestamp })
        where reading.beatsPerMinute > 0 && !run.isPaused(at: reading.timestamp) {
            let t = run.movingOffset(at: reading.timestamp)
            if let last = samples.last, t <= last.t { continue }
            samples.append((t, reading.beatsPerMinute))
        }
        var squares = 0.0
        var seconds = 0.0
        for (index, sample) in samples.enumerated() {
            let gap = index + 1 < samples.count ? samples[index + 1].t - sample.t : .infinity
            let dt = gap <= maxSampleGap ? gap : 1
            squares += dt * sample.v * sample.v
            seconds += dt
        }
        guard seconds >= minimumCoveredSeconds else { return nil }
        if let movingSeconds, seconds / movingSeconds < minimumCoverage { return nil }
        return (sqrt(squares / seconds), seconds)
    }

    private static func positive(_ value: Double?) -> Double? {
        guard let value, value.isFinite, value > 0 else { return nil }
        return value
    }

    private static func result(_ load: Double, _ method: Method) -> Result? {
        guard load.isFinite, load >= 0 else { return nil }
        return Result(load: Int(load.rounded()), method: method)
    }
}

extension RecordedRun {
    /// Inside a pause the member or auto-pause started.
    func isPaused(at date: Date) -> Bool {
        pauses.contains { date >= $0.start && date < ($0.end ?? .distantFuture) }
    }

    /// Moving seconds from the start to `date`: wall time minus the pauses
    /// before it.
    func movingOffset(at date: Date) -> Double {
        let paused = pauses.reduce(0.0) { total, pause in
            let start = max(pause.start, startedAt)
            let end = min(pause.end ?? date, date)
            return total + max(0, end.timeIntervalSince(start))
        }
        return max(0, date.timeIntervalSince(startedAt) - paused)
    }
}
