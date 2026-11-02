import Foundation
import HealthKit

/// Detail streams for an Apple Health workout (docs/plans/endurance-training-load
/// P3). The app reads the heart-rate and cycling-power samples recorded inside
/// a run or ride and sends them compacted to one value per second; the Worker
/// reduces them to threshold-independent figures and scores the workout's
/// load from them. It decides whether a stream covers enough of the workout,
/// so the app only drops streams too short to matter.
struct HealthStreamPoint: Equatable {
    /// Seconds from the workout's start.
    let t: TimeInterval
    let v: Double
    /// The writing app's bundle identifier, when HealthKit reports it.
    let source: String?
}

/// One compacted stream: whole seconds from the workout start and the mean
/// reading in each second, rounded to a whole number.
struct HealthStream: Equatable {
    let t: [Int]
    let v: [Int]

    var jsonBody: [String: Any] { ["t": t, "v": v] }
}

enum HealthWorkoutStreams {
    /// Fewer points than the 30-second window normalized power needs can
    /// never be scored, so they are not sent.
    static let minimumPoints = 30
    /// The Worker's limit: a day at one sample a second.
    static let maximumPoints = 86_400

    /// Keep one writer's samples (the workout's own app when it recorded
    /// enough, otherwise the app with the most samples, so a watch and a
    /// chest strap are never interleaved) and average them into whole seconds.
    static func compact(_ points: [HealthStreamPoint], preferredSource: String?) -> HealthStream? {
        let usable = points.filter { $0.t.isFinite && $0.v.isFinite && $0.t >= 0 && $0.v >= 0 }
        var counts: [String: Int] = [:]
        for point in usable { counts[point.source ?? "", default: 0] += 1 }
        let chosen: String
        if let preferredSource, counts[preferredSource, default: 0] >= minimumPoints {
            chosen = preferredSource
        } else if let best = counts.max(by: { a, b in
            a.value != b.value ? a.value < b.value : a.key > b.key
        }) {
            chosen = best.key
        } else {
            return nil
        }
        var sums: [Int: Double] = [:]
        var counted: [Int: Int] = [:]
        for point in usable where (point.source ?? "") == chosen {
            let second = Int(point.t.rounded(.down))
            guard second < maximumPoints else { continue }
            sums[second, default: 0] += point.v
            counted[second, default: 0] += 1
        }
        guard sums.count >= minimumPoints else { return nil }
        let seconds = sums.keys.sorted()
        return HealthStream(
            t: seconds,
            v: seconds.map { second in
                Int(((sums[second] ?? 0) / Double(counted[second] ?? 1)).rounded())
            })
    }

    enum PauseMark: Equatable {
        case pause, resume
    }

    /// Paused stretches, in seconds from the workout start, from its pause
    /// and resume marks in time order. A pause with no resume runs to the
    /// end; a repeated mark changes nothing.
    static func pausedRanges(_ marks: [(mark: PauseMark, t: TimeInterval)],
                             duration: TimeInterval) -> [Range<TimeInterval>] {
        var ranges: [Range<TimeInterval>] = []
        var pausedAt: TimeInterval?
        for (mark, t) in marks.sorted(by: { $0.t < $1.t }) {
            switch mark {
            case .pause:
                if pausedAt == nil { pausedAt = t }
            case .resume:
                if let from = pausedAt, t > from { ranges.append(from..<t) }
                if pausedAt != nil { pausedAt = nil }
            }
        }
        if let from = pausedAt, duration > from { ranges.append(from..<duration) }
        return ranges
    }

    /// Readings outside every paused stretch.
    static func removing(_ paused: [Range<TimeInterval>],
                         from points: [HealthStreamPoint]) -> [HealthStreamPoint] {
        guard !paused.isEmpty else { return points }
        return points.filter { point in !paused.contains { $0.contains(point.t) } }
    }

    /// The body's `streams` value: only streams with enough points.
    static func jsonBody(_ streams: [String: HealthStream]) -> [String: Any] {
        streams.mapValues { $0.jsonBody }
    }
}

/// Collects a series query's quantities. HealthKit calls the handler serially
/// on its own queue; the box only crosses into that closure.
private final class HealthStreamAccumulator: @unchecked Sendable {
    var points: [HealthStreamPoint] = []
    var finished = false
}

extension HealthWorkoutStreams {
    /// The workout's pause and resume marks (manual and automatic), in
    /// seconds from its start.
    static func pauseMarks(for workout: HKWorkout) -> [(mark: PauseMark, t: TimeInterval)] {
        (workout.workoutEvents ?? []).compactMap { event -> (mark: PauseMark, t: TimeInterval)? in
            let t = event.dateInterval.start.timeIntervalSince(workout.startDate)
            switch event.type {
            case .pause, .motionPaused: return (.pause, t)
            case .resume, .motionResumed: return (.resume, t)
            default: return nil
            }
        }
    }

    /// Every quantity of `identifier` recorded during the workout, including
    /// each reading inside series samples (Apple Watch stores workout heart
    /// rate that way). Nil when HealthKit fails, for example while the phone
    /// is locked, so the caller can leave the stored streams alone; a denied
    /// read is indistinguishable from no data and returns an empty list.
    static func read(_ identifier: HKQuantityTypeIdentifier, unit: HKUnit,
                     from start: Date, to end: Date,
                     store: HKHealthStore) async -> [HealthStreamPoint]? {
        let type = HKQuantityType(identifier)
        let predicate = HKQuery.predicateForSamples(withStart: start, end: end, options: [])
        let box = HealthStreamAccumulator()
        return await withCheckedContinuation { continuation in
            let query = HKQuantitySeriesSampleQuery(
                quantityType: type, predicate: predicate
            ) { _, quantity, interval, sample, done, error in
                guard !box.finished else { return }
                if error != nil {
                    box.finished = true
                    continuation.resume(returning: nil)
                    return
                }
                if let quantity, let interval, interval.start >= start, interval.start <= end {
                    box.points.append(HealthStreamPoint(
                        t: interval.start.timeIntervalSince(start),
                        v: quantity.doubleValue(for: unit),
                        source: sample?.sourceRevision.source.bundleIdentifier))
                }
                if done {
                    box.finished = true
                    continuation.resume(returning: box.points)
                }
            }
            query.includeSample = true
            store.execute(query)
        }
    }
}
