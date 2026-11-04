import XCTest
@testable import TresFort

/// "How hard was it?" (docs/plans/sport-activities P2): when the rating is
/// offered, how a rated load is labeled, and the wire shape the Worker sends.
final class EffortRatingTests: XCTestCase {
    /// A soccer match from Apple Health with no heart rate, with `fields`
    /// set over it (NSNull for JSON null).
    private func activity(_ fields: [String: Any] = [:]) throws -> ExternalActivity {
        var row: [String: Any] = [
            "id": "healthkit:activity:u:1", "source": "healthkit", "external_id": "1", "date": "2026-11-02",
            "kind": "other", "sport": "soccer", "name": "Soccer", "moving_time_sec": 5400, "elapsed_time_sec": 5400,
            "synced_at": 1,
        ]
        row.merge(fields) { _, new in new }
        return try JSONDecoder().decode(ExternalActivity.self, from: JSONSerialization.data(withJSONObject: row))
    }

    func testAWorkoutWithNoLoadOffersTheRating() throws {
        let unrated = try activity(["effective_load": NSNull(), "load_method": NSNull(), "effort": NSNull()])
        XCTAssertNil(unrated.effort)
        XCTAssertNil(unrated.shownLoad)
        XCTAssertTrue(unrated.offersEffortRating)
    }

    func testARatedWorkoutShowsAnEstimateAndCanStillBeChanged() throws {
        let rated = try activity(["effective_load": 129, "load_method": "effort", "effort": 6])
        XCTAssertEqual(rated.effort, 6)
        XCTAssertEqual(rated.shownLoad, 129)
        XCTAssertEqual(rated.loadMethodLabel, "effort estimate")
        XCTAssertTrue(rated.offersEffortRating)
    }

    func testAMeasuredLoadHidesTheRating() throws {
        let measured = try activity([
            "average_hr": 150, "effective_load": 100, "load_method": "heart_rate_average", "effort": 9,
        ])
        XCTAssertEqual(measured.loadMethodLabel, "avg heart rate")
        XCTAssertFalse(measured.offersEffortRating)
        // An older Worker sends only the provider's load.
        let provider = try activity(["source": "intervals", "training_load": 72])
        XCTAssertEqual(provider.shownLoad, 72)
        XCTAssertFalse(provider.offersEffortRating)
    }

    func testAnOlderWorkerWithoutRatingsDecodes() throws {
        let older = try activity()
        XCTAssertNil(older.effort)
        XCTAssertTrue(older.offersEffortRating)
    }

    func testTheScaleNamesEveryStep() {
        XCTAssertEqual(Array(EffortScale.range), Array(1...10))
        XCTAssertEqual(EffortScale.label(1), "Very easy")
        XCTAssertEqual(EffortScale.label(3), "Moderate")
        XCTAssertEqual(EffortScale.label(7), "Very hard")
        XCTAssertEqual(EffortScale.label(10), "All out")
        XCTAssertFalse(EffortScale.range.contains { EffortScale.label($0).isEmpty })
    }

    func testTheWorkersResponseDecodes() throws {
        let body = #"{"activity":{"id":"healthkit:activity:u:1","effort":null,"effective_load":null}}"#
        let response = try JSONDecoder().decode(ActivityEffortResponse.self, from: Data(body.utf8))
        XCTAssertEqual(response.activity.id, "healthkit:activity:u:1")
        XCTAssertNil(response.activity.effort)
    }
}
