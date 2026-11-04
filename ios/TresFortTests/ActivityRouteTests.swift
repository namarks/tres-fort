import CoreLocation
import XCTest
@testable import TresFort

/// Run routes as the app reads them (docs/plans/run-recorder P5 and P6):
/// the server's compact encoding, the map framing, and the in-memory store.
@MainActor
final class ActivityRouteTests: XCTestCase {
    /// The shape src/activityRoute.ts serves: two segments split by a pause.
    private static let json = """
    {"activity_id":"recording:activity:u:r1","recording_id":"r1",
     "route":{"v":1,"start_ms":1761962400000,"dt":[0,1000,1000,60000,1000],
              "dlat":[45519000,27,27,500,27],"dlon":[-122679300,-11,-11,-300,-11],
              "alt":[153,null,154,150,150],"breaks":[3]}}
    """

    private func decode(_ text: String = ActivityRouteTests.json) throws -> ActivityRouteResponse {
        try JSONDecoder().decode(ActivityRouteResponse.self, from: Data(text.utf8))
    }

    func testDecodesTheServersRouteIntoSegments() throws {
        let response = try decode()
        XCTAssertEqual(response.recording_id, "r1")
        let segments = try XCTUnwrap(response.route).segments
        XCTAssertEqual(segments.map(\.count), [3, 2])
        XCTAssertEqual(segments[0][0].latitude, 45.519, accuracy: 1e-9)
        XCTAssertEqual(segments[0][0].longitude, -122.6793, accuracy: 1e-9)
        XCTAssertEqual(segments[0][2].latitude, 45.519054, accuracy: 1e-9)
        XCTAssertEqual(segments[1][0].latitude, 45.519554, accuracy: 1e-9)
        XCTAssertEqual(segments[1][0].longitude, -122.679622, accuracy: 1e-9)
    }

    func testARunRecordedWithoutGPSStillNamesItsRecording() throws {
        let response = try decode(#"{"activity_id":"recording:activity:u:r2","recording_id":"r2","route":null}"#)
        XCTAssertEqual(response.recording_id, "r2")
        XCTAssertNil(response.route)
    }

    func testATrackFromIntervalsHasNoRecordingBehindIt() throws {
        let response = try decode(Self.json.replacingOccurrences(
            of: #""activity_id":"recording:activity:u:r1","recording_id":"r1","#,
            with: #""activity_id":"intervals:activity:u:i9","source":"intervals","recording_id":null,"#))
        XCTAssertEqual(response.source, "intervals")
        XCTAssertNil(response.recording_id)
        XCTAssertEqual(response.route?.drawableSegments.map(\.count), [3, 2])
        let copy = ExternalActivity(
            id: "intervals:activity:u:i9", source: "intervals", external_id: "i9", date: "2026-11-01", kind: "run",
            name: nil, moving_time_sec: 60, elapsed_time_sec: nil, distance_m: 100, average_watts: nil,
            weighted_avg_watts: nil, average_hr: nil, max_hr: nil, training_load: nil, intensity: nil,
            calories: nil, elevation_gain_m: nil, synced_at: 1, deleted_at: nil)
        // Nothing the app recorded, so nothing for "Delete run" to delete.
        XCTAssertNil(copy.recordedRunID(routeRecordingID: response.recording_id))
    }

    func testOnlyLinesWithTwoPointsAreDrawnAndMismatchedArraysDrawNothing() throws {
        let lone = try decode(Self.json.replacingOccurrences(of: "\"breaks\":[3]", with: "\"breaks\":[2,4]"))
        XCTAssertEqual(lone.route?.segments.map(\.count), [2, 2, 1])
        XCTAssertEqual(lone.route?.drawableSegments.map(\.count), [2, 2])
        let broken = try decode(Self.json.replacingOccurrences(of: "\"dlon\":[-122679300,-11,-11,-300,-11]",
                                                               with: "\"dlon\":[-122679300]"))
        XCTAssertEqual(broken.route?.segments.isEmpty, true)
        let future = try decode(Self.json.replacingOccurrences(of: "\"v\":1", with: "\"v\":2"))
        XCTAssertEqual(future.route?.drawableSegments.isEmpty, true)
    }

    func testTheMapFramesEveryPointWithAMargin() throws {
        let segments = try XCTUnwrap(decode().route).segments
        let region = try XCTUnwrap(ActivityRouteMap.region(for: segments))
        for point in segments.flatMap({ $0 }) {
            XCTAssertLessThanOrEqual(abs(point.latitude - region.center.latitude), region.span.latitudeDelta / 2)
            XCTAssertLessThanOrEqual(abs(point.longitude - region.center.longitude), region.span.longitudeDelta / 2)
        }
        // A short route is never framed closer than about 300 m.
        XCTAssertGreaterThanOrEqual(region.span.latitudeDelta, 0.003)
        XCTAssertNil(ActivityRouteMap.region(for: []))
    }

    func testOnlyRunsFromTheRecorderOrIntervalsCanHaveARoute() {
        func activity(source: String, kind: String) -> ExternalActivity {
            ExternalActivity(
                id: "a", source: source, external_id: "a", date: "2026-11-01", kind: kind, name: nil,
                moving_time_sec: 60, elapsed_time_sec: nil, distance_m: 100, average_watts: nil,
                weighted_avg_watts: nil, average_hr: nil, max_hr: nil, training_load: nil,
                intensity: nil, calories: nil, elevation_gain_m: nil, synced_at: 1, deleted_at: nil)
        }
        XCTAssertTrue(activity(source: "recording", kind: "run").mayHaveRecordedRoute)
        XCTAssertTrue(activity(source: "intervals", kind: "run").mayHaveRecordedRoute)
        XCTAssertFalse(activity(source: "healthkit", kind: "run").mayHaveRecordedRoute)
        XCTAssertFalse(activity(source: "intervals", kind: "ride").mayHaveRecordedRoute)
    }

    func testTheStoreReadsARouteOnceAndForgetsItForAnotherAccount() async throws {
        let response = try decode()
        var reads: [(String, String)] = []
        let store = ActivityRouteStore(fetch: { id, jwt in
            reads.append((id, jwt))
            return response
        })
        let nick = ActivityRouteAccess(accountID: "u", jwt: "token-1")
        let first = await store.route(for: "intervals:activity:i1", access: nick)
        let again = await store.route(for: "intervals:activity:i1",
                                      access: ActivityRouteAccess(accountID: "u", jwt: "token-2"))
        XCTAssertEqual(first, response)
        XCTAssertEqual(again, response)
        XCTAssertEqual(reads.count, 1)
        _ = await store.route(for: "intervals:activity:i1", access: ActivityRouteAccess(accountID: "v", jwt: "t"))
        XCTAssertEqual(reads.count, 2)
        XCTAssertEqual(reads.last?.1, "t")
    }

    func testNoRouteIsRememberedBrieflyAndAFailedReadIsRetried() async throws {
        var clock = Date(timeIntervalSince1970: 1_000)
        var reads = 0
        var fails = true
        let store = ActivityRouteStore(fetch: { _, _ in
            reads += 1
            if fails { throw URLError(.notConnectedToInternet) }
            return nil
        }, now: { clock })
        let access = ActivityRouteAccess(accountID: "u", jwt: "t")
        let failed = await store.route(for: "a", access: access)
        XCTAssertNil(failed)
        fails = false
        _ = await store.route(for: "a", access: access)
        XCTAssertEqual(reads, 2, "a failed read is not remembered")
        _ = await store.route(for: "a", access: access)
        XCTAssertEqual(reads, 2, "no route is remembered for a while")
        clock.addTimeInterval(ActivityRouteStore.missingLifetime + 1)
        _ = await store.route(for: "a", access: access)
        XCTAssertEqual(reads, 3)
    }

    func testTheClientAsksForTheActivitysRouteAndReadsANotFoundAsNoRoute() async throws {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [RouteRequestProtocol.self]
        let session = URLSession(configuration: config)
        defer { session.invalidateAndCancel() }
        let api = APIClient(baseURL: URL(string: "https://route.test")!, transport: session)
        RouteRequestProtocol.respond(status: 404, body: #"{"error":"not_found"}"#)
        let missing = try await api.activityRoute(activityID: "intervals:activity:i9", jwt: "synthetic")
        XCTAssertNil(missing)
        XCTAssertEqual(RouteRequestProtocol.recorded()?.url?.path, "/api/activities/intervals:activity:i9/route")
        XCTAssertEqual(RouteRequestProtocol.recorded()?.httpMethod, "GET")
        RouteRequestProtocol.respond(status: 200, body: Self.json)
        let found = try await api.activityRoute(activityID: "recording:activity:u:r1", jwt: "synthetic")
        XCTAssertEqual(found?.route?.segments.count, 2)
        RouteRequestProtocol.respond(status: 500, body: "{}")
        do {
            _ = try await api.activityRoute(activityID: "a", jwt: "synthetic")
            XCTFail("A server error is not \"no route\"")
        } catch let error as APIError {
            XCTAssertEqual(error.httpStatus, 500)
        }
    }
}

private final class RouteRequestProtocol: URLProtocol {
    private static let lock = NSLock()
    private static var latest: URLRequest?
    private static var status = 200
    private static var body = "{}"

    static func recorded() -> URLRequest? { lock.lock(); defer { lock.unlock() }; return latest }
    static func respond(status: Int, body: String) {
        lock.lock(); defer { lock.unlock() }
        self.status = status
        self.body = body
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        Self.lock.lock()
        Self.latest = request
        let status = Self.status
        let body = Self.body
        Self.lock.unlock()
        client?.urlProtocol(self, didReceive: HTTPURLResponse(url: request.url!, statusCode: status,
            httpVersion: nil, headerFields: nil)!, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(body.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}
