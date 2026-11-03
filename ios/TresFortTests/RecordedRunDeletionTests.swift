import XCTest
@testable import TresFort

/// Deleting a run recorded in the app (docs/plans/run-recorder P5(d)): every
/// copy the app made goes, and nothing goes when the server can't delete the
/// intervals.icu upload.
@MainActor
final class RecordedRunDeletionTests: XCTestCase {
    private let recordingID = "0b7a2c4e-1111-4a2b-9c3d-5e6f7a8b9c0d"
    private let healthID = UUID(uuidString: "6F9619FF-8B86-D011-B42D-00C04FC964FF")!

    private final class Events {
        var log: [String] = []
        var sentHealthIDs: [UUID]?
    }

    private func health(_ events: Events, found: [UUID]?, deletes: Bool = true) -> RecordedRunHealthCopies {
        RecordedRunHealthCopies(
            find: { id in
                events.log.append("find \(id.uuidString.lowercased())")
                return found
            },
            delete: { ids in
                events.log.append("health delete \(ids.count)")
                return deletes
            })
    }

    private func response(intervals: String, healthRemoved: Int = 1) -> RecordedRunDeleteResponse {
        RecordedRunDeleteResponse(recording_id: recordingID,
                                  intervals: .init(status: intervals),
                                  health_removed: healthRemoved)
    }

    func testDeletesOnTheServerFirstThenTheHealthWorkout() async {
        let events = Events()
        let outcome = await RecordedRunDeletion.delete(
            recordingID: recordingID, health: health(events, found: [healthID]),
            server: { id, healthIDs in
                events.log.append("server \(id)")
                events.sentHealthIDs = healthIDs
                return self.response(intervals: "deleted")
            })
        XCTAssertEqual(events.log, ["find \(recordingID)", "server \(recordingID)", "health delete 1"])
        XCTAssertEqual(events.sentHealthIDs, [healthID])
        XCTAssertEqual(outcome, .deleted("Run deleted from Tres Fort, Apple Health and intervals.icu."))
    }

    func testNothingIsDeletedFromHealthWhenTheServerRefuses() async {
        let events = Events()
        let outcome = await RecordedRunDeletion.delete(
            recordingID: recordingID, health: health(events, found: [healthID]),
            server: { _, _ in
                events.log.append("server")
                throw APIError.http(409, #"{"error":"intervals_write_forbidden","deleted":false}"#)
            })
        XCTAssertEqual(events.log, ["find \(recordingID)", "server"])
        guard case let .failed(message) = outcome else { return XCTFail("expected a failure, got \(outcome)") }
        XCTAssertTrue(message.contains("nothing was deleted"))
        XCTAssertTrue(message.contains("Reconnect intervals.icu"))
    }

    func testServerAndConnectionFailuresSayNothingWasDeleted() async {
        func outcome(_ error: Error) async -> RecordedRunDeleteOutcome {
            let events = Events()
            let result = await RecordedRunDeletion.delete(
                recordingID: recordingID, health: health(events, found: [healthID]),
                server: { _, _ in throw error })
            XCTAssertFalse(events.log.contains("health delete 1"))
            return result
        }
        let unavailable = await outcome(APIError.http(502, #"{"error":"intervals_unavailable"}"#))
        XCTAssertEqual(unavailable, .failed("intervals.icu couldn’t delete its copy right now, so nothing was deleted. Try again in a moment."))
        let signedOut = await outcome(APIError.http(401, "{}"))
        XCTAssertEqual(signedOut, .failed("Sign in again, then try deleting the run."))
        let offline = await outcome(URLError(.notConnectedToInternet))
        XCTAssertEqual(offline, .failed("The run couldn’t be deleted. Check your connection and try again."))
    }

    func testARunTheServerAlreadyDeletedStillLosesItsHealthWorkout() async {
        // The first try deleted the run, but its answer was lost.
        let events = Events()
        let retry = await RecordedRunDeletion.delete(
            recordingID: recordingID, health: health(events, found: [healthID]),
            server: { _, _ in
                events.log.append("server")
                throw APIError.http(404, #"{"error":"not_found"}"#)
            })
        XCTAssertEqual(events.log, ["find \(recordingID)", "server", "health delete 1"])
        XCTAssertEqual(retry, .deleted("This run was already deleted. Its Apple Health workout is deleted now too."))

        let kept = await RecordedRunDeletion.delete(
            recordingID: recordingID, health: health(Events(), found: [healthID], deletes: false),
            server: { _, _ in throw APIError.http(404, "{}") })
        XCTAssertEqual(kept, .deleted("This run was already deleted. Apple Health kept its copy; you can delete it in the Health app."))
        let none = await RecordedRunDeletion.delete(
            recordingID: recordingID, health: health(Events(), found: []),
            server: { _, _ in throw APIError.http(404, "{}") })
        XCTAssertEqual(none, .deleted("This run was already deleted."))
    }

    func testNothingIsDeletedWhenHealthCantBeSearched() async {
        let events = Events()
        let outcome = await RecordedRunDeletion.delete(
            recordingID: recordingID, health: health(events, found: nil),
            server: { _, _ in
                events.log.append("server")
                return self.response(intervals: "deleted")
            })
        XCTAssertEqual(events.log, ["find \(recordingID)"])
        XCTAssertEqual(outcome, .failed("Apple Health couldn’t be checked for this run’s workout, so nothing was deleted. Try again in a moment."))
    }

    func testSaysWhereTheRunWentFromAndWhatKeptACopy() async {
        XCTAssertEqual(RecordedRunDeletion.message(intervals: "not_found", healthDeleted: true),
                       "Run deleted from Tres Fort and Apple Health.")
        XCTAssertEqual(RecordedRunDeletion.message(intervals: "deleted", healthDeleted: nil),
                       "Run deleted from Tres Fort and intervals.icu.")
        XCTAssertEqual(RecordedRunDeletion.message(intervals: "not_connected", healthDeleted: nil),
                       "Run deleted from Tres Fort.")
        XCTAssertEqual(RecordedRunDeletion.message(intervals: "deleted", healthDeleted: false),
                       "Run deleted from Tres Fort and intervals.icu. Apple Health kept its copy; you can delete it in the Health app.")

        let events = Events()
        let kept = await RecordedRunDeletion.delete(
            recordingID: recordingID, health: health(events, found: [healthID], deletes: false),
            server: { _, _ in self.response(intervals: "not_connected") })
        XCTAssertEqual(kept, .deleted("Run deleted from Tres Fort. Apple Health kept its copy; you can delete it in the Health app."))
    }

    func testARunWithoutAHealthWorkoutOrAValidIDNeverTouchesHealth() async {
        let events = Events()
        let outcome = await RecordedRunDeletion.delete(
            recordingID: recordingID, health: health(events, found: []),
            server: { _, healthIDs in
                events.sentHealthIDs = healthIDs
                return self.response(intervals: "deleted", healthRemoved: 0)
            })
        XCTAssertEqual(events.log, ["find \(recordingID)"])
        XCTAssertEqual(events.sentHealthIDs, [])
        XCTAssertEqual(outcome, .deleted("Run deleted from Tres Fort and intervals.icu."))

        let invalid = Events()
        let refused = await RecordedRunDeletion.delete(
            recordingID: "not-a-uuid", health: health(invalid, found: [healthID]),
            server: { _, _ in
                invalid.log.append("server")
                return self.response(intervals: "deleted")
            })
        XCTAssertTrue(invalid.log.isEmpty)
        guard case .failed = refused else { return XCTFail("expected a failure, got \(refused)") }
    }

    func testOnlyTheRecordingOrItsIntervalsCopyCanBeDeleted() {
        func activity(source: String, kind: String = "run", externalID: String = "x") -> ExternalActivity {
            ExternalActivity(
                id: "a", source: source, external_id: externalID, date: "2026-11-01", kind: kind, name: nil,
                moving_time_sec: 60, elapsed_time_sec: nil, distance_m: 100, average_watts: nil,
                weighted_avg_watts: nil, average_hr: nil, max_hr: nil, training_load: nil,
                intensity: nil, calories: nil, elevation_gain_m: nil, synced_at: 1, deleted_at: nil)
        }
        XCTAssertEqual(activity(source: "recording", externalID: recordingID)
            .recordedRunID(routeRecordingID: nil), recordingID)
        XCTAssertEqual(activity(source: "intervals").recordedRunID(routeRecordingID: recordingID), recordingID)
        XCTAssertNil(activity(source: "intervals").recordedRunID(routeRecordingID: nil),
                     "an intervals.icu run with no recording behind it isn't the app's to delete")
        XCTAssertNil(activity(source: "healthkit").recordedRunID(routeRecordingID: recordingID))
        XCTAssertNil(activity(source: "intervals", kind: "ride").recordedRunID(routeRecordingID: recordingID))
    }

    func testTheStoreForgetsADeletedRunsRoute() async throws {
        let json = """
        {"activity_id":"recording:activity:u:\(recordingID)","recording_id":"\(recordingID)",
         "route":{"v":1,"start_ms":1761962400000,"dt":[0,1000],"dlat":[45519000,27],
                  "dlon":[-122679300,-11],"alt":[null,null],"breaks":[]}}
        """
        let route = try JSONDecoder().decode(ActivityRouteResponse.self, from: Data(json.utf8))
        var reads = 0
        var deleted = false
        let store = ActivityRouteStore(fetch: { _, _ in
            reads += 1
            return deleted ? nil : route
        })
        let access = ActivityRouteAccess(accountID: "u", jwt: "t")
        let before = await store.route(for: "intervals:activity:i1", access: access)
        XCTAssertNotNil(before)
        deleted = true
        store.forget(recordingID: recordingID.uppercased())
        let after = await store.route(for: "intervals:activity:i1", access: access)
        XCTAssertNil(after)
        XCTAssertEqual(reads, 1, "the deleted route is neither served nor read again")
    }

    func testTheClientNamesTheHealthWorkoutsOnTheDelete() async throws {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [DeleteRequestProtocol.self]
        let session = URLSession(configuration: config)
        defer { session.invalidateAndCancel() }
        let api = APIClient(baseURL: URL(string: "https://delete.test")!, transport: session)
        DeleteRequestProtocol.respond(status: 200, body: """
        {"ok":true,"recording_id":"\(recordingID)","intervals":{"status":"deleted","activity_id":"i9"},"health_removed":1}
        """)
        let other = UUID(uuidString: "11111111-2222-3333-4444-555555555555")!
        let response = try await api.deleteRecordedRun(
            recordingID: recordingID.uppercased(), healthWorkoutIDs: [healthID, other], jwt: "synthetic")
        XCTAssertEqual(response, self.response(intervals: "deleted"))
        let request = try XCTUnwrap(DeleteRequestProtocol.recorded())
        XCTAssertEqual(request.httpMethod, "DELETE")
        XCTAssertEqual(request.url?.path, "/api/activities/recordings/\(recordingID)")
        let query = URLComponents(url: try XCTUnwrap(request.url), resolvingAgainstBaseURL: false)?.queryItems
        XCTAssertEqual(query, [URLQueryItem(name: "health_workout_id", value: healthID.uuidString),
                               URLQueryItem(name: "health_workout_id", value: other.uuidString)])
        XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer synthetic")

        _ = try await api.deleteRecordedRun(recordingID: recordingID, healthWorkoutIDs: [], jwt: "synthetic")
        XCTAssertNil(DeleteRequestProtocol.recorded()?.url?.query)
    }
}

private final class DeleteRequestProtocol: URLProtocol {
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
