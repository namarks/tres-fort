import XCTest

final class PlanlessAccountJourneyTests: XCTestCase {
    func testAccountWithoutServerSetupEvidenceCanEnterDirectlyWithoutCreatingTraining() {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchEnvironment["TRESFORT_UI_FIXTURE"] = "activation-manual"
        app.launchArguments = ["-AppleLanguages", "(en)", "-AppleLocale", "en_US"]
        app.launch()
        let signIn = app.buttons["Sign in with Apple"]
        XCTAssertTrue(signIn.waitForExistence(timeout: UITestWait.screen))
        signIn.tap()
        let enter = app.buttons["onboarding.continueToApp"]
        XCTAssertTrue(enter.waitForExistence(timeout: UITestWait.screen))
        XCTAssertEqual(enter.label, "Continue to app")
        XCTAssertTrue(app.buttons["Get started"].exists)
        for _ in 0..<6 where !enter.isHittable { app.swipeUp() }
        XCTAssertTrue(enter.isHittable)
        enter.tap()
        XCTAssertTrue(app.navigationBars["Today"].waitForExistence(timeout: UITestWait.screen))
        XCTAssertFalse(app.buttons["trainingSetup.next"].exists)
        let value = app.staticTexts["fixture.scenario"].value as? String ?? ""
        for counter in ["profileWrites:0", "starterWrites:0", "workoutWrites:0"] {
            XCTAssertTrue(value.split(separator: ";").contains(Substring(counter)), value)
        }
    }
}
