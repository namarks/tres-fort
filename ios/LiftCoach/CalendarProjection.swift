import Foundation

// ────────────────────────────────────────────────────────────────────────
// FROZEN PROJECTION ALGORITHM — must match the backend byte-for-byte.
//
// For a given calendar date, decide what (if anything) to show in the
// month grid / agenda. This is the single source of truth on the client;
// it is deliberately isolated here and over-commented so the lead can
// diff it against the server's projection.
//
//   date < today  → show a cell ONLY if a real cached session exists,
//                    using that session's status.
//   date >= today  → a real session WINS (planned / in_progress /
//                     completed / skipped). Otherwise:
//                       weekday(date) → schedule.week → day_template_id
//                       resolvable     → .projected(template)
//                       null/missing/dangling → .rest
//
// "weekday" is derived from the YYYY-MM-DD date via Calendar (the
// calendar rule, NOT a UTC offset).
// ────────────────────────────────────────────────────────────────────────

/// What a single day resolves to. `session` carries the real cached
/// session when one exists; `template` carries the plan day for a
/// planned/projected workout (so the agenda can show targets).
enum DayProjection: Equatable {
    /// A real session exists for this date. `status` is its raw status
    /// (`planned` / `in_progress` / `completed` / `skipped` / other).
    case session(status: String)
    /// No real session; the weekly schedule projects this template here
    /// (today or future only).
    case projected(templateID: String)
    /// Rest day — today/future with no session and no resolvable
    /// schedule entry (null / missing / dangling id).
    case rest
    /// Nothing to show (a past day with no real session).
    case none

    /// Coarse visual/semantic bucket used by the grid + agenda.
    enum Kind { case completed, inProgress, planned, projected, skipped, rest, none }

    var kind: Kind {
        switch self {
        case .session(let s):
            switch s {
            case "completed":   return .completed
            case "in_progress": return .inProgress
            case "planned":     return .planned
            case "skipped":     return .skipped
            default:            return .planned   // unknown → treat as planned
            }
        case .projected: return .projected
        case .rest:      return .rest
        case .none:      return .none
        }
    }
}

enum CalendarProjection {

    /// Gregorian / POSIX / device-tz calendar — identical rule to the
    /// `YYYY-MM-DD` formatting used elsewhere in the app (SyncModel).
    static let calendar: Calendar = {
        var c = Calendar(identifier: .gregorian)
        c.locale = Locale(identifier: "en_US_POSIX")
        c.timeZone = .current
        return c
    }()

    private static let isoFormatter: DateFormatter = {
        let f = DateFormatter()
        f.calendar = Calendar(identifier: .gregorian)
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = .current
        f.dateFormat = "yyyy-MM-dd"
        return f
    }()

    static func dateString(_ date: Date) -> String { isoFormatter.string(from: date) }
    static func date(from ymd: String) -> Date? { isoFormatter.date(from: ymd) }

    /// Lowercase 3-letter weekday key for a `YYYY-MM-DD` string, derived
    /// via Calendar (calendar rule, not UTC). Sunday-based component is
    /// mapped to the contract's mon..sun keys.
    static func weekdayKey(forDateString ymd: String) -> String? {
        guard let d = date(from: ymd) else { return nil }
        return weekdayKey(for: d)
    }

    static func weekdayKey(for date: Date) -> String {
        // Calendar.weekday: 1 = Sunday … 7 = Saturday.
        let wd = calendar.component(.weekday, from: date)
        switch wd {
        case 1:  return "sun"
        case 2:  return "mon"
        case 3:  return "tue"
        case 4:  return "wed"
        case 5:  return "thu"
        case 6:  return "fri"
        default: return "sat"   // 7
        }
    }

    /// Resolve a single date.
    ///
    /// - Parameters:
    ///   - dateString: the day to resolve, `YYYY-MM-DD`.
    ///   - today: today's `YYYY-MM-DD` (injected so callers share one clock).
    ///   - sessionByDate: real cached sessions keyed by `YYYY-MM-DD`. If
    ///     several share a date, the caller passes the most relevant one.
    ///   - schedule: parsed `meta.schedule`, or nil.
    ///   - templateIDs: set of day_template ids that exist in the plan
    ///     (used to detect dangling schedule references).
    static func project(
        dateString: String,
        today: String,
        sessionByDate: [String: SessionRow],
        schedule: PlanSchedule?,
        templateIDs: Set<String>
    ) -> DayProjection {
        let real = sessionByDate[dateString]

        if dateString < today {
            // Past: only a real session is ever shown.
            if let real { return .session(status: real.status) }
            return .none
        }

        // today or future: a real session always wins.
        if let real { return .session(status: real.status) }

        // No session → consult the weekly schedule.
        guard
            let schedule,
            let key = weekdayKey(forDateString: dateString),
            let templateID = schedule.templateID(forWeekdayKey: key),
            templateIDs.contains(templateID)        // dangling id → rest
        else {
            return .rest
        }
        return .projected(templateID: templateID)
    }
}
