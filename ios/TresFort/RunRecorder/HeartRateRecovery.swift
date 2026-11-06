import Foundation

/// Heart rate after a run recorded in the app (docs/plans/run-recorder P7):
/// the reading at the stop and one and two minutes later, in whole bpm. It
/// describes the cool-down, never the run, so it changes no time, distance,
/// heart rate average or load. Uploaded with the run and served back with
/// its route (`GET /api/activities/:id/route`, `heart_rate_recovery`).
struct HeartRateRecovery: Codable, Equatable {
    var atStop: Int
    var after60s: Int?
    var after120s: Int?

    enum CodingKeys: String, CodingKey {
        case atStop = "at_stop"
        case after60s = "after_60s"
        case after120s = "after_120s"
    }

    /// How far heart rate fell by one and two minutes; negative if it rose.
    var drop60s: Int? { after60s.map { atStop - $0 } }
    var drop120s: Int? { after120s.map { atStop - $0 } }

    /// "28 bpm in 1 min · 44 in 2 min", as the web says it. Nil when nothing
    /// after the stop was measured.
    var summary: String? {
        var parts: [String] = []
        if let drop = drop60s { parts.append("\(Self.signed(drop)) bpm in 1 min") }
        if let drop = drop120s {
            parts.append(parts.isEmpty ? "\(Self.signed(drop)) bpm in 2 min" : "\(Self.signed(drop)) in 2 min")
        }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    /// A rise reads "+4"; a fall is the plain number.
    private static func signed(_ drop: Int) -> String { drop >= 0 ? "\(drop)" : "+\(-drop)" }
}

/// Watches the strap's readings after a run stops for the readings one and
/// two minutes later. Pure, so the timing rules are tested without a strap.
struct HeartRateRecoveryMeasurement: Equatable {
    /// Seconds after the stop that are recorded.
    static let marks: [TimeInterval] = [60, 120]
    /// A reading this close to a mark counts for it.
    static let tolerance: TimeInterval = 5
    /// The run's last reading must be this recent at the stop to count as
    /// the heart rate at the stop.
    static let stopTolerance: TimeInterval = 5
    /// Readings outside this are dropped; the server takes whole bpm in it.
    static let plausible: ClosedRange<Double> = 20...250
    /// How long the cool-down lasts on screen.
    static var duration: TimeInterval { marks.last ?? 0 }

    let stoppedAt: Date
    let atStop: Double
    /// The reading counted for each mark, in `marks` order; nil while the
    /// mark is open or when no reading came close enough to it.
    private(set) var readings: [Double?]
    /// Marks that are settled, with or without a reading.
    private(set) var settled: [Bool]
    private var previous: RecordedRun.HeartRateSample?

    /// Nil when the run has no reading close enough to the stop.
    init?(run: RecordedRun, stoppedAt: Date) {
        guard let last = run.heartRates.last,
              abs(stoppedAt.timeIntervalSince(last.timestamp)) <= Self.stopTolerance,
              Self.plausible.contains(last.beatsPerMinute) else { return nil }
        self.stoppedAt = stoppedAt
        atStop = last.beatsPerMinute
        readings = Self.marks.map { _ in nil }
        settled = Self.marks.map { _ in false }
    }

    var isComplete: Bool { !settled.contains(false) }

    /// The heart rate after the stop, or nil when no mark got a reading.
    var result: HeartRateRecovery? {
        guard readings.contains(where: { $0 != nil }) else { return nil }
        let bpm = { (value: Double?) in value.map { Int($0.rounded()) } }
        return HeartRateRecovery(atStop: Int(atStop.rounded()), after60s: bpm(readings[0]),
                                 after120s: bpm(readings[1]))
    }

    /// A reading from the strap after the stop. Each mark takes the reading
    /// nearest it, the last one before or the first one after, when it is
    /// within the tolerance.
    mutating func add(_ sample: RecordedRun.HeartRateSample) {
        guard Self.plausible.contains(sample.beatsPerMinute), sample.timestamp > stoppedAt,
              previous.map({ sample.timestamp > $0.timestamp }) ?? true else { return }
        let seconds = sample.timestamp.timeIntervalSince(stoppedAt)
        for index in Self.marks.indices where !settled[index] && seconds >= Self.marks[index] {
            let mark = Self.marks[index]
            let candidates = [previous, sample].compactMap { $0 }.filter {
                abs($0.timestamp.timeIntervalSince(stoppedAt) - mark) <= Self.tolerance
            }
            let nearest = candidates.min {
                abs($0.timestamp.timeIntervalSince(stoppedAt) - mark) < abs($1.timestamp.timeIntervalSince(stoppedAt) - mark)
            }
            readings[index] = nearest?.beatsPerMinute
            settled[index] = true
        }
        previous = sample
    }

    /// Settles every mark the clock is past by more than the tolerance,
    /// with the last reading if it was close enough. For a strap that went
    /// quiet without disconnecting.
    mutating func expire(at date: Date) {
        let seconds = date.timeIntervalSince(stoppedAt)
        for index in Self.marks.indices where !settled[index] && seconds > Self.marks[index] + Self.tolerance {
            if let previous,
               abs(previous.timestamp.timeIntervalSince(stoppedAt) - Self.marks[index]) <= Self.tolerance {
                readings[index] = previous.beatsPerMinute
            }
            settled[index] = true
        }
    }
}

extension RecordedRun {
    /// The plain mean of the run's readings; nil without any. What the
    /// summary shows once the strap's live reading is gone.
    var averageHeartRate: Double? {
        guard !heartRates.isEmpty else { return nil }
        return heartRates.reduce(0) { $0 + $1.beatsPerMinute } / Double(heartRates.count)
    }

    var maximumHeartRate: Double? { heartRates.map(\.beatsPerMinute).max() }
}
