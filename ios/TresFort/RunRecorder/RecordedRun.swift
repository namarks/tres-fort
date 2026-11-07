import Foundation

/// One run recorded in the app (docs/plans/run-recorder). The recorder fills
/// it while the run is in progress and the store keeps it on the device until
/// `POST /api/activities/recordings` acknowledges the upload. Tres Fort keeps
/// the run and its GPS route, private to the member (P5); Apple Health keeps
/// its own copy, and intervals.icu receives the TCX file when the account is
/// connected.
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

    /// The iPhone's barometer: meters above where it started reading, which
    /// follows hills far more closely than GPS altitude (P7).
    struct AltitudeSample: Codable, Equatable {
        var timestamp: Date
        var meters: Double
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
    /// The planned run it follows and the step it's on. Nil for a run
    /// started without a plan, and in runs saved before planned runs.
    var plan: RunPlanFollowing? = nil
    /// The plan slot the run was started for, so saving it marks that slot
    /// done even when the run was recovered after the app was stopped. Nil
    /// for a run started without one, and in runs saved before this.
    var plannedSlotID: String? = nil
    /// True once Apple Health saved the workout with its route and any strap
    /// readings. With an older Worker and no intervals.icu connection, only
    /// such a run leaves this iPhone's upload queue; any other run is its only
    /// copy. Nil in runs saved before this was recorded.
    var savedToHealth: Bool? = nil
    /// Heart rate at the stop and one and two minutes later, read from the
    /// strap after the run ended (P7). Never part of the run's own figures.
    /// Nil without a strap, and in runs saved before this.
    var recovery: HeartRateRecovery? = nil
    /// Barometer readings while the run recorded (P7): the climb, and the
    /// shape of the uploaded run's elevation. Nil on an iPhone without a
    /// barometer, when Motion & Fitness is off, and in runs saved before this.
    var altitudes: [AltitudeSample]? = nil

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
