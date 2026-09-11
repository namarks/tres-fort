import XCTest

final class WorkoutLibraryJourneyTests: XCTestCase {
    override func setUpWithError() throws { continueAfterFailure = false }

    private func launch() -> XCUIApplication {
        let app = XCUIApplication()
        app.launchEnvironment["TRESFORT_UI_FIXTURE"] = "library"
        app.launchArguments = ["-AppleLanguages", "(en)", "-AppleLocale", "en_US"]
        app.launch()
        XCTAssertTrue(app.buttons["today.chooseWorkout"].waitForExistence(timeout: 10))
        app.buttons["today.chooseWorkout"].tap()
        XCTAssertTrue(app.navigationBars["Choose a workout"].waitForExistence(timeout: 5))
        return app
    }

    func testLibraryBadgesUnscheduleAndDateAssignment() {
        let app = launch()
        XCTAssertEqual(app.staticTexts["workoutSchedule-synthetic-day"].label, "Tue")
        XCTAssertEqual(app.staticTexts["workoutSchedule-hotel"].label, "On demand")
        app.buttons["Actions for Gym"].tap()
        app.buttons["Unschedule"].tap()
        let onDemand = NSPredicate(format: "label == %@", "On demand")
        expectation(for: onDemand, evaluatedWith: app.staticTexts["workoutSchedule-synthetic-day"])
        waitForExpectations(timeout: 5)
        XCTAssertTrue(app.buttons["Actions for Gym"].exists)
        app.buttons["Actions for Hotel"].tap()
        app.buttons["Use on a date"].tap()
        XCTAssertTrue(app.buttons["assignLibraryWorkout"].waitForExistence(timeout: 5))
        app.buttons["assignLibraryWorkout"].tap()
        XCTAssertTrue(app.navigationBars["Choose a workout"].waitForExistence(timeout: 5))
        XCTAssertEqual(app.staticTexts["workoutSchedule-hotel"].label, "On demand")
        let image = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        image.name = "workout-library"; image.lifetime = .keepAlways; add(image)
        app.navigationBars["Choose a workout"].buttons["Done"].tap()
        XCTAssertTrue(app.staticTexts["Hotel"].waitForExistence(timeout: 5))
    }

    func testDeleteIsExplicitAndSeparateFromUnschedule() {
        let app = launch()
        app.buttons["Actions for Hotel"].tap()
        XCTAssertFalse(app.buttons["Unschedule"].isEnabled)
        app.buttons["Delete workout"].tap()
        XCTAssertTrue(app.buttons["Delete workout"].waitForExistence(timeout: 5))
        app.buttons["Delete workout"].tap()
        let gone = NSPredicate(format: "exists == false")
        expectation(for: gone, evaluatedWith: app.buttons["Actions for Hotel"])
        waitForExpectations(timeout: 5)
        XCTAssertTrue(app.buttons["Actions for Gym"].exists)
        XCTAssertEqual(app.staticTexts["workoutSchedule-synthetic-day"].label, "Tue")
    }
}
