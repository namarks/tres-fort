import ActivityKit
import Foundation

// Shared between the app (the run recorder starts, updates and ends the
// Activity) and the widget extension (renders it on the Lock Screen and in
// the Dynamic Island). Compiled into BOTH targets, like RestActivityAttributes.
struct RunActivityAttributes: ActivityAttributes {
    struct ContentState: Codable, Hashable {
        /// While running, the clock counts up from here: the start moved
        /// later by every pause, so the time needs no updates.
        var clockStart: Date
        /// The moving time to show while paused, when the clock stops.
        var pausedSeconds: Double?
        var meters: Double
        /// Seconds per `unit` over the last 30 seconds, when there is one.
        var currentPace: Double?
        var unit: RunDistanceUnit

        var isPaused: Bool { pausedSeconds != nil }
    }

    /// `RecordedRun.uploadID`, so a control on an older run's activity does
    /// nothing to a newer run.
    var recordingID: String
}

/// Miles or kilometers for the recorder's screen, Lock Screen and spoken
/// splits. The upload always carries meters.
enum RunDistanceUnit: String, Codable, CaseIterable, Hashable {
    case miles
    case kilometers

    var meters: Double { self == .miles ? 1_609.344 : 1_000 }
    var abbreviation: String { self == .miles ? "mi" : "km" }
    var title: String { self == .miles ? "Miles" : "Kilometers" }
    var spokenName: String { self == .miles ? "mile" : "kilometer" }
}

enum RunFormat {
    static func duration(_ seconds: Double) -> String {
        let total = max(0, Int(seconds.rounded(.down)))
        let h = total / 3600, m = (total % 3600) / 60, s = total % 60
        return h > 0 ? String(format: "%d:%02d:%02d", h, m, s) : String(format: "%d:%02d", m, s)
    }

    static func distance(_ meters: Double, in unit: RunDistanceUnit) -> String {
        String(format: "%.2f", max(0, meters) / unit.meters)
    }

    static func miles(_ meters: Double) -> String { distance(meters, in: .miles) }

    /// "8:05" per mile or kilometer, or a dash when there is no pace yet.
    /// Paces slower than an hour per unit read as no pace.
    static func pace(_ secondsPerUnit: Double?) -> String {
        guard let secondsPerUnit, secondsPerUnit.isFinite, secondsPerUnit > 0, secondsPerUnit < 3600 else {
            return "–"
        }
        let total = Int(secondsPerUnit.rounded())
        return String(format: "%d:%02d", total / 60, total % 60)
    }
}
