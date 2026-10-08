import XCTest

/// Reveal a control on its own scrolling surface without overshooting it or
/// tapping coordinates. The caller keeps ownership of the eventual action.
enum UITestScrolling {
    static func reveal(_ element: XCUIElement, in app: XCUIApplication,
                       maxAttempts: Int, surface: XCUIElement? = nil,
                       file: StaticString = #filePath, line: UInt = #line) {
        if let surface {
            XCTAssertTrue(surface.exists, file: file, line: line)
        } else {
            XCTAssertTrue(element.waitForExistence(timeout: 5), file: file, line: line)
        }
        for _ in 0..<maxAttempts {
            let targetExists = element.exists
            if targetExists && element.isHittable && element.frame.maxY <= app.frame.maxY - 34 { break }
            // The target can be above the viewport after a previous gesture.
            // Select its own surface so a sheet never scrolls underlying Today;
            // fixed controls already reachable above return without a gesture.
            let scroll: XCUIElement
            if let surface {
                // A Form's lazy child may not exist until scrolled into view.
                // Keep the caller's front surface bound independently of it.
                scroll = surface
            } else {
                let identifier = element.identifier.isEmpty ? element.label : element.identifier
                scroll = app.scrollViews.containing(element.elementType, identifier: identifier).firstMatch
            }
            guard scroll.exists else { break }
            let viewport = scroll.frame.intersection(app.frame)
            let top = viewport.minY + 8
            let bottom = min(viewport.maxY, app.frame.maxY - 34) - 8
            let height = bottom - top
            guard !viewport.isNull, height > 48 else { break }
            // Discover an absent lazy child by moving forward on the explicitly
            // supplied surface; once materialized, recover either direction.
            let offset = targetExists ? element.frame.midY - (top + bottom) / 2 : height * 0.45
            let down = offset < 0
            // Partial, slow drags avoid the momentum of swipeUp overshooting a
            // short control in the smaller accessibility-size viewport.
            let distance = min(height * 0.45, max(24, abs(offset)))
            let startY = top + height * (down ? 0.25 : 0.75)
            let origin = app.coordinate(withNormalizedOffset: .zero)
            let start = origin.withOffset(CGVector(dx: viewport.midX, dy: startY))
            let end = origin.withOffset(CGVector(dx: viewport.midX, dy: startY + (down ? distance : -distance)))
            start.press(forDuration: 0.1, thenDragTo: end,
                        withVelocity: .slow, thenHoldForDuration: 0.5)
        }
        XCTAssertTrue(element.isHittable, file: file, line: line)
        XCTAssertLessThanOrEqual(element.frame.maxY, app.frame.maxY - 34, file: file, line: line)
    }
}
