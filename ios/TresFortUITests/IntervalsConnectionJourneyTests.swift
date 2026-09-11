import XCTest

final class IntervalsConnectionJourneyTests: XCTestCase {
    override func setUpWithError() throws { continueAfterFailure = false }

    override func tearDownWithError() throws {
        if (testRun?.failureCount ?? 0) > 0 { print(XCUIApplication().debugDescription) }
    }

    private func tap(_ element: XCUIElement, in app: XCUIApplication) {
        XCTAssertTrue(element.waitForExistence(timeout: 10), element.description)
        for _ in 0..<10 {
            if element.isHittable { element.tap(); return }
            app.swipeUp()
        }
        XCTFail("Control is not reachable: \(element.description)")
    }

    private func launch(_ scenario: String) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchEnvironment["TRESFORT_UI_FIXTURE"] = scenario
        app.launchArguments = ["-AppleLanguages", "(en)", "-AppleLocale", "en_US"]
        app.launch()
        tap(app.tabBars.buttons["Profile"], in: app)
        tap(app.buttons["profile.connections"], in: app)
        tap(app.buttons["connections.intervals"], in: app)
        return app
    }

    private func connect(_ app: XCUIApplication) {
        let key = app.secureTextFields["intervals.apiKey"]
        tap(key, in: app); key.typeText("synthetic-test-key")
        // The form's scroll dismisses the keyboard without relying on a
        // particular device's Return key label.
        app.swipeUp()
        tap(app.buttons["intervals.connect"], in: app)
    }

    private func assertImportedActivity(_ app: XCUIApplication) {
        tap(app.tabBars.buttons["Calendar"], in: app)
        XCTAssertTrue(app.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", "Morning ride")).firstMatch.waitForExistence(timeout: 10))
    }

    func testConnectImmediatelyRefreshesCalendar() {
        let app = launch("intervals-connect")
        connect(app)
        XCTAssertTrue(app.staticTexts["Last synced"].waitForExistence(timeout: 10))
        assertImportedActivity(app)
    }

    func testSavedConnectionRetriesImportWithoutAnotherCredentialSubmission() {
        let app = launch("intervals-retry")
        connect(app)
        let retry = app.buttons["intervals.retry"]
        XCTAssertTrue(retry.waitForExistence(timeout: 10))
        XCTAssertEqual(retry.label, "Retry sync")
        tap(retry, in: app)
        XCTAssertTrue(app.staticTexts["Last synced"].waitForExistence(timeout: 10))
        assertImportedActivity(app)
    }

    func testReconnectAndDisconnectRetainImportedHistory() {
        let app = launch("intervals-reauth")
        XCTAssertEqual(app.staticTexts["intervals.status"].label, "Reconnect needed")
        connect(app)
        XCTAssertTrue(app.staticTexts["Last synced"].waitForExistence(timeout: 10))
        tap(app.buttons["intervals.disconnect"], in: app)
        let disconnected = app.staticTexts["intervals.status"]
        XCTAssertTrue(disconnected.waitForExistence(timeout: 10))
        let settled = XCTNSPredicateExpectation(predicate: NSPredicate(format: "label == %@", "Not connected"), object: disconnected)
        XCTAssertEqual(XCTWaiter.wait(for: [settled], timeout: 10), .completed)
        assertImportedActivity(app)
    }
}
