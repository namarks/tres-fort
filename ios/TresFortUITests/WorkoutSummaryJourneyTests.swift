import XCTest

final class WorkoutSummaryJourneyTests: XCTestCase {
    override func setUpWithError() throws { continueAfterFailure = false }

    private func launch(largeText: Bool = false) throws -> XCUIApplication {
        let url = try XCTUnwrap(Bundle(for: Self.self).url(forResource: "WorkoutSummaryPresentation", withExtension: "json"))
        let app = XCUIApplication()
        app.launchEnvironment["TRESFORT_UI_FIXTURE"] = "workout-summary"
        app.launchEnvironment["TRESFORT_UI_SUMMARY_CONTRACT"] = try String(contentsOf: url)
        if largeText { app.launchEnvironment["TRESFORT_UI_LARGE_TEXT"] = "1" }
        app.launchArguments = ["-AppleLanguages", "(en)", "-AppleLocale", "en_US"]
        app.launch()
        XCTAssertTrue(app.staticTexts["workoutSummary.duration"].waitForExistence(timeout: 10))
        return app
    }

    private func capture(_ name: String) {
        let attachment = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        attachment.name = name; attachment.lifetime = .keepAlways; add(attachment)
    }

    func testSummaryLeadsAndDetailsAppearOnlyOnce() throws {
        let app = try launch()
        XCTAssertTrue(app.staticTexts["workoutSummary.duration"].label.contains("45 min"))
        XCTAssertTrue(app.staticTexts["workoutSummary.volume"].label.contains("990 lb"))
        XCTAssertTrue(app.staticTexts["workoutSummary.reps"].label.contains("42"))
        XCTAssertFalse(app.staticTexts["Previous: 10 reps"].exists)
        XCTAssertFalse(app.staticTexts["1 sets not logged"].exists)
        XCTAssertFalse(app.staticTexts["Goblet Squat · 45 lb · 12 reps"].exists)
        capture("completed-workout-summary")
        app.buttons["workoutSummary.records"].tap()
        XCTAssertTrue(app.staticTexts["Previous: 10 reps"].waitForExistence(timeout: 5))
        app.buttons["workoutSummary.records"].tap()
        let targets = app.buttons["workoutSummary.targets"]
        for _ in 0..<8 where !targets.isHittable { app.swipeUp() }
        XCTAssertTrue(targets.isHittable)
        XCTAssertEqual(app.staticTexts.matching(identifier: "PLANK").count, 1)
        capture("completed-workout-details")
        targets.tap()
        XCTAssertTrue(app.staticTexts["1 sets not logged"].waitForExistence(timeout: 5))
    }

    func testSummaryStacksAtAccessibilityTextSize() throws {
        let app = try launch(largeText: true)
        let duration = app.staticTexts["workoutSummary.duration"]
        let volume = app.staticTexts["workoutSummary.volume"]
        XCTAssertTrue(volume.waitForExistence(timeout: 5))
        XCTAssertGreaterThan(volume.frame.minY, duration.frame.maxY)
        XCTAssertEqual(volume.frame.minX, duration.frame.minX, accuracy: 2)
        capture("completed-workout-large-text")
    }
}
