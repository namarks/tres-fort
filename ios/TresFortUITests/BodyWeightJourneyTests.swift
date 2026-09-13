import XCTest

final class BodyWeightJourneyTests: XCTestCase {
    override func setUpWithError() throws { continueAfterFailure = false }

    private func enableWeight(_ app: XCUIApplication) {
        XCTAssertTrue(app.buttons["weight.manageAccess"].waitForExistence(timeout: 10))
        app.buttons["weight.manageAccess"].tap()
        app.switches["health.readWeight"].coordinate(withNormalizedOffset: CGVector(dx: 0.9, dy: 0.5)).tap()
        XCTAssertTrue(app.staticTexts["View measurements in Progress → Weight."].waitForExistence(timeout: 5))
        app.buttons["Done"].tap()
    }

    func testWeightConnectTrendUnitsRefreshAndDisconnect() throws {
        let app = XCUIApplication()
        app.launchEnvironment["TRESFORT_UI_FIXTURE"] = "weight"
        app.launchEnvironment["TRESFORT_UI_WEIGHT_CLEAR_ON_REFRESH"] = "1"
        app.launchArguments = ["-AppleLanguages", "(en)", "-AppleLocale", "en_US"]
        app.launch()
        enableWeight(app)
        XCTAssertTrue(app.otherElements["weight.chart"].waitForExistence(timeout: 5))
        let latest = app.descendants(matching: .any)["weight.latest"].firstMatch
        XCTAssertEqual(latest.value as? String, "176.4 lb")
        app.buttons["kg"].tap()
        XCTAssertEqual(latest.value as? String, "80.0 kg")
        app.buttons["90 days"].tap()
        let screenshot = XCTAttachment(screenshot: app.screenshot())
        screenshot.name = "Weight trend — synthetic measurements"
        screenshot.lifetime = .keepAlways
        add(screenshot)
        app.swipeUp()
        app.buttons["weight.connectOrRefresh"].tap()
        XCTAssertTrue(app.staticTexts["weight.empty"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.otherElements["weight.chart"].exists)
        app.buttons["weight.settings"].tap()
        app.switches["health.readWeight"].coordinate(withNormalizedOffset: CGVector(dx: 0.9, dy: 0.5)).tap()
        app.buttons["Done"].tap()
        XCTAssertTrue(app.buttons["weight.manageAccess"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.staticTexts["weight.empty"].exists)
    }

    func testEmptyAccessExplainsHowToEnableWeightAtLargeTextSize() throws {
        let app = XCUIApplication()
        app.launchEnvironment["TRESFORT_UI_FIXTURE"] = "weight"
        app.launchEnvironment["TRESFORT_UI_WEIGHT_EMPTY"] = "1"
        app.launchEnvironment["TRESFORT_UI_LARGE_TEXT"] = "1"
        app.launch()
        enableWeight(app)
        XCTAssertTrue(app.staticTexts["weight.empty"].waitForExistence(timeout: 5))
        let screenshot = XCTAttachment(screenshot: app.screenshot())
        screenshot.name = "Weight empty state — accessibility text"
        screenshot.lifetime = .keepAlways
        add(screenshot)
    }
}
