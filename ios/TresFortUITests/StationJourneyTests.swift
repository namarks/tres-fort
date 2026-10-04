import XCTest

final class StationJourneyTests: XCTestCase {
    override func setUpWithError() throws {
        continueAfterFailure = false
        try XCTSkipIf(UIDevice.current.userInterfaceIdiom != .pad, "Station Mode is an iPad surface")
    }

    override func tearDownWithError() throws {
        XCUIDevice.shared.orientation = .portrait
        if (testRun?.failureCount ?? 0) > 0 { print(XCUIApplication().debugDescription) }
    }

    private func launch(largeText: Bool = false) -> XCUIApplication {
        XCUIDevice.shared.orientation = .landscapeLeft
        let app = XCUIApplication()
        app.launchEnvironment["TRESFORT_UI_FIXTURE"] = "app-store"
        if largeText { app.launchEnvironment["TRESFORT_UI_LARGE_TEXT"] = "1" }
        app.launchArguments = ["-AppleLanguages", "(en)", "-AppleLocale", "en_US",
                               "-restAudioCuesEnabled", "NO"]
        app.launch()
        XCTAssertTrue(app.buttons["today.station"].waitForExistence(timeout: 10))
        return app
    }

    func testLandscapeSetupIsOptInAndDoesNotStartWorkout() {
        let app = launch()
        app.buttons["today.station"].tap()
        let enable = app.buttons["station.enableCamera"]
        XCTAssertTrue(enable.waitForExistence(timeout: 5))
        XCTAssertTrue(enable.isHittable)
        XCTAssertLessThanOrEqual(enable.frame.maxY, app.frame.maxY)
        XCTAssertFalse(app.buttons["station.trial"].isEnabled)
        XCTAssertEqual(app.staticTexts["station.repCount"].label, "MediaPipe: 0 reps")
        XCTAssertFalse(app.staticTexts["station.appleCount"].exists)
        XCTAssertTrue(app.staticTexts["station.trialNotice"].exists)
        app.buttons["station.exercise.curl"].tap()
        XCTAssertEqual(app.staticTexts["station.movement"].label, "CURL")
        XCTAssertEqual(app.staticTexts["station.leftRepCount"].label, "Left arm: 0 reps")
        XCTAssertEqual(app.staticTexts["station.rightRepCount"].label, "Right arm: 0 reps")
        XCTAssertFalse(app.staticTexts["station.repCount"].exists)
        app.buttons["station.exercise.benchPress"].tap()
        XCTAssertEqual(app.staticTexts["station.movement"].label, "BENCH PRESS")
        XCTAssertFalse(app.staticTexts["station.leftRepCount"].exists)
        capture("ipad-station-landscape-setup")
        app.buttons["station.done"].tap()
        XCTAssertTrue(app.buttons["today.startWorkout"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.buttons["LOG SET 1"].exists)
    }

    func testCameraUnavailableCanExitWithoutLoggingASet() {
        let app = launch()
        let start = app.buttons["today.startWorkout"]
        for _ in 0..<6 where !start.isHittable { app.scrollViews.firstMatch.swipeUp() }
        start.tap()
        XCTAssertTrue(app.buttons["LOG SET 1"].waitForExistence(timeout: 5))
        app.buttons["today.station"].tap()
        app.buttons["station.enableCamera"].tap()
        let status = app.staticTexts["station.cameraStatus"]
        let unavailable = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "label == %@", "A front camera is not available on this device."), object: status)
        XCTAssertEqual(XCTWaiter.wait(for: [unavailable], timeout: 5), .completed)
        XCTAssertTrue(app.buttons["station.enableCamera"].isEnabled)
        XCTAssertFalse(app.buttons["station.trial"].isEnabled)
        XCTAssertEqual(app.staticTexts["station.repCount"].label, "MediaPipe: 0 reps")
        app.buttons["station.done"].tap()
        XCTAssertTrue(app.buttons["LOG SET 1"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.buttons["LOG SET 2"].exists)
    }

    func testRotationAndLargeTextKeepSetupAndExitReachable() {
        let app = launch(largeText: true)
        app.buttons["today.station"].tap()
        XCTAssertTrue(app.buttons["station.done"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["station.done"].isHittable)
        let bench = app.buttons["station.exercise.benchPress"]
        for _ in 0..<6 where !bench.isHittable { app.scrollViews.firstMatch.swipeUp() }
        XCTAssertTrue(bench.isHittable)
        bench.tap()
        // At an accessibility size the landscape layout stacks the counter
        // before the camera, rather than retaining the two-column layout.
        let reps = app.staticTexts["station.repCount"]
        let enable = app.buttons["station.enableCamera"]
        for _ in 0..<8 where !enable.isHittable { app.scrollViews.firstMatch.swipeUp() }
        XCTAssertLessThan(reps.frame.minY, enable.frame.minY)
        XCUIDevice.shared.orientation = .portrait
        for _ in 0..<8 where !enable.isHittable { app.scrollViews.firstMatch.swipeUp() }
        XCTAssertTrue(enable.isHittable)
        capture("ipad-station-accessibility-portrait")
        XCTAssertTrue(app.buttons["station.done"].isHittable)
        app.buttons["station.done"].tap()
        XCTAssertTrue(app.buttons["today.station"].waitForExistence(timeout: 5))
    }

    func testSavedTestsAreReachableWithoutCameraOrWorkoutWrites() {
        let app = launch()
        app.buttons["today.station"].tap()
        let record = app.buttons["station.recordTest"]
        let saved = app.buttons["station.savedTests"]
        for _ in 0..<8 where !saved.isHittable { app.scrollViews.firstMatch.swipeUp() }
        XCTAssertTrue(record.exists)
        XCTAssertFalse(record.isEnabled)
        XCTAssertTrue(saved.isHittable)
        saved.tap()
        XCTAssertTrue(app.navigationBars["Saved tests"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["No saved tests"].exists)
        app.navigationBars["Saved tests"].buttons["Done"].tap()
        app.buttons["station.done"].tap()
        XCTAssertTrue(app.buttons["today.startWorkout"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.buttons["LOG SET 1"].exists)
    }

    private func capture(_ name: String) {
        let attachment = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
