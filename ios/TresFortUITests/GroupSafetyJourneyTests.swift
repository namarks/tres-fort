import XCTest

final class GroupSafetyJourneyTests: XCTestCase {
    override func setUpWithError() throws { continueAfterFailure = false }
    override func tearDownWithError() throws {
        if (testRun?.failureCount ?? 0) > 0 {
            print(XCUIApplication().debugDescription)
            let image = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
            image.name = "group-safety-failure"; image.lifetime = .keepAlways; add(image)
        }
    }

    private func launch() -> XCUIApplication {
        let app = XCUIApplication()
        app.launchEnvironment["TRESFORT_UI_FIXTURE"] = "group-safety"
        app.launchArguments = ["-AppleLanguages", "(en)", "-AppleLocale", "en_US"]
        app.launch()
        XCTAssertTrue(app.staticTexts["fixture.scenario"].waitForExistence(timeout: UITestWait.screen))
        return app
    }
    private func tap(_ element: XCUIElement, app: XCUIApplication) {
        _ = element.waitForExistence(timeout: 2)
        for _ in 0..<8 {
            if element.exists && element.isHittable { element.tap(); return }
            app.swipeUp()
        }
        XCTFail("Control unreachable: \(element)")
    }

    func testReportFallbackBlockAndUnblock() {
        let app = launch()
        tap(app.tabBars.buttons["Group"], app: app)
        tap(app.buttons.matching(NSPredicate(format: "label CONTAINS %@", "Evening walk")).firstMatch, app: app)
        tap(app.buttons["Group safety options"], app: app)
        tap(app.buttons["Report"], app: app)
        XCTAssertTrue(app.buttons["Draft report email"].waitForExistence(timeout: UITestWait.screen))
        tap(app.buttons["Copy report reference"], app: app)
        XCTAssertTrue(app.staticTexts["Reference copied. Include it in your email to support."].exists)
        let screenshot = XCTAttachment(screenshot: app.screenshot())
        screenshot.name = "group-report"; screenshot.lifetime = .keepAlways; add(screenshot)
        tap(app.buttons["Block member"], app: app)
        tap(app.sheets.buttons["Block member"], app: app)
        if app.buttons["Done"].waitForExistence(timeout: 3) { app.buttons["Done"].tap() }
        // The source row and any already-open detail must stop displaying it.
        XCTAssertFalse(app.staticTexts["A gentle loop"].exists)
        app.swipeDown()
        XCUIDevice.shared.press(.home)
        app.activate()
        XCTAssertFalse(app.staticTexts["Sample member"].exists)
        tap(app.tabBars.buttons["Profile"], app: app)
        tap(app.buttons["Group safety"], app: app)
        tap(app.buttons["Unblock"], app: app)
        tap(app.sheets.buttons["Unblock"], app: app)
        XCTAssertTrue(app.staticTexts["No blocked members"].waitForExistence(timeout: UITestWait.screen))
    }

    func testOperatorCanEnterReportMemberIDAndRestrictSharing() {
        let app = launch()
        tap(app.tabBars.buttons["Profile"], app: app)
        tap(app.buttons["Group safety"], app: app)
        let field = app.textFields["Member ID from report"]
        tap(field, app: app)
        field.typeText("c3223561-0e27-4727-b369-681078533ca6")
        tap(app.buttons["Restrict sharing"], app: app)
        tap(app.sheets.buttons["Restrict sharing"], app: app)
        XCTAssertTrue(app.staticTexts["Group sharing restricted."].waitForExistence(timeout: UITestWait.screen))
    }
}
