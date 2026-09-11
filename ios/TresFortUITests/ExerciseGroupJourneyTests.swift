import XCTest

final class ExerciseGroupJourneyTests: XCTestCase {
    override func setUpWithError() throws { continueAfterFailure = false }

    private func launch() throws -> XCUIApplication {
        let app = XCUIApplication()
        let contract = try XCTUnwrap(Bundle(for: Self.self).url(forResource: "ExerciseGroups", withExtension: "json"))
        app.launchEnvironment["TRESFORT_UI_FIXTURE"] = "groups"
        app.launchEnvironment["TRESFORT_UI_GROUP_CONTRACT"] = try String(contentsOf: contract, encoding: .utf8)
        // Notification permission is covered by the activation journeys.
        app.launchArguments = ["-AppleLanguages", "(en)", "-AppleLocale", "en_US", "-restAudioCuesEnabled", "NO"]
        app.launch()
        XCTAssertTrue(app.buttons["today.chooseWorkout"].waitForExistence(timeout: 10))
        app.buttons["today.chooseWorkout"].tap()
        let workout = app.buttons.containing(.staticText, identifier: "Warm-up and strength").firstMatch
        XCTAssertTrue(workout.waitForExistence(timeout: 10))
        workout.tap()
        XCTAssertTrue(app.buttons["workoutDetails.edit"].waitForExistence(timeout: 5))
        app.buttons["workoutDetails.edit"].tap()
        XCTAssertTrue(app.buttons["editor.actions"].waitForExistence(timeout: 5))
        return app
    }

    private func reveal(_ element: XCUIElement, in app: XCUIApplication) {
        _ = element.waitForExistence(timeout: 5)
        for _ in 0..<12 {
            if element.exists && element.isHittable && element.frame.maxY < app.frame.maxY - 10 { return }
            app.swipeUp()
        }
        XCTFail("Control did not become reachable: \(element)")
    }

    private func screenshot(_ name: String) {
        let attachment = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    private func author(_ app: XCUIApplication, slots: [String], roundRestDecrements: Int, transition: Bool) {
        app.buttons["editor.actions"].tap()
        app.buttons["Group exercises"].tap()
        for slot in slots {
            let select = app.buttons["editor.select.\(slot)"]
            reveal(select, in: app)
            select.tap()
            XCTAssertEqual(select.value as? String, "Selected")
        }
        let group = app.buttons["Group as superset"]
        XCTAssertTrue(group.isEnabled)
        group.tap()
        let roundRest = app.steppers["group.roundRest"]
        reveal(roundRest, in: app)
        for _ in 0..<roundRestDecrements { roundRest.buttons["group.roundRest-Decrement"].tap() }
        if transition { app.steppers["group.transitionRest"].buttons["group.transitionRest-Increment"].tap() }
        screenshot(transition ? "working-group-prescription" : "warmup-group-prescription")
        let save = app.buttons["Save group"]
        reveal(save, in: app)
        save.tap()
        XCTAssertTrue(app.buttons["editor.actions"].waitForExistence(timeout: 10))
    }

    func testAuthorWarmupAndWorkingSupersetThenRunAlternatingRounds() throws {
        let app = try launch()
        author(app, slots: ["group-pushup", "group-squat"], roundRestDecrements: 1, transition: false)
        XCTAssertTrue(app.staticTexts["Superset A"].exists)
        XCTAssertTrue(app.staticTexts["Round rest: 30s"].exists)
        author(app, slots: ["group-bench", "group-row"], roundRestDecrements: 4, transition: true)
        reveal(app.buttons["Edit Superset B"], in: app)
        XCTAssertTrue(app.staticTexts["Transition rest: 15s"].exists)
        screenshot("authored-two-groups")
        app.navigationBars["Edit Warm-up and strength"].buttons["Done"].tap()
        app.navigationBars["Warm-up and strength"].buttons["Done"].tap()
        app.navigationBars["Choose a workout"].buttons["Done"].tap()
        let start = app.buttons["today.startWorkout"]
        reveal(start, in: app)
        screenshot("group-workout-preview")
        start.tap()
        let allowNotifications = XCUIApplication(bundleIdentifier: "com.apple.springboard")
            .alerts.buttons["Allow"]
        if allowNotifications.waitForExistence(timeout: 5) { allowNotifications.tap() }

        let names = ["PUSH-UP", "BODYWEIGHT SQUAT", "PUSH-UP", "BODYWEIGHT SQUAT",
                     "BENCH PRESS", "BARBELL ROW", "BENCH PRESS", "BARBELL ROW"]
        let rounds = [1, 1, 2, 2, 1, 1, 2, 2]
        for index in names.indices {
            let name = app.staticTexts[names[index]]
            XCTAssertTrue(name.waitForExistence(timeout: 10))
            if index == 0 {
                screenshot("superset-runner-before-header-check")
                XCTAssertTrue(app.descendants(matching: .any)["runner.group"].waitForExistence(timeout: 5))
                XCTAssertTrue(app.descendants(matching: .any)["runner.group.member.group-pushup"].exists)
                XCTAssertTrue(app.descendants(matching: .any)["runner.group.member.group-squat"].exists)
                XCTAssertTrue(app.staticTexts["Log each exercise to advance automatically."].exists)
            }
            if index >= 4 {
                let weight = app.buttons["runner.weight"]
                for _ in 0..<5 where !weight.isHittable { app.swipeDown() }
                reveal(weight, in: app)
                if index < 6 {
                    weight.tap()
                    app.segmentedControls["weight.unit"].buttons["kg"].tap()
                    let entry = app.textFields["weight.entry"]
                    let previous = entry.value as? String ?? ""
                    entry.coordinate(withNormalizedOffset: CGVector(dx: 0.95, dy: 0.5)).tap()
                    entry.typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: previous.count)
                                   + (index == 4 ? "20" : "15"))
                    XCTAssertEqual(entry.value as? String, index == 4 ? "20" : "15")
                    app.buttons["Save"].tap()
                }
                XCTAssertEqual(weight.value as? String, index % 2 == 0 ? "20" : "15")
                if index == 6 { screenshot("superset-second-round-retains-kilograms") }
            }
            let log = app.buttons["LOG ROUND \(rounds[index])"]
            XCTAssertTrue(log.waitForExistence(timeout: 5))
            XCTAssertTrue(log.isEnabled)
            XCTAssertTrue(app.frame.contains(log.frame))
            XCTAssertGreaterThanOrEqual(log.frame.height, 44)
            if index == 0 || index == 4 { screenshot("group-runner-member-\(index)") }
            // iOS can report isHittable=false after restoring the rest screen's
            // navigation chrome even though this visible footer receives taps.
            // Exercise its actual touch target; the exact next member/rest and
            // fixture sequence below prove the tap logged one physical set.
            log.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
            if index == 0 || index == 2 {
                // A zero transition advances immediately without a rest cue.
                XCTAssertTrue(app.staticTexts[names[index + 1]].waitForExistence(timeout: 5))
                XCTAssertFalse(app.buttons["rest.done"].exists)
            } else {
                let done = app.buttons["rest.done"]
                XCTAssertTrue(done.waitForExistence(timeout: 5))
                XCTAssertEqual(app.staticTexts["rest.upNext"].label,
                               index + 1 < names.count ? names[index + 1] : "DONE")
                if index == 4 { screenshot("transition-rest-next-member") }
                done.tap()
            }
        }
        XCTAssertTrue(app.staticTexts["READY TO FINISH"].waitForExistence(timeout: 10))
        let finish = app.buttons["FINISH"]
        XCTAssertTrue(finish.waitForExistence(timeout: 5))
        XCTAssertTrue(finish.isEnabled)
        XCTAssertTrue(app.frame.contains(finish.frame))
        XCTAssertGreaterThanOrEqual(finish.frame.height, 44)
        // The final pinned action follows the same rest/chrome transition as
        // Log. Verify a real touch and the acknowledged completion below.
        finish.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
        XCTAssertTrue(app.staticTexts["WORKOUT COMPLETE"].waitForExistence(timeout: 10))
        XCTAssertFalse(app.staticTexts["Synthetic member sequence mismatch"].exists)
        screenshot("completed-alternating-workout")
    }

    func testGroupedTargetsAndUngroupKeepIndividualRests() throws {
        let app = try launch()
        author(app, slots: ["group-pushup", "group-squat"], roundRestDecrements: 1, transition: false)
        let slot = app.buttons["editor.slot.group-pushup"]
        reveal(slot, in: app)
        slot.tap()
        let ordinaryRest = app.steppers["slot.ordinaryRest"]
        reveal(ordinaryRest, in: app)
        XCTAssertFalse(ordinaryRest.isEnabled)
        XCTAssertTrue(app.staticTexts["Individual rest · inactive"].exists)
        screenshot("grouped-slot-inactive-rest")
        app.navigationBars.buttons["Cancel"].tap()
        let edit = app.buttons["Edit Superset A"]
        // Scroll back to the start of the card after returning from a long form.
        for _ in 0..<5 where !edit.isHittable { app.swipeDown() }
        XCTAssertTrue(edit.waitForExistence(timeout: 5))
        edit.tap()
        let ungroup = app.buttons["Ungroup"]
        reveal(ungroup, in: app)
        ungroup.tap()
        XCTAssertTrue(app.buttons["editor.actions"].waitForExistence(timeout: 10))
        XCTAssertFalse(app.staticTexts["Superset A"].exists)
        let pushup = app.buttons["editor.slot.group-pushup"]
        for _ in 0..<5 where !pushup.isHittable { app.swipeDown() }
        XCTAssertTrue(pushup.staticTexts["2×10 · 45s rest"].exists)
        XCTAssertTrue(app.buttons["editor.slot.group-squat"].staticTexts["2×10 · 90s rest"].exists)
        screenshot("ungrouped-original-rests")
    }
}
