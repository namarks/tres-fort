import XCTest

final class BodyWeightJourneyTests: XCTestCase {
    override func setUpWithError() throws { continueAfterFailure = false }

    func testWeightConnectTrendUnitsRefreshAndDisconnect() throws {
        let app = XCUIApplication()
        app.launchEnvironment["TRESFORT_UI_FIXTURE"] = "weight"
        app.launchArguments = ["-AppleLanguages", "(en)", "-AppleLocale", "en_US"]
        app.launch()
        let connect = app.buttons["weight.connectOrRefresh"]
        XCTAssertTrue(connect.waitForExistence(timeout: 10))
        connect.tap()
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
        XCTAssertTrue(connect.isHittable)
        connect.tap() // fixture models source deletion / revoked read access
        XCTAssertTrue(app.staticTexts["weight.empty"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.otherElements["weight.chart"].exists)
        app.buttons["weight.disconnect"].tap()
        XCTAssertTrue(app.buttons["Connect weight"].exists)
        XCTAssertFalse(app.staticTexts["weight.empty"].exists)
    }

    func testEmptyAccessExplainsHowToEnableWeightAtLargeTextSize() throws {
        let app = XCUIApplication()
        app.launchEnvironment["TRESFORT_UI_FIXTURE"] = "weight"
        app.launchEnvironment["TRESFORT_UI_WEIGHT_EMPTY"] = "1"
        app.launchEnvironment["TRESFORT_UI_LARGE_TEXT"] = "1"
        app.launch()
        XCTAssertTrue(app.buttons["weight.connectOrRefresh"].waitForExistence(timeout: 10))
        app.buttons["weight.connectOrRefresh"].tap()
        XCTAssertTrue(app.staticTexts["weight.empty"].waitForExistence(timeout: 5))
        let screenshot = XCTAttachment(screenshot: app.screenshot())
        screenshot.name = "Weight empty state — accessibility text"
        screenshot.lifetime = .keepAlways
        add(screenshot)
    }
}
