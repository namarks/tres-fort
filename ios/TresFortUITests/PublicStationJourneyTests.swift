import XCTest

final class PublicStationJourneyTests: XCTestCase {
    override func setUpWithError() throws {
        continueAfterFailure = false
        #if !APP_STORE_BUILD
        throw XCTSkip("The manual Station entry belongs to the public build")
        #endif
        try XCTSkipIf(UIDevice.current.userInterfaceIdiom != .pad, "Station is an iPad surface")
    }

    override func tearDownWithError() throws {
        XCUIDevice.shared.orientation = .portrait
        if (testRun?.failureCount ?? 0) > 0 { print(XCUIApplication().debugDescription) }
    }

    private func launch(largeText: Bool = false, partner: String? = nil) -> XCUIApplication {
        XCUIDevice.shared.orientation = .landscapeLeft
        let app = XCUIApplication()
        app.launchEnvironment["TRESFORT_UI_FIXTURE"] = "app-store"
        if largeText { app.launchEnvironment["TRESFORT_UI_LARGE_TEXT"] = "1" }
        if let partner { app.launchEnvironment["TRESFORT_UI_STATION_PARTNER"] = partner }
        app.launchArguments = ["-AppleLanguages", "(en)", "-AppleLocale", "en_US", "-restAudioCuesEnabled", "NO"]
        app.launch()
        XCTAssertTrue(app.buttons["today.station"].waitForExistence(timeout: 10))
        app.buttons["today.station"].tap()
        XCTAssertTrue(app.buttons["station.done"].waitForExistence(timeout: 5))
        assertNoMovementCamera(in: app)
        return app
    }

    private func assertNoMovementCamera(in app: XCUIApplication) {
        for id in ["station.enableCamera", "station.recordTest", "station.savedTests", "station.trial", "station.catalog"] {
            XCTAssertFalse(app.buttons[id].exists, id)
        }
        XCTAssertFalse(app.staticTexts["station.repCount"].exists)
    }

    func testManualSetupIsOptInAndDoesNotStartAWorkout() {
        let app = launch()
        XCTAssertTrue(app.staticTexts["station.manualSetup"].exists)
        let connect = app.switches["station.link"]
        XCTAssertTrue(connect.exists)
        XCTAssertEqual(connect.value as? String, "0")
        XCTAssertEqual(app.staticTexts["station.linkStatus"].label, "Connect when your iPhone is ready.")
        XCTAssertFalse(app.buttons["station.trainTogether"].isEnabled)
        app.buttons["station.done"].tap()
        XCTAssertTrue(app.buttons["today.startWorkout"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.buttons["runner.logSet"].exists)
    }

    func testPortraitLargestTextKeepsManualSetupAndExitReachable() {
        let app = launch(largeText: true)
        XCUIDevice.shared.orientation = .portrait
        let connect = app.switches["station.link"]
        UITestScrolling.reveal(connect, in: app, maxAttempts: 12)
        XCTAssertEqual(connect.value as? String, "0")
        assertNoMovementCamera(in: app)
        XCTAssertTrue(app.buttons["station.done"].isHittable)
        app.buttons["station.done"].tap()
        XCTAssertTrue(app.buttons["today.station"].waitForExistence(timeout: 5))
    }

    func testManualPartnerPanelShowsSeparateLoadsAndClosesWithoutPhoneWrites() {
        let app = launch(partner: "active")
        XCTAssertTrue(app.staticTexts["partner.stationStep"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["Jordan"].exists)
        XCTAssertTrue(app.staticTexts["Casey"].exists)
        XCTAssertTrue(app.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", "20 kg")).firstMatch.exists)
        XCTAssertFalse(app.staticTexts["partner.stationRest"].exists)
        app.buttons["partner.stationClose"].tap()
        XCTAssertTrue(app.staticTexts["station.manualSetup"].waitForExistence(timeout: 5))
        app.buttons["station.done"].tap()
        XCTAssertTrue(app.buttons["today.startWorkout"].waitForExistence(timeout: 5))
    }

    func testLargestTextSharedRestAdvancesThroughManualControl() {
        let app = launch(largeText: true, partner: "rest")
        XCUIDevice.shared.orientation = .portrait
        XCTAssertTrue(app.staticTexts["partner.stationRest"].waitForExistence(timeout: 5))
        let previous = app.staticTexts["partner.stationStep"].label
        let skip = app.buttons["Skip rest"]
        UITestScrolling.reveal(skip, in: app, maxAttempts: 12)
        skip.tap()
        let advanced = XCTNSPredicateExpectation(predicate: NSPredicate(format: "label != %@", previous),
                                                 object: app.staticTexts["partner.stationStep"])
        XCTAssertEqual(XCTWaiter.wait(for: [advanced], timeout: 5), .completed)
        XCTAssertFalse(app.staticTexts["partner.stationRest"].exists)
        assertNoMovementCamera(in: app)
        XCTAssertTrue(app.buttons["station.done"].isHittable)
    }
}
