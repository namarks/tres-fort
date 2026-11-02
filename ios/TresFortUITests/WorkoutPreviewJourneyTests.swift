import XCTest

final class WorkoutPreviewJourneyTests: XCTestCase {
    override func setUpWithError() throws { continueAfterFailure = false }
    override func tearDownWithError() throws {
        if (testRun?.failureCount ?? 0) > 0 { print(XCUIApplication().debugDescription) }
    }

    private let longName = "Single-Arm Dumbbell Shoulder Press with a Controlled Eccentric"

    private func launch(reduceMotion: Bool = false) throws -> XCUIApplication {
        let app = XCUIApplication()
        app.launchEnvironment["TRESFORT_UI_FIXTURE"] = "app-store"
        if reduceMotion { app.launchEnvironment["TRESFORT_UI_REDUCE_MOTION"] = "1" }
        // Twelve rows, four circuits, with an offline demo, unmapped movement,
        // and failed remote image in each group. Never contact a real account.
        let slots: [[String: Any]] = (0..<12).map { index in
            var slot: [String: Any] = ["id": "preview-\(index)", "exercise_id": "preview-exercise-\(index)",
                "exercise_name": index % 3 == 0 ? "Barbell Squat" : index % 3 == 1 ? longName : "Cable Face Pull",
                "exercise_unit": "lb", "exercise_modality": "barbell", "order_index": index,
                "target_sets": 3, "target_reps": 8, "rest_seconds": 60, "target_weight": 45,
                "group_id": "preview-group-\(index / 3)", "group_rest_seconds": 90,
                "group_transition_seconds": 15, "cues": "Keep the movement controlled."]
            if index % 3 == 0 { slot["exercise_demo_slug"] = "Romanian_Deadlift" }
            if index % 3 == 2 { slot["exercise_demo_slug"] = "unavailable-art" }
            return slot
        }
        let fixture: [String: Any] = ["name": "Preview training", "day_name": "Strength A", "slots": slots]
        app.launchEnvironment["TRESFORT_UI_GROUP_CONTRACT"] = String(
            data: try JSONSerialization.data(withJSONObject: fixture), encoding: .utf8)
        app.launchArguments = ["-AppleLanguages", "(en)", "-AppleLocale", "en_US", "-restAudioCuesEnabled", "NO"]
        app.launch()
        let preview = app.buttons["today.viewWorkout"]
        XCTAssertTrue(preview.waitForExistence(timeout: UITestWait.screen)); preview.tap()
        XCTAssertTrue(app.navigationBars["Strength A"].waitForExistence(timeout: UITestWait.screen))
        return app
    }

    private func reveal(_ element: XCUIElement, in app: XCUIApplication) {
        for _ in 0..<22 {
            if element.exists && element.isHittable { return }
            // At the largest system text size the pinned action fills the
            // lower half of the sheet. Swipe only inside its scrollable area;
            // an application-wide swipe starts on that fixed footer.
            let top = app.navigationBars["Strength A"].frame.maxY + 24
            let bottom = app.buttons["workoutDetails.start"].frame.minY - 24
            let origin = app.coordinate(withNormalizedOffset: .zero)
            origin.withOffset(CGVector(dx: app.frame.midX, dy: bottom))
                .press(forDuration: 0.05,
                       thenDragTo: origin.withOffset(CGVector(dx: app.frame.midX, dy: top)))
        }
        XCTFail("Preview content is unreachable: \(element)")
    }

    private func capture(_ name: String) {
        let attachment = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        attachment.name = name; attachment.lifetime = .keepAlways; add(attachment)
    }

    func testLongGroupedPreviewKeepsDetailsAndStartReachableWithMissingArt() throws {
        let app = try launch()
        XCTAssertTrue(app.staticTexts["Circuit A"].exists)
        XCTAssertTrue(app.staticTexts["A1"].exists)
        XCTAssertTrue(app.staticTexts.matching(identifier: "3 rounds · 90s round rest").firstMatch.exists)
        XCTAssertTrue(app.staticTexts.matching(identifier: "15s between exercises").firstMatch.exists)
        let start = app.buttons["workoutDetails.start"]
        XCTAssertTrue(start.isHittable)
        reveal(app.staticTexts.matching(identifier: "Barbell Squat").firstMatch, in: app)
        capture("preview-thumbnails")
        let info = app.buttons.matching(identifier: "Exercise information for " + longName).firstMatch
        reveal(info, in: app); info.tap()
        XCTAssertTrue(app.staticTexts["No demo available yet"].waitForExistence(timeout: UITestWait.screen))
        app.buttons["exerciseInfo.done"].tap()
        let last = app.otherElements["workoutPreview.exercise.preview-11"]
        reveal(last, in: app)
        XCTAssertTrue(app.staticTexts["D3"].exists)
        reveal(last.staticTexts["Cable Face Pull"], in: app)
        XCTAssertTrue(start.isHittable)
        capture("preview-thumbnails-long-workout-end")
        app.navigationBars["Strength A"].buttons["Done"].tap()
        XCTAssertTrue(app.buttons["today.startWorkout"].waitForExistence(timeout: UITestWait.screen))
    }

    func testReducedMotionPreviewKeepsInformationAndStartReachable() throws {
        // The app treats this launch override like the system Reduce Motion
        // setting (see ReduceMotion.swift). Toggling it in Apple's Settings app
        // depended on Settings' layout and speed and timed out on loaded CI
        // simulators.
        let app = try launch(reduceMotion: true)
        let name = app.staticTexts.matching(identifier: longName).firstMatch
        reveal(name, in: app)
        capture("preview-thumbnails-reduce-motion")
        let info = app.buttons.matching(identifier: "Exercise information for " + longName).firstMatch
        // The info action precedes the full-width text at accessibility sizes.
        for _ in 0..<3 where !info.isHittable { app.swipeDown() }
        XCTAssertTrue(info.isHittable)
        XCTAssertGreaterThanOrEqual(info.frame.width, 44)
        XCTAssertGreaterThanOrEqual(info.frame.height, 44)
        info.tap()
        XCTAssertTrue(app.segmentedControls["exerciseInfo.tabs"].waitForExistence(timeout: UITestWait.screen))
        app.buttons["exerciseInfo.done"].tap()
        XCTAssertTrue(app.buttons["workoutDetails.start"].isHittable)
    }
}
