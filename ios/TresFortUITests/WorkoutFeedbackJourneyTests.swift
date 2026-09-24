import XCTest

final class WorkoutFeedbackJourneyTests: XCTestCase {
    override func setUpWithError() throws { continueAfterFailure = false }
    override func tearDownWithError() throws {
        if (testRun?.failureCount ?? 0) > 0 { print(XCUIApplication().debugDescription) }
    }
    struct Fixture: Decodable { let recognized: String; let edited: String; let perceived_fatigue: Int }
    private func fixture() throws -> Fixture {
        let url = try XCTUnwrap(Bundle(for: Self.self).url(forResource: "WorkoutFeedback", withExtension: "json"))
        return try JSONDecoder().decode(Fixture.self, from: Data(contentsOf: url))
    }
    private func launch(_ speech: String = "available", reuse: Bool = false, conflict: Bool = false, scenario: String = "ready-to-finish") -> XCUIApplication {
        let app = XCUIApplication()
        app.launchEnvironment["TRESFORT_UI_FIXTURE"] = scenario
        app.launchEnvironment["TRESFORT_FEEDBACK_SPEECH"] = speech
        app.launchEnvironment["TRESFORT_FEEDBACK_TRANSCRIPT"] = (try? fixture())?.recognized
        if reuse { app.launchEnvironment["TRESFORT_UI_REUSE_FEEDBACK"] = "1" }
        if conflict { app.launchEnvironment["TRESFORT_UI_FEEDBACK_CONFLICT"] = "1" }
        // Feedback journeys use synthetic speech and keep unrelated rest-cue
        // notification permission out of the workout Resume boundary.
        app.launchArguments = ["-AppleLanguages", "(en)", "-AppleLocale", "en_US", "-restAudioCuesEnabled", "NO"]
        app.launch()
        XCTAssertTrue(app.staticTexts["fixture.scenario"].waitForExistence(timeout: 10))
        return app
    }
    private func reveal(_ element: XCUIElement, app: XCUIApplication) {
        for _ in 0..<6 { if element.isHittable { return }; app.swipeUp() }
        XCTAssertTrue(element.isHittable)
    }
    private func openFeedback(_ app: XCUIApplication) {
        let open = app.buttons["feedback.open"]
        XCTAssertTrue(open.waitForExistence(timeout: 10))
        reveal(open, app: app); open.tap()
        XCTAssertTrue(app.buttons["feedback.talk"].waitForExistence(timeout: 5))
    }
    private func type(_ text: String, app: XCUIApplication, replacing: Bool = false) {
        let note = app.textViews["feedback.note"]
        reveal(note, app: app); note.tap()
        if replacing {
            // Command-A was ignored intermittently by the simulator. Use the
            // native editing menu, and require full deletion before typing.
            XCTAssertTrue(app.keyboards.firstMatch.waitForExistence(timeout: 5))
            note.press(forDuration: 1.2)
            let selectAll = app.menuItems["Select All"]
            XCTAssertTrue(selectAll.waitForExistence(timeout: 5))
            selectAll.tap()
            note.typeText(XCUIKeyboardKey.delete.rawValue)
            XCTAssertEqual(note.value as? String, "", "Replacement must clear the entire transcript")
        }
        note.typeText(text)
        XCTAssertEqual(note.value as? String, text)
        if app.buttons["Done"].isHittable { app.buttons["Done"].tap() }
    }
    private func finish(_ app: XCUIApplication) {
        let finish = app.buttons["FINISH"]
        reveal(finish, app: app); finish.tap()
        XCTAssertTrue(app.staticTexts["WORKOUT COMPLETE"].waitForExistence(timeout: 10))
        let record = app.buttons["today.viewCompletedWorkout"]
        reveal(record, app: app); record.tap()
    }
    private func screenshot(_ name: String) {
        let attachment = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        attachment.name = name; attachment.lifetime = .keepAlways; add(attachment)
    }

    private func openFinishSummary(_ app: XCUIApplication) {
        let actions = app.buttons["today.workoutActions"]
        XCTAssertTrue(actions.waitForExistence(timeout: 5)); actions.tap()
        app.buttons["Finish workout"].tap()
        XCTAssertTrue(app.staticTexts["feedback.finishSummary"].waitForExistence(timeout: 5))
    }
    private func openCompletedWorkout(_ app: XCUIApplication) {
        XCTAssertTrue(app.staticTexts["WORKOUT COMPLETE"].waitForExistence(timeout: 10))
        let record = app.buttons["today.viewCompletedWorkout"]
        reveal(record, app: app); record.tap()
    }

    func testEarlyFinishStartsWithSummaryAndNeedsNoFeedback() {
        let app = launch(scenario: "workout-swap")
        openFinishSummary(app)
        XCTAssertTrue(app.staticTexts["feedback.earlyFinishNote"].exists)
        XCTAssertFalse(app.textViews["feedback.note"].exists)
        XCTAssertFalse(app.buttons["feedback.talk"].exists)
        XCTAssertTrue(app.buttons["feedback.finishWithoutChanges"].isHittable)
        screenshot("feedback-optional-finish-summary")
        app.buttons["feedback.finishWithoutChanges"].tap()
        openCompletedWorkout(app)
        XCTAssertFalse(app.staticTexts["feedback.saved-note"].exists)
        XCTAssertFalse(app.staticTexts["feedback.saved-fatigue"].exists)
    }

    func testExpandedEarlyFinishSavesOnlyReviewedFeedback() {
        let app = launch(scenario: "workout-swap")
        openFinishSummary(app)
        app.buttons["feedback.expand"].tap()
        type("Finished early after one set", app: app)
        XCTAssertTrue(app.buttons["feedback.saveAndFinish"].isHittable)
        app.buttons["feedback.saveAndFinish"].tap()
        openCompletedWorkout(app)
        XCTAssertEqual(app.staticTexts["feedback.saved-note"].label, "Finished early after one set")
    }

    func testFinishWithoutFeedbackDoesNotSaveExpandedDraft() {
        let app = launch(scenario: "workout-swap")
        openFinishSummary(app)
        app.buttons["feedback.expand"].tap()
        type("Unapproved draft", app: app)
        app.buttons["feedback.finishWithoutChanges"].tap()
        openCompletedWorkout(app)
        XCTAssertFalse(app.staticTexts["feedback.saved-note"].exists)
    }

    func testFinishSummaryPreservesPreviouslySavedFeedback() {
        let app = launch()
        openFeedback(app); type("Previously saved feedback", app: app)
        app.buttons["Save feedback"].tap()
        let returnToExercises = app.buttons["Return to exercises"]
        XCTAssertTrue(returnToExercises.waitForExistence(timeout: 5))
        let finishAction = app.buttons["FINISH"]
        // Hittability alone can include a clipped row behind the fixed footer.
        for _ in 0..<6 where !returnToExercises.isHittable
            || returnToExercises.frame.maxY > finishAction.frame.minY { app.swipeUp() }
        XCTAssertLessThanOrEqual(returnToExercises.frame.maxY, finishAction.frame.minY)
        returnToExercises.tap()
        openFinishSummary(app)
        XCTAssertTrue(app.staticTexts["Your saved feedback will be included."].exists)
        XCTAssertFalse(app.textViews["feedback.note"].exists)
        app.buttons["feedback.expand"].tap()
        type("Unapproved replacement", app: app, replacing: true)
        XCTAssertEqual(app.buttons["feedback.finishWithoutChanges"].label, "Finish with saved feedback")
        app.buttons["feedback.finishWithoutChanges"].tap()
        openCompletedWorkout(app)
        XCTAssertEqual(app.staticTexts["feedback.saved-note"].label, "Previously saved feedback")
    }

    func testVoiceEditedTranscriptAndFatigueReachAcknowledgedWorkout() throws {
        let values = try fixture()
        let app = launch()
        openFeedback(app)
        app.buttons["feedback.talk"].tap()
        XCTAssertTrue(app.buttons["feedback.stop"].waitForExistence(timeout: 5))
        app.buttons["feedback.stop"].tap()
        XCTAssertEqual(app.textViews["feedback.note"].value as? String, values.recognized)
        type(values.edited, app: app, replacing: true)
        let fatigue = app.buttons["feedback.fatigue"]
        reveal(fatigue, app: app); fatigue.tap()
        app.buttons["\(values.perceived_fatigue) / 10"].tap()
        screenshot("feedback-reviewed-transcript")
        app.buttons["Save feedback"].tap()
        XCTAssertTrue(app.staticTexts["feedback.saved-note"].waitForExistence(timeout: 5))
        XCTAssertEqual(app.staticTexts["feedback.saved-note"].label, values.edited)
        finish(app)
        XCTAssertEqual(app.staticTexts["feedback.saved-note"].label, values.edited)
        XCTAssertEqual(app.staticTexts["feedback.saved-fatigue"].label, "Fatigue: 7/10")
        screenshot("feedback-acknowledged")
    }

    func testDeniedPermissionPreservesTypingAndExplicitSave() {
        let app = launch("denied")
        openFeedback(app)
        type("Typed before asking to record", app: app)
        let talk = app.buttons["feedback.talk"]
        app.swipeDown(); reveal(talk, app: app); talk.tap()
        XCTAssertTrue(app.staticTexts["Recording permission is off. You can type instead or skip."].waitForExistence(timeout: 5))
        XCTAssertEqual(app.textViews["feedback.note"].value as? String, "Typed before asking to record")
        app.buttons["Save feedback"].tap()
        finish(app)
        XCTAssertEqual(app.staticTexts["feedback.saved-note"].label, "Typed before asking to record")
        XCTAssertFalse(app.staticTexts["feedback.saved-fatigue"].exists)
    }

    func testCanceledOrEmptyRecordingAndUnavailableRecognitionCanSkip() {
        for mode in ["available", "empty", "unavailable"] {
            let app = launch(mode)
            openFeedback(app); app.buttons["feedback.talk"].tap()
            if mode == "unavailable" {
                XCTAssertTrue(app.staticTexts["On-device transcription is unavailable. You can type instead or skip."].waitForExistence(timeout: 5))
            } else {
                XCTAssertTrue(app.buttons["Cancel recording"].waitForExistence(timeout: 5))
                app.buttons["Cancel recording"].tap()
                XCTAssertEqual(app.textViews["feedback.note"].value as? String, "")
            }
            app.buttons["Cancel"].tap()
            finish(app)
            XCTAssertFalse(app.staticTexts["feedback.saved-note"].exists)
            app.terminate()
        }
    }

    func testApprovedFeedbackSurvivesRelaunchBeforeFinish() {
        let app = launch()
        openFeedback(app); type("Saved before relaunch", app: app)
        app.buttons["Save feedback"].tap()
        XCTAssertTrue(app.staticTexts["feedback.saved-note"].waitForExistence(timeout: 5))
        app.terminate()
        let reopened = launch(reuse: true)
        let resume = reopened.buttons["today.startWorkout"]
        XCTAssertTrue(resume.waitForExistence(timeout: 10)); resume.tap()
        XCTAssertTrue(reopened.staticTexts["feedback.saved-note"].waitForExistence(timeout: 5))
        XCTAssertEqual(reopened.staticTexts["feedback.saved-note"].label, "Saved before relaunch")
        finish(reopened)
        XCTAssertEqual(reopened.staticTexts["feedback.saved-note"].label, "Saved before relaunch")
    }

    func testFeedbackConflictReviewsBothVersionsAndCompletesExplicitChoice() {
        for useMine in [false, true] {
            let app = launch(conflict: true)
            openFeedback(app); type("My approved feedback", app: app)
            app.buttons["Save feedback"].tap()
            let finish = app.buttons["FINISH"]
            reveal(finish, app: app); finish.tap()
            let review = app.buttons["Review feedback"]
            XCTAssertTrue(review.waitForExistence(timeout: 10)); review.tap()
            XCTAssertTrue(app.staticTexts["My approved feedback"].waitForExistence(timeout: 5))
            XCTAssertTrue(app.staticTexts["Newer saved feedback"].exists)
            screenshot("feedback-conflict-review")
            let choice = app.buttons[useMine ? "Use my feedback" : "Keep saved feedback"]
            reveal(choice, app: app); choice.tap()
            XCTAssertTrue(app.staticTexts["WORKOUT COMPLETE"].waitForExistence(timeout: 10))
        let record = app.buttons["today.viewCompletedWorkout"]
        reveal(record, app: app); record.tap()
            XCTAssertEqual(app.staticTexts["feedback.saved-note"].label, useMine ? "My approved feedback" : "Newer saved feedback")
            app.terminate()
        }
    }
}
