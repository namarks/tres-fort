import XCTest
@testable import TresFort

final class WeekFortTests: XCTestCase {
    private func state(_ kind: DayProjection.Kind, sets: Int = 0, activity: Bool = false,
                       ride: Bool = false, blackout: Bool = false) -> WeekFort.State {
        WeekFort.state(kind: kind, loggedSets: sets, hasActivity: activity,
                       hasPlannedRide: ride, suppressesEndurance: blackout)
    }

    func testLoggedWorkRaisesATrainedTower() {
        XCTAssertEqual(state(.completed), .trained)
        XCTAssertEqual(state(.inProgress, sets: 3), .trained)
        XCTAssertEqual(state(.none, activity: true), .trained, "a run or a logged activity is training")
        XCTAssertEqual(state(.rest, activity: true), .trained)
        XCTAssertEqual(state(.planned, activity: true), .trained)
    }

    func testWorkStillToDoIsAPlannedTower() {
        XCTAssertEqual(state(.planned), .planned)
        XCTAssertEqual(state(.projected), .planned)
        XCTAssertEqual(state(.inProgress, sets: 0), .planned, "an in-progress session with no sets records no work")
        XCTAssertEqual(state(.rest, ride: true), .planned)
    }

    func testEverythingElseRests() {
        for kind: DayProjection.Kind in [.rest, .skipped, .unavailable, .light, .none] {
            XCTAssertEqual(state(kind), .rest, "\(kind)")
        }
    }

    func testHardBlackoutIgnoresEnduranceLikeTheCalendar() {
        XCTAssertEqual(state(.unavailable, activity: true, blackout: true), .rest)
        XCTAssertEqual(state(.unavailable, ride: true, blackout: true), .rest)
        XCTAssertEqual(state(.completed, blackout: true), .trained, "a logged session still counts")
    }

    private func days(_ states: [WeekFort.State]) -> [WeekFort.Day] {
        states.enumerated().map { WeekFort.Day(ymd: "2026-11-0\($0.offset + 2)", state: $0.element, isToday: $0.offset == 1) }
    }

    func testSummaryCountsTrainedAgainstEveryTrainingDay() {
        XCTAssertEqual(WeekFort.summary(days([.trained, .planned, .rest, .planned, .rest, .planned, .planned])), "1 of 5 done")
        XCTAssertEqual(WeekFort.summary(days([.planned, .planned, .rest])), "2 planned")
        XCTAssertEqual(WeekFort.summary(days([.trained, .rest])), "1 done")
        XCTAssertEqual(WeekFort.summary(days([.rest, .rest])), "Rest week")
    }

    func testAccessibilityLabelNamesTheWeekAndCount() {
        XCTAssertEqual(WeekFort.accessibilityLabel(title: "THIS WEEK", days: days([.trained, .planned, .rest])),
                       "This week: 1 of 2 training days done")
        XCTAssertEqual(WeekFort.accessibilityLabel(title: "NEXT WEEK", days: days([.planned, .rest])),
                       "Next week: 0 of 1 training day done")
        XCTAssertEqual(WeekFort.accessibilityLabel(title: "THIS WEEK", days: days([.rest])), "This week: rest week")
    }
}
