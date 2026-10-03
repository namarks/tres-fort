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
        let kilograms = try prescription(["target_weight_unit": "kg", "target_weight": 10])
        XCTAssertEqual(kilograms.prescriptionLabel(in: .lb), "4×10 · 22.046 lb each hand")
    }

    /// Kettlebell Swing as served: catalog unit lb, slot prescribed in kg.
    private func swing(_ weight: Double, unit: String) throws -> TemplateExercise {
        try prescription(["exercise_name": "Kettlebell Swing", "exercise_modality": "kettlebell",
            "exercise_load_mode": "total", "target_sets": 3, "target_reps": 15,
            "target_weight": weight, "target_weight_unit": unit])
    }

    func testSlotLoadConvertsFromItsOwnUnitToEveryDisplayUnit() throws {
        let kilograms = try swing(24, unit: "kg"), pounds = try swing(24, unit: "lb")
        XCTAssertEqual(kilograms.prescriptionLabel(in: .kg), "3×15 · 24 kg")
        XCTAssertEqual(kilograms.prescriptionLabel(in: .lb), "3×15 · 52.911 lb")
        XCTAssertEqual(pounds.prescriptionLabel(in: .kg), "3×15 · 10.886 kg")
        XCTAssertEqual(pounds.prescriptionLabel(in: .lb), "3×15 · 24 lb")
        XCTAssertEqual(try swing(16, unit: "kg").prescriptionLabel(in: .kg), "3×15 · 16 kg")
        XCTAssertEqual(kilograms.targetWeightUnit, .kg)
        XCTAssertEqual(kilograms.target_weight, 24)
    }

    func testCatalogUnitNeverDecidesTheSlotLoadUnit() throws {
        // A slot without a declared unit is lb even when the catalog says
        // otherwise; a declared slot unit wins over any catalog unit.
        for catalogUnit in ["kg", "sec", "min"] {
            let undeclared = try prescription(["exercise_unit": catalogUnit, "exercise_load_mode": "total"])
            XCTAssertEqual(undeclared.targetWeightUnit, .lb)
            XCTAssertEqual(undeclared.prescriptionLabel(in: .lb), "4×10 · 25 lb")
        }
        let declared = try prescription(["exercise_unit": "lb", "target_weight_unit": "kg",
                                         "exercise_load_mode": "total"])
        XCTAssertEqual(declared.prescriptionLabel(in: .kg), "4×10 · 25 kg")
    }

    func testBodyweightSlotsWithZeroOrMissingLoadNeverShowAConvertedWeight() throws {
        let bodyweight: [String: Any] = ["exercise_name": "Push-Up", "exercise_modality": "bw",
                                         "exercise_load_mode": "total", "target_sets": 3]
        let units: [Any] = ["kg", "lb", NSNull()]
        for unit in units {
            let zero = try prescription(bodyweight.merging(["target_weight": 0, "target_weight_unit": unit]) { _, new in new })
            let missing = try prescription(bodyweight.merging(["target_weight": NSNull(), "target_weight_unit": unit]) { _, new in new })
            for display in WeightUnit.allCases {
                XCTAssertEqual(zero.prescriptionLabel(in: display), "3×10 · Bodyweight")
                XCTAssertEqual(missing.prescriptionLabel(in: display), "3×10")
            }
        }
        let added = try prescription(bodyweight.merging(["target_weight": 10, "target_weight_unit": "kg"]) { _, new in new })
        XCTAssertEqual(added.prescriptionLabel(in: .kg), "3×10 · +10 kg")
        XCTAssertEqual(added.prescriptionLabel(in: .lb), "3×10 · +22.046 lb")
        let assisted = try prescription(bodyweight.merging(["target_weight": -10, "target_weight_unit": "kg"]) { _, new in new })
        XCTAssertEqual(assisted.prescriptionLabel(in: .kg), "3×10 · 10 kg assistance")
    }

    func testKilogramLoadShownInPoundsSavesBackToExactKilograms() throws {
        // Opening the editor on a 24 kg slot in lb and saving untouched text
        // keeps exactly 24 kg; an edited lb value converts once, into kg.
        var draft = WeightEntryDraft(weight: 24, storedUnit: .kg, unit: .lb)
        XCTAssertEqual(draft.text, "52.911")
        XCTAssertEqual(draft.storedWeight, 24)
        draft.select(.kg)
        XCTAssertEqual(draft.text, "24")
        XCTAssertEqual(draft.storedWeight, 24)
        draft.select(.lb)
        draft.text = "55"
        XCTAssertEqual(try XCTUnwrap(draft.storedWeight), 55 * 0.45359237, accuracy: 1e-9)
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
