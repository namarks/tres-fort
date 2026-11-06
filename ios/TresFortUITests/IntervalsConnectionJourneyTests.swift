import XCTest

final class IntervalsConnectionJourneyTests: XCTestCase {
    override func setUpWithError() throws { continueAfterFailure = false }

    override func tearDownWithError() throws {
        if (testRun?.failureCount ?? 0) > 0 { print(XCUIApplication().debugDescription) }
    }

    private func tap(_ element: XCUIElement, in app: XCUIApplication) {
        // Form rows below the fold are not in the accessibility tree yet, and
        // Profile's Integrations row sits below the training rows. Scroll
        // toward it before requiring that it exists.
        if !element.waitForExistence(timeout: UITestWait.screen) {
            for _ in 0..<6 where !element.exists { app.swipeUp() }
        }
        XCTAssertTrue(element.waitForExistence(timeout: UITestWait.screen), element.description)
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
        XCTAssertTrue(app.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", "Morning ride")).firstMatch.waitForExistence(timeout: UITestWait.screen))
    }

    func testConnectImmediatelyRefreshesCalendar() {
        let app = launch("intervals-connect")
        connect(app)
        XCTAssertTrue(app.staticTexts["Last synced"].waitForExistence(timeout: UITestWait.screen))
        assertImportedActivity(app)
        XCTAssertTrue(app.staticTexts["Garmin Edge 840"].waitForExistence(timeout: UITestWait.screen))
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = "Imported activity with Garmin attribution"
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    /// No coach needed: a run typed in on Today goes to intervals.icu with its
    /// distance and time, then shows in Activity: in History and under
    /// Endurance on Progress.
    func testLogARunWithDistanceAndTimeFromToday() {
        let app = launch("intervals-connect")
        connect(app)
        XCTAssertTrue(app.staticTexts["Last synced"].waitForExistence(timeout: UITestWait.screen))

        tap(app.tabBars.buttons["Today"], in: app)
        tap(app.buttons["today.moreWaysToTrain"], in: app)
        tap(app.buttons["today.logActivity"], in: app)
        XCTAssertTrue(app.navigationBars["Log activity"].waitForExistence(timeout: UITestWait.screen))
        tap(app.buttons["activity.type"], in: app)
        tap(app.buttons["Run"], in: app)

        let time = app.textFields["activity.time"]
        tap(time, in: app)
        time.typeText("25:00")
        let distance = app.textFields["activity.distance"]
        tap(distance, in: app)
        distance.typeText("3.1")
        let pace = app.staticTexts["activity.pace"]
        XCTAssertTrue(pace.waitForExistence(timeout: UITestWait.screen))
        XCTAssertEqual(pace.label, "8:04 /mi")

        tap(app.buttons["activity.save"], in: app)
        let sheet = app.navigationBars["Log activity"]
        let dismissed = XCTNSPredicateExpectation(predicate: NSPredicate(format: "exists == false"), object: sheet)
        XCTAssertEqual(XCTWaiter.wait(for: [dismissed], timeout: UITestWait.screen), .completed)

        // Activity opens on History, which lists the run with its distance
        // and opens that run.
        tap(app.tabBars.buttons["Activity"], in: app)
        let run = app.descendants(matching: .any).matching(NSPredicate(
            format: "identifier BEGINSWITH 'activityHistory.entry.activity:' AND label CONTAINS %@", "3.1 mi")).firstMatch
        XCTAssertTrue(run.waitForExistence(timeout: UITestWait.screen))
        let ride = app.descendants(matching: .any)["activityHistory.entry.activity:synthetic-imported-ride"]
        XCTAssertTrue(ride.exists, "The synced ride is listed beside the run")
        tap(app.buttons["activityHistory.filter.runs"], in: app)
        XCTAssertTrue(run.waitForExistence(timeout: UITestWait.screen))
        XCTAssertFalse(ride.exists, "The Runs filter leaves the ride out")
        let history = XCTAttachment(screenshot: app.screenshot())
        history.name = "Activity history after logging a run"
        history.lifetime = .keepAlways
        add(history)
        tap(run, in: app)
        XCTAssertTrue(app.descendants(matching: .any).matching(NSPredicate(
            format: "identifier BEGINSWITH 'dayAgenda.activity.'")).firstMatch
            .waitForExistence(timeout: UITestWait.screen), "A run opens on its own")
        app.navigationBars.buttons.element(boundBy: 0).tap()

        tap(app.segmentedControls["activity.side"].buttons["Progress"], in: app)
        let endurance = app.buttons["progress.endurance"]
        XCTAssertTrue(endurance.waitForExistence(timeout: UITestWait.screen))
        // The card reads as one button, so its run row is part of its label.
        XCTAssertTrue(app.descendants(matching: .any).matching(NSPredicate(format: "label CONTAINS %@", "3.1 mi"))
            .firstMatch.waitForExistence(timeout: UITestWait.screen))
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = "Endurance on Activity → Progress after logging a run"
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    func testSavedConnectionRetriesImportWithoutAnotherCredentialSubmission() {
        let app = launch("intervals-retry")
        connect(app)
        let retry = app.buttons["intervals.retry"]
        XCTAssertTrue(retry.waitForExistence(timeout: UITestWait.screen))
        XCTAssertEqual(retry.label, "Retry sync")
        tap(retry, in: app)
        XCTAssertTrue(app.staticTexts["Last synced"].waitForExistence(timeout: UITestWait.screen))
        assertImportedActivity(app)
    }

    func testReconnectAndDisconnectRetainImportedHistory() {
        let app = launch("intervals-reauth")
        XCTAssertEqual(app.staticTexts["intervals.status"].label, "Reconnect needed")
        connect(app)
        XCTAssertTrue(app.staticTexts["Last synced"].waitForExistence(timeout: UITestWait.screen))
        tap(app.buttons["intervals.disconnect"], in: app)
        let disconnected = app.staticTexts["intervals.status"]
        XCTAssertTrue(disconnected.waitForExistence(timeout: UITestWait.screen))
        let settled = XCTNSPredicateExpectation(predicate: NSPredicate(format: "label == %@", "Not connected"), object: disconnected)
        XCTAssertEqual(XCTWaiter.wait(for: [settled], timeout: UITestWait.screen), .completed)
        assertImportedActivity(app)
    }
}
