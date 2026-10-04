import XCTest

final class BodyWeightJourneyTests: XCTestCase {
    override func setUpWithError() throws { continueAfterFailure = false }
    override func tearDownWithError() throws {
        if (testRun?.failureCount ?? 0) > 0 { print(XCUIApplication().debugDescription) }
    }

    private func launchFailure(_ failure: String, largeText: Bool = false) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchEnvironment["TRESFORT_UI_FIXTURE"] = "weight"
        app.launchEnvironment["TRESFORT_UI_WEIGHT_FAILURE"] = failure
        if largeText { app.launchEnvironment["TRESFORT_UI_LARGE_TEXT"] = "1" }
        app.launchArguments = ["-AppleLanguages", "(en)", "-AppleLocale", "en_US"]
        app.launch()
        return app
    }

    private func enableWeightWithFailure(_ app: XCUIApplication, stayInSettings: Bool = false) {
        XCTAssertTrue(app.buttons["weight.manageAccess"].waitForExistence(timeout: 10))
        app.buttons["weight.manageAccess"].tap()
        let toggle = app.switches["health.readWeight"]
        XCTAssertTrue(toggle.waitForExistence(timeout: 5))
        toggle.coordinate(withNormalizedOffset: CGVector(dx: 0.9, dy: 0.5)).tap()
        let settings = app.collectionViews.containing(.switch, identifier: "health.readWeight").firstMatch
        XCTAssertTrue(settings.staticTexts["weight.error.title"].waitForExistence(timeout: 5))
        XCTAssertEqual(toggle.value as? String, "1", "The error must preserve the weight opt-in")
        if !stayInSettings { app.buttons["Done"].tap() }
    }

    private func capture(_ name: String, app: XCUIApplication) {
        let screenshot = XCTAttachment(screenshot: app.screenshot())
        screenshot.name = name
        screenshot.lifetime = .keepAlways
        add(screenshot)
    }

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

    func testWeightReadFailureReconnectsDirectlyWithoutTogglingAccess() {
        let app = launchFailure("reconnect")
        enableWeightWithFailure(app)
        XCTAssertTrue(app.staticTexts["weight.error.title"].waitForExistence(timeout: 5))
        XCTAssertEqual(app.staticTexts["weight.error.title"].label, "Couldn’t read weight")
        XCTAssertFalse(app.staticTexts["weight.error.message"].label.localizedCaseInsensitiveContains("unlock"))
        XCTAssertFalse(app.buttons["weight.connectOrRefresh"].exists, "A failed read should offer recovery instead of repeating the same query")
        let reconnect = app.buttons["weight.recover"]
        XCTAssertTrue(reconnect.isHittable)
        XCTAssertEqual(reconnect.label, "Reconnect Apple Health")
        XCTAssertTrue(app.descendants(matching: .any)["weight.permissionHelp"].firstMatch.exists)
        capture("Weight read failure — reconnect in place", app: app)

        reconnect.tap()

        XCTAssertTrue(app.otherElements["weight.chart"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.staticTexts["weight.error.title"].exists)
        XCTAssertFalse(reconnect.exists)
        capture("Weight recovery — synthetic measurements restored", app: app)
        app.buttons["weight.settings"].tap()
        XCTAssertEqual(app.switches["health.readWeight"].value as? String, "1")
    }

    func testAppleHealthSettingsReconnectsInlineWithoutTurningWeightOff() {
        let app = launchFailure("reconnect")
        enableWeightWithFailure(app, stayInSettings: true)
        let settings = app.collectionViews.containing(.switch, identifier: "health.readWeight").firstMatch
        let reconnect = settings.buttons["weight.recover"]
        XCTAssertTrue(reconnect.isHittable)
        XCTAssertEqual(reconnect.label, "Reconnect Apple Health")
        capture("Apple Health settings — inline weight recovery", app: app)

        reconnect.tap()

        XCTAssertTrue(settings.staticTexts["View measurements in Progress → Weight."].waitForExistence(timeout: 5))
        XCTAssertEqual(app.switches["health.readWeight"].value as? String, "1")
        XCTAssertFalse(settings.staticTexts["weight.error.title"].exists)
        app.buttons["Done"].tap()
        XCTAssertTrue(app.otherElements["weight.chart"].waitForExistence(timeout: 5))
    }

    func testLockedWeightReadExplainsUnlockAndRetriesInPlace() {
        let app = launchFailure("locked")
        enableWeightWithFailure(app)
        XCTAssertTrue(app.staticTexts["weight.error.message"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["weight.error.message"].label.localizedCaseInsensitiveContains("unlock"))
        let retry = app.buttons["weight.recover"]
        XCTAssertEqual(retry.label, "Try again")
        XCTAssertTrue(retry.isHittable)
        XCTAssertFalse(app.descendants(matching: .any)["weight.permissionHelp"].firstMatch.exists)

        retry.tap()

        XCTAssertTrue(app.otherElements["weight.chart"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.staticTexts["weight.error.title"].exists)
    }

    func testReconnectRemainsReachableAtAccessibilityTextSize() {
        let app = launchFailure("reconnect", largeText: true)
        enableWeightWithFailure(app)
        XCTAssertTrue(app.staticTexts["weight.error.title"].waitForExistence(timeout: 5))
        let reconnect = app.buttons["weight.recover"]
        for _ in 0..<4 where !reconnect.isHittable { app.swipeUp() }
        XCTAssertTrue(reconnect.isHittable)
        XCTAssertEqual(reconnect.label, "Reconnect Apple Health")
        capture("Weight recovery — accessibility text", app: app)

        reconnect.tap()

        XCTAssertTrue(app.descendants(matching: .any)["weight.latest"].firstMatch.waitForExistence(timeout: 5))
        XCTAssertFalse(app.staticTexts["weight.error.title"].exists)
    }

    func testRestrictedHealthExplainsRestrictionWithoutOfferingIneffectiveReconnect() {
        let app = launchFailure("restricted")
        enableWeightWithFailure(app)
        XCTAssertTrue(app.staticTexts["weight.error.title"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.buttons["weight.recover"].exists)
        XCTAssertFalse(app.buttons["weight.connectOrRefresh"].exists)
        XCTAssertFalse(app.staticTexts["weight.error.message"].label.localizedCaseInsensitiveContains("unlock"))
        XCTAssertTrue(app.buttons["weight.settings"].isHittable)
    }
}
