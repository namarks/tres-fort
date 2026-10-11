import XCTest
@testable import TresFort

final class TodayWeekSectionTests: XCTestCase {
    private func ymd(_ dates: [Date]) -> [String] { dates.map(CalendarProjection.dateString) }

    func testPagesStartOnTheWeekContainingTodayAndRunForward() {
        // Sunday 2026-10-11 belongs to the week of Monday 2026-10-05.
        let weeks = TodayWeekSection.weeks(startingWith: "2026-10-11", count: TodayWeekSection.weekCount)
        XCTAssertEqual(weeks.count, TodayWeekSection.weekCount)
        XCTAssertEqual(ymd(weeks[0]), ["2026-10-05", "2026-10-06", "2026-10-07", "2026-10-08",
                                        "2026-10-09", "2026-10-10", "2026-10-11"])
        XCTAssertEqual(ymd(weeks[1]).first, "2026-10-12")
        XCTAssertEqual(ymd(weeks[1]).last, "2026-10-18")
        for (index, week) in weeks.enumerated() {
            XCTAssertEqual(week.count, 7, "week \(index)")
            if index > 0, let previous = weeks[index - 1].last, let first = week.first {
                XCTAssertEqual(CalendarProjection.calendar.dateComponents([.day], from: previous, to: first).day, 1)
            }
        }
    }

    func testWeeksCrossYearAndDaylightSavingBoundaries() {
        let weeks = TodayWeekSection.weeks(startingWith: "2026-12-30", count: 3)
        XCTAssertEqual(ymd(weeks[0]).first, "2026-12-28")
        XCTAssertEqual(ymd(weeks[1]).first, "2027-01-04")
        XCTAssertEqual(ymd(weeks[2]).last, "2027-01-17")
        let fallBack = TodayWeekSection.weeks(startingWith: "2026-10-26", count: 2)
        XCTAssertEqual(ymd(fallBack[1]), ["2026-11-02", "2026-11-03", "2026-11-04", "2026-11-05",
                                          "2026-11-06", "2026-11-07", "2026-11-08"])
    }

    func testInvalidTodayHasNoPages() {
        XCTAssertTrue(TodayWeekSection.weeks(startingWith: "not-a-date", count: 4).isEmpty)
        XCTAssertTrue(TodayWeekSection.weeks(startingWith: "2026-10-11", count: 0).isEmpty)
    }

    func testTitlesNameTheNearWeeksThenTheirDates() {
        let weeks = TodayWeekSection.weeks(startingWith: "2026-10-11", count: 4)
        XCTAssertEqual(TodayWeekSection.title(forWeek: 0, days: weeks[0]), "THIS WEEK")
        XCTAssertEqual(TodayWeekSection.title(forWeek: 1, days: weeks[1]), "NEXT WEEK")
        XCTAssertEqual(TodayWeekSection.title(forWeek: 2, days: weeks[2]), "OCT 19 – 25")
        XCTAssertEqual(TodayWeekSection.title(forWeek: 3, days: weeks[3]), "OCT 26 – NOV 1")
    }
}
