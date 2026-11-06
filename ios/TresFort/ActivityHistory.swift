import Foundation

/// Everything a member has done, newest first, for History on the Activity
/// tab: workouts finished in Très Fort, runs, rides and swims from any source
/// (recorded in the app, Apple Health, intervals.icu, .fit files) and
/// activities logged by hand, such as soccer. Pure, so the view and tests
/// share one set of rules.
struct ActivityHistory {
    /// The filter chips above the list. Only kinds the member has done show.
    enum Category: String, CaseIterable, Identifiable, Hashable {
        case workouts, runs, rides, swims, walks, other

        var id: String { rawValue }

        var title: String {
            switch self {
            case .workouts: return "Workouts"
            case .runs: return "Runs"
            case .rides: return "Rides"
            case .swims: return "Swims"
            case .walks: return "Walks"
            case .other: return "Other"
            }
        }

        /// A run, ride, swim or walk kind from any source; a logged "lift"
        /// counts as a workout.
        static func forKind(_ kind: String) -> Category {
            switch kind {
            case "run": return .runs
            case "ride": return .rides
            case "swim": return .swims
            case "walk", "hike": return .walks
            case "lift", "strength": return .workouts
            default: return .other
            }
        }
    }

    struct Entry: Identifiable, Equatable {
        enum Kind: Equatable {
            /// A workout from the runner; its record has the sets.
            case workout
            /// A run, ride, swim or other activity from a provider or the recorder.
            case activity
            /// An activity the member logged by hand.
            case logged
        }

        let id: String
        let date: String
        let kind: Kind
        let category: Category
        let title: String
        let glyph: String
        /// Facts after the date, such as "3.3 mi · 25m · 7:47 /mi".
        let details: [String]
        let attribution: String?
        /// Recorded in the app, so its record has a route map.
        let hasRoute: Bool
        let inProgress: Bool
        /// What tapping the entry opens: one activity on its own, or the
        /// whole date's record for a workout (nil).
        let focus: DayAgendaFocus?
    }

    struct Month: Identifiable, Equatable {
        /// `YYYY-MM`.
        let id: String
        let entries: [Entry]
    }

    /// What the history needs to know about a saved workout.
    struct WorkoutInfo: Equatable {
        let name: String
        /// Only an outdoor run, so the recorded run stands for it.
        let isRunOnly: Bool
    }

    let entries: [Entry]

    init(sessions: [SessionRow],
         activities: [ExternalActivity],
         logged: [ActivityRow],
         today: String,
         unit: RunDistanceUnit,
         setCount: (String) -> Int,
         workout: (String?) -> WorkoutInfo?,
         isHidden: (String) -> Bool = { _ in false }) {
        let liveActivities = activities.filter { !$0.isDeleted && $0.date <= today && !isHidden($0.date) }
        let activitiesByDate = Dictionary(grouping: liveActivities, by: \.date)
        var out: [(entry: Entry, order: Int)] = []

        // A retry or correction must not list a session twice, nor keep an
        // older state after the current one changed.
        let current = Dictionary(sessions.map { ($0.id, $0) }, uniquingKeysWith: { a, b in
            (a.updated_at ?? 0) > (b.updated_at ?? 0) ? a : b
        })
        for session in current.values where session.date <= today {
            let count = setCount(session.id)
            let inProgress = session.status == "in_progress"
            guard session.status == "completed" || (inProgress && count > 0) else { continue }
            let info = workout(session.workout_id)
            // A finished run workout is its run: list the run once, with the
            // distance and pace, instead of a workout of one timed set.
            if !inProgress, info?.isRunOnly == true,
               PlannedRunRecord.matchingRun(workoutName: info?.name,
                                            among: activitiesByDate[session.date] ?? []) != nil {
                continue
            }
            let title = info?.name ?? (session.isFreestyle ? "Freestyle workout" : "Workout")
            var details = ["\(count) \(count == 1 ? "set" : "sets")"]
            if !inProgress, let start = session.started_at, let end = session.completed_at,
               start > 0, end > start {
                details.append(EnduranceProgress.duration((end - start) / 1_000))
            }
            out.append((Entry(id: "workout:" + session.id, date: session.date, kind: .workout,
                              category: .workouts, title: title, glyph: "dumbbell.fill",
                              details: details, attribution: nil, hasRoute: false,
                              inProgress: inProgress, focus: nil), 0))
        }

        for activity in liveActivities {
            var details: [String] = []
            if let meters = activity.distance_m,
               let distance = EnduranceProgress.distance(meters, kind: activity.kind, unit: unit) {
                details.append(distance)
            }
            let seconds = EnduranceProgress.seconds(activity)
            if seconds > 0 { details.append(EnduranceProgress.duration(seconds)) }
            if let pace = EnduranceProgress.pace(activity, unit: unit) { details.append(pace) }
            out.append((Entry(id: "activity:" + activity.id, date: activity.date, kind: .activity,
                              category: Category.forKind(activity.kind), title: activity.displayTitle,
                              glyph: activity.glyph, details: details,
                              attribution: activity.source_attribution,
                              hasRoute: activity.source == "recording", inProgress: false,
                              focus: .activity(activity.id)), 1))
        }

        for row in logged where row.deleted_at == nil && row.date <= today && !isHidden(row.date) {
            let label = PendingActivity.label(for: row.type)
            let title = row.title?.trimmingCharacters(in: .whitespacesAndNewlines)
            var details: [String] = []
            if let minutes = row.duration_minutes, minutes > 0 {
                details.append(EnduranceProgress.duration(minutes * 60))
            }
            if let title, !title.isEmpty, title != label { details.append(label) }
            out.append((Entry(id: "logged:" + row.id, date: row.date, kind: .logged,
                              category: Category.forKind(row.type),
                              title: (title?.isEmpty == false ? title! : label),
                              glyph: PendingActivity.glyph(for: row.type), details: details,
                              attribution: nil, hasRoute: false, inProgress: false,
                              focus: .logged(row.id)), 2))
        }

        // Newest date first; on one date, the workout, then activities, then
        // logged ones, each in a stable order.
        entries = out.sorted { a, b in
            if a.entry.date != b.entry.date { return a.entry.date > b.entry.date }
            if a.order != b.order { return a.order < b.order }
            if a.entry.title != b.entry.title { return a.entry.title < b.entry.title }
            return a.entry.id < b.entry.id
        }.map(\.entry)
    }

    /// Kinds present in the history, in a fixed order.
    var categories: [Category] {
        let present = Set(entries.map(\.category))
        return Category.allCases.filter(present.contains)
    }

    /// Entries in one category (all of them for nil), by month, newest first.
    func months(in category: Category? = nil) -> [Month] {
        let shown = category.map { wanted in entries.filter { $0.category == wanted } } ?? entries
        var months: [Month] = []
        for entry in shown {
            let key = String(entry.date.prefix(7))
            if let last = months.last, last.id == key {
                months[months.count - 1] = Month(id: key, entries: last.entries + [entry])
            } else {
                months.append(Month(id: key, entries: [entry]))
            }
        }
        return months
    }

    /// "November 2026" for `2026-11`.
    static func monthTitle(_ id: String) -> String {
        guard let date = CalendarProjection.date(from: id + "-01") else { return id }
        return monthFormatter.string(from: date)
    }

    /// "Mon, Nov 2" for a civil date.
    static func dayTitle(_ civilDate: String) -> String {
        guard let date = CalendarProjection.date(from: civilDate) else { return civilDate }
        return dayFormatter.string(from: date)
    }

    private static let monthFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.calendar = CalendarProjection.calendar
        formatter.timeZone = CalendarProjection.calendar.timeZone
        formatter.setLocalizedDateFormatFromTemplate("MMMM yyyy")
        return formatter
    }()

    private static let dayFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.calendar = CalendarProjection.calendar
        formatter.timeZone = CalendarProjection.calendar.timeZone
        formatter.setLocalizedDateFormatFromTemplate("EEE MMM d")
        return formatter
    }()
}
