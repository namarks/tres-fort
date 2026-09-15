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

    private func launch(_ fixture: String, retry: Bool = false, pendingSetup: Bool = false, starterUsed: Bool = false, pendingStage: String? = nil, captureLinks: Bool = false) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchEnvironment["TRESFORT_UI_FIXTURE"] = fixture
        if captureLinks { app.launchEnvironment["TRESFORT_UI_CAPTURE_LINKS"] = "1" }
        if let pendingStage { app.launchEnvironment["TRESFORT_UI_PENDING_TRAINING_STAGE"] = pendingStage }
        if pendingSetup { app.launchEnvironment["TRESFORT_UI_PENDING_TRAINING_PROFILE"] = "1" }
        if starterUsed { app.launchEnvironment["TRESFORT_UI_STARTER_ALREADY_USED"] = "1" }
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

    // Form rows below the viewport are not materialized in the accessibility
    // tree yet. Scroll before requiring existence for the longer coach setup.
    private func scrollAndTap(_ element: XCUIElement, in app: XCUIApplication,
                              file: StaticString = #filePath, line: UInt = #line) {
        for _ in 0..<8 {
            if element.exists && element.isHittable {
                element.tap()
                return
            }
            app.swipeUp()
        }
        XCTFail("Control is not reachable after scrolling: \(element.description)", file: file, line: line)
    }

    func testMobileCoachApprovalRequiresExplicitDecision() {
        let app = launch("coach-approval")
        XCTAssertTrue(app.staticTexts["Review AI access"].waitForExistence(timeout: 10))
        XCTAssertTrue(app.staticTexts["App name supplied by the connecting client: Synthetic AI app"].exists)
        XCTAssertFalse(app.buttons["coach-approval.continue"].exists)
        let image = XCTAttachment(screenshot: app.screenshot())
        image.name = "mobile-coach-consent"; image.lifetime = .keepAlways; add(image)
        scrollAndTap(app.buttons["coach-approval.allow"], in: app)
        XCTAssertTrue(app.staticTexts["Access allowed"].waitForExistence(timeout: 10))
        XCTAssertTrue(app.buttons["coach-approval.continue"].exists)
        // Leave before the AI app exchanges its code. Cancellation must still
        // be reachable when the profile reports no connected grant.
        tap(app.buttons["Done"], in: app)
        tap(app.tabBars.buttons["Profile"], in: app)
        scrollAndTap(app.buttons["coach.manageAccess"], in: app)
        scrollAndTap(app.buttons["Disconnect all AI apps"], in: app)
        let confirmation = app.sheets["Disconnect all AI apps?"]
        XCTAssertTrue(confirmation.waitForExistence(timeout: 5))
        XCTAssertTrue(confirmation.buttons["Disconnect all AI apps"].isHittable)
    }

    private func onboard(_ app: XCUIApplication, invited: Bool = false) {
        tap(app.buttons["Get started"], in: app)
        tap(app.buttons["trainingSetup.skip"], in: app)
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
        let finish = app.buttons["FINISH"]
        XCTAssertTrue(finish.waitForExistence(timeout: 5))
        XCTAssertTrue(finish.isEnabled)
        XCTAssertTrue(app.frame.contains(finish.frame))
        XCTAssertGreaterThanOrEqual(finish.frame.height, 44)
        // After rest restores the app chrome, XCTest can misreport this pinned
        // button's hittability. A physical tap must complete the workout below.
        finish.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
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

    func testMixedSportSetupCreatesFirstWorkoutAndKeepsProfile() {
        let app = launch("activation-manual")
        tap(app.buttons["Sign in with Apple"], in: app)
        tap(app.buttons["Get started"], in: app)
        for activity in ["weightlifting", "running", "swimming"] {
            let toggle = app.switches["trainingSetup.\(activity)"]
            for _ in 0..<8 where !toggle.exists || !toggle.isHittable { app.swipeUp() }
            XCTAssertTrue(toggle.waitForExistence(timeout: 10))
            toggle.coordinate(withNormalizedOffset: CGVector(dx: 0.9, dy: 0.5)).tap()
            XCTAssertEqual(toggle.value as? String, "1")
        }
        tap(app.buttons["trainingSetup.next"], in: app)
        tap(app.buttons["trainingSetup.next"], in: app)
        tap(app.buttons["trainingSetup.next"], in: app)
        let starterName = app.staticTexts["Start moving"]
        for _ in 0..<8 where !starterName.exists || !starterName.isHittable { app.swipeUp() }
        XCTAssertTrue(starterName.waitForExistence(timeout: 10))
        tap(app.buttons["trainingSetup.accept"], in: app)
        tap(app.buttons["trainingSetup.done"], in: app)
        tap(app.buttons["I don't have a code"], in: app)
        tap(app.buttons["Skip for now"], in: app)
        tap(app.buttons["Enter Très Fort"], in: app)
        completeFirstWorkout(app)
        tap(app.tabBars.buttons["Profile"], in: app)
        tap(app.buttons["profile.trainingProfile"], in: app)
        let savedRunning = app.switches["trainingSetup.running"]
        for _ in 0..<8 where !savedRunning.exists || !savedRunning.isHittable { app.swipeUp() }
        XCTAssertTrue(savedRunning.waitForExistence(timeout: 10))
        XCTAssertEqual(savedRunning.value as? String, "1")
        let savedSwimming = app.switches["trainingSetup.swimming"]
        for _ in 0..<8 where !savedSwimming.exists || !savedSwimming.isHittable { app.swipeUp() }
        XCTAssertEqual(savedSwimming.value as? String, "1")
        let image = XCTAttachment(screenshot: app.screenshot())
        image.name = "multisport-training-profile"; image.lifetime = .keepAlways; add(image)
    }

    func testExistingMemberCanFindStarterFromEmptyTodayAndSkipWithoutCreating() {
        for fixture in ["empty", "empty-plan"] {
            let app = launch(fixture)
            tap(app.buttons["today.starterWorkout"], in: app)
            let running = app.switches["trainingSetup.running"]
            for _ in 0..<8 where !running.exists || !running.isHittable { app.swipeUp() }
            XCTAssertTrue(running.waitForExistence(timeout: 10))
            tap(app.buttons["trainingSetup.skip"], in: app)
            XCTAssertTrue(app.buttons["today.starterWorkout"].waitForExistence(timeout: 10))
            app.terminate()
        }
    }

    func testSetupCanBeSkippedWhileItsInitialReadIsPending() {
        let app = launch("activation-manual", pendingSetup: true)
        tap(app.buttons["Sign in with Apple"], in: app)
        tap(app.buttons["Get started"], in: app)
        let skip = app.buttons["trainingSetup.skip"]
        XCTAssertTrue(skip.waitForExistence(timeout: 5))
        XCTAssertTrue(skip.isEnabled)
        tap(skip, in: app)
        XCTAssertTrue(app.buttons["I don't have a code"].waitForExistence(timeout: 5))
    }

    func testSetupCanBeSkippedDuringPendingSavePreviewAndAcceptance() {
        for stage in ["save", "preview", "accept"] {
            let app = launch("activation-manual", pendingStage: stage)
            tap(app.buttons["Sign in with Apple"], in: app)
            tap(app.buttons["Get started"], in: app)
            tap(app.buttons["trainingSetup.next"], in: app)
            tap(app.buttons["trainingSetup.next"], in: app)
            tap(app.buttons["trainingSetup.next"], in: app)
            if stage == "accept" { tap(app.buttons["trainingSetup.accept"], in: app) }
            let skip = app.buttons["trainingSetup.skip"]
            XCTAssertTrue(skip.isEnabled)
            tap(skip, in: app)
            XCTAssertTrue(app.buttons["I don't have a code"].waitForExistence(timeout: 5))
            app.terminate()
        }
    }

    func testConsumedStarterDoesNotAdvertiseAnotherOneAfterLibraryDeletion() {
        let app = launch("empty-plan", starterUsed: true)
        XCTAssertTrue(app.staticTexts["YOUR NEXT WORKOUT"].waitForExistence(timeout: 10))
        XCTAssertFalse(app.buttons["today.starterWorkout"].exists)
        XCTAssertTrue(app.buttons["today.createWorkout"].isHittable)
    }

    func testOptionalWorkingSetCanBeSavedAndProfileRemainsEditable() {
        let app = launch("activation-manual")
        tap(app.buttons["Sign in with Apple"], in: app)
        onboard(app)
        tap(app.buttons["Enter Très Fort"], in: app)
        tap(app.tabBars.buttons["Profile"], in: app)
        tap(app.buttons["profile.trainingProfile"], in: app)
        tap(app.buttons["trainingSetup.next"], in: app)
        tap(app.buttons["trainingSetup.next"], in: app)
        tap(app.buttons["trainingSetup.addBaseline"], in: app)
        tap(app.textFields["trainingSetup.baselineWeight"], in: app)
        app.textFields["trainingSetup.baselineWeight"].typeText("20")
        tap(app.buttons["trainingSetup.saveBaseline"], in: app)
        XCTAssertTrue(app.staticTexts["Goblet Squat"].waitForExistence(timeout: 5))
        tap(app.buttons["trainingSetup.next"], in: app)
        tap(app.buttons["profile.trainingProfile"], in: app)
        tap(app.buttons["trainingSetup.next"], in: app)
        tap(app.buttons["trainingSetup.next"], in: app)
        XCTAssertTrue(app.staticTexts["Goblet Squat"].waitForExistence(timeout: 5))
        let image = XCTAttachment(screenshot: app.screenshot())
        image.name = "optional-working-set"; image.lifetime = .keepAlways; add(image)
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
        XCTAssertTrue(app.navigationBars["Add exercises"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.textFields["createWorkout.name"].exists)
        tap(app.buttons["exercisePicker.exercise.synthetic-exercise"], in: app)
        tap(app.buttons["createWorkout.review"], in: app)
        tap(app.buttons["createWorkout.create"], in: app)
        XCTAssertTrue(app.navigationBars["Edit Workout 1"].waitForExistence(timeout: 10))
        tap(app.buttons["editor.slot.created-slot-0"], in: app)
        let sets = app.steppers["3 sets"]
        XCTAssertTrue(sets.waitForExistence(timeout: 5))
        sets.buttons["Decrement"].tap()
        app.steppers["2 sets"].buttons["Decrement"].tap()
        tap(app.buttons["Save targets"], in: app)
        tap(app.navigationBars["Edit Workout 1"].buttons["Done"], in: app)
        tap(app.navigationBars["Workout 1"].buttons["Done"], in: app)
        completeFirstWorkout(app)
        tap(app.tabBars.buttons["Profile"], in: app)
        tap(app.buttons.containing(.staticText, identifier: "Set up your AI coach").firstMatch, in: app)
        XCTAssertTrue(app.navigationBars["Connect your coach"].waitForExistence(timeout: 5))
    }

    func testCoachSetupOffersCodexClaudeAndOtherApps() {
        let app = launch("activation-manual", captureLinks: true)
        tap(app.buttons["Sign in with Apple"], in: app)
        onboard(app)
        tap(app.buttons["Enter Très Fort"], in: app)
        tap(app.buttons["Set up my coach"], in: app)
        let picker = app.buttons["coach.app-picker"]
        XCTAssertTrue(app.staticTexts["coach.data-sharing"].label.contains("Anthropic"))
        XCTAssertFalse(app.buttons["coach.generate-code"].exists)
        tap(app.buttons["coach.connect-claude"], in: app)
        let opened = app.staticTexts["fixture.opened-url"]
        XCTAssertTrue(opened.waitForExistence(timeout: 5))
        let parts = URLComponents(string: opened.label)!
        XCTAssertEqual(parts.host, "claude.ai")
        XCTAssertEqual(parts.path, "/customize/connectors")
        XCTAssertEqual(parts.queryItems?.first { $0.name == "connectorUrl" }?.value,
                       "https://ui-fixture.invalid/mcp")
        XCTAssertEqual(parts.queryItems?.first { $0.name == "connectorName" }?.value, "Très Fort")
        let claudeImage = XCTAttachment(screenshot: app.screenshot())
        claudeImage.name = "claude-direct-coach-setup"; claudeImage.lifetime = .keepAlways; add(claudeImage)

        tap(picker, in: app)
        tap(app.buttons["Other compatible app"], in: app)
        XCTAssertTrue(app.staticTexts["coach.data-sharing"].label.contains("configured model provider"))
        tap(picker, in: app)
        tap(app.buttons["Codex"], in: app)
        XCTAssertFalse(app.buttons["coach.generate-code"].exists)
        tap(app.buttons["coach.codex-setup"], in: app)
        XCTAssertTrue(app.buttons["coach.codex-setup"].label.contains("Copied"))
        XCTAssertTrue(app.staticTexts["coach.codex-mobile-limit"].label.contains("computer"))
        let image = XCTAttachment(screenshot: app.screenshot())
        image.name = "codex-guided-coach-setup"; image.lifetime = .keepAlways; add(image)
        scrollAndTap(app.buttons["Manual setup"], in: app)
        scrollAndTap(app.buttons.containing(.staticText, identifier: "URL").firstMatch, in: app)
        XCTAssertTrue(app.staticTexts["https://ui-fixture.invalid/mcp"].exists)
        XCTAssertFalse(app.staticTexts["codex mcp login tres-fort"].exists)
        scrollAndTap(app.buttons["Command-line setup"], in: app)
        scrollAndTap(app.buttons.containing(.staticText, identifier: "Sign in").firstMatch, in: app)
        XCTAssertTrue(app.staticTexts["codex mcp login tres-fort"].exists)
    }

    func testEmptyTodayOffersCoachSetupDirectly() {
        let app = launch("activation-manual")
        tap(app.buttons["Sign in with Apple"], in: app)
        onboard(app)
        tap(app.buttons["Enter Très Fort"], in: app)
        XCTAssertTrue(app.buttons["Create a workout"].waitForExistence(timeout: 10))
        tap(app.buttons["Set up my coach"], in: app)
        XCTAssertTrue(app.navigationBars["Connect your coach"].waitForExistence(timeout: 10))
        XCTAssertTrue(app.buttons["coach.connect-claude"].isHittable)
        scrollAndTap(app.buttons["Use a connect code"], in: app)
        scrollAndTap(app.buttons["coach.generate-code"], in: app)
        let regenerate = app.buttons["coach.generate-code"]
        // The generated-code row pushes this control below the viewport.
        for _ in 0..<5 where !regenerate.exists || !regenerate.isHittable { app.swipeUp() }
        XCTAssertTrue(regenerate.waitForExistence(timeout: 10))
        XCTAssertTrue(regenerate.label.contains("Generate a new code"))
    }

    func testColdAndCachedEmptyFailuresOfferRecoveryWithoutCreation() {
        for fixture in ["load-failure", "cached-empty"] {
            let app = launch(fixture)
            XCTAssertTrue(app.buttons["Try again"].waitForExistence(timeout: 10))
            XCTAssertFalse(app.staticTexts["YOUR FIRST WORKOUT"].exists)
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

    func testSignInOffersAppleWithoutReviewerPasswordUI() {
        let app = launch("sign-in")
        XCTAssertTrue(app.buttons["Sign in with Apple"].waitForExistence(timeout: 10))
        XCTAssertFalse(app.buttons["Reviewer sign-in"].exists)
        XCTAssertFalse(app.secureTextFields["review.password"].exists)
    }

}
