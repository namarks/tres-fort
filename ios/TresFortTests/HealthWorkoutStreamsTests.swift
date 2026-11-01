import XCTest
@testable import TresFort

/// Detail streams sent with Apple Health runs and rides
/// (docs/plans/endurance-training-load P3).
final class HealthWorkoutStreamsTests: XCTestCase {
    private func points(_ value: Double, count: Int, every step: Double = 1,
                        from start: Double = 0, source: String? = "watch") -> [HealthStreamPoint] {
        (0..<count).map { HealthStreamPoint(t: start + Double($0) * step, v: value, source: source) }
    }

    func testAveragesReadingsIntoWholeSeconds() throws {
        let twiceASecond = (0..<120).map {
            HealthStreamPoint(t: Double($0) * 0.5, v: $0 % 2 == 0 ? 150 : 151, source: "strap")
        }
        let stream = try XCTUnwrap(HealthWorkoutStreams.compact(twiceASecond, preferredSource: nil))
        XCTAssertEqual(stream.t, Array(0..<60))
        XCTAssertEqual(Set(stream.v), [151]) // 150.5 rounds up
    }

    func testKeepsOneWriterSoTwoDevicesAreNeverInterleaved() throws {
        let watch = points(140, count: 600, every: 5, source: "com.apple.health")
        let strap = points(150, count: 3600, source: "com.example.strap")
        // The workout's own app wins when it recorded enough.
        let own = try XCTUnwrap(HealthWorkoutStreams.compact(watch + strap, preferredSource: "com.apple.health"))
        XCTAssertEqual(own.t.count, 600)
        XCTAssertEqual(Set(own.v), [140])
        // Otherwise the app with the most samples.
        let most = try XCTUnwrap(HealthWorkoutStreams.compact(watch + strap, preferredSource: "com.zwift"))
        XCTAssertEqual(most.t.count, 3600)
        XCTAssertEqual(Set(most.v), [150])
    }

    func testDropsStreamsTooShortToScore() {
        XCTAssertNil(HealthWorkoutStreams.compact([], preferredSource: nil))
        XCTAssertNil(HealthWorkoutStreams.compact(points(140, count: 29), preferredSource: nil))
        // Zwift writes heart rate about every ten minutes: sent, and the
        // Worker decides it covers too little of the ride.
        XCTAssertNotNil(HealthWorkoutStreams.compact(points(140, count: 30, every: 600), preferredSource: nil))
    }

    func testIgnoresInvalidReadingsAndCapsAtADay() throws {
        var input = points(200, count: 40)
        input.append(HealthStreamPoint(t: -1, v: 200, source: "watch"))
        input.append(HealthStreamPoint(t: 41, v: .nan, source: "watch"))
        input.append(HealthStreamPoint(t: 90_000, v: 200, source: "watch"))
        let stream = try XCTUnwrap(HealthWorkoutStreams.compact(input, preferredSource: "watch"))
        XCTAssertEqual(stream.t, Array(0..<40))
    }

    func testPushBodyCarriesStreamsOnlyWhenRead() throws {
        func push(_ streams: [String: HealthStream]?) -> [String: Any] {
            HealthKitActivityPush(id: "w", date: "2026-10-24", start_date_local_ms: 1,
                start_date_utc_ms: 2, source_timezone: nil, kind: "ride", name: "Ride",
                moving_time_sec: 3600, elapsed_time_sec: 3600, distance_m: nil, average_hr: nil,
                max_hr: nil, calories: nil, elevation_gain_m: nil, raw: nil, streams: streams).jsonBody
        }
        // A failed read omits the key, so the Worker keeps what it stored.
        XCTAssertNil(push(nil)["streams"])
        // An empty read says the workout has none.
        XCTAssertEqual((push([:])["streams"] as? [String: Any])?.isEmpty, true)
        let body = push(["heart_rate": HealthStream(t: [0, 1], v: [150, 151])])
        let heartRate = try XCTUnwrap((body["streams"] as? [String: Any])?["heart_rate"] as? [String: Any])
        XCTAssertEqual(heartRate["t"] as? [Int], [0, 1])
        XCTAssertEqual(heartRate["v"] as? [Int], [150, 151])
        XCTAssertNoThrow(try JSONSerialization.data(withJSONObject: body))
    }

    func testOnlyRunsAndRidesCarryStreams() {
        XCTAssertTrue(HealthKitSyncModel.hasDetailStreams(kind: "run"))
        XCTAssertTrue(HealthKitSyncModel.hasDetailStreams(kind: "ride"))
        XCTAssertFalse(HealthKitSyncModel.hasDetailStreams(kind: "swim"))
        XCTAssertFalse(HealthKitSyncModel.hasDetailStreams(kind: "strength"))
    }
}
