import XCTest

/// Exercise real controls in the full tab shell so the primary action cannot
/// pass merely because a standalone fixture omitted the tab bar.
final class UIActionJourneyTests: XCTestCase {
    override func setUpWithError() throws { continueAfterFailure = false }

    private func launch(_ fixture: String = "app-store") -> XCUIApplication {
        let app = XCUIApplication()
        app.launchEnvironment["TRESFORT_UI_FIXTURE"] = fixture
        app.launchArguments = ["-AppleLanguages", "(en)", "-AppleLocale", "en_US", "-restAudioCuesEnabled", "NO"]
        app.launch()
        return app
    }

    private func tap(_ element: XCUIElement, in app: XCUIApplication) {
        XCTAssertTrue(element.waitForExistence(timeout: 10))
        for _ in 0..<6 where !element.isHittable { app.swipeUp() }
        XCTAssertTrue(element.isHittable)
        element.tap()
    }

    private func capture(_ name: String) {
        let image = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        image.name = "ui-fix-" + name; image.lifetime = .keepAlways; add(image)
    }

    func testProfileKeepsAccountActionsInAccountAndNameRowIsTappable() {
        let app = launch()
        tap(app.tabBars.buttons["Profile"], in: app)
        XCTAssertTrue(app.buttons["profile.account"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.buttons["Download account data"].exists)
        XCTAssertFalse(app.buttons["Delete account"].exists)
        capture("profile")
        let name = app.buttons["profile.editName"]
        XCTAssertGreaterThanOrEqual(name.frame.height, 44)
        name.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
        XCTAssertTrue(app.navigationBars["Edit Name"].waitForExistence(timeout: 5))
        tap(app.buttons["Cancel"], in: app)
        tap(app.buttons["profile.account"], in: app)
        XCTAssertTrue(app.navigationBars["Account"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["Download account data"].exists)
        capture("account")
        tap(app.buttons["Delete account"], in: app)
        let confirmation = app.alerts["Permanently delete your account?"]
        XCTAssertTrue(confirmation.waitForExistence(timeout: 5))
        confirmation.buttons["Cancel"].tap()
        XCTAssertTrue(app.navigationBars["Account"].exists)
    }

    func testLogSetStaysAboveTabsBeforeAndAfterScrolling() {
        let app = launch()
        tap(app.buttons["today.startWorkout"], in: app)
        let log = app.buttons["LOG SET 1"]
        XCTAssertTrue(log.waitForExistence(timeout: 5))
        XCTAssertTrue(log.isHittable)
        XCTAssertLessThan(log.frame.maxY, app.tabBars.firstMatch.frame.minY)
        XCTAssertFalse(app.buttons["today.discardWorkout"].exists)
        capture("runner")
        let y = log.frame.minY
        app.swipeUp()
        XCTAssertEqual(log.frame.minY, y, accuracy: 2)
        XCTAssertTrue(log.isHittable)
        XCTAssertTrue(app.staticTexts["runner.setSummary"].exists)
        log.tap()
        XCTAssertTrue(app.buttons["rest.done"].waitForExistence(timeout: 10))
        XCTAssertFalse(log.isHittable, "The full rest screen must shield the pinned action")
        app.buttons["rest.done"].tap()
        let next = app.buttons["LOG SET 2"]
        XCTAssertTrue(next.waitForExistence(timeout: 10))
        XCTAssertTrue(next.isEnabled)
        XCTAssertLessThan(next.frame.maxY, app.tabBars.firstMatch.frame.minY)
        XCTAssertTrue(app.frame.contains(next.frame))
        next.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
        XCTAssertTrue(app.buttons["rest.done"].waitForExistence(timeout: 5))
        app.buttons["rest.done"].tap()
        XCTAssertTrue(app.buttons["LOG SET 3"].waitForExistence(timeout: 5),
                      "A physical tap after rest must log exactly one more set")
    }

    func testEditorUsesExplicitReorderingAndConfirmedRemoval() {
        let app = launch()
        tap(app.buttons["today.viewWorkout"], in: app)
        tap(app.buttons["workoutDetails.edit"], in: app)
        let squat = app.buttons["editor.slot.a-squat"]
        XCTAssertTrue(squat.waitForExistence(timeout: 5))
        XCTAssertFalse(app.buttons["editor.doneReordering"].exists)
        XCTAssertTrue(squat.isEnabled)
        capture("editor")
        tap(app.buttons["editor.actions"], in: app)
        tap(app.buttons["Reorder exercises"], in: app)
        XCTAssertTrue(app.buttons["editor.doneReordering"].exists)
        XCTAssertFalse(app.buttons["Options for Barbell Squat"].exists)
        capture("reorder")
        let reorder = app.buttons.matching(NSPredicate(format: "label BEGINSWITH 'Reorder'")).firstMatch
        XCTAssertTrue(reorder.exists)
        let row = app.buttons["editor.slot.a-row"]
        reorder.press(forDuration: 0.5, thenDragTo: row)
        expectation(for: NSPredicate { _, _ in squat.frame.minY > row.frame.minY }, evaluatedWith: squat)
        waitForExpectations(timeout: 5)
        tap(app.buttons["editor.doneReordering"], in: app)
        XCTAssertGreaterThan(squat.frame.minY, row.frame.minY)
        squat.swipeLeft()
        tap(app.buttons["Remove"], in: app)
        let alert = app.alerts["Remove Barbell Squat?"]
        XCTAssertTrue(alert.waitForExistence(timeout: 5))
        capture("remove-exercise")
        alert.buttons["Cancel"].tap()
        XCTAssertTrue(squat.exists)
        tap(app.buttons["Options for Barbell Squat"], in: app)
        tap(app.buttons["Remove exercise"], in: app)
        XCTAssertTrue(alert.waitForExistence(timeout: 5))
        alert.buttons["Remove exercise"].tap()
        expectation(for: NSPredicate(format: "exists == false"), evaluatedWith: squat)
        waitForExpectations(timeout: 10)
        XCTAssertTrue(app.buttons["editor.slot.a-row"].exists)
    }

    func testSetDeletionRequiresConfirmationAndCancelPreservesValues() {
        let app = launch("ready-to-finish")
        let edit = app.buttons["edit-set-synthetic-set"]
        tap(edit, in: app)
        tap(app.buttons["Delete set 1 of Barbell Squat"], in: app)
        let alert = app.alerts["Delete set 1 of Barbell Squat?"]
        XCTAssertTrue(alert.waitForExistence(timeout: 5))
        capture("delete-set")
        alert.buttons["Cancel"].tap()
        XCTAssertEqual(app.textFields["Reps"].value as? String, "5")
        tap(app.buttons["Delete set 1 of Barbell Squat"], in: app)
        alert.buttons["Delete set"].tap()
        expectation(for: NSPredicate(format: "exists == false"), evaluatedWith: edit)
        waitForExpectations(timeout: 10)
        XCTAssertEqual(app.staticTexts["summary.value.Sets saved"].label, "0")
        XCTAssertFalse(app.buttons["FINISH"].exists, "An unresolved set must not leave a no-op Finish action")
        tap(app.buttons["finished.reviewExercises"], in: app)
        XCTAssertTrue(app.buttons["LOG SET 1"].waitForExistence(timeout: 5))
    }

    func testCompletedExerciseShowsCompletionInsteadOfANoOpLogAction() {
        let app = launch("ready-to-finish")
        tap(app.buttons["Return to exercises"], in: app)
        XCTAssertTrue(app.staticTexts["runner.exerciseComplete"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.buttons["LOG SET 2"].exists)
        tap(app.buttons["today.workoutActions"], in: app)
        tap(app.buttons["Finish workout"], in: app)
        tap(app.buttons["Finish without feedback"], in: app)
        XCTAssertTrue(app.staticTexts["WORKOUT COMPLETE"].waitForExistence(timeout: 10))
    }

    func testFinishCanReturnToWorkoutOrExplicitlyFinishWithoutFeedback() {
        let app = launch()
        tap(app.buttons["today.startWorkout"], in: app)
        tap(app.buttons["today.workoutActions"], in: app)
        tap(app.buttons["Finish workout"], in: app)
        XCTAssertTrue(app.navigationBars["Finish workout"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.buttons["Skip"].exists)
        XCTAssertTrue(app.buttons["feedback.saveAndFinish"].isHittable)
        XCTAssertTrue(app.buttons["feedback.finishWithoutChanges"].isHittable)
        capture("finish")
        tap(app.buttons["Keep working"], in: app)
        XCTAssertTrue(app.buttons["LOG SET 1"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.staticTexts["WORKOUT COMPLETE"].exists)
        tap(app.buttons["today.workoutActions"], in: app)
        tap(app.buttons["Finish workout"], in: app)
        tap(app.buttons["Finish without feedback"], in: app)
        XCTAssertTrue(app.staticTexts["WORKOUT COMPLETE"].waitForExistence(timeout: 10))
    }

    func testSaveFeedbackAndFinishKeepsApprovedNote() {
        let app = launch()
        tap(app.buttons["today.startWorkout"], in: app)
        tap(app.buttons["today.workoutActions"], in: app)
        tap(app.buttons["Finish workout"], in: app)
        let note = app.textViews["feedback.note"]
        tap(note, in: app)
        note.typeText("Finished early today.")
        if app.buttons["Done"].isHittable { app.buttons["Done"].tap() }
        tap(app.buttons["feedback.saveAndFinish"], in: app)
        XCTAssertTrue(app.staticTexts["WORKOUT COMPLETE"].waitForExistence(timeout: 10))
        tap(app.buttons["today.viewCompletedWorkout"], in: app)
        XCTAssertEqual(app.staticTexts["feedback.saved-note"].label, "Finished early today.")
    }
}
