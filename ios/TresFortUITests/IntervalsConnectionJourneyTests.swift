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

    /// A tap that lands while the connection screen is still settling can
    /// leave the key field without keyboard focus. Retry the tap until it
    /// has focus, then type.
    private func type(_ text: String, into field: XCUIElement, in app: XCUIApplication) {
        let focused = NSPredicate(format: "hasKeyboardFocus == true")
        for _ in 0..<3 {
            tap(field, in: app)
            let wait = XCTNSPredicateExpectation(predicate: focused, object: field)
            if XCTWaiter.wait(for: [wait], timeout: 2) == .completed { break }
        }
        field.typeText(text)
    }

    private func connect(_ app: XCUIApplication) {
        type("synthetic-test-key", into: app.secureTextFields["intervals.apiKey"], in: app)
        // The form's scroll dismisses the keyboard without relying on a
        // particular device's Return key label.
        app.swipeUp()
        tap(app.buttons["intervals.connect"], in: app)
    }

    private func assertImportedActivity(_ app: XCUIApplication) {
        tap(app.tabBars.buttons["Today"], in: app)
        tap(app.buttons["today.calendar"], in: app)
        XCTAssertTrue(app.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", "Morning ride")).firstMatch.waitForExistence(timeout: 10))
    }

    func testConnectImmediatelyRefreshesCalendar() {
        let app = launch("intervals-connect")
        connect(app)
        XCTAssertTrue(app.staticTexts["Last synced"].waitForExistence(timeout: 10))
        assertImportedActivity(app)
        XCTAssertTrue(app.staticTexts["Garmin Edge 840"].waitForExistence(timeout: 10))
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = "Imported activity with Garmin attribution"
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    /// No coach needed: a run typed in on Today goes to intervals.icu with its
    /// distance and time, then shows under Endurance on Progress.
    func testLogARunWithDistanceAndTimeFromToday() {
        let app = launch("intervals-connect")
        connect(app)
        XCTAssertTrue(app.staticTexts["Last synced"].waitForExistence(timeout: 10))

        tap(app.tabBars.buttons["Today"], in: app)
        tap(app.buttons["today.moreWaysToTrain"], in: app)
        tap(app.buttons["today.logActivity"], in: app)
        XCTAssertTrue(app.navigationBars["Log activity"].waitForExistence(timeout: 5))
        tap(app.buttons["activity.type"], in: app)
        tap(app.buttons["Run"], in: app)

        let time = app.textFields["activity.time"]
        tap(time, in: app)
        time.typeText("25:00")
        let distance = app.textFields["activity.distance"]
        tap(distance, in: app)
        distance.typeText("3.1")
        let pace = app.staticTexts["activity.pace"]
        XCTAssertTrue(pace.waitForExistence(timeout: 5))
        XCTAssertEqual(pace.label, "8:04 /mi")

        tap(app.buttons["activity.save"], in: app)
        let sheet = app.navigationBars["Log activity"]
        let dismissed = XCTNSPredicateExpectation(predicate: NSPredicate(format: "exists == false"), object: sheet)
        XCTAssertEqual(XCTWaiter.wait(for: [dismissed], timeout: 10), .completed)

        tap(app.tabBars.buttons["Progress"], in: app)
        let endurance = app.buttons["progress.endurance"]
        XCTAssertTrue(endurance.waitForExistence(timeout: 10))
        // The card reads as one button, so its run row is part of its label.
        XCTAssertTrue(app.descendants(matching: .any).matching(NSPredicate(format: "label CONTAINS %@", "3.1 mi"))
            .firstMatch.waitForExistence(timeout: 10))
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = "Endurance on Progress after logging a run"
        attachment.lifetime = .keepAlways
        add(attachment)
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
