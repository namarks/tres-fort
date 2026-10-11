import XCTest
@testable import TresFort

final class WorkoutConsistencyTests: XCTestCase {
    private func session(_ id: String, _ date: String, _ status: String = "completed", revision: Int = 1) -> SessionRow {
        SessionRow(id: id, date: date, status: status, workout_id: nil, updated_at: revision)
    }

    func testMondayBoundaryZeroWeeksAndPartialCurrentWeek() {
        let summary = WorkoutConsistency(sessions: [
            session("old", "2026-08-16"), session("first", "2026-08-17"),
            session("sunday", "2026-09-06"), session("monday", "2026-09-07"),
            session("today", "2026-09-08"), session("future", "2026-09-09")
        ], today: "2026-09-08", weekCount: 4)
        XCTAssertEqual(summary.weeks.map(\.start), ["2026-08-17", "2026-08-24", "2026-08-31", "2026-09-07"])
        XCTAssertEqual(summary.weeks.map(\.completed), [1, 0, 1, 2])
        XCTAssertEqual(summary.weeks.last?.end, "2026-09-08")
        XCTAssertEqual(summary.weeks.map(\.isCurrent), [false, false, false, true])
        XCTAssertEqual(summary.total, 4)
    }

    func testOnlyCurrentCompletedRecordsCountIncludingSeparateSameDayWorkouts() {
        let summary = WorkoutConsistency(sessions: [
            session("a", "2026-09-08"), session("a", "2026-09-08"),
            session("b", "2026-09-08"), session("discard", "2026-09-08"),
            session("discard", "2026-09-08", "discarded", revision: 2),
            session("planned", "2026-09-08", "planned"),
            session("active", "2026-09-08", "in_progress"),
            session("skip", "2026-09-08", "skipped")
        ], today: "2026-09-08")
        XCTAssertEqual(summary.total, 2)
    }

    func testCivilWeeksCrossDSTAndYearBoundaryWithoutTimestampConversion() {
        let dst = WorkoutConsistency(sessions: [session("a", "2026-03-08"), session("b", "2026-03-09")],
                                     today: "2026-03-09", weekCount: 2)
        XCTAssertEqual(dst.weeks.map(\.start), ["2026-03-02", "2026-03-09"])
        XCTAssertEqual(dst.weeks.map(\.completed), [1, 1])
        let year = WorkoutConsistency(sessions: [session("a", "2025-12-31"), session("b", "2026-01-01")],
                                      today: "2026-01-01", weekCount: 1)
        XCTAssertEqual(year.weeks.first?.start, "2025-12-29")
        XCTAssertEqual(year.total, 2)
    }

    func testEmptyHistoryKeepsAllWeeksAtZeroAndInvalidClockHasNoProjection() {
        XCTAssertEqual(WorkoutConsistency(sessions: [], today: "2026-09-08").weeks.map(\.completed), Array(repeating: 0, count: 8))
        XCTAssertTrue(WorkoutConsistency(sessions: [], today: "invalid").weeks.isEmpty)
    }

    func testDayGridRunsMondayToSundayWithTodayFutureAndSameDayCounts() {
        let summary = WorkoutConsistency(sessions: [
            session("mon", "2026-09-07"), session("a", "2026-09-08"), session("b", "2026-09-08"),
            session("future", "2026-09-10"), session("last", "2026-09-06")
        ], today: "2026-09-08", weekCount: 2)
        let current = summary.weeks[1]
        XCTAssertEqual(current.days.map(\.date), ["2026-09-07", "2026-09-08", "2026-09-09", "2026-09-10",
                                                  "2026-09-11", "2026-09-12", "2026-09-13"])
        XCTAssertEqual(current.days.map(\.completed), [1, 2, 0, 0, 0, 0, 0])
        XCTAssertEqual(current.days.map(\.isToday), [false, true, false, false, false, false, false])
        XCTAssertEqual(current.days.map(\.isFuture), [false, false, true, true, true, true, true])
        XCTAssertEqual(summary.weeks[0].days.last?.date, "2026-09-06")
        XCTAssertEqual(summary.weeks[0].days.last?.completed, 1)
        XCTAssertEqual(summary.activeDays, 3)
        XCTAssertEqual(summary.total, 4)
    }

    func testStreakKeepsAnUnfinishedCurrentWeekAndLooksBeyondTheWindow() {
        let history = ["2026-07-22", "2026-07-29", "2026-08-05", "2026-08-12",
                       "2026-08-26", "2026-09-02", "2026-09-09"].enumerated().map { session("s\($0.offset)", $0.element) }
        let waiting = WorkoutConsistency(sessions: history, today: "2026-09-16", weekCount: 2)
        XCTAssertEqual(waiting.currentStreak, 3, "An empty week in progress must not reset the streak")
        XCTAssertEqual(waiting.longestStreak, 4)
        let trained = WorkoutConsistency(sessions: history + [session("today", "2026-09-16")],
                                         today: "2026-09-16", weekCount: 2)
        XCTAssertEqual(trained.currentStreak, 4)
        XCTAssertEqual(trained.longestStreak, 4)
    }

    func testStreakEndsAfterAMissedWeekAndIgnoresUnfinishedRecords() {
        let gap = WorkoutConsistency(sessions: [session("a", "2026-09-01"), session("b", "2026-09-16")],
                                     today: "2026-09-16")
        XCTAssertEqual(gap.currentStreak, 1)
        let lapsed = WorkoutConsistency(sessions: [
            session("a", "2026-08-31"), session("skip", "2026-09-08", "skipped"),
            session("plan", "2026-09-15", "planned"), session("discard", "2026-09-14"),
            session("discard", "2026-09-14", "discarded", revision: 2)
        ], today: "2026-09-16")
        XCTAssertEqual(lapsed.currentStreak, 0)
        XCTAssertEqual(lapsed.longestStreak, 1)
        XCTAssertEqual(WorkoutConsistency(sessions: [], today: "2026-09-16").longestStreak, 0)
    }

    func testScheduledWorkoutsPerWeekCountsAssignedWeekdaysOnly() {
        XCTAssertEqual(WorkoutConsistency.scheduledPerWeek(
            PlanSchedule(version: 1, week: ["tue": "a", "thu": "b", "sat": "a", "sun": nil])), 3)
        XCTAssertNil(WorkoutConsistency.scheduledPerWeek(PlanSchedule(version: 1, week: ["mon": nil])))
        XCTAssertNil(WorkoutConsistency.scheduledPerWeek(nil))
    }
}
