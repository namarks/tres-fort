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
        let confirmation = app.alerts["Delete Hotel?"]
        XCTAssertTrue(confirmation.waitForExistence(timeout: 5))
        confirmation.buttons["Delete workout"].tap()
        let gone = NSPredicate(format: "exists == false")
        expectation(for: gone, evaluatedWith: app.buttons["Actions for Hotel"])
        waitForExpectations(timeout: 5)
        XCTAssertTrue(app.buttons["Actions for Gym"].exists)
        XCTAssertEqual(app.staticTexts["workoutSchedule-synthetic-day"].label, "Tue")
    }

    func testWorkoutOpensFromEmptyRowSpaceAndDisclosure() {
        let app = launch()
        let row = app.buttons["library.workout.hotel"]
        // Exercise blank horizontal space, vertical padding, and the chevron.
        // A label-center tap alone does not catch the original plain-button gap.
        for point in [CGVector(dx: 0.7, dy: 0.5), CGVector(dx: 0.5, dy: 0.08),
                      CGVector(dx: 0.96, dy: 0.5)] {
            XCTAssertTrue(row.waitForExistence(timeout: 5))
            row.coordinate(withNormalizedOffset: point).tap()
            let details = app.navigationBars["Hotel"]
            XCTAssertTrue(details.waitForExistence(timeout: 5))
            XCTAssertTrue(app.buttons["workoutDetails.edit"].exists)
            details.buttons["Done"].tap()
        }
        let image = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        image.name = "workout-library-row-navigation"; image.lifetime = .keepAlways; add(image)
        let actions = app.buttons["Actions for Hotel"]
        XCTAssertGreaterThanOrEqual(actions.frame.width, 44)
        XCTAssertGreaterThanOrEqual(actions.frame.height, 44)
        actions.coordinate(withNormalizedOffset: CGVector(dx: 0.1, dy: 0.1)).tap()
        XCTAssertTrue(app.buttons["Use on a date"].waitForExistence(timeout: 5))
    }

    func testSwipeDeleteRequiresConfirmationAndCancelKeepsWorkout() {
        let app = launch()
        let row = app.buttons["library.workout.hotel"]
        row.swipeLeft()
        XCTAssertTrue(app.buttons["Delete"].waitForExistence(timeout: 5))
        XCTAssertTrue(row.exists, "Swiping must not remove a workout")
        XCTAssertFalse(app.alerts["Delete Hotel?"].exists, "Full swipe must not execute Delete")
        app.buttons["Delete"].tap()
        let confirmation = app.alerts["Delete Hotel?"]
        XCTAssertTrue(confirmation.waitForExistence(timeout: 5))
        let image = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        image.name = "workout-library-delete-confirmation"; image.lifetime = .keepAlways; add(image)
        confirmation.buttons["Cancel"].tap()
        XCTAssertTrue(row.waitForExistence(timeout: 5))
        row.tap()
        XCTAssertTrue(app.navigationBars["Hotel"].waitForExistence(timeout: 5))
        app.navigationBars["Hotel"].buttons["Done"].tap()
        row.swipeLeft()
        app.buttons["Delete"].tap()
        XCTAssertTrue(confirmation.waitForExistence(timeout: 5))
        confirmation.buttons["Delete workout"].tap()
        expectation(for: NSPredicate(format: "exists == false"), evaluatedWith: row)
        waitForExpectations(timeout: 5)
        XCTAssertTrue(app.buttons["library.workout.synthetic-day"].exists)
        XCTAssertEqual(app.staticTexts["workoutSchedule-synthetic-day"].label, "Tue")
    }
}
