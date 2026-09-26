import XCTest
@testable import TresFort

final class WorkoutNamingTests: XCTestCase {
    private let workout = #"{"id":"w","name":"Hotel","order_index":0,"exercises":[]}"#

    func testReleasedCanonicalAndDualPlanReadsPreserveScheduleAndCacheCompatibility() throws {
        let meta = #"{"schedule":{"version":1,"week":{"mon":"w","thu":"w","fri":"other"}}}"#
        let base: [String: Any] = ["id": "p", "name": "Training", "version": 8, "meta": meta]
        let w = try JSONSerialization.jsonObject(with: Data(workout.utf8))
        var decoded: [PlanTree] = []
        for fields: [String: Any] in [["days": [w]], ["workouts": [w]], ["days": [w], "workouts": [w]]] {
            let bytes = try JSONSerialization.data(withJSONObject: base.merging(fields) { _, new in new })
            let plan = try JSONDecoder().decode(PlanTree.self, from: bytes)
            decoded.append(plan)
            XCTAssertEqual(plan.workouts.first?.id, "w")
            XCTAssertEqual(plan.meta, meta)
            XCTAssertEqual(WorkoutLibraryPolicy.scheduleBadge(workoutID: "w", plan: plan), "Mon · Thu")
            XCTAssertEqual(WorkoutLibraryPolicy.scheduleBadge(workoutID: "hotel", plan: plan), "On demand")
            let week = WorkoutLibraryPolicy.unscheduling(workoutID: "w", plan: plan)
            XCTAssertEqual(week["mon"], "")
            XCTAssertEqual(week["thu"], "")
            XCTAssertEqual(week["fri"], "other")
            // Old persisted bytes are readable; new snapshots are canonical.
            let cached = try JSONSerialization.jsonObject(with: JSONEncoder().encode(plan)) as! [String: Any]
            XCTAssertNotNil(cached["workouts"])
            XCTAssertNil(cached["days"])
        }
        XCTAssertEqual(decoded[0], decoded[1]); XCTAssertEqual(decoded[1], decoded[2])
        let conflict = base.merging(["days": [w], "workouts": []]) { _, new in new }
        XCTAssertThrowsError(try JSONDecoder().decode(PlanTree.self,
            from: JSONSerialization.data(withJSONObject: conflict)))
    }

    func testSessionAliasesRetainNullAndAttemptAndRejectContradiction() throws {
        let base: [String: Any] = ["id": "s", "date": "2026-09-09", "status": "planned", "attempt": 7, "write_protocol": "attempt-v1"]
        for value: Any in ["w", NSNull()] {
            for fields: [String: Any] in [["day_template_id": value], ["workout_id": value], ["workout_id": value, "day_template_id": value]] {
                let session = try JSONDecoder().decode(SessionRow.self, from: JSONSerialization.data(
                    withJSONObject: base.merging(fields) { _, new in new }))
                XCTAssertEqual(session.workout_id, value as? String)
                XCTAssertEqual(session.attempt, 7)
                let cached = try JSONSerialization.jsonObject(with: JSONEncoder().encode(session)) as! [String: Any]
                XCTAssertNil(cached["day_template_id"])
                XCTAssertEqual(cached["workout_id"] as? String, value as? String)
            }
        }
        let conflict = base.merging(["workout_id": NSNull(), "day_template_id": "w"]) { _, new in new }
        XCTAssertThrowsError(try JSONDecoder().decode(SessionRow.self, from: JSONSerialization.data(withJSONObject: conflict)))
    }

    func testReleasedPendingWritesKeepWorkoutIdentityAndGenerationOnRelaunch() throws {
        let terminal = Data(#"{"id":"finish","action":"finish","date":"2026-09-09","dayTemplateID":"w","resolvedSessionID":"s","expectedAttempt":7,"deliveryState":"queued"}"#.utf8)
        let intent = try JSONDecoder().decode(WorkoutTerminalIntent.self, from: terminal)
        XCTAssertEqual(intent.workoutID, "w"); XCTAssertEqual(intent.expectedAttempt, 7)
        let body = #"{"id":"set","exercise_id":"ex","template_exercise_id":"slot","set_index":1,"weight":10,"reps":5,"is_warmup":false,"logged_at":1,"is_timed":false}"#
        let set = Data("{\"body\":\(body),\"date\":\"2026-09-09\",\"dayTemplateID\":\"w\",\"expectedAttempt\":7,\"deliveryState\":\"queued\"}".utf8)
        let pending = try JSONDecoder().decode(PendingSetIntent.self, from: set)
        XCTAssertEqual(pending.workoutID, "w"); XCTAssertEqual(pending.expectedAttempt, 7)
        for data in [try JSONEncoder().encode(pending), try JSONEncoder().encode(intent)] {
            let stored = try JSONSerialization.jsonObject(with: data) as! [String: Any]
            XCTAssertEqual(stored["dayTemplateID"] as? String, "w")
            XCTAssertNil(stored["workoutID"])
        }
    }

    func testRequestsUseCanonicalPathsAndWorkoutPins() async throws {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [WorkoutRequestProtocol.self]
        let session = URLSession(configuration: config)
        defer { session.invalidateAndCancel() }
        let api = APIClient(baseURL: URL(string: "https://workout-contract.test")!, transport: session)
        let operations: [() async throws -> Void] = [
            { _ = try await api.addWorkout(name: "Lift", exerciseIDs: [], expectedPlanID: "p", expectedVersion: 3, jwt: "synthetic") },
            { _ = try await api.updateWorkout(dayID: "w", fields: ["name": "Lift"], expectedVersion: 3, jwt: "synthetic") },
            { _ = try await api.createSession(date: "2026-09-21", workoutID: "w", jwt: "synthetic") },
            { _ = try await api.setCalendarDate("2026-09-21", dayID: "w", expectedAttempt: 0, jwt: "synthetic") },
            { _ = try await api.setCalendarDate("2026-09-21", dayID: nil, expectedAttempt: 1, jwt: "synthetic") },
        ]
        let paths = ["/api/workouts", "/api/workouts/w", "/api/sessions", "/api/calendar/2026-09-21", "/api/calendar/2026-09-21"]
        for (index, operation) in operations.enumerated() {
            do { try await operation(); XCTFail("Synthetic transport must reject") }
            catch let error as APIError { XCTAssertEqual(error.httpStatus, 418) }
            let request = try XCTUnwrap(WorkoutRequestProtocol.recorded())
            XCTAssertEqual(request.url?.path, paths[index])
            let body = try JSONSerialization.jsonObject(with: try XCTUnwrap(request.httpBody)) as! [String: Any]
            XCTAssertNil(body["day_template_id"])
            if index == 2 || index == 3 { XCTAssertEqual(body["workout_id"] as? String, "w") }
            if index == 4 { XCTAssertTrue(body["workout_id"] is NSNull) }
        }
    }
}

private final class WorkoutRequestProtocol: URLProtocol {
    private static let lock = NSLock()
    private static var latest: URLRequest?
    static func recorded() -> URLRequest? { lock.lock(); defer { lock.unlock() }; return latest }
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        var captured = request
        if captured.httpBody == nil, let stream = captured.httpBodyStream {
            stream.open(); defer { stream.close() }
            var bytes = Data()
            var buffer = [UInt8](repeating: 0, count: 1024)
            while stream.hasBytesAvailable {
                let count = stream.read(&buffer, maxLength: buffer.count)
                if count <= 0 { break }
                bytes.append(buffer, count: count)
            }
            captured.httpBody = bytes
        }
        Self.lock.lock(); Self.latest = captured; Self.lock.unlock()
        client?.urlProtocol(self, didReceive: HTTPURLResponse(url: request.url!, statusCode: 418,
            httpVersion: nil, headerFields: nil)!, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data("{}".utf8))
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}
