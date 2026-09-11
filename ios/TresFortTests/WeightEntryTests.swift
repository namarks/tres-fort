import XCTest
@testable import TresFort

final class WeightEntryTests: XCTestCase {
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
