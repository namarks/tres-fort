import XCTest

final class MemberActivationJourneyTests: XCTestCase {
    override func setUpWithError() throws { continueAfterFailure = false }

    override func tearDownWithError() throws {
        if (testRun?.failureCount ?? 0) > 0 {
            print(XCUIApplication().debugDescription)
            let image = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
            image.name = "activation-failure"; image.lifetime = .keepAlways; add(image)
        }
    }

    private func launch(_ fixture: String, retry: Bool = false) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchEnvironment["TRESFORT_UI_FIXTURE"] = fixture
        if retry {
            app.launchEnvironment["TRESFORT_UI_AUTH_RETRY"] = "1"
            app.launchEnvironment["TRESFORT_UI_INVITE_RETRY"] = "1"
        }
        app.launchArguments = ["-AppleLanguages", "(en)", "-AppleLocale", "en_US"]
        app.launch()
        XCTAssertTrue(app.staticTexts["fixture.scenario"].waitForExistence(timeout: 10))
        return app
    }

    private func tap(_ element: XCUIElement, in app: XCUIApplication,
                     file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertTrue(element.waitForExistence(timeout: 10), element.description, file: file, line: line)
        for _ in 0..<12 {
            if element.isHittable { element.tap(); return }
            app.swipeUp()
        }
        XCTFail("Control is not reachable: \(element.description)", file: file, line: line)
    }

    private func onboard(_ app: XCUIApplication, invited: Bool = false) {
        tap(app.buttons["Get started"], in: app)
        if !invited { tap(app.buttons["I don't have a code"], in: app) }
        tap(app.buttons["Skip for now"], in: app)
        XCTAssertTrue(app.staticTexts["Choose your first step"].waitForExistence(timeout: 5))
    }

    private func completeFirstWorkout(_ app: XCUIApplication) {
        if app.buttons["today.startWorkout"].exists {
            tap(app.buttons["today.startWorkout"], in: app)
        } else {
            tap(app.buttons["today.chooseWorkout"], in: app)
            tap(app.buttons["library.workout.synthetic-day"], in: app)
            tap(app.buttons["workoutDetails.start"], in: app)
        }
        // Real entry asks for rest-notification permission before starting.
        // Exercise that prompt on this disposable simulator; existence waits
        // alone do not trigger XCTest's default interruption handler.
        let allow = XCUIApplication(bundleIdentifier: "com.apple.springboard").alerts.buttons["Allow"]
        if allow.waitForExistence(timeout: 3) { allow.tap() }
        tap(app.buttons["LOG SET 1"], in: app)
        if app.buttons["rest.done"].waitForExistence(timeout: 3) {
            tap(app.buttons["rest.done"], in: app)
        }
        tap(app.buttons["FINISH"], in: app)
        XCTAssertTrue(app.staticTexts["WORKOUT COMPLETE"].waitForExistence(timeout: 10))
        let image = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        image.name = "activation-first-completion"; image.lifetime = .keepAlways; add(image)
    }

    func testOwnerEntryReachesFirstCompletedWorkout() {
        let app = launch("activation-owner")
        XCTAssertTrue(app.buttons["app.privacy-policy"].isHittable)
        XCTAssertTrue(app.buttons["Contact support"].isHittable)
        tap(app.buttons["Sign in with Apple"], in: app)
        onboard(app)
        tap(app.buttons["Enter Très Fort"], in: app)
        completeFirstWorkout(app)
    }

    func testInvitedEntrySurvivesSignInAndPreviewRetryThenCompletesWorkout() {
        let app = launch("activation-invite", retry: true)
        XCTAssertTrue(app.staticTexts["Your group invite will be ready after sign-in and setup."].exists)
        tap(app.buttons["Sign in with Apple"], in: app)
        XCTAssertTrue(app.buttons["Sign in with Apple"].waitForExistence(timeout: 10))
        tap(app.buttons["Sign in with Apple"], in: app)
        onboard(app, invited: true)
        tap(app.buttons["Enter Très Fort"], in: app)
        let retry = app.buttons["Try again"]
        XCTAssertTrue(retry.waitForExistence(timeout: 10))
        XCTAssertGreaterThanOrEqual(retry.frame.height, 44, "The retry button itself must own its full touch target")
        // Tap below the text, inside the button's expanded touch target.
        XCTAssertTrue(retry.isHittable)
        retry.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.85)).tap()
        tap(app.buttons["Join Synthetic Crew"], in: app)
        XCTAssertTrue(app.tabBars.buttons["Group"].isSelected)
        tap(app.tabBars.buttons["Today"], in: app)
        completeFirstWorkout(app)
    }

    func testIndependentCoachIntentReturnsToPersonalSetupThenCompletesWorkout() {
        let app = launch("activation-coach")
        tap(app.buttons["Set up my coach"], in: app)
        XCTAssertTrue(app.staticTexts["Sign in to continue to Coach Connect."].exists)
        tap(app.buttons["Sign in with Apple"], in: app)
        onboard(app)
        tap(app.buttons["Enter Très Fort"], in: app)
        XCTAssertTrue(app.navigationBars["Connect your coach"].waitForExistence(timeout: 10))
        XCTAssertTrue(app.staticTexts["Your coach is connected"].waitForExistence(timeout: 10))
        XCTAssertTrue(app.staticTexts["coach.data-sharing"].exists)
        tap(app.navigationBars["Connect your coach"].buttons["Done"], in: app)
        tap(app.tabBars.buttons["Today"], in: app)
        completeFirstWorkout(app)
    }

    func testInviteAndCoachChoicesAreDeliveredOnceInOrder() {
        let app = launch("activation-invite")
        tap(app.buttons["Sign in with Apple"], in: app)
        onboard(app, invited: true)
        tap(app.buttons["Set up my coach"], in: app)
        tap(app.buttons["Join Synthetic Crew"], in: app)
        XCTAssertTrue(app.navigationBars["Connect your coach"].waitForExistence(timeout: 10))
        tap(app.navigationBars["Connect your coach"].buttons["Done"], in: app)
        tap(app.tabBars.buttons["Group"], in: app)
        XCTAssertTrue(app.staticTexts["SYNTHETIC CREW"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.buttons["Join Synthetic Crew"].exists)
    }

    func testManualOnlyMemberBuildsAndCompletesFirstWorkout() {
        let app = launch("activation-manual")
        tap(app.buttons["Sign in with Apple"], in: app)
        onboard(app)
        tap(app.buttons["Build my first workout"], in: app)
        tap(app.buttons["Create workout"], in: app)
        XCTAssertTrue(app.navigationBars["Edit Workout A"].waitForExistence(timeout: 10))
        tap(app.buttons["editor.actions"], in: app)
        tap(app.buttons["Add exercise"], in: app)
        tap(app.buttons.containing(.staticText, identifier: "Barbell Squat").firstMatch, in: app)
        let sets = app.steppers["3 sets"]
        XCTAssertTrue(sets.waitForExistence(timeout: 5))
        sets.buttons["Decrement"].tap()
        app.steppers["2 sets"].buttons["Decrement"].tap()
        tap(app.buttons["Add to workout"], in: app)
        tap(app.navigationBars["Edit Workout A"].buttons["Done"], in: app)
        tap(app.navigationBars["Workouts"].buttons["Done"], in: app)
        completeFirstWorkout(app)
        tap(app.tabBars.buttons["Profile"], in: app)
        tap(app.buttons.containing(.staticText, identifier: "Set up your Claude coach").firstMatch, in: app)
        XCTAssertTrue(app.navigationBars["Connect your coach"].waitForExistence(timeout: 5))
    }

    func testEmptyTodayOffersCoachSetupDirectly() {
        let app = launch("activation-manual")
        tap(app.buttons["Sign in with Apple"], in: app)
        onboard(app)
        tap(app.buttons["Enter Très Fort"], in: app)
        XCTAssertTrue(app.buttons["Create a workout"].waitForExistence(timeout: 10))
        tap(app.buttons["Set up my coach"], in: app)
        XCTAssertTrue(app.navigationBars["Connect your coach"].waitForExistence(timeout: 10))
        tap(app.buttons["Generate connect code"], in: app)
        XCTAssertTrue(app.buttons["Generate a new code"].waitForExistence(timeout: 10))
    }

    func testColdAndCachedEmptyFailuresOfferRecoveryWithoutCreation() {
        for fixture in ["load-failure", "cached-empty"] {
            let app = launch(fixture)
            XCTAssertTrue(app.buttons["Try again"].waitForExistence(timeout: 10))
            XCTAssertFalse(app.staticTexts["NO PLAN YET"].exists)
            XCTAssertFalse(app.buttons["Create a workout"].exists)
            tap(app.buttons["Try again"], in: app)
            XCTAssertTrue(app.buttons["Try again"].waitForExistence(timeout: 10))
            app.terminate()
        }
        let cached = launch("cached-plan")
        XCTAssertFalse(cached.staticTexts["NO PLAN YET"].exists)
        XCTAssertFalse(cached.buttons["Create a workout"].exists)
    }

    func testServerFailureRetryCanVerifyAnEmptyAccount() {
        let app = launch("server-failure")
        XCTAssertTrue(app.buttons["Try again"].waitForExistence(timeout: 10))
        XCTAssertFalse(app.buttons["Create a workout"].exists)
        tap(app.buttons["Try again"], in: app)
        XCTAssertTrue(app.buttons["Create a workout"].waitForExistence(timeout: 10))
    }
}
