import Foundation

/// Counts completed native workout records, using their civil workout dates.
/// External and manual activities are deliberately outside this projection.
struct WorkoutConsistency {
    struct Week: Identifiable, Equatable {
        var id: String { start }
        let start: String
        let end: String
        let completed: Int
        let isCurrent: Bool
    }

    let weeks: [Week]
    var total: Int { weeks.reduce(0) { $0 + $1.completed } }

    init(sessions: [SessionRow], today: String, weekCount: Int = 8) {
        let calendar = CalendarProjection.calendar
        guard weekCount > 0, let date = CalendarProjection.date(from: today),
              CalendarProjection.dateString(date) == today else { weeks = []; return }
        let daysSinceMonday = (calendar.component(.weekday, from: date) + 5) % 7
        let monday = calendar.date(byAdding: .day, value: -daysSinceMonday, to: date)!
        // A retry/correction must not double-count an ID or retain its older
        // completed state after the current record has been discarded.
        let current = Dictionary(sessions.map { ($0.id, $0) }, uniquingKeysWith: { a, b in
            (a.updated_at ?? 0) > (b.updated_at ?? 0) ? a : b
        })
        let dates = current.values.filter { $0.status == "completed" && $0.date <= today }
            .map(\.date)
        weeks = (0..<weekCount).reversed().map { offset in
            let start = CalendarProjection.dateString(calendar.date(byAdding: .day, value: -offset * 7, to: monday)!)
            let end = offset == 0 ? today : CalendarProjection.dateString(
                calendar.date(byAdding: .day, value: -offset * 7 + 6, to: monday)!)
            return Week(start: start, end: end,
                        completed: dates.filter { $0 >= start && $0 <= end }.count,
                        isCurrent: offset == 0)
        }
    }
}
