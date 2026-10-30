import CoreLocation
import Foundation

extension RecordedRun.RoutePoint {
    /// Altitude is kept only when the fix carries a valid vertical accuracy.
    init(_ location: CLLocation) {
        self.init(
            timestamp: location.timestamp,
            latitude: location.coordinate.latitude,
            longitude: location.coordinate.longitude,
            altitude: location.verticalAccuracy >= 0 ? location.altitude : nil,
            horizontalAccuracy: location.horizontalAccuracy)
    }
}

extension RecordedRun {
    /// Wall time since the start minus every pause, up to `now` or the end.
    /// The screen's clock uses this; the saved moving time comes from the
    /// workout builder when it reported one.
    func activeSeconds(at now: Date) -> Double {
        let end = endedAt ?? now
        let paused = pauses.reduce(0.0) { total, pause in
            let pauseEnd = min(pause.end ?? end, end)
            return total + max(0, pauseEnd.timeIntervalSince(max(pause.start, startedAt)))
        }
        return max(0, end.timeIntervalSince(startedAt) - paused)
    }

    var isPaused: Bool { pauses.last.map { $0.end == nil } ?? false }

    /// Closes an open pause; a run never ends or resumes with one open.
    mutating func closePause(at date: Date) {
        guard let last = pauses.indices.last, pauses[last].end == nil else { return }
        pauses[last].end = max(date, pauses[last].start)
    }
}

/// Which GPS fixes become route points. Distance comes from the workout
/// builder, so the filter only keeps the map and the uploaded track honest.
enum RunLocationFilter {
    /// Fixes less precise than this are dropped. Open-sky fixes on a phone
    /// are usually 3 to 10 m.
    static let maximumHorizontalAccuracy: CLLocationAccuracy = 50
    /// Faster than a sprinter: a jump implying more is a bad fix.
    static let maximumSpeed: CLLocationSpeed = 12

    static func accepts(_ point: RecordedRun.RoutePoint, after previous: RecordedRun.RoutePoint?,
                        startedAt: Date) -> Bool {
        guard point.horizontalAccuracy >= 0, point.horizontalAccuracy <= maximumHorizontalAccuracy,
              point.latitude.isFinite, point.longitude.isFinite,
              point.timestamp >= startedAt else { return false }
        guard let previous else { return true }
        let seconds = point.timestamp.timeIntervalSince(previous.timestamp)
        guard seconds > 0 else { return false }
        return RecordedRunTCX.meters(previous, point) / seconds <= maximumSpeed
    }
}

enum RunPace {
    static let metersPerMile = RunDistanceUnit.miles.meters
    /// Current pace looks back this far over the route.
    static let currentWindow: TimeInterval = 30

    /// Seconds per unit over the last 30 seconds of route since the latest
    /// pause, or nil when there is too little movement to say.
    static func current(_ run: RecordedRun, unit: RunDistanceUnit = .miles) -> Double? {
        guard !run.isPaused, let segment = RecordedRunTCX.segments(run).last,
              let last = segment.last else { return nil }
        let window = segment.filter { last.timestamp.timeIntervalSince($0.timestamp) <= currentWindow }
        guard let first = window.first else { return nil }
        let seconds = last.timestamp.timeIntervalSince(first.timestamp)
        let meters = zip(window, window.dropFirst()).reduce(0.0) { $0 + RecordedRunTCX.meters($1.0, $1.1) }
        guard seconds >= 10, meters >= 10 else { return nil }
        return seconds / (meters / unit.meters)
    }

    static func average(movingSeconds: Double, meters: Double, unit: RunDistanceUnit = .miles) -> Double? {
        guard movingSeconds > 0, meters >= 10 else { return nil }
        return movingSeconds / (meters / unit.meters)
    }
}
