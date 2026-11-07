import Foundation

/// The training load a recorded run gets on the Worker, worked out on the
/// iPhone so the summary shows it the moment the run stops
/// (docs/plans/run-recorder P7). It mirrors `src/trainingLoad.ts` on what
/// the Worker reads from the uploaded file: heart rate on moving time
/// against the run threshold heart rate, then average pace against
/// threshold pace, then the file's average heart rate. One hour at
/// threshold is 100.
enum RunLoad {
    enum Method: Equatable {
        case heartRate
        case pace
        case averageHeartRate

        /// Short enough for the summary tile ("Load · HR"); the same
        /// methods the activity views label in full.
        var shortLabel: String {
            switch self {
            case .heartRate: "HR"
            case .pace: "pace"
            case .averageHeartRate: "avg HR"
            }
        }
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
        // The Worker keeps moving time in whole seconds.
        let moving = movingSeconds > 0 ? movingSeconds.rounded() : nil
        let stream = RecordedRunTCX.heartRateStream(run)
        if let threshold = positive(thresholdHeartRate),
           let summary = heartRateSummary(stream, movingSeconds: moving) {
            let ratio = summary.rms / threshold
            return result(summary.seconds / 3600 * ratio * ratio * 100, .heartRate)
        }
        if let threshold = positive(thresholdPacePerKm), let moving, run.distanceMeters > 0 {
            let ratio = threshold / (moving / (run.distanceMeters / 1000))
            return result(moving / 3600 * ratio * ratio * 100, .pace)
        }
        if let threshold = positive(thresholdHeartRate), let moving, !stream.isEmpty {
            let average = stream.reduce(0) { $0 + $1.v } / Double(stream.count)
            let ratio = average / threshold
            return result(moving / 3600 * ratio * ratio * 100, .averageHeartRate)
        }
        return nil
    }

    /// Root mean square of the readings over the seconds they cover, as
    /// `heartRateStreamSummary` reduces them: each reading holds until the
    /// next, a gap over 10 s counts one second. Nil when the readings cover
    /// too little of the run.
    static func heartRateSummary(_ stream: [(t: Double, v: Double)],
                                 movingSeconds: Double?) -> (rms: Double, seconds: Double)? {
        var samples: [(t: Double, v: Double)] = []
        for sample in stream.filter({ $0.t.isFinite && $0.v.isFinite && $0.v > 0 }).sorted(by: { $0.t < $1.t }) {
            if let last = samples.last, sample.t <= last.t { continue }
            samples.append(sample)
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
