import XCTest

final class RunnerStreamlineJourneyTests: XCTestCase {
    override func setUpWithError() throws { continueAfterFailure = false }

    override func tearDownWithError() throws {
        if (testRun?.failureCount ?? 0) > 0 { print(XCUIApplication().debugDescription) }
    }

    private func launch(largeText: Bool = false, startWorkout: Bool = true) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchEnvironment["TRESFORT_UI_FIXTURE"] = "app-store"
        app.launchEnvironment["TRESFORT_UI_ACCEPT_CORRECTIONS"] = "1"
        if largeText { app.launchEnvironment["TRESFORT_UI_LARGE_TEXT"] = "1" }
        app.launchArguments = ["-AppleLanguages", "(en)", "-AppleLocale", "en_US",
                               "-restAudioCuesEnabled", "NO",
                               "-com.nmarkspdx.tresfort.weight-entry-unit", "lb"]
        app.launch()
        let start = app.buttons["today.startWorkout"]
        XCTAssertTrue(start.waitForExistence(timeout: 10))
        guard startWorkout else { return app }
        for _ in 0..<6 where !start.isHittable { app.swipeUp() }
        start.tap()
        XCTAssertTrue(app.buttons["LOG SET 1"].waitForExistence(timeout: 5))
        return app
    }

    func testLargestTextSeparatesTodayActionsAndExerciseDemoFromTitle() {
        let app = launch(largeText: true, startWorkout: false)
        let view = app.buttons["today.viewWorkout"]
        let change = app.buttons["today.changeWorkout"]
        XCTAssertTrue(view.exists); XCTAssertTrue(change.exists)
        XCTAssertGreaterThanOrEqual(change.frame.minY, view.frame.maxY)
        capture("today-accessibility-actions-stacked")
        let start = app.buttons["today.startWorkout"]
        for _ in 0..<8 where !start.isHittable { app.swipeUp() }
        XCTAssertTrue(start.isHittable); start.tap()
        let title = app.staticTexts["runner.exerciseTitle"]
        XCTAssertTrue(title.waitForExistence(timeout: 5))
        let demo = app.buttons["Show demo for Barbell Squat"]
        XCTAssertTrue(demo.exists)
        XCTAssertGreaterThanOrEqual(demo.frame.minY, title.frame.maxY)
        capture("runner-accessibility-title-and-demo")
        for _ in 0..<6 where !demo.isHittable { app.scrollViews.firstMatch.swipeUp() }
        XCTAssertTrue(demo.isHittable); demo.tap()
        XCTAssertTrue(app.staticTexts["MUSCLES"].waitForExistence(timeout: 5))
    }

    func testCompactRestKeepsEndEditAndLoggingReachableAtAccessibilitySize() {
        let app = launch(largeText: true)
        app.buttons["LOG SET 1"].tap()
        let minimize = app.buttons["rest.minimize"]
        XCTAssertTrue(minimize.waitForExistence(timeout: 5))
        for _ in 0..<10 where !minimize.isHittable { app.swipeUp() }
        XCTAssertTrue(minimize.isHittable); minimize.tap()
        XCTAssertTrue(app.buttons["Expand rest timer"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["rest.done"].isHittable)
        XCTAssertTrue(app.buttons["LOG SET 2"].isHittable)
        XCTAssertGreaterThan(app.scrollViews.firstMatch.frame.height, 100)
        let edit = app.buttons["rest.editLastSet"]
        for _ in 0..<6 where !edit.isHittable
            || edit.frame.maxY > app.buttons["LOG SET 2"].frame.minY { app.scrollViews.firstMatch.swipeUp() }
        XCTAssertTrue(edit.isHittable); edit.tap()
        XCTAssertTrue(app.navigationBars["Correct set"].waitForExistence(timeout: 5))
        app.buttons["Cancel"].tap()
        for _ in 0..<6 where !app.buttons["rest.done"].isHittable { app.scrollViews.firstMatch.swipeDown() }
        capture("compact-rest-accessibility-size")
        app.buttons["rest.done"].tap()
        XCTAssertTrue(app.buttons["LOG SET 2"].isHittable)
        app.buttons["LOG SET 2"].coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
        XCTAssertTrue(app.buttons["LOG SET 3"].waitForExistence(timeout: 5))
    }

    private func capture(_ name: String) {
        let attachment = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        attachment.name = name; attachment.lifetime = .keepAlways; add(attachment)
    }

    func testLoadRepsAndLoggingAreVisibleWithoutScrolling() {
        let app = launch()
        let weight = app.buttons["runner.weight"]
        let reps = app.buttons["Increase reps by 1"]
        XCTAssertTrue(weight.isHittable)
        XCTAssertTrue(reps.isHittable)
        XCTAssertTrue(app.buttons["LOG SET 1"].isHittable)
        XCTAssertLessThan(reps.frame.maxY, app.buttons["LOG SET 1"].frame.minY)
        XCTAssertFalse(app.segmentedControls["runner.weight.unit"].exists)
        capture("runner-inputs-before-scrolling")
        reps.tap()
        XCTAssertEqual(app.staticTexts["runner.setSummary"].label, "135 × 6 · lb")
    }

    func testCompactRestPersistsAndCorrectionTargetsLastSetAfterAdvancing() {
        let app = launch()
        app.buttons["LOG SET 1"].tap()
        let minimize = app.buttons["rest.minimize"]
        XCTAssertTrue(minimize.waitForExistence(timeout: 5))
        for _ in 0..<4 where !minimize.isHittable { app.swipeUp() }
        minimize.tap()
        XCTAssertTrue(app.buttons["Expand rest timer"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["rest.editLastSet"].exists)
        XCTAssertEqual(app.staticTexts["rest.lastValues"].label, "Last set · 135 × 5 · lb")
        XCTAssertEqual(app.staticTexts["rest.nextValues"].label, "Set 2 of 3 · 135 × 5 · lb")
        XCTAssertFalse(app.staticTexts["Next · Barbell Squat"].exists)
        let repsControl = app.buttons["Increase reps by 1"]
        XCTAssertTrue(repsControl.isHittable)
        XCTAssertLessThan(repsControl.frame.maxY, app.buttons["LOG SET 2"].frame.minY)
        capture("compact-rest-next-and-last-set")
        app.buttons["rest.done"].tap()
        app.buttons["LOG SET 2"].tap()
        XCTAssertTrue(app.buttons["Expand rest timer"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.staticTexts["rest.status"].exists)
        app.buttons["rest.done"].tap()
        app.buttons["LOG SET 3"].tap()
        let edit = app.buttons["rest.editLastSet"]
        XCTAssertTrue(edit.waitForExistence(timeout: 5))
        XCTAssertEqual(edit.label, "Edit last set of Barbell Squat")
        XCTAssertEqual(app.staticTexts["runner.exerciseTitle"].label, "DUMBBELL ROW")
        XCTAssertTrue(app.staticTexts["Last set · Barbell Squat"].exists)
        XCTAssertEqual(app.staticTexts["rest.nextValues"].label, "Set 1 of 3 · 40 × 10 · lb")
        edit.tap()
        let reps = app.textFields["Reps"]
        XCTAssertTrue(reps.waitForExistence(timeout: 5))
        let old = reps.value as? String ?? ""
        reps.tap()
        // The numeric value is right-aligned; 95% falls before a one-digit
        // value. Place the caret after the final glyph before replacing it.
        reps.coordinate(withNormalizedOffset: CGVector(dx: 1, dy: 0.5))
            .withOffset(CGVector(dx: -1, dy: 0)).tap()
        reps.typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: old.count) + "6")
        XCTAssertEqual(reps.value as? String, "6")
        app.buttons["Save"].tap()
        let corrected = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "label == %@", "135 × 6 · lb"),
            object: app.staticTexts["rest.lastValues"])
        XCTAssertEqual(XCTWaiter.wait(for: [corrected], timeout: 10), .completed)
        XCTAssertEqual(edit.label, "Edit last set of Barbell Squat")
        capture("last-set-corrected-after-exercise-advance")
        app.buttons["rest.done"].tap()
        XCTAssertEqual(app.staticTexts["runner.setSummary"].label, "40 × 10 · lb")
        XCTAssertTrue(app.buttons["LOG SET 1"].exists)
    }

    func testOneSavedSetUsesSingularCompletionSummary() {
        let app = launch()
        app.buttons["LOG SET 1"].tap()
        let minimize = app.buttons["rest.minimize"]
        XCTAssertTrue(minimize.waitForExistence(timeout: 5))
        for _ in 0..<6 where !minimize.isHittable { app.swipeUp() }
        XCTAssertTrue(minimize.isHittable); minimize.tap()
        app.buttons["rest.done"].tap()
        app.buttons["today.workoutActions"].tap()
        app.buttons["Finish workout"].tap()
        let finish = app.buttons["feedback.finishWithoutChanges"]
        XCTAssertTrue(finish.waitForExistence(timeout: 5)); finish.tap()
        let summary = app.staticTexts["today.completedSummary"]
        XCTAssertTrue(summary.waitForExistence(timeout: 10))
        XCTAssertEqual(summary.label, "1 working set · 1 exercise")
    }
}
