import Foundation
import XCTest
@testable import TresFort

@MainActor
final class SourceAttributionTests: XCTestCase {
    private func activity(_ extra: [String: Any] = [:]) throws -> ExternalActivity {
        var value: [String: Any] = ["id": "ride-a", "source": "intervals", "external_id": "a",
            "date": "2026-09-08", "kind": "ride", "synced_at": 1_000]
        value.merge(extra) { _, new in new }
        return try JSONDecoder().decode(ExternalActivity.self, from: JSONSerialization.data(withJSONObject: value))
    }

    func testLegacyAndAttributedActivityDecodeAndPersist() throws {
        XCTAssertNil(try activity().source_attribution)
        XCTAssertNil(try activity().attribution_version)
        let attributed = try activity(["source_attribution": "Garmin Edge 840", "attribution_version": 1])
        XCTAssertEqual(attributed.source_attribution, "Garmin Edge 840")
        XCTAssertEqual(try JSONDecoder().decode(ExternalActivity.self, from: JSONEncoder().encode(attributed)), attributed)
    }

    func testLegacyCacheRefreshesOnlyActivitiesAndStopsAfterAttributionArrives() throws {
        let name = "SourceAttributionTests.\(UUID().uuidString)"
        let defaults = LocalPersistence(suiteName: name)!
        defer {
            defaults.removePersistentDomain(forName: name)
            try? FileManager.default.removeItem(at: defaults.trainingStore.directory)
        }
        func response(_ activity: ExternalActivity) -> StateResponse {
            StateResponse(plan: nil, plan_version: 0, sessions: [], sets: [],
                external_events: [], external_activities: [activity], activities: [],
                server_time: 100_000, externalSyncCursorsVersion: 2, planGroupsVersion: 1)
        }
        let first = try XCTUnwrap(StateSnapshotStore.reserveFullStateRequest(userID: "user-a", defaults: defaults))
        XCTAssertNotNil(StateSnapshotStore.commitStateResponse(response(try activity()), ticket: first, defaults: defaults))
        let upgrade = try XCTUnwrap(StateSnapshotStore.reserveStateRequest(userID: "user-a", defaults: defaults))
        XCTAssertEqual(upgrade.watermarks.activitiesSince, 0)
        XCTAssertEqual(upgrade.watermarks.eventsSince, 40_000)
        XCTAssertEqual(upgrade.watermarks.setsSince, 40_000)
        let fresh = try activity(["source_attribution": "Garmin Edge 840", "attribution_version": 1])
        XCTAssertNotNil(StateSnapshotStore.commitStateResponse(response(fresh), ticket: upgrade, defaults: defaults))
        let next = try XCTUnwrap(StateSnapshotStore.reserveStateRequest(userID: "user-a", defaults: defaults))
        XCTAssertEqual(next.watermarks.activitiesSince, 40_000)
        XCTAssertEqual(StateSnapshotStore.load(userID: "user-a", defaults: defaults)?.state.external_activities.first?.source_attribution, "Garmin Edge 840")
    }

    func testGroupAttributionFollowsVisibleRangeAndSurvivesDailyBucketing() throws {
        let series = try JSONDecoder().decode(MemberActivitySeries.self, from: Data(#"{"user_id":"a","days":[{"date":"2026-09-01","sessions":0,"rides":1,"activities":{},"source_attribution":"Includes Garmin device-sourced data"}]}"#.utf8))
        let today = try XCTUnwrap(CalendarProjection.date(from: "2026-09-12"))
        XCTAssertNil(ActivityLanes.lane(range: .week, series: series, today: today).sourceAttribution)
        for range in [ActivityRange.month, .year] {
            let lane = ActivityLanes.lane(range: range, series: series, today: today)
            XCTAssertEqual(lane.sourceAttribution, "Includes Garmin device-sourced data")
            XCTAssertEqual(lane.totalIntensity, 1)
        }
    }
}
