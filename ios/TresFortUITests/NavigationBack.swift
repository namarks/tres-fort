import XCTest

extension XCUIElement {
    /// A pushed screen's Back button in its navigation bar. Its label follows
    /// the previous screen's title, so tests use UIKit's identifier instead.
    var backButton: XCUIElement { buttons["BackButton"] }
}
