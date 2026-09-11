import XCTest

final class WorkoutFeedbackJourneyTests: XCTestCase {
    override func setUpWithError() throws { continueAfterFailure = false }
    struct Fixture: Decodable { let recognized: String; let edited: String; let perceived_fatigue: Int }
    private func fixture() throws -> Fixture {
        let url = try XCTUnwrap(Bundle(for: Self.self).url(forResource: "WorkoutFeedback", withExtension: "json"))
        return try JSONDecoder().decode(Fixture.self, from: Data(contentsOf: url))
    }
    private func launch(_ speech: String = "available", reuse: Bool = false, conflict: Bool = false) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchEnvironment["TRESFORT_UI_FIXTURE"] = "ready-to-finish"
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
            // A missing selection menu must never fall back to deleting
            // backward from an arbitrary cursor and leave old suffixes behind.
            note.typeKey("a", modifierFlags: .command)
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
            app.buttons["Skip"].tap()
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
