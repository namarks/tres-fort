import XCTest

final class StationConnectionJourneyTests: XCTestCase {
    override func setUpWithError() throws { continueAfterFailure = false }

    override func tearDownWithError() throws {
        let app = XCUIApplication()
        if (testRun?.failureCount ?? 0) > 0 { print(app.debugDescription) }
        app.terminate()
    }

    private func launch(shortcut: Bool = false, rememberedAccount: String? = nil,
                        largeText: Bool = false) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchEnvironment["TRESFORT_UI_FIXTURE"] = "app-store"
        if let rememberedAccount { app.launchEnvironment["TRESFORT_UI_STATION_REMEMBERED_ACCOUNT"] = rememberedAccount }
        if largeText { app.launchEnvironment["TRESFORT_UI_LARGE_TEXT"] = "1" }
        app.launchArguments = ["-AppleLanguages", "(en)", "-AppleLocale", "en_US", "-restAudioCuesEnabled", "NO"]
        if shortcut {
            app.open(URL(string: "tresfort://ipad-display")!)
        } else {
            app.launch()
        }
        return app
    }

    private func tap(_ element: XCUIElement, in app: XCUIApplication) {
        XCTAssertTrue(element.waitForExistence(timeout: 10))
        UITestScrolling.reveal(element, in: app, maxAttempts: 12)
        element.tap()
    }

    private func capture(_ name: String) {
        let attachment = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    func testPhoneConnectionIsVisibleBeforeAndDuringWorkoutAndRemembersExplicitChoice() throws {
        try XCTSkipIf(UIDevice.current.userInterfaceIdiom != .phone)
        let app = launch()
        tap(app.buttons["today.ipadDisplay"], in: app)
        XCTAssertTrue(app.buttons["station.phoneConnect"].waitForExistence(timeout: 5))
        capture("iphone-connect-ipad")
        // Looking at setup and dismissing does not opt in.
        app.navigationBars["iPad display"].buttons["Done"].tap()
        tap(app.buttons["today.ipadDisplay"], in: app)
        tap(app.buttons["station.phoneConnect"], in: app)
        XCTAssertTrue(app.buttons["station.phoneDisconnect"].waitForExistence(timeout: 5))
        // The fixture refuses the key request. The real setup must expose
        // recovery without requesting local networking or starting a workout.
        let offline = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "label CONTAINS %@", "internet"),
            object: app.staticTexts["station.phoneStatus"])
        XCTAssertEqual(XCTWaiter.wait(for: [offline], timeout: 10), .completed)
        app.navigationBars["iPad display"].buttons["Done"].tap()
        XCTAssertTrue(app.buttons["today.startWorkout"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.buttons["runner.logSet"].exists)
        tap(app.buttons["today.ipadDisplay"], in: app)
        XCTAssertTrue(app.buttons["station.phoneDisconnect"].waitForExistence(timeout: 5))
        tap(app.buttons["station.phoneDisconnect"], in: app)
        XCTAssertTrue(app.buttons["station.phoneConnect"].waitForExistence(timeout: 5))
        app.navigationBars["iPad display"].buttons["Done"].tap()
        tap(app.buttons["today.startWorkout"], in: app)
        XCTAssertTrue(app.buttons["runner.logSet"].waitForExistence(timeout: 5))
        tap(app.buttons["today.ipadDisplay"], in: app)
        XCTAssertTrue(app.buttons["station.phoneConnect"].waitForExistence(timeout: 5))
    }

    func testPhoneSetupShortcutOpensConfirmationWithoutEnablingOrStartingWorkout() throws {
        try XCTSkipIf(UIDevice.current.userInterfaceIdiom != .phone)
        let app = launch(shortcut: true)
        XCTAssertTrue(app.buttons["station.phoneConnect"].waitForExistence(timeout: 10))
        XCTAssertFalse(app.buttons["station.phoneDisconnect"].exists)
        app.navigationBars["iPad display"].buttons["Done"].tap()
        XCTAssertTrue(app.buttons["today.startWorkout"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.buttons["runner.logSet"].exists)
        tap(app.buttons["today.ipadDisplay"], in: app)
        XCTAssertTrue(app.buttons["station.phoneConnect"].waitForExistence(timeout: 5))
    }

    func testIPadSetupCodeRetryAndRememberedReconnectAreReachable() throws {
        try XCTSkipIf(UIDevice.current.userInterfaceIdiom != .pad)
        let app = launch()
        tap(app.buttons["today.station"], in: app)
        XCTAssertFalse(app.images["station.setupCode"].exists)
        tap(app.buttons["station.connectPhone"], in: app)
        XCTAssertTrue(app.images["station.setupCode"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["station.connectionProblem"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["station.connectionProblem"].label.contains("internet"))
        capture("ipad-scan-to-connect")
        tap(app.buttons["station.retryConnection"], in: app)
        XCTAssertTrue(app.images["station.setupCode"].waitForExistence(timeout: 5))
        app.buttons["station.done"].tap()
        tap(app.buttons["today.station"], in: app)
        XCTAssertTrue(app.images["station.setupCode"].waitForExistence(timeout: 5), "Reopening Station restores this account’s opt-in")
        tap(app.buttons["ipadWorkout.options"], in: app)
        let reconnect = app.switches["station.link"]
        XCTAssertEqual(reconnect.value as? String, "1")
        tap(reconnect, in: app)
        XCTAssertEqual(reconnect.value as? String, "0")
        app.buttons["station.done"].tap()
        tap(app.buttons["today.station"], in: app)
        XCTAssertTrue(app.buttons["station.connectPhone"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.images["station.setupCode"].exists)
    }

    func testAnotherAccountsRememberedIPadPreferenceDoesNotConnect() throws {
        try XCTSkipIf(UIDevice.current.userInterfaceIdiom != .pad)
        let app = launch(rememberedAccount: "another-member")
        tap(app.buttons["today.station"], in: app)
        XCTAssertTrue(app.buttons["station.connectPhone"].waitForExistence(timeout: 5))
        XCTAssertEqual(app.switches["station.link"].value as? String, "0")
        XCTAssertFalse(app.images["station.setupCode"].exists)
    }

    func testLargestTextKeepsSetupAndDismissalReachable() {
        let app = launch(largeText: true)
        if UIDevice.current.userInterfaceIdiom == .phone {
            tap(app.buttons["today.ipadDisplay"], in: app)
            tap(app.buttons["station.phoneConnect"], in: app)
            tap(app.buttons["station.phoneDisconnect"], in: app)
            XCTAssertTrue(app.navigationBars["iPad display"].buttons["Done"].isHittable)
        } else {
            tap(app.buttons["today.station"], in: app)
            tap(app.buttons["station.connectPhone"], in: app)
            tap(app.buttons["ipadWorkout.options"], in: app)
            tap(app.switches["station.link"], in: app)
            XCTAssertTrue(app.buttons["station.done"].isHittable)
        }
        capture("station-setup-largest-text")
    }
}
