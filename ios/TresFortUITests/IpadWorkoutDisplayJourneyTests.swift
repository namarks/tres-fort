import XCTest

final class IpadWorkoutDisplayJourneyTests: XCTestCase {
    override func setUpWithError() throws {
        continueAfterFailure = false
        try XCTSkipIf(UIDevice.current.userInterfaceIdiom != .pad, "Distance workout display is an iPad surface")
    }

    override func tearDownWithError() throws {
        let app = XCUIApplication()
        if (testRun?.failureCount ?? 0) > 0 { print(app.debugDescription) }
        // Do not rotate a remaining modal or SpringBoard just to clean up.
        // Each launch establishes its orientation after the app is foreground.
        if app.state != .notRunning { app.terminate() }
    }

    private func launch(largeText: Bool = false, linked: String? = nil) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchEnvironment["TRESFORT_UI_FIXTURE"] = "app-store"
        app.launchEnvironment["TRESFORT_UI_ACCEPT_CORRECTIONS"] = "1"
        if largeText { app.launchEnvironment["TRESFORT_UI_LARGE_TEXT"] = "1" }
        if let linked { app.launchEnvironment["TRESFORT_UI_STATION_DISPLAY"] = linked }
        app.launchArguments = ["-AppleLanguages", "(en)", "-AppleLocale", "en_US",
                               "-restAudioCuesEnabled", "NO",
                               "-com.nmarkspdx.tresfort.weight-entry-unit", "lb"]
        app.launch()
        orient(.landscapeLeft, in: app)
        let entry = app.buttons[linked == nil ? "today.startWorkout" : "today.station"]
        XCTAssertTrue(entry.waitForExistence(timeout: UITestWait.screen))
        reveal(entry, in: app)
        // Starting a workout isn't safe to repeat, so this waits but never
        // taps a second time.
        entry.tapWhenReady()
        if linked != "disconnected" {
            XCTAssertTrue(element("ipadWorkout.display", in: app).waitForExistence(timeout: UITestWait.screen))
        }
        return app
    }

    private func orient(_ orientation: UIDeviceOrientation, in app: XCUIApplication,
                        file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertEqual(app.state, .runningForeground, file: file, line: line)
        if XCUIDevice.shared.orientation != orientation {
            XCUIDevice.shared.orientation = orientation
        }
        let expected = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
            let frame = app.frame
            return orientation.isLandscape ? frame.width > frame.height : frame.height > frame.width
        }, object: nil)
        XCTAssertEqual(XCTWaiter.wait(for: [expected], timeout: 5), .completed,
                       "The foreground app must finish the requested rotation", file: file, line: line)
    }

    private func element(_ id: String, in app: XCUIApplication) -> XCUIElement {
        app.descendants(matching: .any).matching(identifier: id).firstMatch
    }

    private func reveal(_ value: XCUIElement, in app: XCUIApplication,
                        file: StaticString = #filePath, line: UInt = #line) {
        UITestScrolling.reveal(value, in: app, maxAttempts: 14, file: file, line: line)
    }

    private func expectLabel(_ label: String, on value: XCUIElement,
                             file: StaticString = #filePath, line: UInt = #line) {
        let expected = XCTNSPredicateExpectation(predicate: NSPredicate(format: "label == %@", label), object: value)
        XCTAssertEqual(XCTWaiter.wait(for: [expected], timeout: 5), .completed, file: file, line: line)
    }

    private func assertVisible(_ value: XCUIElement, in app: XCUIApplication,
                               file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertTrue(value.exists, file: file, line: line)
        XCTAssertTrue(value.isHittable, file: file, line: line)
        XCTAssertTrue(app.frame.contains(value.frame), "Display element is clipped: \(value.identifier)", file: file, line: line)
    }

    private func capture(_ name: String) {
        let attachment = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        attachment.name = name; attachment.lifetime = .keepAlways; add(attachment)
    }

    func testStandaloneLoggingRestAndExerciseProgressionUseTheSameDisplay() {
        let app = launch()
        let phase = app.staticTexts["ipadWorkout.phase"]
        expectLabel("READY FOR YOUR SET", on: phase)
        XCTAssertEqual(app.staticTexts["runner.exerciseTitle"].label, "BARBELL SQUAT")
        XCTAssertEqual(element("ipadWorkout.target", in: app).label, "135 lb × 5 reps")
        XCTAssertEqual(app.staticTexts["ipadWorkout.position"].label, "SET 1 OF 3")
        XCTAssertFalse(element("ipadWorkout.countdown", in: app).exists)
        capture("ipad-display-standalone-ready")

        for set in 1...3 {
            let log = app.buttons["runner.logSet"]
            assertVisible(log, in: app)
            XCTAssertEqual(log.label, "LOG SET \(set)")
            log.tap()
            let endRest = app.buttons["rest.done"]
            XCTAssertTrue(endRest.waitForExistence(timeout: 5))
            expectLabel("REST", on: phase)
            assertVisible(element("ipadWorkout.countdown", in: app), in: app)
            assertVisible(endRest, in: app)
            XCTAssertTrue(app.buttons["runner.logSet"].exists, "Logging keeps a stable target below the separate rest action")
            XCTAssertFalse(app.buttons["runner.logSet"].isEnabled, "End rest before logging the next set")
            if set == 1 {
                XCTAssertEqual(app.staticTexts["ipadWorkout.position"].label, "SET 2 OF 3")
                XCTAssertTrue(element("ipadWorkout.next", in: app).label.contains("SET 2 OF 3"))
                capture("ipad-display-standalone-rest")
            }
            endRest.tap()
            expectLabel("READY FOR YOUR SET", on: phase)
            XCTAssertFalse(element("ipadWorkout.countdown", in: app).exists)
        }
        XCTAssertEqual(app.staticTexts["runner.exerciseTitle"].label, "DUMBBELL ROW")
        XCTAssertEqual(app.staticTexts["ipadWorkout.position"].label, "SET 1 OF 3")
        XCTAssertTrue(element("ipadWorkout.target", in: app).label.contains("40 lb"))
        capture("ipad-display-standalone-next-exercise")

        app.buttons["runner.outline"].tap()
        let completedSquat = app.buttons["Barbell Squat"]
        XCTAssertTrue(completedSquat.waitForExistence(timeout: 5)); completedSquat.tap()
        expectLabel("EXERCISE COMPLETE", on: phase)
        XCTAssertFalse(element("ipadWorkout.target", in: app).exists)
        XCTAssertFalse(element("ipadWorkout.next", in: app).exists)
        XCTAssertFalse(app.buttons["runner.logSet"].exists)
        XCTAssertTrue(app.buttons["runner.outline"].isHittable)
    }

    func testRepeatingTheEndRestTapNeverLogsTheNextSet() {
        for orientation in [UIDeviceOrientation.landscapeLeft, .portrait] {
            let app = launch()
            orient(orientation, in: app)
            app.buttons["runner.logSet"].tap()
            let endRest = app.buttons["rest.done"]
            XCTAssertTrue(endRest.waitForExistence(timeout: 5))
            let log = app.buttons["runner.logSet"]
            XCTAssertFalse(log.isEnabled)
            let logFrame = log.frame
            let endFrame = endRest.frame
            print("End rest repeat frames before: orientation=\(orientation.rawValue), rest=\(endFrame), log=\(logFrame)")
            XCTAssertTrue(app.frame.contains(logFrame), "The reserved logging control must remain fully visible during rest")
            XCTAssertFalse(endFrame.intersects(logFrame), "Rest and logging must retain distinct tap targets")
            let repeatedTap = app.coordinate(withNormalizedOffset: .zero)
                .withOffset(CGVector(dx: endFrame.midX, dy: endFrame.midY))
            endRest.tap()
            repeatedTap.tap()
            let resultingPhase = app.staticTexts["ipadWorkout.phase"].label
            let resultingPosition = app.staticTexts["ipadWorkout.position"].label
            print("End rest repeat state after: phase=\(resultingPhase), position=\(resultingPosition), log=\(log.frame)")

            expectLabel("READY FOR YOUR SET", on: app.staticTexts["ipadWorkout.phase"])
            XCTAssertEqual(app.staticTexts["ipadWorkout.position"].label, "SET 2 OF 3")
            XCTAssertEqual(log.label, "LOG SET 2")
            XCTAssertTrue(log.isEnabled)
            XCTAssertEqual(log.frame.minY, logFrame.minY, accuracy: 1)
            XCTAssertFalse(app.buttons["rest.done"].exists)
            capture(orientation == .portrait ? "ipad-display-end-rest-repeat-portrait" : "ipad-display-end-rest-repeat-landscape")
            app.terminate()
        }
    }

    func testEditedValuesSurviveOutlineNavigationAndBecomeTheLoggedSet() {
        let app = launch()
        let editor = app.navigationBars["Next set"]
        app.buttons["runner.editValues"].tap(until: editor)
        replace(app.textFields["Weight"], with: "140")
        replace(app.textFields["Reps"], with: "6")
        replace(app.textFields["—"], with: "8.5")
        editor.buttons["Save"].tap()
        expectLabel("140 lb × 6 reps · RPE 8.5", on: element("ipadWorkout.target", in: app))
        XCTAssertTrue(element("ipadWorkout.next", in: app).label.contains("RPE 8.5"))
        capture("ipad-display-edited-rpe")

        app.buttons["runner.outline"].tap()
        let row = app.buttons["Dumbbell Row"]
        XCTAssertTrue(row.waitForExistence(timeout: 5)); row.tap()
        XCTAssertEqual(app.staticTexts["runner.exerciseTitle"].label, "DUMBBELL ROW")
        app.buttons["runner.outline"].tap()
        let squat = app.buttons["Barbell Squat"]
        XCTAssertTrue(squat.waitForExistence(timeout: 5))
        XCTAssertFalse(squat.staticTexts["Skipped"].exists)
        squat.tap()
        expectLabel("140 lb × 6 reps · RPE 8.5", on: element("ipadWorkout.target", in: app))
        XCTAssertEqual(app.buttons["runner.logSet"].label, "LOG SET 1")

        app.buttons["runner.logSet"].tap()
        XCTAssertTrue(app.buttons["rest.done"].waitForExistence(timeout: 5))
        expectLabel("Last set · 140 × 6 · lb · RPE 8.5", on: app.staticTexts["rest.lastValues"])
        capture("ipad-display-rest-rpe")
        app.buttons["rest.done"].tap()
        expectLabel("140 lb × 6 reps · RPE 8.5", on: element("ipadWorkout.target", in: app))
        XCTAssertEqual(app.buttons["runner.logSet"].label, "LOG SET 2")
    }

    func testPortraitAndLandscapeKeepInstructionsAndPrimaryControlsVisible() {
        let app = launch()
        for orientation in [UIDeviceOrientation.portrait, .landscapeLeft] {
            orient(orientation, in: app)
            for id in ["runner.exerciseTitle", "ipadWorkout.phase", "ipadWorkout.position", "ipadWorkout.target", "ipadWorkout.next"] {
                assertVisible(element(id, in: app), in: app)
            }
            for id in ["runner.editValues", "runner.outline", "runner.logSet"] {
                assertVisible(app.buttons[id], in: app)
                XCTAssertGreaterThanOrEqual(app.buttons[id].frame.height, 44)
            }
            capture(orientation == .portrait ? "ipad-display-portrait" : "ipad-display-landscape")
        }
    }

    func testAccessibilityLayoutKeepsEditingLoggingAndRestReachableAfterRotation() {
        let app = launch(largeText: true)
        orient(.portrait, in: app)
        let edit = app.buttons["runner.editValues"]
        reveal(edit, in: app); edit.tap(until: app.navigationBars["Next set"])
        app.navigationBars["Next set"].buttons["Cancel"].tap()
        let log = app.buttons["runner.logSet"]
        reveal(log, in: app); log.tap()
        let endRest = app.buttons["rest.done"]
        XCTAssertTrue(endRest.waitForExistence(timeout: 5))
        reveal(endRest, in: app)
        capture("ipad-display-accessibility-portrait-rest")
        orient(.landscapeLeft, in: app)
        reveal(endRest, in: app); endRest.tap()
        reveal(log, in: app)
        XCTAssertEqual(log.label, "LOG SET 2")
        let outline = app.buttons["runner.outline"]
        reveal(outline, in: app); outline.tap(until: app.navigationBars["Workout outline"])
        XCTAssertTrue(app.buttons["runner.outline.done"].isHittable)
    }

    func testLinkedDisplayShowsManualMovementAndRestWithoutLocalWorkoutActions() {
        for mode in ["ready", "rest"] {
            let app = launch(linked: mode)
            expectLabel(mode == "rest" ? "REST" : "READY FOR YOUR SET", on: app.staticTexts["ipadWorkout.phase"])
            XCTAssertEqual(app.staticTexts["runner.exerciseTitle"].label, "CABLE FACE PULL")
            XCTAssertEqual(element("ipadWorkout.target", in: app).label, "22.5 kg × 12 reps · RPE 8")
            XCTAssertEqual(app.staticTexts["ipadWorkout.position"].label, "SET 2 OF 3")
            XCTAssertTrue(element("ipadWorkout.source", in: app).label.contains("iPhone"))
            XCTAssertEqual(element("ipadWorkout.countdown", in: app).exists, mode == "rest")
            let next = element("ipadWorkout.next", in: app)
            XCTAssertTrue(next.label.contains(mode == "rest" ? "CABLE FACE PULL" : "PLANK"))
            XCTAssertTrue(next.label.contains(mode == "rest" ? "RPE 8" : "RPE 7"))
            if mode == "ready" { XCTAssertTrue(next.label.contains("45 seconds")) }
            XCTAssertFalse(app.buttons["runner.logSet"].exists)
            XCTAssertFalse(app.buttons["runner.editValues"].exists)
            XCTAssertFalse(app.buttons["rest.done"].exists)
            capture("ipad-display-linked-\(mode)")
            app.buttons["station.done"].tap(until: app.buttons["today.startWorkout"])
            app.terminate()
        }
    }

    func testLinkedDisplayClearsStaleInstructionsWhenTheProjectionIsWithdrawn() {
        let app = launch(linked: "disconnected")
        XCTAssertTrue(element("ipadWorkout.connection", in: app).waitForExistence(timeout: 5))
        XCTAssertFalse(element("ipadWorkout.target", in: app).exists)
        XCTAssertFalse(app.staticTexts["runner.exerciseTitle"].exists)
        XCTAssertFalse(element("ipadWorkout.countdown", in: app).exists)
        XCTAssertFalse(app.buttons["runner.logSet"].exists)
        XCTAssertTrue(app.buttons["station.done"].isHittable)
        capture("ipad-display-linked-disconnected")
        app.buttons["station.done"].tap(until: app.buttons["today.startWorkout"])
    }

    func testLinkedControlsMoveTheIphoneWorkoutBesideItsOutlineAndClock() {
        let app = launch(linked: "controls")
        let phase = app.staticTexts["ipadWorkout.phase"]
        expectLabel("READY FOR YOUR SET", on: phase)
        XCTAssertEqual(app.staticTexts["runner.exerciseTitle"].label, "CABLE FACE PULL")
        XCTAssertEqual(element("ipadWorkout.target", in: app).label, "22.5 kg × 12 reps · RPE 8")
        XCTAssertEqual(app.staticTexts["ipadWorkout.position"].label, "SET 1 OF 3")
        assertVisible(element("ipadWorkout.clock", in: app), in: app)
        assertVisible(element("ipadWorkout.workoutTime", in: app), in: app)
        let outline = element("ipadWorkout.outline", in: app)
        XCTAssertTrue(outline.exists)
        XCTAssertTrue(app.frame.contains(outline.frame), "The outline sits beside the set")
        XCTAssertFalse(element("ipadWorkout.next", in: app).exists, "The outline takes the place of Up next")
        capture("ipad-display-linked-controls")

        // Log the set here; the iPhone logs it and starts the rest.
        let log = app.buttons["runner.logSet"]
        assertVisible(log, in: app)
        XCTAssertEqual(log.label, "LOG SET 1")
        log.tap()
        let endRest = app.buttons["rest.done"]
        XCTAssertTrue(endRest.waitForExistence(timeout: 5))
        expectLabel("REST", on: phase)
        XCTAssertEqual(app.staticTexts["ipadWorkout.position"].label, "SET 2 OF 3")
        XCTAssertFalse(log.isEnabled, "End rest before logging the next set")
        endRest.tap()
        expectLabel("READY FOR YOUR SET", on: phase)
        XCTAssertEqual(log.label, "LOG SET 2")

        let editor = app.navigationBars["Next set"]
        app.buttons["runner.editValues"].tap(until: editor)
        replace(app.textFields["Reps"], with: "10")
        editor.buttons["Save"].tap()
        expectLabel("22.5 kg × 10 reps · RPE 8", on: element("ipadWorkout.target", in: app))

        // Choosing an exercise in the outline moves the iPhone there without skipping.
        let goblet = app.buttons["ipadWorkout.outline.synthetic-control-goblet"]
        assertVisible(goblet, in: app)
        goblet.tap()
        expectLabel("GOBLET SQUAT", on: app.staticTexts["runner.exerciseTitle"])
        XCTAssertEqual(app.staticTexts["ipadWorkout.position"].label, "SET 1 OF 3")
        let facePull = app.buttons["ipadWorkout.outline.synthetic-control-face-pull"]
        XCTAssertTrue((facePull.value as? String)?.contains("1 of 3 sets") == true)

        let plank = app.buttons["ipadWorkout.outline.synthetic-control-plank"]
        assertVisible(plank, in: app)
        plank.tap()
        expectLabel("PLANK", on: app.staticTexts["runner.exerciseTitle"])
        let start = app.buttons["runner.startSet"]
        XCTAssertEqual(start.label, "START SET 1")
        start.tap()
        let stop = app.buttons["runner.stopTimedSet"]
        XCTAssertTrue(stop.waitForExistence(timeout: 5))
        XCTAssertFalse(facePull.isEnabled, "A running hold stays until it is stopped")
        stop.tap()
        XCTAssertTrue(endRest.waitForExistence(timeout: 5))
        expectLabel("REST", on: phase)

        let toggle = app.buttons["ipadWorkout.outlineToggle"]
        XCTAssertEqual(toggle.label, "Hide outline")
        toggle.tap()
        XCTAssertTrue(element("ipadWorkout.next", in: app).waitForExistence(timeout: 5))
        XCTAssertFalse(outline.exists)
        toggle.tap()
        XCTAssertTrue(outline.waitForExistence(timeout: 5))

        orient(.portrait, in: app)
        assertVisible(element("ipadWorkout.clock", in: app), in: app)
        assertVisible(app.staticTexts["runner.exerciseTitle"], in: app)
        assertVisible(app.buttons["ipadWorkout.outline.synthetic-control-plank"], in: app)
        assertVisible(endRest, in: app)
        capture("ipad-display-linked-controls-portrait")
    }

    func testReconnectingKeepsTheLinkedWorkoutOnScreenWithItsControlsOff() {
        let app = launch(linked: "reconnecting")
        assertVisible(element("ipadWorkout.reconnecting", in: app), in: app)
        XCTAssertEqual(app.staticTexts["runner.exerciseTitle"].label, "CABLE FACE PULL")
        XCTAssertEqual(app.staticTexts["ipadWorkout.position"].label, "SET 1 OF 3")
        let log = app.buttons["runner.logSet"]
        XCTAssertTrue(log.exists, "Controls keep their place while the iPhone reconnects")
        XCTAssertFalse(log.isEnabled)
        XCTAssertFalse(app.buttons["runner.editValues"].isEnabled)
        XCTAssertFalse(app.buttons["ipadWorkout.outline.synthetic-control-goblet"].isEnabled)
        capture("ipad-display-linked-reconnecting")
        app.buttons["station.done"].tap(until: app.buttons["today.startWorkout"])
    }

    private func replace(_ field: XCUIElement, with text: String) {
        XCTAssertTrue(field.waitForExistence(timeout: 5))
        let old = field.value as? String ?? ""
        field.tap()
        field.coordinate(withNormalizedOffset: CGVector(dx: 1, dy: 0.5))
            .withOffset(CGVector(dx: -1, dy: 0)).tap()
        field.typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: old.count) + text)
        XCTAssertEqual(field.value as? String, text)
    }
}
