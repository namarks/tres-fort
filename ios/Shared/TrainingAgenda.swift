import Foundation

// Shared between the app (which publishes the agenda) and the widget extension
// (which only reads it). Compiled into BOTH targets — lives in ios/Shared.
//
// The snapshot is a display copy of the app's own calendar projection for
// today and the next few civil days. It carries no account identifier, token
// or logged data: the app writes it after each published plan/session change
// and clears it at every account boundary, so the widget never decides what a
// day is on its own.

/// One civil day as the app's projection resolved it when the snapshot was
/// written.
struct TrainingAgendaDay: Codable, Equatable {
    enum Status: String, Codable {
        /// A scheduled, planned or not-yet-started workout.
        case workout
        /// A workout with logged sets that has not been finished.
        case inProgress
        case completed
        case skipped
        case rest
        /// A trip that blacks the date out.
        case unavailable
        /// A trip that allows only light, unstructured training.
        case light
    }

    let date: String            // YYYY-MM-DD, device-local civil date
    let status: Status
    let workoutName: String?
    let exerciseNames: [String]

    var isWorkoutDay: Bool {
        switch status {
        case .workout, .inProgress, .completed: return true
        case .skipped, .rest, .unavailable, .light: return false
        }
    }
}

struct TrainingAgendaSnapshot: Codable, Equatable {
    static let currentVersion = 1

    var version: Int = TrainingAgendaSnapshot.currentVersion
    /// Consecutive civil days starting at the day the app wrote the snapshot.
    let days: [TrainingAgendaDay]

    func day(for ymd: String) -> TrainingAgendaDay? {
        days.first { $0.date == ymd }
    }

    /// The first day after `ymd` that still has a workout to do.
    func nextWorkout(after ymd: String) -> TrainingAgendaDay? {
        days.first { $0.date > ymd && ($0.status == .workout || $0.status == .inProgress) }
    }
}

/// App Group storage for the snapshot. Both targets carry the same
/// `com.apple.security.application-groups` entitlement.
enum TrainingAgendaStore {
    static let appGroupID = "group.com.nmarkspdx.tresfort"
    static let snapshotKey = "com.nmarkspdx.tresfort.training-agenda.v1"
    static let widgetKind = "TodayWorkoutWidget"

    static var sharedDefaults: UserDefaults? { UserDefaults(suiteName: appGroupID) }

    static func load(from defaults: UserDefaults?) -> TrainingAgendaSnapshot? {
        guard let data = defaults?.data(forKey: snapshotKey),
              let snapshot = try? JSONDecoder().decode(TrainingAgendaSnapshot.self, from: data),
              snapshot.version == TrainingAgendaSnapshot.currentVersion
        else { return nil }
        return snapshot
    }

    /// Returns whether the stored value changed, so callers reload widget
    /// timelines only when there is something new to draw.
    @discardableResult
    static func save(_ snapshot: TrainingAgendaSnapshot?, to defaults: UserDefaults?) -> Bool {
        guard let defaults else { return false }
        guard let snapshot else {
            guard defaults.object(forKey: snapshotKey) != nil else { return false }
            defaults.removeObject(forKey: snapshotKey)
            return true
        }
        // Sorted keys make equal snapshots encode to equal bytes; keyed
        // containers otherwise have no stable order across encodes.
        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys
        guard let data = try? encoder.encode(snapshot) else { return false }
        guard defaults.data(forKey: snapshotKey) != data else { return false }
        defaults.set(data, forKey: snapshotKey)
        return true
    }
}

/// Navigation-only link used by the widget and workout reminders. It opens the
/// Today tab and never starts, logs or changes a workout.
enum TrainingAgendaLink {
    static let todayURL = URL(string: "tresfort://today")!
    static let openToday = Notification.Name("com.nmarkspdx.tresfort.open-today")

    static func isTodayURL(_ url: URL) -> Bool {
        guard let parts = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return false }
        return parts.scheme == "tresfort" && parts.host == "today"
            && (parts.path.isEmpty || parts.path == "/")
    }
}

/// Civil-date helpers shared by the widget timeline and reminder planning.
/// Same rule as CalendarProjection: Gregorian, POSIX, device time zone.
enum TrainingAgendaCalendar {
    static func calendar(timeZone: TimeZone = .current) -> Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.locale = Locale(identifier: "en_US_POSIX")
        calendar.timeZone = timeZone
        return calendar
    }

    static func dateString(_ date: Date, calendar: Calendar) -> String {
        let parts = calendar.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", parts.year ?? 0, parts.month ?? 0, parts.day ?? 0)
    }

    static func date(from ymd: String, calendar: Calendar) -> Date? {
        let fields = ymd.split(separator: "-").compactMap { Int($0) }
        guard fields.count == 3 else { return nil }
        return calendar.date(from: DateComponents(year: fields[0], month: fields[1], day: fields[2]))
    }
}

/// One widget entry per civil day, so the widget turns over at midnight
/// without waiting for the app to run.
enum TrainingAgendaTimeline {
    struct Entry: Equatable {
        let date: Date
        let day: TrainingAgendaDay?
        let next: TrainingAgendaDay?
    }

    static func entries(snapshot: TrainingAgendaSnapshot?, now: Date, calendar: Calendar) -> [Entry] {
        let today = TrainingAgendaCalendar.dateString(now, calendar: calendar)
        guard let snapshot else { return [Entry(date: now, day: nil, next: nil)] }
        var entries = [Entry(date: now, day: snapshot.day(for: today),
                             next: snapshot.nextWorkout(after: today))]
        for day in snapshot.days where day.date > today {
            guard let start = TrainingAgendaCalendar.date(from: day.date, calendar: calendar) else { continue }
            entries.append(Entry(date: start, day: day, next: snapshot.nextWorkout(after: day.date)))
        }
        // After the last projected day the widget asks for the app instead of
        // guessing a schedule it no longer has.
        if let last = snapshot.days.last?.date, last >= today,
           let lastStart = TrainingAgendaCalendar.date(from: last, calendar: calendar),
           let end = calendar.date(byAdding: .day, value: 1, to: lastStart) {
            entries.append(Entry(date: end, day: nil, next: nil))
        }
        return entries
    }
}
