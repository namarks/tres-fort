import XCTest
@testable import TresFort

final class WeightEntryTests: XCTestCase {
    private func prescription(_ overrides: [String: Any] = [:]) throws -> TemplateExercise {
        var row: [String: Any] = [
            "id": "slot", "exercise_id": "press", "exercise_name": "Dumbbell Push Press",
            "exercise_unit": "lb", "exercise_modality": "dumbbell", "exercise_load_mode": "per_hand",
            "order_index": 0, "target_sets": 4, "target_reps": 10, "rest_seconds": 60,
            "target_weight": 25
        ]
        row.merge(overrides) { _, value in value }
        return try JSONDecoder().decode(TemplateExercise.self, from: JSONSerialization.data(withJSONObject: row))
    }

    func testPrescriptionShowsPerHandLoadInPreferredUnitWithoutDoubling() throws {
        let exercise = try prescription()
        XCTAssertEqual(exercise.prescriptionLabel(in: .lb), "4×10 · 25 lb each hand")
        XCTAssertEqual(exercise.prescriptionLabel(in: .kg), "4×10 · 11.34 kg each hand")
        XCTAssertEqual(exercise.target_weight, 25)
        let kilograms = try prescription(["exercise_unit": "kg", "target_weight": 10])
        XCTAssertEqual(kilograms.prescriptionLabel(in: .lb), "4×10 · 22.046 lb each hand")
    }

    func testPrescriptionKeepsTotalLoadRepRangeAndEffort() throws {
        let exercise = try prescription(["exercise_load_mode": "total", "target_reps_max": 12, "target_rpe": 7.5])
        XCTAssertEqual(exercise.prescriptionLabel(in: .lb), "4×10–12 · 25 lb · RPE 7.5")
    }

    func testPrescriptionDoesNotInventMissingLoadOrGiveCardioAWeight() throws {
        XCTAssertEqual(try prescription(["target_weight": NSNull()]).prescriptionLabel(in: .lb), "4×10")
        let cardio = try prescription(["exercise_modality": "cardio", "target_duration_s": 60, "target_sets": 1])
        XCTAssertEqual(cardio.prescriptionLabel(in: .kg), "1 min")
    }

    func testBodyweightAssistanceAndLoadedHoldsRetainTheirMeaning() throws {
        let bodyweight: [String: Any] = ["exercise_modality": "bw", "exercise_load_mode": "total"]
        for (weight, label) in [(0.0, "Bodyweight"), (25.0, "+25 lb"), (-25.0, "25 lb assistance")] {
            XCTAssertEqual(try prescription(bodyweight.merging(["target_weight": weight]) { _, new in new })
                .prescriptionLabel(in: .lb), "4×10 · \(label)")
        }
        let hold = try prescription(["target_duration_s": 30])
        XCTAssertEqual(hold.prescriptionLabel(in: .lb), "4×30s · 25 lb each hand")
    }

    func testKilogramsAreConvertedToStoredPoundsAndBack() throws {
        var draft = WeightEntryDraft(weight: 45, storedUnit: .lb, unit: .kg)
        draft.text = "20"
        XCTAssertEqual(try XCTUnwrap(draft.storedWeight), 20 / 0.45359237, accuracy: 0.000000001)
        draft.select(.lb)
        XCTAssertEqual(try XCTUnwrap(draft.storedWeight), 20 / 0.45359237, accuracy: 0.000000001)
        draft.select(.kg)
        XCTAssertEqual(draft.text, "20")
    }

    func testUntouchedRoundedTextAndUnitTogglesNeverChangeOriginalWeight() {
        var draft = WeightEntryDraft(weight: 47.5, storedUnit: .lb, unit: .kg)
        for _ in 0..<20 {
            XCTAssertEqual(draft.storedWeight, 47.5)
            draft.select(.lb)
            draft.select(.kg)
        }
        XCTAssertEqual(draft.storedWeight, 47.5)
        XCTAssertEqual(WeightUnit.text(100), "100")
        XCTAssertEqual(WeightUnit.text(0), "0")
        XCTAssertEqual(WeightUnit.text(2.5), "2.5")
    }

    func testStoredKilogramsAndSignedAssistanceUseTheDeclaredUnit() throws {
        var draft = WeightEntryDraft(weight: -10, storedUnit: .kg, unit: .lb)
        XCTAssertEqual(draft.storedWeight, -10)
        draft.text = "-20"
        XCTAssertEqual(try XCTUnwrap(draft.storedWeight), -20 * 0.45359237, accuracy: 0.000000001)
    }

    func testEmptyInvalidAndNonFiniteEntryCannotBeSaved() {
        var draft = WeightEntryDraft(weight: 45, storedUnit: .lb, unit: .lb)
        for text in ["", "abc", "nan", "inf", "1e999"] {
            draft.text = text
            XCTAssertNil(draft.storedWeight)
        }
        draft.text = ""
        draft.select(.kg)
        XCTAssertNil(draft.storedWeight)
        draft.text = "45"
        XCTAssertEqual(draft.storedWeight!, 45 / 0.45359237, accuracy: 0.000000001)
    }
}
