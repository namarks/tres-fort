import Foundation

/// A run, ride, swim or walk entered by hand. Like the coach's log_activity,
/// it goes to the member's intervals.icu account
/// (`POST /api/activities/endurance`), never the local activity log, and
/// comes back through the activity sync.
struct EnduranceEntry: Equatable {
    /// Activity kinds intervals.icu takes as endurance.
    static let kinds: Set<String> = ["run", "ride", "swim", "walk"]

    enum DistanceUnit: String, CaseIterable, Identifiable {
        case mi, km, m, yd
        var id: String { rawValue }
        var meters: Double {
            switch self {
            case .mi: 1609.344
            case .km: 1000
            case .m: 1
            case .yd: 0.9144
            }
        }

        /// Swims are measured in pool lengths; everything else in mi or km.
        static func choices(for kind: String) -> [DistanceUnit] {
            kind == "swim" ? [.m, .yd] : [.mi, .km]
        }
    }

    /// Client UUID, the idempotency key: a retry returns the same activity.
    let id: String
    let date: String
    let kind: String
    let durationS: Int
    let distanceM: Double?
    let indoor: Bool
    /// "HH:mm" in the member's time zone.
    let startTime: String
    let title: String?
    let notes: String?

    var body: [String: Any] {
        var body: [String: Any] = [
            "id": id, "date": date, "type": kind, "duration_s": durationS,
            "start_time": startTime,
        ]
        if let distanceM { body["distance_m"] = distanceM }
        // A pool is indoors, but intervals.icu never marks a swim as trainer.
        if kind != "swim" { body["indoor"] = indoor }
        if let title { body["title"] = title }
        if let notes { body["notes"] = notes }
        return body
    }

    /// The longest activity the server accepts: seven days.
    static let maxSeconds = 7 * 24 * 3600

    /// "45" (minutes), "45:30" or "1:05:30" in seconds. Nil when unreadable,
    /// zero or longer than `maxSeconds`.
    static func seconds(from text: String) -> Int? {
        let parts = text.trimmingCharacters(in: .whitespaces)
            .split(separator: ":", omittingEmptySubsequences: false)
        guard (1...3).contains(parts.count) else { return nil }
        var numbers: [Int] = []
        for part in parts {
            // Bounding each part first keeps the arithmetic below from
            // overflowing on a pasted huge number.
            guard let n = Int(part), (0...maxSeconds).contains(n) else { return nil }
            numbers.append(n)
        }
        let total: Int
        switch numbers.count {
        case 1:
            total = numbers[0] * 60
        case 2:
            guard numbers[1] < 60 else { return nil }
            total = numbers[0] * 60 + numbers[1]
        default:
            guard numbers[1] < 60, numbers[2] < 60 else { return nil }
            total = numbers[0] * 3600 + numbers[1] * 60 + numbers[2]
        }
        return (1...maxSeconds).contains(total) ? total : nil
    }

    /// The longest distance the form takes: about seven days of nonstop
    /// riding. Anything outside 1 m...this is a typo, not an activity.
    static let maxMeters = 5_000_000.0

    /// The distance in meters, or nil when the field is empty, unreadable or
    /// outside 1 m to `maxMeters`.
    static func meters(from text: String, unit: DistanceUnit) -> Double? {
        let trimmed = text.trimmingCharacters(in: .whitespaces)
            .replacingOccurrences(of: ",", with: ".")
        guard let value = Double(trimmed), value.isFinite else { return nil }
        let meters = value * unit.meters
        return (1...maxMeters).contains(meters) ? meters : nil
    }

    /// An empty distance is fine (it's optional); anything else must be a
    /// positive number.
    static func isReadableDistance(_ text: String, unit: DistanceUnit) -> Bool {
        text.trimmingCharacters(in: .whitespaces).isEmpty || meters(from: text, unit: unit) != nil
    }

    /// Pace for runs and walks ("8:02 /mi"), speed for rides ("18.6 mph"),
    /// and pace per 100 for swims ("1:52 /100m").
    static func paceLabel(seconds: Int, meters: Double, unit: DistanceUnit, kind: String) -> String? {
        guard seconds > 0, meters > 0 else { return nil }
        if kind == "ride" {
            let hours = Double(seconds) / 3600
            let distance = meters / unit.meters
            let speed = distance / hours
            return String(format: "%.1f %@", speed, unit == .mi ? "mph" : "km/h")
        }
        let per = kind == "swim" ? 100 * unit.meters : unit.meters
        // Only a pace that fits a clock converts to Int; anything else is
        // not worth showing.
        let raw = (Double(seconds) * per / meters).rounded()
        guard raw.isFinite, raw >= 1, raw <= Double(maxSeconds) else { return nil }
        let pace = Int(raw)
        let suffix = kind == "swim" ? "/100\(unit.rawValue)" : "/\(unit.rawValue)"
        return clock(pace) + " " + suffix
    }

    /// "1:05:30" or "45:30".
    static func clock(_ seconds: Int) -> String {
        let h = seconds / 3600, m = (seconds % 3600) / 60, s = seconds % 60
        return h > 0 ? String(format: "%d:%02d:%02d", h, m, s) : String(format: "%d:%02d", m, s)
    }

    /// What the server said went wrong, or a plain fallback. Nothing is ever
    /// saved on a failure, so every message says so.
    static func failureMessage(_ error: Error) -> String {
        if let api = error as? APIError, let body = api.httpBody,
           let data = body.data(using: .utf8),
           let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let message = json["message"] as? String {
            return message
        }
        if error is URLError {
            return "Couldn't reach Tres Fort. Check your connection and try again. Nothing was saved."
        }
        return "Couldn't save this to intervals.icu. Nothing was saved; try again."
    }
}

/// `POST /api/activities/endurance` response. A 200 (`deduplicated`) means an
/// earlier attempt, or the same session already on intervals.icu, was found.
struct EnduranceLogResult: Decodable, Equatable {
    let ok: Bool
    let deduplicated: Bool
    let activity_id: String?
}

extension APIClient {
    func logEndurance(_ entry: EnduranceEntry, jwt: String) async throws -> EnduranceLogResult {
        try await post("api/activities/endurance", body: entry.body, jwt: jwt)
    }
}
