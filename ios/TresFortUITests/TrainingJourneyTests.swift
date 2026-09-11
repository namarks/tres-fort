import XCTest

final class TrainingJourneyTests: XCTestCase {
    override func setUpWithError() throws { continueAfterFailure = false }

    @discardableResult
    private func launch(_ fixture: String, largeText: Bool = false) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchEnvironment["TRESFORT_UI_FIXTURE"] = fixture
        if largeText { app.launchEnvironment["TRESFORT_UI_LARGE_TEXT"] = "1" }
        app.launchArguments = ["-AppleLanguages", "(en)", "-AppleLocale", "en_US"]
        app.launch()
        XCTAssertTrue(app.staticTexts["fixture.scenario"].waitForExistence(timeout: 10))
        return app
    }

    private func screenshot(_ name: String) {
        let attachment = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    func testFreshSignInShowsExplicitAppleEntry() {
        let app = launch("sign-in")
        // Fixture mode substitutes only the provider button: exercise sign-in
        // intent without launching AuthenticationServices or sending credentials.
        XCTAssertTrue(app.buttons["Sign in with Apple"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.buttons["Create a workout"].exists)
        screenshot("fresh-sign-in")
        app.buttons["Sign in with Apple"].tap()
        XCTAssertTrue(app.staticTexts["Sign-in requested (synthetic)"].waitForExistence(timeout: 5))
    }

    func testVerifiedEmptyPlanCanCreateRoutineAndFirstWorkout() {
        let app = launch("empty")
        XCTAssertTrue(app.buttons["Create a workout"].waitForExistence(timeout: 10))
        screenshot("verified-empty-plan")
        app.buttons["Create a workout"].tap()
        let name = app.textFields["createWorkout.name"]
        XCTAssertTrue(name.waitForExistence(timeout: 5)); name.tap(); name.typeText("Workout A")
        reveal(app.buttons["createWorkout.create"], in: app)
        app.buttons["createWorkout.create"].tap()
        XCTAssertTrue(app.navigationBars["Edit Workout A"].waitForExistence(timeout: 10))
        XCTAssertFalse(app.buttons["Create workout"].exists)
        screenshot("created-first-workout")
    }

    func testFailedInitialLoadCannotMasqueradeAsEmptyPlan() {
        let app = launch("load-failure")
        XCTAssertTrue(app.buttons["Try again"].waitForExistence(timeout: 10))
        XCTAssertFalse(app.buttons["Create a workout"].exists)
        app.buttons["Try again"].tap()
        XCTAssertTrue(app.staticTexts["COULDN’T LOAD YOUR PLAN"].waitForExistence(timeout: 5))
        screenshot("failed-initial-load")
    }

    func testOrdinarySetLogsAndCompletesThroughAcknowledgement() {
        let app = launch("ordinary")
        XCTAssertTrue(app.buttons["LOG SET 1"].waitForExistence(timeout: 10))
        screenshot("ordinary-workout")
        app.buttons["LOG SET 1"].tap()
        XCTAssertTrue(app.buttons["rest.done"].waitForExistence(timeout: 5))
        app.buttons["rest.done"].tap()
        XCTAssertTrue(app.staticTexts["READY TO FINISH"].waitForExistence(timeout: 10))
        screenshot("logged-ready-to-finish")
        let finish = app.buttons["FINISH"]
        if !finish.isHittable { app.swipeUp() }
        finish.tap()
        XCTAssertTrue(app.staticTexts["WORKOUT COMPLETE"].waitForExistence(timeout: 10))
        screenshot("acknowledged-completion")
    }

    func testBodyweightAndTimedRunnerFixtures() {
        let bodyweight = launch("bodyweight")
        XCTAssertTrue(bodyweight.buttons["LOG SET 1"].waitForExistence(timeout: 10))
        screenshot("bodyweight-workout")
        bodyweight.terminate()
        let timed = launch("timed")
        XCTAssertTrue(timed.staticTexts["PLANK"].waitForExistence(timeout: 10))
        screenshot("timed-workout")
    }

    func testTimedSetSurvivesExerciseStripAndPreviousNextPreview() {
        let app = launch("timed-navigation")
        let start = app.buttons["START SET 1"]
        reveal(start, in: app)
        start.tap()
        let remaining = app.staticTexts["runner.timer.remaining"]
        XCTAssertTrue(remaining.waitForExistence(timeout: 5))
        let initial = Int(remaining.label.dropLast())!

        // Re-selecting the executing exercise is a no-op, not a timer reset.
        let bike = app.buttons["Stationary Bike"]
        bike.tap()
        XCTAssertTrue(remaining.exists)
        XCTAssertFalse(start.exists)

        for (control, heading) in [("NEXT →", "PUSH-UP"), ("← PREV", "GOBLET SQUAT"),
                                   ("Push-Up", "PUSH-UP")] {
            let navigation = app.buttons[control]
            if control == "Push-Up" { app.swipeDown() }
            reveal(navigation, in: app)
            navigation.tap()
            XCTAssertTrue(app.navigationBars["Workout preview"].waitForExistence(timeout: 5))
            XCTAssertTrue(app.staticTexts[heading].exists)
            XCTAssertTrue(app.staticTexts["runner.preview.timer"].label.hasPrefix("Stationary Bike · "))
            XCTAssertFalse(app.buttons["LOG SET 1"].exists)
            screenshot("timer-preview-\(heading)")
            app.buttons["Return to timer"].tap()
            XCTAssertTrue(remaining.waitForExistence(timeout: 5))
            XCTAssertLessThan(Int(remaining.label.dropLast())!, initial)
            XCTAssertFalse(start.exists)
        }
        let stop = app.buttons["STOP & LOG"]
        reveal(stop, in: app)
        stop.tap()
        let restDone = app.buttons["rest.done"]
        if restDone.waitForExistence(timeout: 3) { restDone.tap() }
        XCTAssertFalse(remaining.exists)
        // Only the bike was logged; the following exercise still has set 1.
        XCTAssertTrue(app.buttons["LOG SET 1"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["Stationary Bike"].exists)
        let evidence = app.staticTexts["fixture.scenario"].value as? String ?? ""
        XCTAssertTrue(evidence.hasPrefix("bike:1;other:0;seconds:"))
        XCTAssertTrue(evidence.hasSuffix(";warmup:1"))
    }

    func testTimedSetCompletesWhileExercisePreviewIsOpen() {
        let app = launch("timed-preview-completion")
        let start = app.buttons["START SET 1"]
        reveal(start, in: app)
        start.tap()
        app.buttons["Push-Up"].tap()
        XCTAssertTrue(app.navigationBars["Workout preview"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["runner.preview.timer"].exists)
        let closed = NSPredicate(format: "exists == false")
        expectation(for: closed, evaluatedWith: app.navigationBars["Workout preview"])
        waitForExpectations(timeout: 25)
        let restDone = app.buttons["rest.done"]
        if restDone.waitForExistence(timeout: 3) { restDone.tap() }
        XCTAssertTrue(app.buttons["LOG SET 1"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.buttons["STOP & LOG"].exists)
        XCTAssertEqual(app.staticTexts["fixture.scenario"].value as? String,
                       "bike:1;other:0;seconds:15;warmup:1")
        screenshot("timer-completed-during-preview")
    }

    func testPendingSetRemainsVisibleUntilAcknowledged() {
        let app = launch("pending")
        XCTAssertTrue(app.staticTexts["Set queued on this device"].waitForExistence(timeout: 10))
        XCTAssertTrue(app.staticTexts["Sets queued on this device"].exists)
        XCTAssertFalse(app.staticTexts["WORKOUT COMPLETE"].exists)
        screenshot("pending-write")
    }

    func testCorrectionFailurePreservesOriginalAndOffersRecovery() {
        let app = launch("correction-failure")
        XCTAssertTrue(app.buttons["edit-set-synthetic-set"].waitForExistence(timeout: 10))
        app.buttons["edit-set-synthetic-set"].tap()
        let reps = app.textFields["Reps"]
        XCTAssertTrue(reps.waitForExistence(timeout: 5))
        reveal(reps, in: app)
        reps.tap()
        reps.doubleTap()
        reps.typeText("6")
        XCTAssertEqual(reps.value as? String, "6")
        app.buttons["Save"].tap()
        XCTAssertTrue(app.staticTexts["Edit rejected (HTTP 422)."].waitForExistence(timeout: 10))
        XCTAssertTrue(app.staticTexts["45 × 5"].exists)
        screenshot("correction-failure-original-retained")
    }

    func testReadyToFinishFixtureRequiresExplicitFinish() {
        let app = launch("ready-to-finish")
        XCTAssertTrue(app.staticTexts["READY TO FINISH"].waitForExistence(timeout: 10))
        XCTAssertTrue(app.buttons["FINISH"].exists)
        XCTAssertFalse(app.staticTexts["WORKOUT COMPLETE"].exists)
        screenshot("ready-to-finish")
    }

    private func reveal(_ element: XCUIElement, in app: XCUIApplication,
                        file: StaticString = #filePath, line: UInt = #line) {
        _ = element.waitForExistence(timeout: 3)
        for _ in 0..<20 {
            let keyboard = app.keyboards.firstMatch
            let visibleBottom = keyboard.exists ? keyboard.frame.minY : app.frame.maxY - 20
            if element.exists && element.isHittable,
               element.frame.minY >= app.frame.minY + 20,
               element.frame.maxY <= visibleBottom { return }
            if keyboard.exists {
                // Scroll the form above the keyboard, rather than sending a
                // swipe into keyboard keys at the bottom of the screen.
                let top = app.navigationBars.allElementsBoundByIndex
                    .filter { $0.isHittable }.map { $0.frame.maxY }.max() ?? app.frame.minY
                let bottom = keyboard.frame.minY
                let origin = app.coordinate(withNormalizedOffset: .zero)
                let start = origin.withOffset(CGVector(dx: app.frame.midX, dy: bottom - 20))
                let end = origin.withOffset(CGVector(dx: app.frame.midX, dy: top + 20))
                start.press(forDuration: 0.1, thenDragTo: end)
            } else {
                app.swipeUp()
            }
        }
        XCTFail("Control did not become reachable after scrolling", file: file, line: line)
    }

    func testOnboardingCanReachEveryOptionalStep() {
        let app = launch("onboarding")
        let start = app.buttons["Get started"]
        reveal(start, in: app)
        screenshot("journey-onboarding-welcome")
        start.tap()
        let skipGroup = app.buttons["I don't have a code"]
        reveal(skipGroup, in: app)
        screenshot("journey-onboarding-group")
        skipGroup.tap()
        let skipCardio = app.buttons["Skip for now"]
        reveal(skipCardio, in: app)
        screenshot("journey-onboarding-intervals")
        skipCardio.tap()
        let enter = app.buttons["Enter Très Fort"]
        reveal(enter, in: app)
        enter.tap()
        XCTAssertTrue(app.buttons["Create a workout"].waitForExistence(timeout: 10))
    }

    func testWeightEntryAndKeyboardCanSaveExactLoad() {
        let app = launch("ordinary")
        let weight = app.buttons["runner.weight"]
        reveal(weight, in: app)
        screenshot("journey-load-controls")
        weight.tap()
        let entry = app.textFields["weight.entry"]
        XCTAssertTrue(entry.waitForExistence(timeout: 5))
        entry.doubleTap()
        entry.typeText("47.5")
        XCTAssertEqual(entry.value as? String, "47.5")
        screenshot("journey-weight-keyboard")
        XCTAssertTrue(app.buttons["Save"].isHittable)
        app.buttons["Save"].tap()
        XCTAssertEqual(weight.value as? String, "47.5")
    }

    func testKilogramEntryCanSwitchUnitsWithoutChangingTheLoad() {
        let app = launch("ordinary")
        let weight = app.buttons["runner.weight"]
        reveal(weight, in: app)
        weight.tap()
        app.segmentedControls["weight.unit"].buttons["kg"].tap()
        let entry = app.textFields["weight.entry"]
        let previous = entry.value as? String ?? ""
        entry.coordinate(withNormalizedOffset: CGVector(dx: 0.95, dy: 0.5)).tap()
        entry.typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: previous.count) + "20")
        screenshot("kilogram-editor-before-save")
        XCTAssertEqual(entry.value as? String, "20")
        app.buttons["Save"].tap()
        XCTAssertEqual(weight.value as? String, "20")
        screenshot("kilogram-weight-entry")
        app.segmentedControls["runner.weight.unit"].buttons["lb"].tap()
        XCTAssertEqual(weight.value as? String, "44.092")
        app.segmentedControls["runner.weight.unit"].buttons["kg"].tap()
        XCTAssertEqual(weight.value as? String, "20")
        weight.tap()
        app.buttons["Save"].tap()
        XCTAssertEqual(weight.value as? String, "20")
    }

    func testRestAndCompletionRemainReachable() {
        let app = launch("ordinary")
        let log = app.buttons["LOG SET 1"]
        reveal(log, in: app)
        log.tap()
        let done = app.buttons["rest.done"]
        reveal(done, in: app)
        screenshot("journey-rest-complete")
        done.tap()
        let finish = app.buttons["FINISH"]
        XCTAssertTrue(finish.waitForExistence(timeout: 5))
        XCTAssertTrue(finish.isEnabled)
        XCTAssertTrue(app.frame.contains(finish.frame))
        XCTAssertGreaterThanOrEqual(finish.frame.height, 44)
        screenshot("journey-finish")
        finish.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
        XCTAssertTrue(app.staticTexts["WORKOUT COMPLETE"].waitForExistence(timeout: 10))
    }

    func testCorrectionRecoveryRemainsReachable() {
        let app = launch("correction-failure")
        let edit = app.buttons["edit-set-synthetic-set"]
        reveal(edit, in: app)
        XCTAssertEqual(edit.label, "Edit set 1 of Barbell Squat")
        edit.tap()
        let reps = app.textFields["Reps"]
        reveal(reps, in: app)
        reps.tap()
        reps.doubleTap()
        reps.typeText("6")
        XCTAssertEqual(reps.value as? String, "6")
        screenshot("journey-correction-keyboard")
        reveal(app.buttons["Delete set 1 of Barbell Squat"], in: app)
        app.buttons["Save"].tap()
        let reload = app.buttons["reload-correction-synthetic-set"]
        reveal(reload, in: app)
        screenshot("journey-correction-recovery")
        XCTAssertTrue(app.staticTexts["45 × 5"].exists)
        XCTAssertTrue(app.staticTexts["Edit rejected (HTTP 422)."].exists)
        reload.tap()
        XCTAssertTrue(edit.waitForExistence(timeout: 5))
        XCTAssertTrue(edit.isEnabled)
    }

    private func audit(_ fixture: String) throws {
        let app = launch(fixture)
        let ready = fixture == "empty" ? app.buttons["Create a workout"]
            : fixture == "load-failure" ? app.buttons["Try again"]
            : fixture == "ordinary" ? app.buttons["LOG SET 1"]
            : app.staticTexts["READY TO FINISH"]
        XCTAssertTrue(ready.waitForExistence(timeout: 10))
        // iOS 26.2's contrast heuristic flags even opaque #F4F4F5 over this
        // dark gradient. Palette policy tests and measured screenshot evidence
        // cover contrast; these runtime audits enforce targets/text semantics.
        // See docs/plans/app-quality-and-maintainability/evidence/p1/README.md.
        try app.performAccessibilityAudit(for: [.hitRegion, .sufficientElementDescription]) { issue in
            print("Accessibility audit: \(issue.compactDescription): \(issue.detailedDescription)")
            print(issue.element?.debugDescription ?? "No associated element")
            return false
        }
    }

    func testAccessibilityAuditEmpty() throws { try audit("empty") }
    func testAccessibilityAuditLoadFailure() throws { try audit("load-failure") }
    func testAccessibilityAuditOrdinary() throws { try audit("ordinary") }
    func testAccessibilityAuditReadyToFinish() throws { try audit("ready-to-finish") }
}
