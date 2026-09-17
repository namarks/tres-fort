import XCTest

final class WeeklyScheduleJourneyTests: XCTestCase {
    override func setUpWithError() throws { continueAfterFailure = false }

    private func launch(fixture: String = "library", failure: String? = nil) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchEnvironment["TRESFORT_UI_FIXTURE"] = fixture
        if let failure { app.launchEnvironment["TRESFORT_UI_SCHEDULE_FAILURE"] = failure }
        app.launchArguments = ["-AppleLanguages", "(en)", "-AppleLocale", "en_US"]
        app.launch()
        XCTAssertTrue(app.tabBars.buttons["Calendar"].waitForExistence(timeout: 10))
        return app
    }

    private func openSchedule(in app: XCUIApplication) {
        app.tabBars.buttons["Calendar"].tap()
        let schedule = app.buttons["calendar.weeklySchedule"]
        XCTAssertTrue(schedule.waitForExistence(timeout: 5))
        schedule.tap()
        XCTAssertTrue(app.buttons["weeklySchedule.mon"].waitForExistence(timeout: 5))
    }

    private func choose(_ workout: String, on weekday: String, in app: XCUIApplication) {
        app.buttons["weeklySchedule.\(weekday)"].tap()
        let option = app.buttons[workout]
        XCTAssertTrue(option.waitForExistence(timeout: 5))
        option.tap()
    }

    private func assertChoice(_ workout: String, on weekday: String, in app: XCUIApplication,
                              file: StaticString = #filePath, line: UInt = #line) {
        let picker = app.buttons["weeklySchedule.\(weekday)"]
        XCTAssertTrue(picker.waitForExistence(timeout: 5), file: file, line: line)
        XCTAssertTrue(picker.label.contains(workout) || (picker.value as? String)?.contains(workout) == true,
                      "Expected \(workout), got label=\(picker.label), value=\(String(describing: picker.value))",
                      file: file, line: line)
    }

    private func assertClosed(in app: XCUIApplication) {
        expectation(for: NSPredicate(format: "exists == false"),
                    evaluatedWith: app.navigationBars["Weekly schedule"])
        waitForExpectations(timeout: 5)
    }

    func testSaveClosesAfterPersistenceAndReopeningShowsNewSchedule() {
        let app = launch()
        openSchedule(in: app)
        XCTAssertFalse(app.buttons["weeklySchedule.save"].isEnabled)
        assertChoice("Rest", on: "mon", in: app)
        choose("Hotel", on: "mon", in: app)
        app.buttons["weeklySchedule.save"].tap()
        assertClosed(in: app)
        openSchedule(in: app)
        assertChoice("Hotel", on: "mon", in: app)
        assertChoice("Gym", on: "tue", in: app)
        XCTAssertFalse(app.buttons["weeklySchedule.save"].isEnabled)
    }

    func testDirtyDraftSurvivesSwipeAndKeepEditingUntilExplicitDiscard() {
        let app = launch()
        openSchedule(in: app)
        choose("Hotel", on: "mon", in: app)
        app.navigationBars["Weekly schedule"].swipeDown()
        assertChoice("Hotel", on: "mon", in: app)
        app.buttons["weeklySchedule.cancel"].tap()
        let confirmation = app.alerts["Discard schedule changes?"]
        XCTAssertTrue(confirmation.waitForExistence(timeout: 5))
        confirmation.buttons["Keep editing"].tap()
        assertChoice("Hotel", on: "mon", in: app)
        XCTAssertTrue(app.buttons["weeklySchedule.save"].isEnabled)
        app.buttons["weeklySchedule.cancel"].tap()
        confirmation.buttons["Discard changes"].tap()
        assertClosed(in: app)
        openSchedule(in: app)
        assertChoice("Rest", on: "mon", in: app)
        assertChoice("Gym", on: "tue", in: app)
        app.buttons["weeklySchedule.cancel"].tap()
        assertClosed(in: app)
        XCTAssertFalse(confirmation.exists, "An unchanged schedule should close directly")
    }

    func testFailedSaveRetainsDraftAndAllowsExplicitRetry() {
        assertFailedSaveCanRetry(failure: "request")
    }

    func testConflictedSaveRetainsDraftAndRequiresExplicitRetry() {
        assertFailedSaveCanRetry(failure: "conflict")
    }

    private func assertFailedSaveCanRetry(failure: String) {
        let app = launch(failure: failure)
        openSchedule(in: app)
        choose("Hotel", on: "mon", in: app)
        app.buttons["weeklySchedule.save"].tap()
        XCTAssertTrue(app.staticTexts["weeklySchedule.error"].waitForExistence(timeout: 10))
        XCTAssertTrue(app.navigationBars["Weekly schedule"].exists)
        assertChoice("Hotel", on: "mon", in: app)
        assertChoice("Gym", on: "tue", in: app)
        if failure == "conflict" {
            XCTAssertTrue(app.staticTexts["weeklySchedule.conflict"].exists)
        }
        XCTAssertTrue(app.buttons["weeklySchedule.save"].isEnabled)
        app.buttons["weeklySchedule.save"].tap()
        assertClosed(in: app)
        openSchedule(in: app)
        assertChoice("Hotel", on: "mon", in: app)
    }

    func testWorkoutStartStaysVisibleWhilePreviewScrolls() {
        let app = launch(fixture: "app-store")
        let details = app.buttons["today.viewWorkout"]
        XCTAssertTrue(details.waitForExistence(timeout: 5))
        details.tap()
        assertPinnedAction("workoutDetails.start", in: app)
    }

    func testDateAssignmentStaysVisibleWhilePreviewScrolls() {
        let app = launch(fixture: "app-store")
        app.tabBars.buttons["Calendar"].tap()
        app.buttons["calendar.date.2026-09-09"].tap()
        let actions = app.buttons["calendar.dateActions"]
        XCTAssertTrue(actions.waitForExistence(timeout: 5))
        actions.tap()
        app.buttons["calendar.chooseWorkout"].tap()
        let workout = app.buttons["library.workout.synthetic-day"]
        XCTAssertTrue(workout.waitForExistence(timeout: 5))
        workout.tap()
        assertPinnedAction("workoutDetails.schedule", in: app)
    }

    private func assertPinnedAction(_ identifier: String, in app: XCUIApplication) {
        let action = app.buttons[identifier]
        XCTAssertTrue(action.waitForExistence(timeout: 5))
        XCTAssertTrue(action.isHittable, "The primary action must be visible without scrolling")
        let originalY = action.frame.minY
        app.scrollViews.firstMatch.swipeUp()
        XCTAssertTrue(action.isHittable)
        XCTAssertEqual(action.frame.minY, originalY, accuracy: 1,
                       "The primary action must stay fixed while the workout scrolls")
        let capture = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        capture.name = identifier
        capture.lifetime = .keepAlways
        add(capture)
    }
}
