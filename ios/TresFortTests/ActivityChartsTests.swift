import XCTest
@testable import TresFort

/// A run's pace, heart rate and elevation charts as the app draws them
/// (docs/plans/run-detail-charts P1): the server's series, turned into the
/// member's units, and the in-memory store.
@MainActor
final class ActivityChartsTests: XCTestCase {
    /// The shape src/activityStreams.ts serves: 3 m/s, then a stop, then 4 m/s.
    private static let json = """
    {"activity_id":"intervals:activity:u:i9","source":"intervals",
     "streams":{"v":1,"t":[3,8,13,18,23,28,33,38,43,48,53,58],
       "distance_m":[15,30,45,60,75,90,105,125,145,165,185,205],
       "speed_mps":[3,3,3,3,3,0.2,null,4,4,4,4,4],
       "heart_rate":[140,141,142,143,null,150,151,152,153,154,155,156],
       "elevation_m":[10,10,11,12,12,13,14,14,15,16,16,17],
       "moving_s":60,"total_distance_m":205,"elevation_gain_m":7}}
    """

    private func decode(_ text: String = ActivityChartsTests.json) throws -> ActivityStreamsResponse {
        try JSONDecoder().decode(ActivityStreamsResponse.self, from: Data(text.utf8))
    }

    func testARunIsChartedOverDistanceInTheMembersUnit() throws {
        let streams = try decode().streams
        let series = try XCTUnwrap(ActivityChartSeries(streams: streams, kind: "run", unit: .kilometers))
        XCTAssertEqual(series.axis, .distance(.kilometers))
        XCTAssertEqual(series.pace.first?.x ?? 0, 0.015, accuracy: 1e-9)
        // 3 m/s is 5:33 a kilometer.
        XCTAssertEqual(series.pace.first?.y ?? 0, 1000 / 3, accuracy: 1e-6)
        XCTAssertEqual(series.paceText(1000 / 3), "5:33 /km")
        XCTAssertEqual(series.elevationUnit, "m")
        XCTAssertEqual(series.climb, 7)
    }

    func testEveryChartSharesTheWholeActivitysAxis() throws {
        // Heart rate missing at the start must not stretch its chart.
        let text = Self.json.replacingOccurrences(of: "\"heart_rate\":[140,141,142,143,null,",
                                                  with: "\"heart_rate\":[null,null,null,null,null,")
        let series = try XCTUnwrap(ActivityChartSeries(streams: try decode(text).streams, kind: "run", unit: .kilometers))
        XCTAssertEqual(series.heartRate.first?.x ?? 0, 0.09, accuracy: 1e-9)
        XCTAssertEqual(series.xDomain.lowerBound, 0.015, accuracy: 1e-9)
        XCTAssertEqual(series.xDomain.upperBound, 0.205, accuracy: 1e-9)
    }

    func testStandingStillAndMissingPointsBreakTheLine() throws {
        let series = try XCTUnwrap(ActivityChartSeries(streams: try decode().streams, kind: "run", unit: .miles))
        // 0.2 m/s is standing still and null is no data: the pace line
        // resumes as a new segment.
        XCTAssertEqual(series.pace.map(\.segment), [0, 0, 0, 0, 0, 1, 1, 1, 1, 1])
        XCTAssertEqual(series.heartRate.map(\.segment), [0, 0, 0, 0, 1, 1, 1, 1, 1, 1, 1])
        XCTAssertEqual(series.elevation.first?.y ?? 0, 10 * ActivityChartSeries.feetPerMeter, accuracy: 1e-6)
        XCTAssertEqual(series.climb, 23)
        XCTAssertEqual(series.elevationUnit, "ft")
    }

    func testAveragePaceIsMovingTimeOverDistance() throws {
        // 60 s over 205 m: 4:52.7 a kilometer, whatever the points average.
        let series = try XCTUnwrap(ActivityChartSeries(streams: try decode().streams, kind: "run", unit: .kilometers))
        XCTAssertEqual(series.paceAverage ?? 0, 60 / 0.205, accuracy: 1e-6)
        let ride = try XCTUnwrap(ActivityChartSeries(streams: try decode().streams, kind: "ride", unit: .kilometers))
        XCTAssertEqual(ride.paceAverage ?? 0, 0.205 / (60.0 / 3600), accuracy: 1e-6)
    }

    func testARideShowsSpeedNotPace() throws {
        let series = try XCTUnwrap(ActivityChartSeries(streams: try decode().streams, kind: "ride", unit: .miles))
        XCTAssertTrue(series.paceIsSpeed)
        XCTAssertEqual(series.pace.first?.y ?? 0, 3 * 3600 / 1609.344, accuracy: 1e-6)
        XCTAssertEqual(series.paceText(18.64), "18.6 mph")
    }

    func testHeartRateOnlyIsChartedOverMovingTime() throws {
        let text = """
        {"activity_id":"intervals:activity:u:i8","source":"intervals",
         "streams":{"v":1,"t":[30,90,150],"distance_m":null,"speed_mps":null,
           "heart_rate":[120,130,140],"elevation_m":null,
           "moving_s":180,"total_distance_m":null,"elevation_gain_m":null}}
        """
        let series = try XCTUnwrap(ActivityChartSeries(streams: try decode(text).streams, kind: "soccer", unit: .miles))
        XCTAssertEqual(series.axis, .minutes)
        XCTAssertEqual(series.heartRate.map(\.x), [0.5, 1.5, 2.5])
        XCTAssertTrue(series.pace.isEmpty)
        XCTAssertTrue(series.elevation.isEmpty)
        XCTAssertNil(series.climb)
        XCTAssertEqual(series.xText(2.5), "2:30")
    }

    func testOneGPSHiccupDoesNotSquashThePaceChart() {
        var values: [Double?] = Array(repeating: 300, count: 60)
        values[30] = 3000
        let clamped = ActivityChartSeries.clampedToPercentiles(values)
        XCTAssertEqual(clamped[30], 300)
    }

    func testTheReadOutFindsTheNearestPoint() throws {
        let series = try XCTUnwrap(ActivityChartSeries(streams: try decode().streams, kind: "run", unit: .kilometers))
        let index = try XCTUnwrap(ActivityChartSeries.nearestIndex(series.xs, to: 0.031))
        XCTAssertEqual(index, 1)
        XCTAssertEqual(ActivityChartSeries.point(series.heartRate, at: index)?.y, 141)
    }

    func testTheReadOutShowsNothingWhereASeriesHasAGap() throws {
        // Heart rate is missing at 0.075 km; the read-out must not borrow
        // the neighboring 143 or 150 bpm.
        let series = try XCTUnwrap(ActivityChartSeries(streams: try decode().streams, kind: "run", unit: .kilometers))
        let index = try XCTUnwrap(ActivityChartSeries.nearestIndex(series.xs, to: 0.074))
        XCTAssertEqual(index, 4)
        XCTAssertNil(ActivityChartSeries.point(series.heartRate, at: index))
        XCTAssertEqual(ActivityChartSeries.point(series.elevation, at: index)?.y, 12)
    }

    func testTheStoreReadsOncePerAccountAndRemembersNothingToChartBriefly() async throws {
        let response = try decode()
        var calls = 0
        var now = Date(timeIntervalSince1970: 0)
        let store = ActivityStreamsStore(fetch: { id, _ in
            calls += 1
            return id == "i9" ? response : nil
        }, now: { now })
        let a = ActivityRouteAccess(accountID: "a", jwt: "j")
        _ = await store.streams(for: "i9", access: a)
        _ = await store.streams(for: "i9", access: a)
        XCTAssertEqual(calls, 1)
        _ = await store.streams(for: "none", access: a)
        _ = await store.streams(for: "none", access: a)
        XCTAssertEqual(calls, 2)
        now = now.addingTimeInterval(ActivityStreamsStore.missingLifetime + 1)
        _ = await store.streams(for: "none", access: a)
        XCTAssertEqual(calls, 3)
        // Another account never sees the first one's series.
        _ = await store.streams(for: "i9", access: ActivityRouteAccess(accountID: "b", jwt: "k"))
        XCTAssertEqual(calls, 4)
    }

    func testOnlyActivitiesWithStreamsAreAsked() {
        func activity(source: String, kind: String) -> ExternalActivity {
            ExternalActivity(
                id: "x", source: source, external_id: "e", date: "2026-11-01", kind: kind,
                name: nil, moving_time_sec: 60, elapsed_time_sec: nil, distance_m: 100, average_watts: nil,
                weighted_avg_watts: nil, average_hr: nil, max_hr: nil, training_load: nil, intensity: nil,
                calories: nil, elevation_gain_m: nil, synced_at: 1, deleted_at: nil)
        }
        XCTAssertTrue(activity(source: "intervals", kind: "other").mayHaveStreams)
        XCTAssertTrue(activity(source: "healthkit", kind: "run").mayHaveStreams)
        XCTAssertFalse(activity(source: "healthkit", kind: "ride").mayHaveStreams)
        XCTAssertFalse(activity(source: "manual", kind: "run").mayHaveStreams)
    }
}
