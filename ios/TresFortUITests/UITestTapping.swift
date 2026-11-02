import XCTest

/// How long a UI test gives a screen to appear or go away. Simulators on a
/// loaded CI runner can take several seconds to present a sheet or cover, so
/// a fixed few seconds fails healthy runs. A wait ends as soon as its element
/// appears, so a longer limit only slows a run that is already failing. Use it
/// for every wait a test asserts. Keep a short literal only where the element
/// is optional (`if alert.waitForExistence(timeout: 3) { ... }`), since that
/// wait runs to its end whenever the element never comes.
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

extension XCUIApplication {
    /// Scrolls the current screen in short, slow drags until `element` can be
    /// tapped, and reports whether it can. Use it instead of a `swipeUp()`
    /// loop: a swipe is a fling, and on a loaded simulator one fling can carry
    /// a row from under the tab bar to above the navigation bar, so the loop
    /// never sees it on screen. Each drag here moves the content less than the
    /// visible area and holds before lifting, so the content stops where the
    /// finger stops and the element passes through the visible area.
    ///
    /// When the element is already in the accessibility tree above the
    /// visible area it scrolls back down; otherwise it scrolls down the page,
    /// since rows far below the viewport are not materialized yet.
    @discardableResult
    func scroll(toReveal element: XCUIElement, maxDrags: Int = 16) -> Bool {
        for _ in 0..<maxDrags {
            if element.exists && element.isHittable { return true }
            let band = visibleContentBand()
            guard band.height > 80 else { break }
            let elementIsAbove = element.exists && element.frame.midY < band.minY
            // Drag near the leading edge, on row labels rather than trailing
            // switches or steppers a drag could catch. Offsets are measured
            // from the app's own origin.
            let x: CGFloat = 24
            let high = band.minY - frame.minY + band.height * 0.3
            let low = band.minY - frame.minY + band.height * 0.75
            let origin = coordinate(withNormalizedOffset: .zero)
            let start = origin.withOffset(CGVector(dx: x, dy: elementIsAbove ? high : low))
            let end = origin.withOffset(CGVector(dx: x, dy: elementIsAbove ? low : high))
            start.press(forDuration: 0.1, thenDragTo: end,
                        withVelocity: .slow, thenHoldForDuration: 0.3)
        }
        return element.exists && element.isHittable
    }

    /// The part of the screen where scrolled content can be tapped: below any
    /// navigation bar and top tab bar, above any bottom tab bar and keyboard.
    private func visibleContentBand() -> CGRect {
        var top = frame.minY + 60
        var bottom = frame.maxY - 40
        for bar in navigationBars.allElementsBoundByIndex where bar.exists && bar.isHittable {
            top = max(top, bar.frame.maxY)
        }
        let tabBar = tabBars.firstMatch
        if tabBar.exists && tabBar.isHittable {
            if tabBar.frame.midY > frame.midY {
                bottom = min(bottom, tabBar.frame.minY)
            } else {
                top = max(top, tabBar.frame.maxY)
            }
        }
        let keyboard = keyboards.firstMatch
        if keyboard.exists { bottom = min(bottom, keyboard.frame.minY) }
        return CGRect(x: frame.minX, y: top, width: frame.width, height: max(0, bottom - top))
    }
}
