import XCTest

final class HistoryJourneyTests: XCTestCase {
    override func setUpWithError() throws { continueAfterFailure = false }

    func testSmallCachedHistoryJourney() throws { try run("history-small") }
    func testFiveYearCachedHistoryJourney() throws { try run("history-large") }

    func testOneProgressPanelSwitchesBetweenTrendAndSingleDaySummary() throws {
        let app = XCUIApplication()
        app.launchEnvironment["TRESFORT_UI_FIXTURE"] = "history-progress"
        app.launchArguments = ["-AppleLanguages", "(en)", "-AppleLocale", "en_US"]
        app.launch()
        XCTAssertTrue(app.buttons["calendar.exerciseProgress"].waitForExistence(timeout: 15))
        app.buttons["calendar.exerciseProgress"].tap()
        app.buttons["history.exercise.exercise-0"].tap()
        let chart = app.descendants(matching: .any).matching(identifier: "history.progress.chart")
        XCTAssertTrue(chart.firstMatch.waitForExistence(timeout: 5))
        XCTAssertEqual(chart.count, 1)
        XCTAssertTrue(app.buttons.matching(NSPredicate(format: "label BEGINSWITH 'SESSION · 2026-07-01'")).firstMatch.isHittable)
        let overall = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        overall.name = "history-single-progress-panel"
        overall.lifetime = .keepAlways
        add(overall)

        let selector = app.buttons["history.progress.selector"]
        selector.tap()
        app.buttons["33 lb · Best reps"].tap()
        XCTAssertTrue(app.staticTexts["history.progress.summary"].waitForExistence(timeout: 5))
        XCTAssertEqual(app.staticTexts["history.progress.summary"].label, "8 reps · 2026-06-14")
        XCTAssertFalse(chart.firstMatch.exists)
        let sparse = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        sparse.name = "history-single-day-summary"
        sparse.lifetime = .keepAlways
        add(sparse)

        selector.tap()
        app.buttons["35 lb · Best reps"].tap()
        XCTAssertTrue(chart.firstMatch.waitForExistence(timeout: 5))
        XCTAssertEqual(chart.count, 1)
        XCTAssertFalse(app.staticTexts["history.progress.summary"].exists)
        selector.tap()
        app.buttons["Estimated 1RM"].tap()
        XCTAssertTrue(chart.firstMatch.waitForExistence(timeout: 5))
        XCTAssertEqual(chart.count, 1)
        app.terminate()
    }

    private func run(_ fixture: String) throws {
        let app = XCUIApplication()
        app.launchEnvironment["TRESFORT_UI_FIXTURE"] = fixture
        app.launchEnvironment["TRESFORT_UI_REUSE_HISTORY"] = "0"
        let expectedCount = fixture == "history-small" ? "288 sets" : "24960 sets"
        app.launchArguments = ["-AppleLanguages", "(en)", "-AppleLocale", "en_US"]
        app.launch() // Seed once; excluded from cached cold launch samples.
        XCTAssertTrue(app.buttons["calendar.exerciseProgress"].waitForExistence(timeout: 15))
        XCTAssertEqual(app.staticTexts["fixture.scenario"].value as? String, expectedCount, "Seed must be loaded before terminating")
        app.terminate()
        app.launchEnvironment["TRESFORT_UI_REUSE_HISTORY"] = "1"
        for iteration in 0..<2 {
            var times: [String: Double] = [:]
            var start = Date()
            app.launch()
            XCTAssertTrue(app.buttons["calendar.exerciseProgress"].waitForExistence(timeout: 15))
            XCTAssertEqual(app.staticTexts["fixture.scenario"].value as? String, expectedCount, "Cached launch must retain seeded rows")
            times["cached_launch_to_calendar_wall_ms"] = Date().timeIntervalSince(start) * 1_000
            start = Date()
            app.swipeUp()
            times["calendar_swipe_wall_ms"] = Date().timeIntervalSince(start) * 1_000
            start = Date()
            app.buttons["calendar.exerciseProgress"].tap()
            let row = app.buttons.matching(identifier: "history.exercise.exercise-0").firstMatch
            // Only a viewport is built eagerly; scroll to a real history row.
            for _ in 0..<12 where !row.exists || !row.isHittable { app.swipeUp() }
            XCTAssertTrue(row.waitForExistence(timeout: 5))
            times["exercise_list_and_scroll_wall_ms"] = Date().timeIntervalSince(start) * 1_000
            start = Date()
            row.tap()
            XCTAssertTrue(app.navigationBars["Exercise 0"].waitForExistence(timeout: 5))
            times["exercise_detail_wall_ms"] = Date().timeIntervalSince(start) * 1_000
            let capture = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
            capture.name = "\(fixture)-detail-\(iteration)"
            capture.lifetime = .keepAlways
            add(capture)
            let result: [String: Any] = ["fixture": fixture, "iteration": iteration, "samples": times]
            print("HISTORY_UI_PERF " + String(decoding: try JSONSerialization.data(withJSONObject: result, options: [.sortedKeys]), as: UTF8.self))
            app.terminate()
        }
    }
}
