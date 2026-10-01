import XCTest
@testable import TresFort

/// Loads are stored per slot (`target_weight_unit`) and per set
/// (`weight_unit`); the catalog `exercise_unit` never decides either.
final class SlotWeightUnitTests: XCTestCase {
    private func slot(_ overrides: [String: Any] = [:]) throws -> TemplateExercise {
        var row: [String: Any] = [
            "id": "slot", "exercise_id": "ex_kb_swing", "exercise_name": "Kettlebell Swing",
            "exercise_unit": "lb", "exercise_modality": "kettlebell", "order_index": 0,
            "target_sets": 3, "target_reps": 15, "rest_seconds": 60,
            "target_weight": 24, "target_weight_unit": "kg"
        ]
        row.merge(overrides) { _, value in value }
        return try JSONDecoder().decode(TemplateExercise.self, from: JSONSerialization.data(withJSONObject: row))
    }

    private func set(weight: Double, unit: String?, exerciseID: String = "ex_kb_swing") -> SetLog {
        SetLog(id: "set", session_id: "session", exercise_id: exerciseID, template_exercise_id: "slot",
            set_index: 1, weight: weight, reps: 15, rpe: nil, is_warmup: 0, logged_at: 1,
            duration_s: nil, is_timed: 0, deleted_at: nil, updated_at: 1, weight_unit: unit)
    }

    /// A checkpoint draft as an older build persisted it: same prescription,
    /// but `unit` recorded from the catalog (or not at all).
    private func legacyDraft(for exercise: TemplateExercise, unit: String?, weight: Double) throws -> RunnerInputState {
        let draft = RunnerInputState(prescription: RunnerPrescription(exercise), weight: weight,
                                     reps: 12, rpe: 8, durationSeconds: 45)
        var encoded = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(draft)) as? [String: Any])
        var prescription = try XCTUnwrap(encoded["prescription"] as? [String: Any])
        prescription["unit"] = unit
        encoded["prescription"] = prescription
        return try JSONDecoder().decode(RunnerInputState.self, from: JSONSerialization.data(withJSONObject: encoded))
    }

    func testSlotAndSetUnitsDecodeAndDefaultToPoundsWhenAbsent() throws {
        XCTAssertEqual(try slot().target_weight_unit, "kg")
        XCTAssertEqual(try slot().targetWeightUnit, .kg)
        var legacy: [String: Any] = try XCTUnwrap(JSONSerialization.jsonObject(
            with: JSONEncoder().encode(try slot())) as? [String: Any])
        legacy.removeValue(forKey: "target_weight_unit")
        let undeclared = try JSONDecoder().decode(TemplateExercise.self,
            from: JSONSerialization.data(withJSONObject: legacy))
        XCTAssertNil(undeclared.target_weight_unit)
        XCTAssertEqual(undeclared.targetWeightUnit, .lb)

        let row = #"{"id":"set","session_id":"s","exercise_id":"e","template_exercise_id":"slot","set_index":1,"weight":24,"reps":15,"rpe":null,"is_warmup":0,"logged_at":1,"duration_s":null,"is_timed":0,"deleted_at":null,"weight_unit":"kg"}"#
        let logged = try JSONDecoder().decode(SetLog.self, from: Data(row.utf8))
        XCTAssertEqual(logged.weightUnit, .kg)
        let legacyRow = row.replacingOccurrences(of: #","weight_unit":"kg""#, with: "")
        XCTAssertEqual(try JSONDecoder().decode(SetLog.self, from: Data(legacyRow.utf8)).weightUnit, .lb)
    }

    func testSetRequestCarriesItsUnitAndLegacyIntentsAreResentUnchanged() throws {
        let body = SetRequestBody(id: "set", exercise_id: "ex_kb_swing", template_exercise_id: "slot",
            set_index: 1, weight: 24, reps: 15, is_warmup: false, logged_at: 1, duration_s: nil,
            is_timed: false, weight_unit: "kg")
        let wire = try XCTUnwrap(JSONSerialization.jsonObject(
            with: JSONEncoder().encode(body.scoped(to: 2))) as? [String: Any])
        XCTAssertEqual(wire["weight"] as? Double, 24)
        XCTAssertEqual(wire["weight_unit"] as? String, "kg")
        XCTAssertEqual(body.scoped(to: 2).weightUnit, .kg)

        // An intent queued by an older build has no unit; it decodes and is
        // resent byte-for-byte without one rather than gaining a guessed unit.
        var legacy = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(body)) as? [String: Any])
        legacy.removeValue(forKey: "weight_unit")
        let queued = try JSONDecoder().decode(SetRequestBody.self, from: JSONSerialization.data(withJSONObject: legacy))
        XCTAssertNil(queued.weight_unit)
        let resent = try XCTUnwrap(JSONSerialization.jsonObject(
            with: JSONEncoder().encode(queued.scoped(to: 2))) as? [String: Any])
        XCTAssertNil(resent["weight_unit"])
    }

    func testRunnerSeedsEveryCandidateInTheSlotUnit() throws {
        let kilograms = try slot()
        let seeded = RunnerInputPolicy.seed(kilograms, previous: set(weight: 99, unit: "lb"), draft: nil)
        XCTAssertEqual(seeded.weight, 24)
        XCTAssertEqual(seeded.prescription.unit, "kg")

        // Without a target, a previous set converts from its own unit once.
        let noTarget = try slot(["target_weight": NSNull()])
        XCTAssertEqual(RunnerInputPolicy.seed(noTarget, previous: set(weight: 24, unit: "kg"), draft: nil).weight, 24)
        XCTAssertEqual(RunnerInputPolicy.seed(noTarget, previous: set(weight: 55, unit: "lb"), draft: nil).weight,
                       55 * 0.45359237, accuracy: 1e-9)
        let poundSlot = try slot(["target_weight": NSNull(), "target_weight_unit": "lb"])
        XCTAssertEqual(RunnerInputPolicy.seed(poundSlot, previous: set(weight: 20, unit: "kg"), draft: nil).weight,
                       20 / 0.45359237, accuracy: 1e-9)
        XCTAssertEqual(RunnerInputPolicy.seed(poundSlot, previous: set(weight: 20, unit: nil), draft: nil).weight, 20)
        // The default empty bar is 45 lb in whichever unit the slot uses.
        XCTAssertEqual(RunnerInputPolicy.seed(noTarget, previous: nil, draft: nil).weight, 45 * 0.45359237, accuracy: 1e-9)
        XCTAssertEqual(RunnerInputPolicy.seed(poundSlot, previous: nil, draft: nil).weight, 45)
        // Bodyweight: zero or missing load seeds strict bodyweight in either unit.
        for unit in ["kg", "lb"] {
            for weight in [0 as Any, NSNull()] {
                let pushUp = try slot(["exercise_modality": "bw", "target_weight": weight, "target_weight_unit": unit])
                XCTAssertEqual(RunnerInputPolicy.seed(pushUp, previous: nil, draft: nil).weight, 0)
            }
        }
    }

    func testDraftHeldInCatalogPoundsDoesNotSurviveAsAKilogramLoad() throws {
        let kilograms = try slot()
        for unit in ["lb", nil] as [String?] {
            let reseeded = RunnerInputPolicy.seed(kilograms, previous: nil,
                draft: try legacyDraft(for: kilograms, unit: unit, weight: 52.911))
            XCTAssertEqual(reseeded.weight, 24)
            XCTAssertEqual(reseeded.reps, 15)
        }
        let current = RunnerInputPolicy.seed(kilograms, previous: nil,
            draft: try legacyDraft(for: kilograms, unit: "kg", weight: 26))
        XCTAssertEqual(current.weight, 26)
        XCTAssertEqual(current.reps, 12)
    }

    func testPoundDraftsFromOlderBuildsAreRetained() throws {
        let pounds = try slot(["target_weight": 135, "target_weight_unit": "lb", "exercise_modality": "barbell"])
        let hold = try slot(["exercise_unit": "sec", "exercise_modality": "timed", "target_weight": 0,
                             "target_weight_unit": NSNull(), "target_duration_s": 30])
        for (exercise, unit) in [(pounds, "lb"), (pounds, nil), (hold, "sec")] as [(TemplateExercise, String?)] {
            let kept = RunnerInputPolicy.seed(exercise, previous: nil,
                draft: try legacyDraft(for: exercise, unit: unit, weight: 10))
            XCTAssertEqual(kept.weight, 10)
            XCTAssertEqual(kept.reps, 12)
        }
    }

    func testHistoryRowsNameKilogramRepLoadsAndKeepPoundRowsUnchanged() {
        func label(_ weight: Double, _ unit: String?, bodyweight: Bool = false, unilateral: Bool = false) -> String {
            set(weight: weight, unit: unit).valueLabel(timed: false, bodyweight: bodyweight, unilateral: unilateral)
        }
        XCTAssertEqual(label(24, "kg"), "24 kg × 15")
        XCTAssertEqual(label(24, "lb"), "24 × 15")
        XCTAssertEqual(label(24, nil), "24 × 15")
        XCTAssertEqual(label(24, "kg", unilateral: true), "24 kg × 15 per side")
        XCTAssertEqual(label(10, "kg", bodyweight: true), "BW+10 kg × 15")
        XCTAssertEqual(label(-10, "kg", bodyweight: true), "BW−10 kg × 15")
        XCTAssertEqual(label(0, "kg", bodyweight: true), "BW × 15")
        XCTAssertEqual(label(0, "kg"), "0 × 15")
        let hold = SetLog(id: "hold", session_id: "session", exercise_id: "plank", template_exercise_id: nil,
            set_index: 1, weight: 10, reps: 30, rpe: nil, is_warmup: 0, logged_at: 1, duration_s: 30,
            is_timed: 1, deleted_at: nil, updated_at: 1, weight_unit: "kg")
        XCTAssertEqual(hold.valueLabel(timed: true, bodyweight: false, unilateral: false), "30s · +10 kg")
    }

    func testFreestyleSlotKeepsThePreviousSetUnit() {
        let catalog = ExerciseCatalog(id: "ex_kb_swing", name: "Kettlebell Swing", primary_muscle: "hamstrings",
            modality: "kettlebell", unit: "lb", laterality: "bilateral", load_mode: "total", demo_slug: nil)
        let kilograms = FreestyleRunner.exercise(catalog, previous: set(weight: 24, unit: "kg"), order: 0)
        XCTAssertEqual(kilograms.target_weight, 24)
        XCTAssertEqual(kilograms.targetWeightUnit, .kg)
        XCTAssertEqual(kilograms.prescriptionLabel(in: .kg), "1×15 · 24 kg")
        XCTAssertEqual(RunnerInputPolicy.seed(kilograms, previous: nil, draft: nil).weight, 24)
        let legacy = FreestyleRunner.exercise(catalog, previous: set(weight: 24, unit: nil), order: 0)
        XCTAssertEqual(legacy.targetWeightUnit, .lb)
        XCTAssertEqual(legacy.prescriptionLabel(in: .kg), "1×15 · 10.886 kg")
    }
}
