import XCTest

final class ExerciseDiscoveryJourneyTests: XCTestCase {
    override func setUpWithError() throws { continueAfterFailure = false }
    override func tearDownWithError() throws {
        if (testRun?.failureCount ?? 0) > 0 { print(XCUIApplication().debugDescription) }
    }

    private func launch(_ fixture: String) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchEnvironment["TRESFORT_UI_FIXTURE"] = fixture
        app.launchArguments = ["-AppleLanguages", "(en)", "-AppleLocale", "en_US", "-restAudioCuesEnabled", "NO"]
        app.launch()
        return app
    }

    private func reveal(_ element: XCUIElement, in app: XCUIApplication) {
        _ = element.waitForExistence(timeout: 2)
        for _ in 0..<20 where !element.isHittable {
            let results = app.collectionViews["exercisePicker.results"]
            let surface = results.exists ? results : (app.scrollViews.firstMatch.exists ? app.scrollViews.firstMatch : app)
            // A List's accessibility frame includes its bottom safe-area inset.
            // Keep drag gestures above the pinned confirmation/selection.
            let selection = app.staticTexts["runner.swap-selection"]
            let confirm = app.buttons["runner.confirm-swap"]
            let bottom = selection.exists ? selection.frame.minY : (confirm.exists ? confirm.frame.minY : surface.frame.maxY)
            let top = surface.frame.minY
            let height = min(surface.frame.maxY, bottom) - top
            let down = element.exists && element.frame.midY < top + height / 2
            let origin = app.coordinate(withNormalizedOffset: .zero)
            let start = origin.withOffset(CGVector(dx: surface.frame.midX, dy: top + height * (down ? 0.3 : 0.8)))
            let end = origin.withOffset(CGVector(dx: surface.frame.midX, dy: top + height * (down ? 0.8 : 0.3)))
            start.press(forDuration: 0.1, thenDragTo: end)
        }
        XCTAssertTrue(element.isHittable)
    }

    private func tap(_ element: XCUIElement, in app: XCUIApplication) {
        reveal(element, in: app); element.tap()
    }

    private func region(_ name: String, in app: XCUIApplication) {
        let button = app.buttons[name]
        for _ in 0..<3 where !button.isHittable { app.scrollViews["exercisePicker.regions"].swipeLeft() }
        XCTAssertTrue(button.isHittable); button.tap()
    }

    private func search(_ query: String, in app: XCUIApplication) {
        let field = app.textFields["exercisePicker.search"]
        XCTAssertTrue(field.waitForExistence(timeout: 5)); field.tap(); field.typeText(query + "\n")
    }

    private func inspect(_ name: String, in app: XCUIApplication) {
        tap(app.buttons["Exercise information for " + name], in: app)
        XCTAssertTrue(app.segmentedControls["exerciseInfo.tabs"].waitForExistence(timeout: 5))
        app.segmentedControls["exerciseInfo.tabs"].buttons["History"].tap()
        app.buttons["exerciseInfo.done"].tap()
    }

    private func capture(_ name: String) {
        let attachment = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        attachment.name = name; attachment.lifetime = .keepAlways; add(attachment)
    }

    func testSwapAliasFilterInfoAndCancellationPreserveSession() {
        let app = launch("workout-swap")
        tap(app.buttons["runner.swap-exercise"], in: app)
        let replacement = app.buttons["exercisePicker.exercise.synthetic-replacement"]
        XCTAssertTrue(replacement.waitForExistence(timeout: 5))
        XCTAssertLessThan(replacement.frame.minY, app.buttons["exercisePicker.exercise.synthetic-upper"].frame.minY)
        XCTAssertFalse(app.buttons["exercisePicker.exercise.synthetic-exercise"].exists)
        XCTAssertFalse(app.buttons["exercisePicker.exercise.synthetic-hold"].exists)
        XCTAssertFalse(app.buttons["exercisePicker.exercise.synthetic-cardio"].exists)
        region("Lower body", in: app)
        search("front loaded", in: app)
        inspect("Dumbbell Goblet Squat", in: app)
        XCTAssertEqual(app.textFields["exercisePicker.search"].value as? String, "front loaded")
        XCTAssertTrue(app.buttons["Lower body"].isSelected)
        XCTAssertFalse(app.buttons["runner.confirm-swap"].isEnabled)
        tap(replacement, in: app)
        inspect("Dumbbell Goblet Squat", in: app)
        XCTAssertTrue(replacement.isSelected)
        XCTAssertEqual(app.staticTexts["runner.swap-selection"].label,
                       "Replace Barbell Squat with Dumbbell Goblet Squat.")
        capture("swap-alias-selection")
        app.buttons["Cancel"].tap()
        XCTAssertTrue(app.staticTexts["BARBELL SQUAT"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["LOG SET 2"].exists)
        XCTAssertEqual(app.staticTexts["fixture.scenario"].value as? String, "original:1;replacement:0;plan:1")
    }

    func testSwapEmptyResetRetainsCompatibilityAndCanConfirmAliasReplacement() {
        let app = launch("workout-swap")
        tap(app.buttons["runner.swap-exercise"], in: app)
        region("Upper body", in: app)
        search("front loaded", in: app)
        reveal(app.staticTexts["No matching exercises"], in: app)
        tap(app.buttons["Clear search and filters"], in: app)
        XCTAssertEqual(app.textFields["exercisePicker.search"].value as? String, "Search exercises")
        XCTAssertTrue(app.buttons["All"].isSelected)
        XCTAssertFalse(app.buttons["exercisePicker.exercise.synthetic-exercise"].exists)
        XCTAssertFalse(app.buttons["exercisePicker.exercise.synthetic-hold"].exists)
        XCTAssertFalse(app.buttons["exercisePicker.exercise.synthetic-cardio"].exists)
        region("Lower body", in: app)
        search("front loaded", in: app)
        let replacement = app.buttons["exercisePicker.exercise.synthetic-replacement"]
        tap(replacement, in: app)
        inspect("Dumbbell Goblet Squat", in: app)
        XCTAssertTrue(replacement.isSelected)
        XCTAssertTrue(app.buttons["Lower body"].isSelected)
        XCTAssertEqual(app.textFields["exercisePicker.search"].value as? String, "front loaded")
        XCTAssertEqual(app.buttons["runner.confirm-swap"].label, "Swap for this session")
        capture("swap-filtered-confirmation")
        app.buttons["runner.confirm-swap"].tap()
        XCTAssertTrue(app.staticTexts["DUMBBELL GOBLET SQUAT"].waitForExistence(timeout: 5))
        tap(app.buttons["LOG SET 2"], in: app)
        expectation(for: NSPredicate(format: "value == %@", "original:1;replacement:1;plan:1"),
                    evaluatedWith: app.staticTexts["fixture.scenario"])
        waitForExpectations(timeout: 5)
    }

    func testCreationReviewReturnPreservesAliasFilterAndSelection() {
        let app = launch("empty")
        tap(app.buttons["Create a workout"], in: app)
        region("Upper body", in: app)
        search("bp", in: app)
        tap(app.buttons["exercisePicker.exercise.synthetic-upper"], in: app)
        app.buttons["createWorkout.review"].tap()
        XCTAssertTrue(app.textFields["createWorkout.name"].waitForExistence(timeout: 5))
        app.navigationBars.buttons["BackButton"].tap()
        XCTAssertEqual(app.textFields["exercisePicker.search"].value as? String, "bp")
        XCTAssertTrue(app.buttons["Upper body"].isSelected)
        XCTAssertTrue(app.buttons["exercisePicker.exercise.synthetic-upper"].isSelected)
        inspect("Bench Press", in: app)
        XCTAssertEqual(app.buttons["createWorkout.review"].label, "Review workout (1)")
        app.navigationBars["Add exercises"].buttons["Cancel"].tap()
        XCTAssertTrue(app.buttons["Create a workout"].exists)
    }

    func testAddAndWarmupReturnFromConfigurationRetainsSearchAndNamedSavedWorkout() {
        let app = launch("library")
        tap(app.buttons["today.chooseWorkout"], in: app)
        app.buttons["Actions for Gym"].tap(); app.buttons["Edit exercises"].tap()
        for action in ["Add exercise", "Add warm-up"] {
            app.buttons["editor.actions"].tap(); app.buttons[action].tap()
            region("Upper body", in: app)
            search("bp", in: app)
            inspect("Bench Press", in: app)
            tap(app.staticTexts["Bench Press"], in: app)
            XCTAssertTrue(app.navigationBars["Bench Press"].waitForExistence(timeout: 5))
            XCTAssertEqual(app.staticTexts["exercisePicker.savedWorkout"].label, "Saved workout · Gym")
            app.navigationBars["Bench Press"].buttons["BackButton"].tap()
            XCTAssertEqual(app.textFields["exercisePicker.search"].value as? String, "bp")
            XCTAssertTrue(app.buttons["Upper body"].isSelected)
            app.navigationBars[action].buttons["Cancel"].tap()
            XCTAssertTrue(app.navigationBars["Edit Gym"].exists)
        }
        XCTAssertFalse(app.staticTexts["Bench Press"].exists)
    }
}
