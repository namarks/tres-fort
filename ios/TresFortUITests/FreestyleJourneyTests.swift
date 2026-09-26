import XCTest

final class FreestyleJourneyTests: XCTestCase {
    override func setUpWithError() throws { continueAfterFailure = false }
    override func tearDownWithError() throws {
        if (testRun?.failureCount ?? 0) > 0 { print(XCUIApplication().debugDescription) }
    }
    private func reveal(_ element: XCUIElement, app: XCUIApplication) {
        for _ in 0..<8 { if element.isHittable { return }; app.swipeUp() }
        XCTAssertTrue(element.isHittable)
    }
    private func journey(large: Bool, timed: Bool = false) {
        let app = XCUIApplication()
        app.launchEnvironment["TRESFORT_UI_FIXTURE"] = "freestyle"
        if large { app.launchEnvironment["TRESFORT_UI_LARGE_TEXT"] = "1" }
        app.launchArguments = ["-AppleLanguages", "(en)", "-AppleLocale", "en_US", "-restAudioCuesEnabled", timed ? "NO" : "YES"]
        app.launch()
        let start = app.buttons["Start freestyle"]
        XCTAssertTrue(start.waitForExistence(timeout: 10)); reveal(start, app: app); start.tap()
        let search = app.textFields["exercisePicker.search"]
        XCTAssertTrue(search.waitForExistence(timeout: 5))
        search.tap(); search.typeText((timed ? "Goblet Hold" : "Barbell Squat") + "\n")
        let squat = app.buttons[timed ? "freestyle.exercise.synthetic-hold" : "freestyle.exercise.synthetic-exercise"]
        XCTAssertTrue(squat.waitForExistence(timeout: 5)); squat.tap()
        let allow = XCUIApplication(bundleIdentifier: "com.apple.springboard").alerts.buttons["Allow"]
        if allow.waitForExistence(timeout: 2) { allow.tap() }
        let first = app.buttons[timed ? "START SET 1" : "LOG SET 1"]
        XCTAssertTrue(first.waitForExistence(timeout: 5)); first.tap()
        if timed {
            let stop = app.buttons["STOP & LOG"]
            XCTAssertTrue(stop.waitForExistence(timeout: 5))
            // The runner intentionally ignores reflexive taps in the first
            // two seconds. Observe the live countdown before ending the hold.
            let remaining = app.staticTexts["runner.timer.remaining"]
            expectation(for: NSPredicate { _, _ in
                guard let seconds = Int(remaining.label.dropLast()) else { return false }
                return seconds > 0 && seconds <= 27
            }, evaluatedWith: remaining)
            waitForExpectations(timeout: 8)
            stop.tap()
        }
        let skip = app.buttons["rest.done"]
        XCTAssertTrue(skip.waitForExistence(timeout: 5)); skip.tap()
        XCTAssertTrue(app.buttons[timed ? "START SET 2" : "LOG SET 2"].waitForExistence(timeout: 5))
        let addExercise = app.buttons["runner.addFreestyleExercise"]
        reveal(addExercise, app: app); addExercise.tap()
        XCTAssertTrue(search.waitForExistence(timeout: 5))
        search.tap(); search.typeText("Dumbbell Goblet Squat\n")
        let replacement = app.buttons["freestyle.exercise.synthetic-replacement"]
        XCTAssertTrue(replacement.waitForExistence(timeout: 5)); replacement.tap()
        XCTAssertTrue(app.buttons["LOG SET 1"].waitForExistence(timeout: 5)); app.buttons["LOG SET 1"].tap()
        XCTAssertTrue(skip.waitForExistence(timeout: 5)); skip.tap()
        let actions = app.buttons["today.workoutActions"]
        actions.tap(); app.buttons["Finish workout"].tap()
        let finish = app.buttons["feedback.finishWithoutChanges"]
        XCTAssertTrue(finish.waitForExistence(timeout: 5)); reveal(finish, app: app); finish.tap()
        let history = app.buttons["today.viewCompletedWorkout"]
        XCTAssertTrue(history.waitForExistence(timeout: 10)); reveal(history, app: app); history.tap()
        let saveAs = app.buttons["freestyle.saveAsWorkout"]
        XCTAssertTrue(saveAs.waitForExistence(timeout: 5)); reveal(saveAs, app: app); saveAs.tap()
        let save = app.buttons["freestyle.save"]
        reveal(save, app: app)
        let shot = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        shot.name = large ? "freestyle-review-large" : "freestyle-review"; shot.lifetime = .keepAlways; add(shot)
        save.tap()
        expectation(for: NSPredicate(format: "exists == false"), evaluatedWith: save)
        waitForExpectations(timeout: 10)
        XCTAssertFalse(app.buttons["freestyle.saveAsWorkout"].exists)
    }
    func testStartLogAddFinishAndSave() { journey(large: false) }
    func testTimedFreestyleCanContinueAddAndSave() { journey(large: false, timed: true) }
    func testStartLogAddFinishAndSaveLargestText() { journey(large: true) }
}
