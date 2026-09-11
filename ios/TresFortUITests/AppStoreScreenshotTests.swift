import XCTest

/// Asset capture through real screens and controls, using only the isolated
/// simulator transport. Images remain drafts until checked against the final
/// selected candidate. This test does not upload anything to App Store Connect.
final class AppStoreScreenshotTests: XCTestCase {
    override func setUpWithError() throws { continueAfterFailure = false }

    private func launch() -> XCUIApplication {
        let app = XCUIApplication()
        app.launchEnvironment["TRESFORT_UI_FIXTURE"] = "app-store"
        app.launchArguments = ["-AppleLanguages", "(en)", "-AppleLocale", "en_US",
                               "-restAudioCuesEnabled", "NO"]
        app.launch()
        XCTAssertTrue(app.tabBars.buttons["Today"].waitForExistence(timeout: 10))
        XCTAssertTrue(app.buttons["today.startWorkout"].waitForExistence(timeout: 10))
        XCTAssertFalse(app.staticTexts["fixture.scenario"].exists)
        return app
    }

    private func capture(_ name: String) {
        // A freshly created iOS 26 simulator can announce Apple Intelligence.
        // Wait for that transient banner to disappear. Swiping its text can
        // open Settings, so capture must also require the app in foreground.
        let banner = XCUIApplication(bundleIdentifier: "com.apple.springboard")
            .staticTexts["Ready for Apple Intelligence"]
        if banner.exists {
            let gone = XCTNSPredicateExpectation(predicate: NSPredicate(format: "exists == false"), object: banner)
            XCTAssertEqual(XCTWaiter.wait(for: [gone], timeout: 15), .completed)
        }
        XCTAssertEqual(XCUIApplication().state, .runningForeground)
        let attachment = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        attachment.name = "app-store-\(name)"
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    private func tap(_ element: XCUIElement, in app: XCUIApplication) {
        XCTAssertTrue(element.waitForExistence(timeout: 5))
        for _ in 0..<5 where !element.isHittable { app.swipeUp() }
        XCTAssertTrue(element.isHittable)
        element.tap()
    }

    func testCaptureTodayWorkoutsAndHistory() {
        let app = launch()
        capture("01-today")
        tap(app.buttons["today.chooseWorkout"], in: app)
        XCTAssertTrue(app.navigationBars["Choose a workout"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["Strength A"].exists)
        capture("03-workouts")
        tap(app.navigationBars["Choose a workout"].buttons["Done"], in: app)
        tap(app.tabBars.buttons["Calendar"], in: app)
        XCTAssertTrue(app.buttons["calendar.exerciseProgress"].waitForExistence(timeout: 5))
        capture("04-history")
    }

    func testCaptureRunnerAndFeedback() {
        let app = launch()
        tap(app.buttons["today.startWorkout"], in: app)
        let log = app.buttons["LOG SET 1"]
        XCTAssertTrue(log.waitForExistence(timeout: 5))
        XCTAssertTrue(log.isHittable, "Logging must be available without scrolling")
        XCTAssertLessThan(log.frame.maxY, app.tabBars.firstMatch.frame.minY)
        capture("02-runner")
        tap(app.buttons["today.workoutActions"], in: app)
        tap(app.buttons["Finish workout"], in: app)
        XCTAssertTrue(app.textViews["feedback.note"].waitForExistence(timeout: 5))
        tap(app.textViews["feedback.note"], in: app)
        app.textViews["feedback.note"].typeText("Steady reps today. Keep this weight next time.")
        if app.buttons["Done"].isHittable { app.buttons["Done"].tap() }
        XCTAssertEqual(app.textViews["feedback.note"].value as? String,
                       "Steady reps today. Keep this weight next time.")
        capture("05-feedback")
    }
}
