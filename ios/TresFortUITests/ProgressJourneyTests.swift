import XCTest

final class ProgressJourneyTests: XCTestCase {
    override func setUpWithError() throws { continueAfterFailure = false }

    private func launch(largeText: Bool = false, empty: Bool = false) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchEnvironment["TRESFORT_UI_FIXTURE"] = "progress"
        if empty { app.launchEnvironment["TRESFORT_UI_PROGRESS_EMPTY"] = "1" }
        if largeText { app.launchEnvironment["TRESFORT_UI_LARGE_TEXT"] = "1" }
        app.launchArguments = ["-AppleLanguages", "(en)", "-AppleLocale", "en_US"]
        app.launch()
        XCTAssertTrue(app.tabBars.buttons["Progress"].waitForExistence(timeout: 15))
        app.tabBars.buttons["Progress"].tap()
        return app
    }

    private func tap(_ element: XCUIElement, in app: XCUIApplication) {
        for _ in 0..<10 where !element.exists || !element.isHittable { app.swipeUp() }
        XCTAssertTrue(element.waitForExistence(timeout: 5))
        XCTAssertTrue(element.isHittable)
        if element.elementType == .switch {
            element.coordinate(withNormalizedOffset: CGVector(dx: 0.9, dy: 0.5)).tap()
        } else { element.tap() }
    }

    private func capture(_ name: String, app: XCUIApplication) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    func testProgressTabOpensStrengthConsistencyAndOptionalHealthWeight() {
        let app = launch()
        XCTAssertTrue(app.buttons["progress.strength"].waitForExistence(timeout: 10))
        capture("Progress overview — synthetic training", app: app)
        app.buttons["progress.strength"].tap()
        XCTAssertTrue(app.navigationBars["Strength"].waitForExistence(timeout: 5))
        let exercise = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'history.exercise.'")).firstMatch
        XCTAssertTrue(exercise.waitForExistence(timeout: 5))
        exercise.tap()
        XCTAssertTrue(app.otherElements["history.progress.chart"].waitForExistence(timeout: 5))
        app.navigationBars.buttons.element(boundBy: 0).tap()
        app.navigationBars.buttons.element(boundBy: 0).tap()
        tap(app.buttons["progress.consistency"], in: app)
        XCTAssertTrue(app.staticTexts["consistency.total"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["This week so far"].exists)
        app.buttons["12 weeks"].tap()
        capture("Consistency — synthetic completed workouts", app: app)
        app.navigationBars.buttons.element(boundBy: 0).tap()
        tap(app.buttons["progress.weightSettings"], in: app)
        XCTAssertTrue(app.navigationBars["Apple Health"].waitForExistence(timeout: 5))
        tap(app.switches["health.readWeight"], in: app)
        XCTAssertTrue(app.staticTexts["View measurements in Progress → Weight."].waitForExistence(timeout: 5))
        app.buttons["Done"].tap()
        tap(app.buttons["progress.weight"], in: app)
        XCTAssertTrue(app.otherElements["weight.chart"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.buttons["Connect weight"].exists)
        capture("Weight in Progress — synthetic measurements", app: app)
        app.buttons["weight.settings"].tap()
        tap(app.switches["health.readWeight"], in: app)
        app.buttons["Done"].tap()
        XCTAssertTrue(app.buttons["weight.manageAccess"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.otherElements["weight.chart"].exists)
        app.tabBars.buttons["Calendar"].tap()
        XCTAssertTrue(app.buttons["calendar.weeklySchedule"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.buttons["calendar.exerciseProgress"].exists)
        XCTAssertFalse(app.buttons["history.weight"].exists)
    }

    func testEmptyProgressExplainsHowTrainingStartsWithoutRequiringWeight() {
        let app = launch(empty: true)
        XCTAssertTrue(app.staticTexts["Your first working set starts your progress."].waitForExistence(timeout: 10))
        tap(app.buttons["progress.consistency"], in: app)
        XCTAssertEqual(app.staticTexts["consistency.total"].label, "0 completed workouts")
        app.navigationBars.buttons.element(boundBy: 0).tap()
        XCTAssertFalse(app.buttons["progress.weight"].exists)
        XCTAssertTrue(app.buttons["progress.weightSettings"].exists)
        capture("Progress — empty training history", app: app)
    }

    func testProgressAndHealthSettingsRemainReachableAtAccessibilityTextSize() {
        let app = launch(largeText: true)
        XCTAssertTrue(app.buttons["progress.strength"].waitForExistence(timeout: 10))
        capture("Progress overview — accessibility text", app: app)
        tap(app.buttons["progress.consistency"], in: app)
        XCTAssertTrue(app.staticTexts["consistency.total"].waitForExistence(timeout: 5))
        app.navigationBars.buttons.element(boundBy: 0).tap()
        tap(app.buttons["progress.weightSettings"], in: app)
        tap(app.switches["health.readWeight"], in: app)
        app.buttons["Done"].tap()
        tap(app.buttons["progress.weight"], in: app)
        XCTAssertTrue(app.descendants(matching: .any)["weight.latest"].firstMatch.waitForExistence(timeout: 5))
        capture("Progress weight — accessibility text", app: app)
    }
}
