import XCTest

final class PlanChangeJourneyTests: XCTestCase {
    override func setUpWithError() throws { continueAfterFailure = false }

    private func revealChanges(in app: XCUIApplication) {
        for _ in 0..<5 where !app.buttons["Plan changes"].isHittable { app.swipeUp() }
    }

    func testDismissRelaunchRevisitBothActorsAndRestore() {
        let app = XCUIApplication()
        app.launchEnvironment["TRESFORT_UI_FIXTURE"] = "plan-changes"
        app.launchArguments = ["-AppleLanguages", "(en)", "-AppleLocale", "en_US"]
        app.launch()
        XCTAssertTrue(app.buttons["today.chooseWorkout"].waitForExistence(timeout: 15))
        app.buttons["today.chooseWorkout"].tap()
        revealChanges(in: app)
        XCTAssertTrue(app.buttons["planChanges.review"].waitForExistence(timeout: 15))
        XCTAssertTrue(app.descendants(matching: .any).matching(NSPredicate(format: "label CONTAINS 'Prefer five reps' AND label CONTAINS 'You' AND label CONTAINS 'Barbell Squat'")).firstMatch.exists)
        app.buttons["planChanges.dismiss"].tap()
        XCTAssertFalse(app.buttons["planChanges.review"].exists)
        app.terminate()
        app.launchEnvironment["TRESFORT_UI_REUSE_PLAN_CHANGES"] = "1"
        app.launch()
        XCTAssertTrue(app.buttons["today.chooseWorkout"].waitForExistence(timeout: 15))
        XCTAssertFalse(app.buttons["planChanges.review"].exists)
        app.buttons["today.chooseWorkout"].tap()
        revealChanges(in: app)
        app.buttons["Plan changes"].tap()
        XCTAssertTrue(app.buttons["planHistory.before.3"].waitForExistence(timeout: 10))
        let coach = app.descendants(matching: .any).matching(NSPredicate(format: "label CONTAINS 'Reduced load after your feedback' AND label CONTAINS 'Coach'"))
        for _ in 0..<4 where !app.buttons["planHistory.before.2"].isHittable { app.swipeUp() }
        XCTAssertTrue(coach.firstMatch.exists)
        let before = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        before.name = "plan-changes-both-authors"; before.lifetime = .keepAlways; add(before)
        app.buttons["planHistory.before.2"].tap()
        let restore = app.buttons["Restore version 1"]
        for _ in 0..<4 where !restore.isHittable { app.swipeDown() }
        XCTAssertTrue(restore.waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["65 lb → 45 lb"].exists)
        restore.tap()
        app.buttons["Restore as a new version"].tap()
        XCTAssertTrue(app.buttons["planHistory.before.4"].waitForExistence(timeout: 10))
        app.navigationBars["Plan changes"].buttons["Done"].tap()
        revealChanges(in: app)
        XCTAssertTrue(app.buttons["planChanges.review"].waitForExistence(timeout: 10))
        let after = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        after.name = "plan-change-restore-visible"; after.lifetime = .keepAlways; add(after)
    }

    func testRecentChangeReachesExistingWorkoutCorrectionControls() {
        let app = XCUIApplication()
        app.launchEnvironment["TRESFORT_UI_FIXTURE"] = "plan-changes"
        app.launchArguments = ["-AppleLanguages", "(en)", "-AppleLocale", "en_US"]
        app.launch()
        XCTAssertTrue(app.buttons["today.chooseWorkout"].waitForExistence(timeout: 15))
        app.buttons["today.chooseWorkout"].tap()
        revealChanges(in: app)
        XCTAssertTrue(app.buttons["planChanges.review"].waitForExistence(timeout: 15))
        app.buttons["planChanges.review"].tap()
        XCTAssertTrue(app.buttons["planHistory.correct"].waitForExistence(timeout: 10))
        app.buttons["planHistory.correct"].tap()
        XCTAssertTrue(app.navigationBars["Choose a workout"].waitForExistence(timeout: 5))
        let workout = app.buttons["library.workout.synthetic-day"]
        for _ in 0..<5 where !workout.isHittable { app.swipeDown() }
        workout.tap()
        XCTAssertTrue(app.buttons["workoutDetails.edit"].waitForExistence(timeout: 5))
        app.buttons["workoutDetails.edit"].tap()
        XCTAssertTrue(app.buttons["Workout actions"].waitForExistence(timeout: 5))
        app.buttons["Workout actions"].tap()
        XCTAssertTrue(app.buttons["Add exercise"].waitForExistence(timeout: 5))
    }
}
