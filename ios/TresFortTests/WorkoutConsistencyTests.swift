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
}
