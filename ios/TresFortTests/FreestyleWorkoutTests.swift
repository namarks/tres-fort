import XCTest
@testable import TresFort

final class FreestyleWorkoutTests: XCTestCase {
    func testRepPrescriptionEncodesExplicitNullDuration() throws {
        let slot = FreestyleSlot(exercise_id: "bench", target_sets: 2, target_reps: 8,
                                 target_duration_s: nil, target_weight: 100, rest_seconds: 120)
        let wire = try JSONSerialization.jsonObject(with: JSONEncoder().encode(slot)) as! [String: Any]
        XCTAssertTrue(wire["target_duration_s"] is NSNull)
    }

    func testDraftSlotUnitLabelsTheLoadAndIsEchoedOnlyWhenTheDraftDeclaresIt() throws {
        let json = #"""
        {"session":{"id":"s","date":"2026-09-21","status":"completed","workout_id":null,"kind":"freestyle"},
         "source_signature":"sig","slots":[
          {"exercise_id":"swing","target_sets":3,"target_reps":12,"target_duration_s":null,"target_weight":24,
           "target_weight_unit":"kg","rest_seconds":120,"is_timed":false,"source_set_ids":["a","b","c"]},
          {"exercise_id":"bench","target_sets":2,"target_reps":8,"target_duration_s":null,"target_weight":100,
           "rest_seconds":120,"is_timed":false,"source_set_ids":["d","e"]}]}
        """#
        let draft = try JSONDecoder().decode(FreestyleWorkoutDraft.self, from: Data(json.utf8))
        let kg = draft.slots[0], legacy = draft.slots[1]
        XCTAssertEqual(kg.target_weight_unit, "kg")
        XCTAssertEqual(kg.targetWeightUnit, .kg)
        XCTAssertEqual(kg.target_weight, 24)
        XCTAssertEqual(kg.sourceSummary, "From 3 working sets at 24 kg")
        XCTAssertNil(legacy.target_weight_unit)
        XCTAssertEqual(legacy.targetWeightUnit, .lb)
        XCTAssertEqual(legacy.sourceSummary, "From 2 working sets at 100 lb")

        let request = SaveFreestyleRequest(workout_id: "w", name: "Freestyle", expected_plan_id: "p",
            expected_version: 1, expected_attempt: 0, source_signature: draft.source_signature, slots: draft.slots)
        let wire = try JSONSerialization.jsonObject(with: JSONEncoder().encode(request)) as! [String: Any]
        let slots = try XCTUnwrap(wire["slots"] as? [[String: Any]])
        XCTAssertEqual(slots[0]["target_weight_unit"] as? String, "kg")
        XCTAssertEqual(slots[0]["target_weight"] as? Double, 24)
        XCTAssertNil(slots[1]["target_weight_unit"])
        XCTAssertEqual(Set(slots[1].keys), ["exercise_id", "target_sets", "target_reps", "target_duration_s",
                                            "target_weight", "rest_seconds", "source_set_ids"])
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
