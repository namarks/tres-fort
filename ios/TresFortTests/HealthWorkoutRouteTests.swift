import CoreLocation
import XCTest
@testable import TresFort

/// The route Apple Health saved with another app's run, as the app sends it
/// (docs/plans/run-recorder P6(b)): the server's encoding, and which runs
/// are remembered as done.
final class HealthWorkoutRouteTests: XCTestCase {
    private let start = Date(timeIntervalSince1970: 1_761_318_000)

    private func fix(_ second: TimeInterval, _ step: Int, horizontal: Double = 5, vertical: Double = 3,
                     altitude: Double = 15.34) -> CLLocation {
        CLLocation(coordinate: CLLocationCoordinate2D(latitude: 45.519 + Double(step) * 0.0001, longitude: -122.6793),
                   altitude: altitude, horizontalAccuracy: horizontal, verticalAccuracy: vertical,
                   timestamp: start.addingTimeInterval(second))
    }

    func testEncodesEachRouteAndEachLongGapAsItsOwnLine() throws {
        let route = try XCTUnwrap(HealthWorkoutRoute.encode([
            [fix(0, 0), fix(1, 1), fix(2, 2), fix(90, 3), fix(91, 4)],
            [fix(120, 5), fix(121, 6)],
        ]))
        XCTAssertEqual(route.v, 1)
        XCTAssertEqual(route.start_ms, 1_761_318_000_000)
        XCTAssertEqual(route.breaks, [3, 5])
        XCTAssertEqual(route.dt, [0, 1000, 1000, 88_000, 1000, 29_000, 1000])
        XCTAssertEqual(route.alt.first, 153)
        XCTAssertEqual(route.segments.map(\.count), [3, 2, 2])
        XCTAssertEqual(route.segments[0][0].latitude, 45.519, accuracy: 1e-9)
        XCTAssertEqual(route.segments[2][1].latitude, 45.5196, accuracy: 1e-9)
        XCTAssertEqual(route.segments[0][0].longitude, -122.6793, accuracy: 1e-9)
    }

    func testLeavesOutInvalidFixesAndUnknownAltitudes() throws {
        // A later route object that starts before the last kept fix goes
        // back in time; its fix is left out and it adds no line.
        let route = try XCTUnwrap(HealthWorkoutRoute.encode([
            [fix(0, 0, vertical: -1), fix(1, 1, horizontal: -1), fix(2, 2)],
            [fix(1.5, 3)],
        ]))
        XCTAssertEqual(route.dt, [0, 2000])
        XCTAssertEqual(route.alt, [nil, 153])
        XCTAssertEqual(route.breaks, [])
        XCTAssertNil(HealthWorkoutRoute.encode([]))
        XCTAssertNil(HealthWorkoutRoute.encode([[fix(0, 0, horizontal: -1)], []]))
    }

    func testTheBodyIsTheServersRouteWithNullAltitudes() throws {
        let route = try XCTUnwrap(HealthWorkoutRoute.encode([[fix(0, 0, vertical: -1), fix(1, 1)]]))
        let body = route.jsonBody
        let data = try JSONSerialization.data(withJSONObject: ["route": body])
        let decoded = try JSONDecoder().decode([String: EncodedActivityRoute].self, from: data)
        XCTAssertEqual(decoded["route"], route)
        XCTAssertTrue((body["alt"] as? [Any])?.first is NSNull)
    }

    func testOnlyTheRecordersOwnWorkoutsAreSkipped() {
        XCTAssertTrue(HealthWorkoutRoute.isRecorderTag(RunRecordingHealthTag.externalID(for: UUID())))
        XCTAssertFalse(HealthWorkoutRoute.isRecorderTag("strava:123"))
        XCTAssertFalse(HealthWorkoutRoute.isRecorderTag(nil))
    }

    func testTheLedgerRemembersRunsAndForgetsOnesPastTheLookBack() {
        var ledger = HealthRouteLedger(stored: nil)
        let old = UUID()
        let recent = UUID()
        ledger.record(old, start: start.addingTimeInterval(-400 * 86_400))
        ledger.record(recent, start: start)
        XCTAssertTrue(ledger.contains(recent))
        let reloaded = HealthRouteLedger(stored: ledger.stored as Any)
        XCTAssertEqual(reloaded, ledger)
        ledger.prune(before: start.addingTimeInterval(-365 * 86_400))
        XCTAssertFalse(ledger.contains(old))
        XCTAssertTrue(ledger.contains(recent))
        XCTAssertFalse(HealthRouteLedger(stored: "not a ledger").contains(recent))
    }
}
