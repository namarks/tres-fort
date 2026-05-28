import Foundation

// ────────────────────────────────────────────────────────────────────────
// FROZEN PROJECTION ALGORITHM — must match the backend byte-for-byte.
//
// For a given calendar date, decide what (if anything) to show in the
// month grid / agenda. This is the single source of truth on the client;
// it is deliberately isolated here and over-commented so the lead can
// diff it against the server's projection.
//
//   A 'discarded' session is treated as if it NEVER EXISTED (the user
//   explicitly threw it away; its set_logs are soft-deleted server-side).
//   It is dropped before the rule below, so the date falls through:
//     date < today  → .none ;  date >= today → schedule/rest.
//   This mirrors projectCalendar's byDate `discarded` carve-out in the
//   backend byte-for-byte (test/calendar.test.ts is the contract).
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
        // Share the `calendar` static's tz (not an independent `.current`
        // capture) so a system-tz change between the two lazy inits can't
        // parse in one zone and read `.weekday` in another (1-day skew).
        f.timeZone = calendar.timeZone
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
        // A 'discarded' session is treated as if it never existed — the
        // user explicitly threw it away (set_logs soft-deleted server
        // side). Dropping it here (vs. returning .session) makes the date
        // fall through to past=.none / today+=schedule — it VANISHES
        // rather than showing as a skip. Byte-for-byte mirror of
        // projectCalendar's `if (s.status === 'discarded') continue;`.
        let real = sessionByDate[dateString].flatMap {
            $0.status == "discarded" ? nil : $0
        }

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

// ────────────────────────────────────────────────────────────────────────
// FROZEN CONFLICT RULE — must match the backend `detectConflicts`
// byte-for-byte. Deliberately isolated + over-commented so the lead can
// diff this single function against the server. The app is READ-ONLY for
// rides: this only classifies, it never writes anything.
//
// Inputs (all already tombstone-filtered upstream — `deleted_at != null`
// events are NEVER passed here):
//   - a calendar date that carries a LIFT (a real cached session OR a
//     projected lift from CalendarProjection). Rest/none days are not
//     lift dates and produce `.none`.
//   - the external events on a given date.
//
// Rule (evaluated for a LIFT date `L`):
//   (a) SAME-DAY  → if ANY non-deleted external_event falls on `L` itself,
//                    severity = .clash.
//   (b) DAY-BEFORE-HARD → else if `L` is the calendar day immediately
//                    BEFORE a date that has a non-deleted external_event
//                    with training_load >= 150 OR
//                    planned_duration_sec >= 9000, severity = .heavyNextDay.
//   (else)        → .none.
//
// same-day takes precedence over day-before-hard (a date that is both gets
// `.clash`). "The day before" is L + 1 calendar day, computed with the
// same Gregorian/POSIX/device-tz Calendar used everywhere else (civil
// date, NOT a UTC offset) — identical rule to CalendarProjection.
// ────────────────────────────────────────────────────────────────────────

enum RideConflict {

    /// Conflict severity for a lift date. Ordered least→most severe; the
    /// raw values are stable identifiers for cross-checking with the
    /// backend ("none" / "heavy-next-day" / "clash").
    enum Severity: String {
        case none          = "none"
        case heavyNextDay  = "heavy-next-day"
        case clash         = "clash"
    }

    /// Thresholds for a "hard" next-day event — mirror the backend
    /// constants exactly. TSS (training_load) and seconds.
    static let hardLoadThreshold = 150            // training_load >= 150
    static let hardDurationSecThreshold = 9000    // planned_duration_sec >= 9000 (2h30m)

    /// Does a projection represent a LIFT on that date?
    ///
    /// PARITY CONTRACT with the backend `getRideConflicts`/`detectConflicts`:
    /// the lift-bearing set is EXACTLY {completed, inProgress, planned,
    /// projected}. `.skipped` is INTENTIONALLY EXCLUDED — a skipped lift
    /// was not performed, so it cannot conflict with a ride (lead's product
    /// decision; backend lift states are projected|planned|in_progress|
    /// completed). `.rest`/`.none` are not lifts. Keep this set byte-for-
    /// byte aligned with the backend.
    static func dateHasLift(_ proj: DayProjection) -> Bool {
        switch proj.kind {
        case .completed, .inProgress, .planned, .projected:
            return true
        case .skipped, .rest, .none:
            return false
        }
    }

    /// True if a single (already non-deleted) event is a "hard" session
    /// by the frozen thresholds.
    static func isHard(_ e: ExternalEvent) -> Bool {
        let load = e.training_load ?? 0
        let dur = e.planned_duration_sec ?? 0
        return load >= hardLoadThreshold || dur >= hardDurationSecThreshold
    }

    /// `YYYY-MM-DD` for the calendar day AFTER `ymd`, via the shared civil
    /// calendar (same rule as CalendarProjection). nil if `ymd` is malformed.
    static func nextDateString(after ymd: String) -> String? {
        guard
            let d = CalendarProjection.date(from: ymd),
            let next = CalendarProjection.calendar.date(byAdding: .day, value: 1, to: d)
        else { return nil }
        return CalendarProjection.dateString(next)
    }

    /// Severity for a lift date.
    ///
    /// - Parameters:
    ///   - liftDateString: the `YYYY-MM-DD` of the lift being evaluated.
    ///   - hasLift: closure → is this date a lift date? (caller wires the
    ///     CalendarProjection so this stays pure/diffable).
    ///   - ridesOn: closure → non-deleted external events for a date.
    static func severity(
        forLiftDate liftDateString: String,
        hasLift: (String) -> Bool,
        ridesOn: (String) -> [ExternalEvent]
    ) -> Severity {
        // Conflicts only attach to LIFT dates. No lift → no conflict.
        guard hasLift(liftDateString) else { return .none }

        // (a) SAME-DAY — any non-deleted event on the lift date itself.
        if !ridesOn(liftDateString).isEmpty {
            return .clash
        }

        // (b) DAY-BEFORE-HARD — the lift is the day before a hard event.
        if let next = nextDateString(after: liftDateString),
           ridesOn(next).contains(where: isHard) {
            return .heavyNextDay
        }

        return .none
    }
}
