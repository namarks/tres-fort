import Foundation

/// Counts completed native workout records, using their civil workout dates.
/// External and manual activities are deliberately outside this projection.
struct WorkoutConsistency {
    struct Day: Identifiable, Equatable {
        var id: String { date }
        let date: String
        let completed: Int
        let isToday: Bool
        /// Later this week; nothing can be completed there yet.
        let isFuture: Bool
    }

    struct Week: Identifiable, Equatable {
        var id: String { start }
        let start: String
        let end: String
        let completed: Int
        let isCurrent: Bool
        /// Monday through Sunday, including the rest of the current week.
        let days: [Day]
    }

    let weeks: [Week]
    var total: Int { weeks.reduce(0) { $0 + $1.completed } }
    var activeDays: Int { weeks.reduce(0) { $0 + $1.days.filter { $0.completed > 0 }.count } }
    /// Consecutive Monday–Sunday weeks with at least one completed workout,
    /// ending this week. An empty current week is still in progress, so the
    /// count then ends last week instead of resetting.
    let currentStreak: Int
    /// Longest such run anywhere in the history, not just the displayed weeks.
    let longestStreak: Int

    init(sessions: [SessionRow], today: String, weekCount: Int = 8) {
        let calendar = CalendarProjection.calendar
        guard weekCount > 0, let date = CalendarProjection.date(from: today),
              CalendarProjection.dateString(date) == today else {
            weeks = []; currentStreak = 0; longestStreak = 0; return
        }
        let monday = Self.monday(of: date)
        // A retry/correction must not double-count an ID or retain its older
        // completed state after the current record has been discarded.
        let current = Dictionary(sessions.map { ($0.id, $0) }, uniquingKeysWith: { a, b in
            (a.updated_at ?? 0) > (b.updated_at ?? 0) ? a : b
        })
        let dates = current.values.filter { $0.status == "completed" && $0.date <= today }
            .map(\.date)
        let perDay = Dictionary(dates.map { ($0, 1) }, uniquingKeysWith: +)
        weeks = (0..<weekCount).reversed().map { offset in
            let weekStart = calendar.date(byAdding: .day, value: -offset * 7, to: monday)!
            let days = (0..<7).map { index in
                let day = CalendarProjection.dateString(calendar.date(byAdding: .day, value: index, to: weekStart)!)
                return Day(date: day, completed: perDay[day] ?? 0, isToday: day == today, isFuture: day > today)
            }
            let start = days[0].date
            let end = offset == 0 ? today : days[6].date
            return Week(start: start, end: end,
                        completed: dates.filter { $0 >= start && $0 <= end }.count,
                        isCurrent: offset == 0, days: days)
        }

        let activeWeeks = Set(perDay.keys.compactMap { CalendarProjection.date(from: $0) }
            .map { CalendarProjection.dateString(Self.monday(of: $0)) })
        let previousMonday = { (start: String) -> String in
            CalendarProjection.dateString(calendar.date(
                byAdding: .day, value: -7, to: CalendarProjection.date(from: start)!)!)
        }
        var cursor = CalendarProjection.dateString(monday)
        if !activeWeeks.contains(cursor) { cursor = previousMonday(cursor) }
        var streak = 0
        while activeWeeks.contains(cursor) { streak += 1; cursor = previousMonday(cursor) }
        currentStreak = streak

        var longest = 0, run = 0
        var last: String?
        for week in activeWeeks.sorted() {
            run = last.map { previousMonday(week) == $0 } == true ? run + 1 : 1
            longest = max(longest, run)
            last = week
        }
        longestStreak = longest
    }

    /// Workout days in the recurring weekly schedule, or nil when none are set.
    static func scheduledPerWeek(_ schedule: PlanSchedule?) -> Int? {
        guard let schedule else { return nil }
        let count = PlanSchedule.weekdayKeys.filter { schedule.templateID(forWeekdayKey: $0) != nil }.count
        return count > 0 ? count : nil
    }

    private static func monday(of date: Date) -> Date {
        let calendar = CalendarProjection.calendar
        let daysSinceMonday = (calendar.component(.weekday, from: date) + 5) % 7
        return calendar.date(byAdding: .day, value: -daysSinceMonday, to: date)!
    }
}
