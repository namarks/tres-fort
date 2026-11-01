import XCTest
@testable import TresFort

final class SlotLoadDraftTests: XCTestCase {
    func testUntouchedLoadSendsNothing() {
        let draft = SlotLoadDraft(weight: 135, unit: .lb, rpe: 8, allowsAssistance: false)
        XCTAssertTrue(draft.changedFields.isEmpty)
        XCTAssertTrue(draft.isValid)
    }

    func testSwitchingUnitsAndBackKeepsTheExactLoad() {
        var draft = SlotLoadDraft(weight: 135, unit: .lb, rpe: nil, allowsAssistance: false)
        draft.select(.kg)
        XCTAssertEqual(draft.text, "61.235")
        draft.select(.lb)
        XCTAssertEqual(draft.text, "135")
        XCTAssertTrue(draft.changedFields.isEmpty)
    }

    func testSwitchingUnitsSendsTheConvertedLoadInTheNewUnit() throws {
        var draft = SlotLoadDraft(weight: 100, unit: .kg, rpe: nil, allowsAssistance: false)
        draft.select(.lb)
        let fields = draft.changedFields
        XCTAssertEqual(fields["target_weight_unit"] as? String, "lb")
        XCTAssertEqual(try XCTUnwrap(fields["target_weight"] as? Double), 220.462, accuracy: 0.001)
    }

    func testTypedLoadIsSentInTheChosenUnit() {
        var draft = SlotLoadDraft(weight: 135, unit: .lb, rpe: nil, allowsAssistance: false)
        draft.text = "145"
        XCTAssertEqual(draft.changedFields["target_weight"] as? Double, 145)
        XCTAssertEqual(draft.changedFields["target_weight_unit"] as? String, "lb")
        XCTAssertNil(draft.changedFields["target_rpe"])
    }

    func testClearingTheLoadOrEffortSendsNull() {
        var draft = SlotLoadDraft(weight: 135, unit: .lb, rpe: 8, allowsAssistance: false)
        draft.text = " "
        draft.rpe = nil
        XCTAssertTrue(draft.changedFields["target_weight"] is NSNull)
        XCTAssertTrue(draft.changedFields["target_rpe"] is NSNull)
        XCTAssertNil(draft.changedFields["target_weight_unit"])
    }

    func testEmptyLoadStaysEmptyAcrossUnits() {
        var draft = SlotLoadDraft(weight: nil, unit: .lb, rpe: nil, allowsAssistance: false)
        draft.select(.kg)
        XCTAssertEqual(draft.text, "")
        XCTAssertTrue(draft.changedFields.isEmpty)
    }

    func testUnreadableLoadSurvivesAUnitSwitch() {
        var draft = SlotLoadDraft(weight: 135, unit: .lb, rpe: nil, allowsAssistance: false)
        draft.text = "60kg"
        draft.select(.kg)
        XCTAssertEqual(draft.text, "60kg")
        XCTAssertEqual(draft.unit, .kg)
        XCTAssertFalse(draft.isValid)
        XCTAssertNil(draft.changedFields["target_weight"])
    }

    func testCommaDecimalReadsAsADecimal() throws {
        var draft = SlotLoadDraft(weight: nil, unit: .kg, rpe: nil, allowsAssistance: false)
        draft.text = "60,5"
        XCTAssertTrue(draft.isValid)
        XCTAssertEqual(draft.changedFields["target_weight"] as? Double, 60.5)
        draft.select(.lb)
        XCTAssertEqual(try XCTUnwrap(draft.weight), 133.379, accuracy: 0.001)
    }

    func testOnlyAssistanceExercisesMayGoNegative() {
        var lifted = SlotLoadDraft(weight: nil, unit: .lb, rpe: nil, allowsAssistance: false)
        lifted.text = "-20"
        XCTAssertFalse(lifted.isValid)
        var assisted = SlotLoadDraft(weight: nil, unit: .lb, rpe: nil, allowsAssistance: true)
        assisted.text = "-20"
        XCTAssertTrue(assisted.isValid)
        XCTAssertEqual(assisted.changedFields["target_weight"] as? Double, -20)
        lifted.text = "heavy"
        XCTAssertFalse(lifted.isValid)
    }
}
