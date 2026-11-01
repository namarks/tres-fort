import Foundation

/// Runs, rides, swims and walks from intervals.icu and Apple Health, by
/// Monday–Sunday week, for the Endurance card on Progress. Native lifting
/// stays in `WorkoutConsistency`; strength and yoga sessions from other apps
/// are left out here so they never read as endurance.
struct EnduranceProgress {
    struct Week: Identifiable, Equatable {
        var id: String { start }
        let start: String
        let end: String
        let seconds: Int
        let count: Int
        /// Sum of the activities' known training loads: 0 for a week with no
        /// activities, nil for one whose activities all have unknown load.
        var load: Int? = 0
        /// Activities in the week with no known load.
        var unscored: Int = 0
        let isCurrent: Bool
    }

    /// One activity kind's total for a span.
    struct KindTotal: Identifiable, Equatable {
        var id: String { kind }
        let kind: String
        let seconds: Int
        /// Only activities that recorded a distance contribute.
        let meters: Double
        let count: Int
    }

    /// Kinds that count as endurance. Strength, yoga and anything a source
    /// couldn't classify ("other", e.g. Pilates) stay out of the totals.
    static let enduranceKinds: Set<String> = ["run", "ride", "swim", "walk", "hike", "row", "ski", "elliptical"]

    /// Oldest first, ending with this week.
    let weeks: [Week]
    /// This week's totals by kind, most time first.
    let thisWeek: [KindTotal]
    /// Every counted activity in the displayed weeks, newest first.
    let recent: [ExternalActivity]

    var isEmpty: Bool { recent.isEmpty }
    var thisWeekSeconds: Int { weeks.last?.seconds ?? 0 }
    var thisWeekCount: Int { weeks.last?.count ?? 0 }
    /// Mean time over the finished weeks; the current week is still running.
    var averageWeekSeconds: Int {
        let finished = weeks.dropLast()
        guard !finished.isEmpty else { return 0 }
        return finished.reduce(0) { $0 + $1.seconds } / finished.count
    }
    /// Nil when this week's activities all have unknown load.
    var thisWeekLoad: Int? { weeks.last?.load }
    /// Mean load over the finished weeks whose load is known; nil when none is.
    var averageWeekLoad: Int? {
        let known = weeks.dropLast().compactMap(\.load)
        guard !known.isEmpty else { return nil }
        return known.reduce(0, +) / known.count
    }
    /// Whether any counted activity has a load; without one, load stats stay hidden.
    var hasLoad: Bool { recent.contains { $0.shownLoad != nil } }
    /// Counted activities with no known load.
    var unscoredCount: Int { recent.filter { $0.shownLoad == nil }.count }

    init(activities: [ExternalActivity], today: String, weekCount: Int = 12) {
        let calendar = CalendarProjection.calendar
        guard weekCount > 0, let date = CalendarProjection.date(from: today),
              CalendarProjection.dateString(date) == today else {
            weeks = []; thisWeek = []; recent = []; return
        }
        let monday = WorkoutConsistency.monday(of: date)
        let firstDay = CalendarProjection.dateString(
            calendar.date(byAdding: .day, value: -(weekCount - 1) * 7, to: monday)!)
        let unique = Dictionary(activities.map { ($0.id, $0) }, uniquingKeysWith: { a, b in
            (a.synced_at ?? 0) >= (b.synced_at ?? 0) ? a : b
        })
        let counted = unique.values.filter {
            !$0.isDeleted && Self.enduranceKinds.contains($0.kind)
                && $0.date >= firstDay && $0.date <= today
        }
        recent = counted.sorted { a, b in
            a.date != b.date ? a.date > b.date : (a.synced_at ?? 0, a.id) > (b.synced_at ?? 0, b.id)
        }
        weeks = (0..<weekCount).reversed().map { offset in
            let weekStart = calendar.date(byAdding: .day, value: -offset * 7, to: monday)!
            let start = CalendarProjection.dateString(weekStart)
            let end = offset == 0 ? today
                : CalendarProjection.dateString(calendar.date(byAdding: .day, value: 6, to: weekStart)!)
            let inWeek = counted.filter { $0.date >= start && $0.date <= end }
            return Week(start: start, end: end,
                        seconds: inWeek.reduce(0) { $0 + Self.seconds($1) },
                        count: inWeek.count,
                        load: Self.load(inWeek),
                        unscored: inWeek.filter { $0.shownLoad == nil }.count,
                        isCurrent: offset == 0)
        }
        let currentStart = weeks.last?.start ?? today
        let current = counted.filter { $0.date >= currentStart }
        thisWeek = Dictionary(grouping: current, by: \.kind).map { kind, items in
            KindTotal(kind: kind,
                      seconds: items.reduce(0) { $0 + Self.seconds($1) },
                      meters: items.reduce(0) { $0 + max(0, $1.distance_m ?? 0) },
                      count: items.count)
        }
        .sorted { a, b in a.seconds != b.seconds ? a.seconds > b.seconds : a.kind < b.kind }
    }

    /// Known loads summed; nil when activities exist but none has a load,
    /// so unscored training never reads as zero.
    static func load(_ activities: [ExternalActivity]) -> Int? {
        let known = activities.compactMap(\.shownLoad)
        if known.isEmpty && !activities.isEmpty { return nil }
        return known.reduce(0, +)
    }

    static func seconds(_ activity: ExternalActivity) -> Int {
        max(0, activity.moving_time_sec ?? activity.elapsed_time_sec ?? 0)
    }

    /// "2h 15m", "45m" or "0m".
    static func duration(_ seconds: Int) -> String {
        let h = seconds / 3600, m = (seconds % 3600) / 60
        if h > 0 { return m > 0 ? "\(h)h \(m)m" : "\(h)h" }
        return "\(m)m"
    }

    /// Swims in meters or yards to match the member's mi/km choice;
    /// everything else in miles or kilometers.
    static func distance(_ meters: Double, kind: String, unit: RunDistanceUnit) -> String? {
        guard meters.isFinite, meters > 0 else { return nil }
        if kind == "swim" {
            let value = unit == .miles ? meters / 0.9144 : meters
            guard value < 1e12 else { return nil }
            return "\(Int(value.rounded()).formatted()) \(unit == .miles ? "yd" : "m")"
        }
        return String(format: "%.1f %@", meters / unit.meters, unit.abbreviation)
    }

    /// Pace for runs and walks ("8:02 /mi"), speed for rides ("18.6 mph"),
    /// or nil without both a time and a distance.
    static func pace(_ activity: ExternalActivity, unit: RunDistanceUnit) -> String? {
        let seconds = seconds(activity)
        guard let meters = activity.distance_m, meters > 0, seconds > 0 else { return nil }
        switch activity.kind {
        case "ride":
            let speed = (meters / unit.meters) / (Double(seconds) / 3600)
            return String(format: "%.1f %@", speed, unit == .miles ? "mph" : "km/h")
        case "run", "walk", "hike":
            let pace = Double(seconds) / (meters / unit.meters)
            guard pace < 3600 else { return nil }
            return "\(RunFormat.pace(pace)) /\(unit.abbreviation)"
        default:
            return nil
        }
    }
}
