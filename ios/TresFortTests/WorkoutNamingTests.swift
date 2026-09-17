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
            // Cache can still be read after reverting to the released app.
            let cached = try JSONSerialization.jsonObject(with: JSONEncoder().encode(plan)) as! [String: Any]
            XCTAssertNotNil(cached["days"])
            XCTAssertNil(cached["workouts"])
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
                XCTAssertNil(cached["workout_id"])
                XCTAssertEqual(cached["day_template_id"] as? String, value as? String)
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

}
