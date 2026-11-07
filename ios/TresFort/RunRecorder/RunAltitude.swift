import Foundation

/// What the barometer readings of a recorded run mean (docs/plans/run-recorder
/// P7). Pure, so the rules are tested without a barometer.
enum RunAltitude {
    /// A climb counts once it rises this far above the last low point, as
    /// `GAIN_THRESHOLD_M` in `src/activityStreams.ts` counts the chart's.
    static let climbThreshold: Double = 3
    /// A reading further than this from a moment says nothing about it.
    static let maximumGap: TimeInterval = 30

    /// Meters climbed while moving. Each stretch between pauses counts on its
    /// own, so a hill walked up while paused never counts. Nil without
    /// readings from two moving moments.
    static func climb(_ run: RecordedRun) -> Double? {
        let segments = movingSegments(run)
        guard segments.contains(where: { $0.count >= 2 }) else { return nil }
        return segments.reduce(0) { $0 + gain($1.map(\.meters)) }
    }

    /// Meters climbed in one stretch, the way the server counts a chart's.
    static func gain(_ values: [Double]) -> Double {
        guard var low = values.first else { return 0 }
        var total = 0.0
        for value in values {
            if value < low {
                low = value
            } else if value - low >= climbThreshold {
                total += value - low
                low = value
            }
        }
        return total
    }

    /// The readings split into stretches of moving time; a reading inside a
    /// pause is dropped and one after a pause starts a new stretch.
    static func movingSegments(_ run: RecordedRun) -> [[RecordedRun.AltitudeSample]] {
        var result: [[RecordedRun.AltitudeSample]] = []
        var segment: Int?
        for sample in (run.altitudes ?? []).sorted(by: { $0.timestamp < $1.timestamp })
        where sample.meters.isFinite {
            let begun = run.pauses.filter { $0.start <= sample.timestamp }
            if begun.contains(where: { $0.end.map { sample.timestamp < $0 } ?? true }) { continue }
            if begun.count != segment {
                result.append([])
                segment = begun.count
            }
            result[result.count - 1].append(sample)
        }
        return result
    }

    /// The barometer's reading at `date`, between the readings on either
    /// side of it. Nil when no reading is close enough.
    static func relative(at date: Date, in samples: [RecordedRun.AltitudeSample]) -> Double? {
        guard !samples.isEmpty else { return nil }
        // The first reading at or after the date.
        var low = 0, high = samples.count
        while low < high {
            let mid = (low + high) / 2
            if samples[mid].timestamp < date { low = mid + 1 } else { high = mid }
        }
        let after = low < samples.count ? samples[low] : nil
        let before = low > 0 ? samples[low - 1] : nil
        let near = { (sample: RecordedRun.AltitudeSample) in
            abs(sample.timestamp.timeIntervalSince(date)) <= maximumGap
        }
        switch (before, after) {
        case let (before?, after?) where near(before) && near(after):
            let span = after.timestamp.timeIntervalSince(before.timestamp)
            guard span > 0 else { return after.meters }
            let share = date.timeIntervalSince(before.timestamp) / span
            return before.meters + (after.meters - before.meters) * share
        case let (before?, _) where near(before):
            return before.meters
        case let (_, after?) where near(after):
            return after.meters
        default:
            return nil
        }
    }

    /// Elevation for each route point: the barometer's shape, set at the
    /// level GPS put the run on (the median difference over every point with
    /// both). A point with no reading near it keeps its GPS altitude. Nil
    /// without readings or without any GPS altitude to set the level.
    static func fusedAltitudes(_ run: RecordedRun, points: [RecordedRun.RoutePoint]) -> [Double?]? {
        let samples = (run.altitudes ?? []).filter { $0.meters.isFinite }.sorted { $0.timestamp < $1.timestamp }
        guard !samples.isEmpty else { return nil }
        let relatives = points.map { relative(at: $0.timestamp, in: samples) }
        let differences = zip(points, relatives).compactMap { point, relative -> Double? in
            guard let altitude = point.altitude, altitude.isFinite, let relative else { return nil }
            return altitude - relative
        }.sorted()
        guard !differences.isEmpty else { return nil }
        let middle = differences.count / 2
        let level = differences.count % 2 == 1 ? differences[middle]
            : (differences[middle - 1] + differences[middle]) / 2
        return zip(points, relatives).map { point, relative in
            relative.map { $0 + level } ?? point.altitude.flatMap { $0.isFinite ? $0 : nil }
        }
    }
}
