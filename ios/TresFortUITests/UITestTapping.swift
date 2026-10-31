import XCTest

/// How long a UI test gives a screen to appear or go away. Simulators on a
/// loaded CI runner can take several seconds to present a sheet or cover, so
/// a fixed few seconds fails healthy runs. A wait ends as soon as its element
/// appears, so a longer limit only slows a run that is already failing.
enum UITestWait {
    static let screen: TimeInterval = 15
}

extension XCUIElement {
    /// Waits until the control exists, is enabled and can be tapped. A tap on
    /// a control that only exists can be dropped: during launch a button can
    /// be on screen but still disabled, and during an animation it can be
    /// covered.
    @discardableResult
    func waitUntilTappable(timeout: TimeInterval = UITestWait.screen) -> Bool {
        let ready = XCTNSPredicateExpectation(
            predicate: NSPredicate { _, _ in self.exists && self.isEnabled && self.isHittable },
            object: nil)
        return XCTWaiter.wait(for: [ready], timeout: timeout) == .completed
    }

    /// Taps once the control can be tapped. Use it for taps that change state,
    /// such as logging a set, where a second tap would do something else.
    func tapWhenReady(timeout: TimeInterval = UITestWait.screen,
                      file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertTrue(waitUntilTappable(timeout: timeout),
                      "\(self) never became tappable", file: file, line: line)
        tap()
    }

    /// Taps the control once it can be tapped, then waits for `result` to
    /// appear. If the result hasn't appeared halfway through the wait and the
    /// control can still be tapped, the first tap was probably dropped, so it
    /// taps once more. Use it only where a second tap is harmless, such as a
    /// button that opens or closes a screen.
    func tap(until result: XCUIElement, timeout: TimeInterval = UITestWait.screen,
             file: StaticString = #filePath, line: UInt = #line) {
        tapWhenReady(timeout: timeout, file: file, line: line)
        if result.waitForExistence(timeout: timeout / 2) { return }
        if exists && isEnabled && isHittable { tap() }
        XCTAssertTrue(result.waitForExistence(timeout: timeout / 2),
                      "\(result) didn't appear after tapping \(self)", file: file, line: line)
    }
}
