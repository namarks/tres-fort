import XCTest

/// Asset capture through real screens and controls, using only the isolated
/// simulator transport. Images remain drafts until checked against the final
/// selected candidate. This test does not upload anything to App Store Connect.
final class AppStoreScreenshotTests: XCTestCase {
    override func setUpWithError() throws {
        continueAfterFailure = false
        XCUIDevice.shared.orientation = .portrait
    }

    override func tearDownWithError() throws {
        XCUIDevice.shared.orientation = .portrait
        if (testRun?.failureCount ?? 0) > 0 { print(XCUIApplication().debugDescription) }
    }

    private func launch() -> XCUIApplication {
        let app = XCUIApplication()
        app.launchEnvironment["TRESFORT_UI_FIXTURE"] = "app-store"
        app.launchArguments = ["-AppleLanguages", "(en)", "-AppleLocale", "en_US",
                               "-restAudioCuesEnabled", "NO"]
        app.launch()
        XCTAssertTrue(app.navigationBars["Today"].waitForExistence(timeout: 10))
        XCTAssertTrue(app.buttons["today.startWorkout"].waitForExistence(timeout: 10))
        XCTAssertFalse(app.staticTexts["fixture.scenario"].exists)
        if UIDevice.current.userInterfaceIdiom == .phone {
            XCTAssertTrue(app.tabBars.buttons["Today"].exists)
            XCTAssertTrue(app.buttons["today.partner"].exists,
                          "The public candidate includes manual partner training")
        } else {
            XCTAssertTrue(app.buttons["today.station"].exists)
        }
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

    func testSavedPartnerSetupCanBeCancelled() throws {
        try XCTSkipIf(UIDevice.current.userInterfaceIdiom != .phone, "Partner lane recovery belongs to its iPhone")
        let app = XCUIApplication()
        app.launchEnvironment["TRESFORT_UI_FIXTURE"] = "app-store"
        app.launchEnvironment["TRESFORT_UI_PARTNER_READY"] = "1"
        app.launchArguments = ["-AppleLanguages", "(en)", "-AppleLocale", "en_US"]
        app.launch()
        let recovery = app.buttons["today.partner"]
        XCTAssertTrue(recovery.waitForExistence(timeout: 10))
        XCTAssertEqual(recovery.label, "Partner workout setup")
        let start = app.buttons["today.startWorkout"]
        XCTAssertTrue(start.waitForExistence(timeout: 10))
        XCTAssertFalse(start.isEnabled, "A saved ready lane reserves ordinary Today until closed")
        recovery.tap()
        let cancel = app.buttons["Cancel empty start"]
        XCTAssertTrue(cancel.waitForExistence(timeout: 5))
        cancel.tap()
        let released = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "exists == true AND enabled == true"), object: start)
        XCTAssertEqual(XCTWaiter.wait(for: [released], timeout: 5), .completed)
        XCTAssertEqual(recovery.label, "Train together")
    }

    func testCaptureManualStationOnIPad() throws {
        try XCTSkipIf(UIDevice.current.userInterfaceIdiom != .pad, "Native iPad screenshot")
        #if APP_STORE_BUILD
        let app = launch()
        XCUIDevice.shared.orientation = .landscapeLeft
        tap(app.buttons["today.station"], in: app)
        XCTAssertTrue(app.staticTexts["station.manualSetup"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["station.done"].isHittable)
        XCTAssertFalse(app.buttons["station.enableCamera"].exists)
        XCTAssertFalse(app.buttons["station.recordTest"].exists)
        capture("06-station")
        #else
        throw XCTSkip("Public manual Station is captured with APP_STORE_BUILD=1")
        #endif
    }

    func testCaptureTodayWorkoutsAndHistory() {
        let app = launch()
        capture("01-today")
        tap(app.buttons["today.chooseWorkout"], in: app)
        XCTAssertTrue(app.navigationBars["Workouts"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["Strength A"].exists)
        capture("03-workouts")
        tap(app.navigationBars["Workouts"].buttons["Done"], in: app)
        tap(app.buttons["today.calendar"], in: app)
        XCTAssertTrue(app.buttons["calendar.weeklySchedule"].waitForExistence(timeout: 5))
        capture("04-history")
    }

    func testCaptureRunnerAndFeedback() {
        let app = launch()
        tap(app.buttons["today.startWorkout"], in: app)
        let log = app.buttons["LOG SET 1"]
        XCTAssertTrue(log.waitForExistence(timeout: 5))
        XCTAssertTrue(log.isHittable, "Logging must be available without scrolling")
        XCTAssertFalse(app.tabBars.firstMatch.exists)
        XCTAssertTrue(app.frame.contains(log.frame))
        capture("02-runner")
        tap(app.buttons["today.workoutActions"], in: app)
        tap(app.buttons["Finish workout"], in: app)
        XCTAssertTrue(app.staticTexts["feedback.finishSummary"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["feedback.finishWithoutChanges"].isHittable)
        XCTAssertFalse(app.textViews["feedback.note"].exists)
        capture("05-finish-summary")
        tap(app.buttons["feedback.expand"], in: app)
        XCTAssertTrue(app.textViews["feedback.note"].waitForExistence(timeout: 5))
        tap(app.textViews["feedback.note"], in: app)
        app.textViews["feedback.note"].typeText("Steady reps today. Keep this weight next time.")
        if app.buttons["Done"].isHittable { app.buttons["Done"].tap() }
        XCTAssertEqual(app.textViews["feedback.note"].value as? String,
                       "Steady reps today. Keep this weight next time.")
        // The keyboard can leave the Form scrolled beneath its toolbar. Restore
        // the disclosure before capturing this collection surface, without
        // scrolling the runner underneath the sheet or the note's TextEditor.
        let privacy = app.staticTexts["Optional. Saved feedback is shared with your coach and kept out of group feeds."]
        let toolbar = app.navigationBars["Finish workout"]
        let form = app.collectionViews.containing(.textView, identifier: "feedback.note").firstMatch
        let save = app.buttons["feedback.saveAndFinish"]
        XCTAssertTrue(privacy.waitForExistence(timeout: 5))
        XCTAssertTrue(form.exists)
        for _ in 0..<4 {
            let top = max(form.frame.minY, toolbar.frame.maxY) + 12
            if privacy.isHittable && privacy.frame.minY >= top { break }
            let bottom = min(form.frame.maxY, save.frame.minY) - 12
            let height = bottom - top
            guard height > 80 else { break }
            let distance = min(height * 0.3, max(32, top - privacy.frame.minY))
            let origin = app.coordinate(withNormalizedOffset: .zero)
            let start = origin.withOffset(CGVector(dx: form.frame.minX + 12, dy: top + 24))
            let end = origin.withOffset(CGVector(dx: form.frame.minX + 12, dy: top + 24 + distance))
            start.press(forDuration: 0.1, thenDragTo: end,
                        withVelocity: .slow, thenHoldForDuration: 0.5)
        }
        XCTAssertTrue(privacy.isHittable)
        XCTAssertGreaterThanOrEqual(privacy.frame.minY, toolbar.frame.maxY + 8)
        XCTAssertLessThanOrEqual(privacy.frame.maxY, save.frame.minY)
        capture("05-feedback")
    }
}
