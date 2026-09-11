import XCTest

final class CoachingContextJourneyTests: XCTestCase {
    override func setUpWithError() throws { continueAfterFailure = false }
    func testAuthoredContextAndRecentFeedbackRetainRecordedSetSemantics() throws {
        let url = try XCTUnwrap(Bundle(for: Self.self).url(forResource: "CoachingContext", withExtension: "json"))
        let app = XCUIApplication()
        app.launchEnvironment["TRESFORT_UI_FIXTURE"] = "app-store"
        app.launchEnvironment["TRESFORT_UI_COACHING_CONTRACT"] = String(decoding: try Data(contentsOf: url), as: UTF8.self)
        app.launchArguments = ["-AppleLanguages", "(en)", "-AppleLocale", "en_US"]
        app.launch()
        XCTAssertTrue(app.tabBars.buttons["Profile"].waitForExistence(timeout: 15))
        app.tabBars.buttons["Profile"].tap()
        app.buttons["profile.trainingOverview"].tap()
        XCTAssertTrue(app.navigationBars["Training overview"].waitForExistence(timeout: 10))
        app.buttons["coaching.session.recent"].tap()
        let hold = app.staticTexts["Plank: 45s · bodyweight"]
        for _ in 0..<4 where !hold.isHittable { app.swipeUp() }
        XCTAssertTrue(hold.exists)
        XCTAssertTrue(app.staticTexts["Pull-Up: 8 reps · 30 lb assistance · RPE 7"].exists)
        XCTAssertTrue(app.staticTexts["Split Squat: 8 reps per side · 22.25 lb each hand · RPE 8.5"].exists)
        let screenshot = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        screenshot.name = "coaching-session-semantics"; screenshot.lifetime = .keepAlways; add(screenshot)
        for _ in 0..<5 where !app.buttons["coaching.plan"].isHittable { app.swipeDown() }
        app.buttons["coaching.plan"].tap()
        XCTAssertTrue(app.staticTexts.matching(NSPredicate(format: "label CONTAINS 'Autumn event'")).firstMatch.exists)
        XCTAssertTrue(app.staticTexts.matching(NSPredicate(format: "label CONTAINS 'Hotel gym only'")).firstMatch.exists)
        let stress = app.staticTexts.matching(NSPredicate(format: "label BEGINSWITH 'Stress Model:'")).firstMatch
        for _ in 0..<5 where !stress.isHittable { app.swipeUp() }
        XCTAssertTrue(stress.label.contains("Discuss back-to-back long days"))
        XCTAssertTrue(stress.label.contains("Authored, not computed"))
        XCTAssertGreaterThan(stress.frame.height, 100, "Long authored context must wrap rather than clip to one line")
        let plan = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        plan.name = "coaching-authored-context"; plan.lifetime = .keepAlways; add(plan)
    }
}
