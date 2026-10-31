import Foundation

/// One run recorded in the app (docs/plans/run-recorder). The recorder fills
/// it while the run is in progress and the store keeps it on the device until
/// `POST /api/activities/recordings` acknowledges the upload. The GPS route
/// never goes to Tres Fort's database; intervals.icu receives it as a TCX file.
struct RecordedRun: Codable, Equatable, Identifiable {
    static let currentSchemaVersion = 1

    struct RoutePoint: Codable, Equatable {
        var timestamp: Date
        var latitude: Double
        var longitude: Double
        /// Meters above sea level, when the fix carried one.
        var altitude: Double?
        var horizontalAccuracy: Double
    }

    struct HeartRateSample: Codable, Equatable {
        var timestamp: Date
        var beatsPerMinute: Double
    }

    /// A pause the member or auto-pause started; `end` stays nil until the
    /// run resumes.
    struct Pause: Codable, Equatable {
        var start: Date
        var end: Date?
        /// Auto-pause started it, so moving again resumes it. Nil for a
        /// pause the member asked for, and in runs saved before auto-pause.
        var automatic: Bool?
    }

    var schemaVersion: Int = RecordedRun.currentSchemaVersion
    /// Client UUID: the upload's idempotency key and intervals.icu external_id.
    var id: UUID
    /// Device-local civil start date (`YYYY-MM-DD`), like `sessions.date`.
    var date: String
    var name: String?
    var startedAt: Date
    var endedAt: Date?
    /// Time spent running, excluding pauses, from the workout builder.
    var movingSeconds: Double
    /// Distance from the workout builder (Apple's fusion), not summed GPS points.
    var distanceMeters: Double
    var points: [RoutePoint]
    var heartRates: [HeartRateSample]
    var pauses: [Pause]

    /// The server compares UUIDs case-insensitively; send one stable spelling.
    var uploadID: String { id.uuidString.lowercased() }

    var isFinished: Bool { endedAt != nil }

    init(id: UUID = UUID(), startedAt: Date, timeZone: TimeZone = .current, name: String? = nil) {
        self.id = id
        self.date = Self.civilDate(startedAt, timeZone: timeZone)
        self.name = name
        self.startedAt = startedAt
        self.endedAt = nil
        self.movingSeconds = 0
        self.distanceMeters = 0
        self.points = []
        self.heartRates = []
        self.pauses = []
    }

    static func civilDate(_ date: Date, timeZone: TimeZone) -> String {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        let parts = calendar.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", parts.year ?? 0, parts.month ?? 0, parts.day ?? 0)
    }
}
