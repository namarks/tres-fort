import Foundation
import XCTest
@testable import TresFort

final class PrescriptionDecodingTests: XCTestCase {
    func testAcceptedPrescriptionValuesDecodeWithoutShapeLoss() throws {
        let json = #"""
        {
          "id":"slot-a","exercise_id":"ex_pullup","exercise_name":"Pull-Up",
          "exercise_unit":"lb","order_index":0,"target_sets":3,"target_reps":5,
          "target_reps_max":8,"target_rpe":8.5,"rest_seconds":0,
          "target_weight":-12.5,"cues":null,"exercise_modality":"bw",
          "exercise_laterality":"bilateral","exercise_load_mode":"total",
          "exercise_demo_slug":"Pull-Up","target_duration_s":30,"is_warmup":0
        }
        """#.data(using: .utf8)!

        let decoded = try JSONDecoder().decode(TemplateExercise.self, from: json)
        XCTAssertEqual(decoded.order_index, 0)
        XCTAssertEqual(decoded.target_sets, 3)
        XCTAssertEqual(decoded.target_reps, 5)
        XCTAssertEqual(decoded.target_reps_max, 8)
        XCTAssertEqual(decoded.target_rpe, 8.5)
        XCTAssertEqual(decoded.rest_seconds, 0)
        XCTAssertEqual(decoded.target_weight, -12.5)
        XCTAssertEqual(decoded.target_duration_s, 30)
    }
    func testUnilateralTargetsArePerSideWithoutChangingStoredReps() throws {
        for name in ["Renegade Row", "Single-Arm Dumbbell Shoulder Press"] {
            let slot = try exercise(name: name, laterality: "unilateral")
            XCTAssertEqual(slot.targetLabel, "3×10 per side")
            XCTAssertEqual(slot.target_reps, 10)
            let range = try exercise(name: name, laterality: "unilateral", maxReps: 12)
            XCTAssertEqual(range.targetLabel, "3×10–12 per side")
        }
    }

    func testBilateralLegacyAndTimedTargetsKeepTheirUnits() throws {
        XCTAssertEqual(try exercise(laterality: "bilateral").targetLabel, "3×10")
        XCTAssertEqual(try exercise(laterality: nil).targetLabel, "3×10")
        XCTAssertEqual(try exercise(laterality: "unilateral", duration: 30).targetLabel, "3×30s")
    }

    func testSetValuesLabelRepsPerSideForLoadedAndBodyweightExercises() {
        for weight in [0.0, 25.0, -10.0] {
            let label = SetValueFormatter.value(weight: weight, reps: 10,
                durationSeconds: nil, timed: false, bodyweight: true, unilateral: true)
            XCTAssertTrue(label.hasSuffix("10 per side"))
        }
        XCTAssertEqual(SetValueFormatter.value(weight: 25, reps: 10, durationSeconds: nil,
            timed: false, bodyweight: false, unilateral: true), "25 × 10 per side")
        XCTAssertEqual(SetValueFormatter.value(weight: 25, reps: 10, durationSeconds: nil,
            timed: false, bodyweight: false), "25 × 10")
        XCTAssertEqual(SetValueFormatter.value(weight: 0, reps: 30, durationSeconds: 30,
            timed: true, bodyweight: true, unilateral: true), "30s")
    }

    func testSavedSetDetailsRequireTheExerciseRepConvention() {
        let set = SetLog(id: "set", session_id: "session", exercise_id: "row",
            template_exercise_id: nil, set_index: 1, weight: 25, reps: 10,
            rpe: nil, is_warmup: 0, logged_at: 1, duration_s: nil,
            is_timed: 0, deleted_at: nil)
        XCTAssertEqual(set.valueLabel(timed: false, bodyweight: false, unilateral: true),
                       "25 × 10 per side")
        XCTAssertEqual(set.valueLabel(timed: false, bodyweight: false, unilateral: false),
                       "25 × 10")
    }

    private func exercise(name: String = "Exercise", laterality: String?,
                          maxReps: Int? = nil, duration: Int? = nil) throws -> TemplateExercise {
        var json: [String: Any] = [
            "id": "slot", "exercise_id": "exercise", "exercise_name": name,
            "exercise_unit": "lb", "order_index": 0, "target_sets": 3, "target_reps": 10,
            "rest_seconds": 60, "exercise_modality": "dumbbell"
        ]
        json["exercise_laterality"] = laterality
        json["target_reps_max"] = maxReps
        json["target_duration_s"] = duration
        return try JSONDecoder().decode(TemplateExercise.self,
            from: JSONSerialization.data(withJSONObject: json))
    }

}
