import XCTest
@testable import TresFort

final class DateLabelTests: XCTestCase {
    func testLongLabelReadsAsAWeekdayAndDate() {
        XCTAssertEqual(DateLabel.long("2026-11-01"), "Sunday, Nov 1")
        XCTAssertEqual(DateLabel.long("2026-09-09"), "Wednesday, Sep 9")
    }

    func testLongLabelKeepsAnUnreadableValue() {
        XCTAssertEqual(DateLabel.long("not-a-date"), "not-a-date")
    }
}
