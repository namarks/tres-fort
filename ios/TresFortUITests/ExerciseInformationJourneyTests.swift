import XCTest

final class ExerciseInformationJourneyTests: XCTestCase {
    override func setUpWithError() throws { continueAfterFailure = false }
    override func tearDownWithError() throws {
        if (testRun?.failureCount ?? 0) > 0 { print(XCUIApplication().debugDescription) }
    }

    private func launch(_ fixture: String, large: Bool = false) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchEnvironment["TRESFORT_UI_FIXTURE"] = fixture
        if large { app.launchEnvironment["TRESFORT_UI_LARGE_TEXT"] = "1" }
        app.launchArguments = ["-AppleLanguages", "(en)", "-AppleLocale", "en_US",
                               "-restAudioCuesEnabled", "NO"]
        app.launch()
        return app
    }

    private func openInfo(_ name: String, in app: XCUIApplication) {
        let info = app.buttons["Exercise information for " + name]
        XCTAssertTrue(info.waitForExistence(timeout: 5))
        for _ in 0..<8 where !info.isHittable { app.swipeUp() }
        XCTAssertTrue(info.isHittable); info.tap()
        XCTAssertTrue(app.segmentedControls["exerciseInfo.tabs"].waitForExistence(timeout: 5))
    }

    private func history(_ app: XCUIApplication) {
        app.segmentedControls["exerciseInfo.tabs"].buttons["History"].tap()
        XCTAssertTrue(app.segmentedControls["exerciseInfo.tabs"].buttons["Technique"].isHittable)
        XCTAssertTrue(app.buttons["exerciseInfo.done"].isHittable)
    }

    private func capture(_ name: String) {
        let attachment = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        attachment.name = name; attachment.lifetime = .keepAlways; add(attachment)
    }

    func testWorkoutPreviewShowsTechniqueComparableSessionAndFullHistory() {
        let app = launch("app-store")
        let preview = app.buttons["today.viewWorkout"]
        XCTAssertTrue(preview.waitForExistence(timeout: 10)); preview.tap()
        openInfo("Barbell Squat", in: app)
        XCTAssertTrue(app.staticTexts["MUSCLES"].exists)
        capture("exercise-information-technique")
        history(app)
        XCTAssertEqual(app.staticTexts["exerciseInfo.history.date"].label, "2026-09-05")
        XCTAssertTrue(app.staticTexts["135 lb · 5 reps"].exists)
        app.segmentedControls["exerciseInfo.tabs"].buttons["Technique"].tap()
        XCTAssertTrue(app.staticTexts["MUSCLES"].exists)
        history(app)
        capture("exercise-information-history")
        app.buttons["exerciseInfo.history.full"].tap()
        XCTAssertTrue(app.staticTexts["PROGRESS"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons.matching(NSPredicate(format: "label BEGINSWITH 'SESSION · 2026-09-05'")).firstMatch.exists)
        app.navigationBars.buttons["BackButton"].tap()
        app.buttons["exerciseInfo.done"].tap()
        XCTAssertTrue(app.buttons["workoutDetails.start"].exists)
    }

    func testRunnerRetainsDraftValuesAndRestWhileViewingInformation() {
        let app = launch("app-store")
        let start = app.buttons["today.startWorkout"]
        XCTAssertTrue(start.waitForExistence(timeout: 10)); start.tap()
        XCTAssertTrue(app.buttons["LOG SET 1"].waitForExistence(timeout: 5))
        app.buttons["Increase reps by 1"].tap()
        let draft = app.staticTexts["runner.setSummary"].label
        openInfo("Barbell Squat", in: app)
        history(app)
        app.buttons["exerciseInfo.done"].tap()
        XCTAssertEqual(app.staticTexts["runner.setSummary"].label, draft)
        app.buttons["LOG SET 1"].tap()
        let minimize = app.buttons["rest.minimize"]
        XCTAssertTrue(minimize.waitForExistence(timeout: 5)); minimize.tap()
        for _ in 0..<4 where !app.buttons["Exercise information for Barbell Squat"].isHittable { app.swipeDown() }
        openInfo("Barbell Squat", in: app)
        history(app)
        XCTAssertEqual(app.staticTexts["exerciseInfo.history.date"].label, "2026-09-05")
        app.buttons["exerciseInfo.done"].tap()
        XCTAssertTrue(app.buttons["rest.done"].exists)
        XCTAssertTrue(app.buttons["LOG SET 2"].exists)
        XCTAssertEqual(app.staticTexts["runner.setSummary"].label, draft)
    }

    func testActiveTimedSetContinuesWhileInformationIsOpen() {
        let app = launch("timed-navigation")
        let start = app.buttons["START SET 1"]
        XCTAssertTrue(start.waitForExistence(timeout: 10)); start.tap()
        let remaining = app.staticTexts["runner.timer.remaining"]
        XCTAssertTrue(remaining.waitForExistence(timeout: 5))
        let before = Int(remaining.label.dropLast())!
        openInfo("Stationary Bike", in: app)
        XCTAssertTrue(app.staticTexts["Log time in seconds."].exists)
        history(app)
        XCTAssertTrue(app.staticTexts["exerciseInfo.history.empty"].exists)
        app.buttons["exerciseInfo.done"].tap()
        XCTAssertTrue(remaining.waitForExistence(timeout: 5))
        XCTAssertLessThan(Int(remaining.label.dropLast())!, before)
        XCTAssertFalse(start.exists)
        XCTAssertEqual(app.staticTexts["fixture.scenario"].value as? String, "bike:0;other:0;seconds:0;warmup:0")
    }

    func testCreationInfoAtLargeTextPreservesSearchFilterAndSelection() {
        let app = launch("empty", large: true)
        let create = app.buttons["Create a workout"]
        XCTAssertTrue(create.waitForExistence(timeout: 10)); create.tap()
        app.buttons["Upper body"].tap()
        let search = app.textFields["exercisePicker.search"]
        search.tap(); search.typeText("bp\n")
        openInfo("Bench Press", in: app)
        history(app)
        XCTAssertTrue(app.staticTexts["exerciseInfo.history.empty"].exists)
        app.segmentedControls["exerciseInfo.tabs"].buttons["Technique"].tap()
        XCTAssertTrue(app.staticTexts["MUSCLES"].exists)
        history(app)
        capture("exercise-information-empty-large-text")
        app.buttons["exerciseInfo.done"].tap()
        XCTAssertEqual(search.value as? String, "bp")
        XCTAssertTrue(app.buttons["Upper body"].isSelected)
        XCTAssertFalse(app.buttons["createWorkout.review"].isEnabled)
        app.buttons["exercisePicker.exercise.synthetic-upper"].tap()
        XCTAssertEqual(app.buttons["createWorkout.review"].label, "Review workout (1)")
        openInfo("Bench Press", in: app)
        app.buttons["exerciseInfo.done"].tap()
        XCTAssertTrue(app.buttons["exercisePicker.exercise.synthetic-upper"].isSelected)
        XCTAssertEqual(app.buttons["createWorkout.review"].label, "Review workout (1)")
    }

    func testAddAndWarmupInfoDoesNotNavigateToConfiguration() {
        let app = launch("library")
        let library = app.buttons["today.chooseWorkout"]
        XCTAssertTrue(library.waitForExistence(timeout: 10)); library.tap()
        app.buttons["Actions for Gym"].tap()
        app.buttons["Edit exercises"].tap()
        for action in ["Add exercise", "Add warm-up"] {
            app.buttons["editor.actions"].tap(); app.buttons[action].tap()
            XCTAssertTrue(app.navigationBars[action].waitForExistence(timeout: 5))
            app.buttons["Core"].tap()
            openInfo("Plank", in: app)
            XCTAssertTrue(app.staticTexts["Log time in seconds."].exists)
            app.buttons["exerciseInfo.done"].tap()
            XCTAssertTrue(app.navigationBars[action].exists)
            XCTAssertTrue(app.buttons["Core"].isSelected)
            XCTAssertFalse(app.buttons["Add to workout"].exists)
            app.navigationBars[action].buttons["Cancel"].tap()
        }
    }

    func testSwapInfoDoesNotSelectAndRunnerUsesReplacementHistory() {
        let app = launch("workout-swap")
        let swap = app.buttons["runner.swap-exercise"]
        XCTAssertTrue(swap.waitForExistence(timeout: 10))
        for _ in 0..<8 where !swap.isHittable { app.swipeUp() }
        swap.tap()
        openInfo("Dumbbell Goblet Squat", in: app)
        history(app)
        XCTAssertTrue(app.staticTexts["exerciseInfo.history.empty"].exists)
        app.buttons["exerciseInfo.done"].tap()
        XCTAssertFalse(app.buttons["runner.confirm-swap"].isEnabled)
        app.buttons.containing(.staticText, identifier: "Dumbbell Goblet Squat").firstMatch.tap()
        app.buttons["runner.confirm-swap"].tap()
        XCTAssertTrue(app.staticTexts["DUMBBELL GOBLET SQUAT"].waitForExistence(timeout: 5))
        openInfo("Dumbbell Goblet Squat", in: app)
        history(app)
        XCTAssertTrue(app.staticTexts["exerciseInfo.history.empty"].exists)
        XCTAssertFalse(app.buttons["exerciseInfo.history.full"].exists)
        app.buttons["exerciseInfo.done"].tap()
        XCTAssertTrue(app.buttons["LOG SET 2"].exists)
        XCTAssertEqual(app.staticTexts["fixture.scenario"].value as? String, "original:1;replacement:0;plan:1")
    }
}
