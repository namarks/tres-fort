import XCTest
@testable import TresFort

final class FreestyleWorkoutTests: XCTestCase {
    @MainActor func testCapabilityUpgradeReloadsHiddenHistoryOnlyUntilCertified() throws {
        let suite = "freestyle-upgrade-" + UUID().uuidString
        let defaults = try XCTUnwrap(LocalPersistence(suiteName: suite))
        defer {
            defaults.removePersistentDomain(forName: suite)
            try? FileManager.default.removeItem(at: defaults.trainingStore.directory)
        }
        let old = StateResponse(plan: nil, plan_version: 0, sessions: [], sets: [],
            external_events: [], external_activities: [], activities: [], server_time: 100_000,
            freestyleVersion: nil)
        StateSnapshotStore.save(old, userID: "member", defaults: defaults)
        let upgrade = try XCTUnwrap(StateSnapshotStore.reserveStateRequest(userID: "member", defaults: defaults))
        XCTAssertEqual(upgrade.watermarks.setsSince, 0)
        var fresh = old
        fresh.freestyleVersion = 1
        XCTAssertNotNil(StateSnapshotStore.commitStateResponse(fresh, ticket: upgrade, defaults: defaults))
        let next = try XCTUnwrap(StateSnapshotStore.reserveStateRequest(userID: "member", defaults: defaults))
        XCTAssertGreaterThan(next.watermarks.setsSince, 0)
        XCTAssertEqual(StateSnapshotStore.load(userID: "member", defaults: defaults)?.state.freestyleVersion, 1)
    }

    func testRepPrescriptionEncodesExplicitNullDuration() throws {
        let slot = FreestyleSlot(exercise_id: "bench", target_sets: 2, target_reps: 8,
                                 target_duration_s: nil, target_weight: 100, rest_seconds: 120)
        let wire = try JSONSerialization.jsonObject(with: JSONEncoder().encode(slot)) as! [String: Any]
        XCTAssertTrue(wire["target_duration_s"] is NSNull)
    }

    func testSessionKindRoundTripsWithoutChangingLegacyDecode() throws {
        let legacy = Data(#"{"id":"s","date":"2026-09-21","status":"in_progress","day_template_id":null}"#.utf8)
        var session = try JSONDecoder().decode(SessionRow.self, from: legacy)
        XCTAssertFalse(session.isFreestyle)
        session.kind = "freestyle"
        let restored = try JSONDecoder().decode(SessionRow.self, from: JSONEncoder().encode(session))
        XCTAssertTrue(restored.isFreestyle)
        XCTAssertNil(restored.workout_id)
    }

    func testSlotlessSetIntentRetainsLocalIdentityAndAttemptAcrossPersistence() throws {
        let body = SetRequestBody(id: "set", exercise_id: "bench", template_exercise_id: nil,
            set_index: 2, weight: 100, reps: 8, is_warmup: false, logged_at: 1, duration_s: nil, is_timed: false)
        let intent = PendingSetIntent(body: body, date: "2026-09-21", workoutID: nil,
            resolvedSessionID: "s", deliveryState: .queued, failedHTTPStatus: nil, expectedAttempt: 3)
        let restored = try JSONDecoder().decode(PendingSetIntent.self, from: JSONEncoder().encode(intent))
        XCTAssertEqual(restored.slotID, "bench")
        XCTAssertEqual(restored, intent)
        let wire = try JSONSerialization.jsonObject(with: JSONEncoder().encode(body.scoped(to: 3))) as! [String: Any]
        XCTAssertNil(wire["template_exercise_id"])
        XCTAssertNil(wire["prescription"])
        XCTAssertEqual(wire["expected_attempt"] as? Int, 3)
    }

    func testFreestyleStartingInputsDoNotInventLoadOrMixRepAndTimedHistory() {
        let exercise = ExerciseCatalog(id: "hold", name: "Hold", primary_muscle: "core", modality: "timed",
            unit: "sec", laterality: "bilateral", load_mode: "total", demo_slug: nil)
        let rep = SetLog(id: "set", session_id: "s", exercise_id: "hold", template_exercise_id: nil,
            set_index: 1, weight: 150, reps: 12, rpe: nil, is_warmup: 0, logged_at: 1,
            duration_s: 90, is_timed: 0, deleted_at: nil, updated_at: 1)
        let slot = FreestyleRunner.exercise(exercise, previous: rep, order: 0)
        XCTAssertEqual(slot.target_weight, 0)
        XCTAssertEqual(slot.target_duration_s, 30)
        XCTAssertTrue(slot.isTimed)
        let legacy = SetLog(id: "legacy", session_id: "s", exercise_id: "hold", template_exercise_id: nil,
            set_index: 1, weight: 150, reps: 12, rpe: nil, is_warmup: 0, logged_at: 1,
            duration_s: nil, is_timed: 1, deleted_at: nil, updated_at: 1)
        let restored = FreestyleRunner.exercise(exercise, previous: legacy, order: 0)
        XCTAssertEqual(restored.target_duration_s, 12)
        XCTAssertEqual(restored.target_weight, 150)
    }
}
