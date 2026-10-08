import XCTest

final class RunnerStreamlineJourneyTests: XCTestCase {
    override func setUpWithError() throws { continueAfterFailure = false }

    override func tearDownWithError() throws {
        if (testRun?.failureCount ?? 0) > 0 { print(XCUIApplication().debugDescription) }
    }

    private func launch(_ fixture: String = "app-store", largeText: Bool = false,
                        startWorkout: Bool = true, groupContract: String? = nil,
                        tickingClock: Bool = false) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchEnvironment["TRESFORT_UI_FIXTURE"] = fixture
        app.launchEnvironment["TRESFORT_UI_ACCEPT_CORRECTIONS"] = "1"
        app.launchEnvironment["TRESFORT_UI_GROUP_CONTRACT"] = groupContract
        if tickingClock { app.launchEnvironment["TRESFORT_UI_TICKING_CLOCK"] = "1" }
        if largeText { app.launchEnvironment["TRESFORT_UI_LARGE_TEXT"] = "1" }
        app.launchArguments = ["-AppleLanguages", "(en)", "-AppleLocale", "en_US",
                               "-restAudioCuesEnabled", "NO",
                               "-com.nmarkspdx.tresfort.weight-entry-unit", "lb"]
        app.launch()
        if fixture == "app-store" || fixture == "groups" {
            let start = app.buttons["today.startWorkout"]
            XCTAssertTrue(start.waitForExistence(timeout: 10))
            guard startWorkout else { return app }
            reveal(start, in: app); start.tap()
        }
        XCTAssertTrue(app.staticTexts["runner.exerciseTitle"].waitForExistence(timeout: 10))
        return app
    }

    private func reveal(_ element: XCUIElement, in app: XCUIApplication) {
        XCTAssertTrue(element.waitForExistence(timeout: 5))
        for _ in 0..<10 {
            if element.isHittable && element.frame.maxY <= app.frame.maxY - 34 { break }
            // The target can be above the viewport after a previous gesture.
            // Select its own surface so a sheet never scrolls underlying Today;
            // fixed controls already reachable above return without a gesture.
            let identifier = element.identifier.isEmpty ? element.label : element.identifier
            let scroll = app.scrollViews.containing(element.elementType, identifier: identifier).firstMatch
            guard scroll.exists else { break }
            let viewport = scroll.frame.intersection(app.frame)
            let top = viewport.minY + 8
            let bottom = min(viewport.maxY, app.frame.maxY - 34) - 8
            let height = bottom - top
            guard !viewport.isNull, height > 48 else { break }
            let offset = element.frame.midY - (top + bottom) / 2
            let down = offset < 0
            // Partial, slow drags avoid the momentum of swipeUp overshooting a
            // short control in the smaller accessibility-size viewport.
            let distance = min(height * 0.45, max(24, abs(offset)))
            let startY = top + height * (down ? 0.25 : 0.75)
            let origin = app.coordinate(withNormalizedOffset: .zero)
            let start = origin.withOffset(CGVector(dx: viewport.midX, dy: startY))
            let end = origin.withOffset(CGVector(dx: viewport.midX, dy: startY + (down ? distance : -distance)))
            start.press(forDuration: 0.1, thenDragTo: end,
                        withVelocity: .slow, thenHoldForDuration: 0.5)
        }
        XCTAssertTrue(element.isHittable)
        XCTAssertLessThanOrEqual(element.frame.maxY, app.frame.maxY - 34)
    }

    private func capture(_ name: String) {
        let attachment = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        attachment.name = name; attachment.lifetime = .keepAlways; add(attachment)
    }

    func testLargestTextSeparatesTodayActionsAndExerciseDemoFromTitle() {
        let app = launch(largeText: true, startWorkout: false)
        let view = app.buttons["today.viewWorkout"]
        let change = app.buttons["today.changeWorkout"]
        XCTAssertTrue(view.exists); XCTAssertTrue(change.exists)
        XCTAssertGreaterThanOrEqual(change.frame.minY, view.frame.maxY)
        capture("today-accessibility-actions-stacked")
        let start = app.buttons["today.startWorkout"]
        reveal(start, in: app); start.tap()
        let title = app.staticTexts["runner.exerciseTitle"]
        XCTAssertTrue(title.waitForExistence(timeout: 5))
        let demo = app.buttons["Exercise information for Barbell Squat"]
        XCTAssertTrue(demo.exists)
        XCTAssertGreaterThanOrEqual(demo.frame.minY, title.frame.maxY)
        capture("runner-accessibility-title-and-demo")
        reveal(demo, in: app); demo.tap()
        XCTAssertTrue(app.staticTexts["MUSCLES"].waitForExistence(timeout: 5))
    }

    func testCompactRestKeepsEndEditAndLoggingReachableAtAccessibilitySize() {
        let app = launch(largeText: true)
        reveal(app.buttons["LOG SET 1"], in: app); app.buttons["LOG SET 1"].tap()
        let endRest = app.buttons["rest.done"]
        reveal(endRest, in: app)
        XCTAssertTrue(app.buttons["Expand rest timer"].exists)
        let edit = app.buttons["rest.editLastSet"]
        reveal(edit, in: app); edit.tap()
        let correction = app.navigationBars["Correct set"]
        XCTAssertTrue(correction.waitForExistence(timeout: 5))
        app.buttons["Cancel"].tap()
        expectation(for: NSPredicate(format: "exists == false"), evaluatedWith: correction)
        waitForExpectations(timeout: 5)
        // All primary actions share the scrolling surface at accessibility
        // sizes; the footer must never consume the entire input viewport.
        for _ in 0..<8 where !endRest.isHittable { app.scrollViews.firstMatch.swipeDown() }
        XCTAssertTrue(endRest.isHittable); endRest.tap()
        reveal(app.buttons["LOG SET 2"], in: app)
        capture("compact-rest-accessibility-size")
        app.buttons["LOG SET 2"].tap()
        XCTAssertTrue(app.buttons["LOG SET 3"].waitForExistence(timeout: 5))
    }

    func testLoadRepsAndLoggingStayInPlaceWhenRestStarts() {
        let app = launch()
        let weight = app.buttons["runner.weight"]
        let reps = app.buttons["Increase reps by 1"]
        let log = app.buttons["LOG SET 1"]
        let beforeWeight = weight.frame
        let beforeReps = reps.frame
        let beforeLog = log.frame
        XCTAssertTrue(weight.isHittable); XCTAssertTrue(reps.isHittable); XCTAssertTrue(log.isHittable)
        XCTAssertGreaterThanOrEqual(reps.frame.height, 44)
        XCTAssertTrue(app.buttons["runner.outline"].isHittable)
        XCTAssertFalse(app.tabBars.firstMatch.isHittable)
        XCTAssertFalse(app.segmentedControls["runner.weight.unit"].exists)
        reps.tap()
        XCTAssertEqual(app.buttons["runner.reps"].value as? String, "6")
        log.tap()
        XCTAssertTrue(app.buttons["rest.done"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["rest.editLastSet"].isHittable)
        XCTAssertTrue(reps.isHittable)
        XCTAssertEqual(weight.frame.minY, beforeWeight.minY, accuracy: 1)
        XCTAssertEqual(reps.frame.minY, beforeReps.minY, accuracy: 1)
        XCTAssertEqual(app.buttons["LOG SET 2"].frame.minY, beforeLog.minY, accuracy: 1)
        XCTAssertFalse(app.staticTexts["rest.status"].exists)
        capture("focus-rest-keeps-workspace-stable")
    }

    func testCorrectionTargetsLastSetAfterAdvancingAndEndingRest() {
        let app = launch()
        for index in 1...3 {
            app.buttons["LOG SET \(index)"].tap()
            XCTAssertTrue(app.buttons["rest.done"].waitForExistence(timeout: 5))
            app.buttons["rest.done"].tap()
        }
        let edit = app.buttons["rest.editLastSet"]
        XCTAssertTrue(edit.isHittable)
        XCTAssertEqual(edit.label, "Edit last set of Barbell Squat")
        XCTAssertEqual(app.staticTexts["runner.exerciseTitle"].label, "DUMBBELL ROW")
        XCTAssertTrue(app.staticTexts["Last set · Barbell Squat"].exists)
        XCTAssertEqual(app.buttons["runner.weight"].value as? String, "40")
        edit.tap()
        let reps = app.textFields["Reps"]
        XCTAssertTrue(reps.waitForExistence(timeout: 5))
        let old = reps.value as? String ?? ""
        reps.tap()
        reps.coordinate(withNormalizedOffset: CGVector(dx: 1, dy: 0.5))
            .withOffset(CGVector(dx: -1, dy: 0)).tap()
        reps.typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: old.count) + "6")
        XCTAssertEqual(reps.value as? String, "6")
        app.buttons["Save"].tap()
        let corrected = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "label == %@", "135 × 6 · lb"),
            object: app.staticTexts["rest.lastValues"])
        XCTAssertEqual(XCTWaiter.wait(for: [corrected], timeout: 10), .completed)
        XCTAssertEqual(edit.label, "Edit last set of Barbell Squat")
        XCTAssertEqual(app.buttons["runner.weight"].value as? String, "40")
        XCTAssertEqual(app.buttons["runner.reps"].value as? String, "10")
        capture("last-set-corrected-after-advance-and-rest")
    }

    func testOutlineNavigationPreservesDraftsAndDoesNotSkipExercises() {
        let app = launch()
        app.buttons["Increase reps by 1"].tap()
        app.buttons["Increase weight in lb by 5"].tap()
        app.buttons["runner.outline"].tap()
        XCTAssertTrue(app.navigationBars["Workout outline"].waitForExistence(timeout: 5))
        let row = app.buttons["Dumbbell Row"]
        reveal(row, in: app); row.tap()
        XCTAssertEqual(app.staticTexts["runner.exerciseTitle"].label, "DUMBBELL ROW")
        app.buttons["runner.outline"].tap()
        let squat = app.buttons["Barbell Squat"]
        XCTAssertTrue(squat.waitForExistence(timeout: 5))
        XCTAssertFalse(squat.staticTexts["Skipped"].exists)
        squat.tap()
        XCTAssertEqual(app.buttons["runner.weight"].value as? String, "140")
        XCTAssertEqual(app.buttons["runner.reps"].value as? String, "6")
        XCTAssertTrue(app.buttons["LOG SET 1"].exists)
    }

    func testMinimizeAndResumeRetainsDraftAndRest() {
        let app = launch()
        app.buttons["LOG SET 1"].tap()
        XCTAssertTrue(app.buttons["rest.done"].waitForExistence(timeout: 5))
        app.buttons["Increase reps by 1"].tap()
        app.buttons["runner.minimize"].tap()
        XCTAssertTrue(app.buttons["runner.resume"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.tabBars.firstMatch.isHittable)
        app.tabBars.buttons["Progress"].tap()
        let resume = app.buttons["workout.resume"]
        XCTAssertTrue(resume.waitForExistence(timeout: 5))
        XCTAssertTrue(resume.isHittable)
        resume.tap()
        XCTAssertTrue(app.buttons["LOG SET 2"].waitForExistence(timeout: 5))
        XCTAssertEqual(app.buttons["runner.reps"].value as? String, "6")
        XCTAssertTrue(app.buttons["rest.done"].isHittable)
        XCTAssertTrue(app.buttons["rest.editLastSet"].isHittable)
        XCTAssertFalse(app.tabBars.firstMatch.isHittable)
    }

    func testMinimizeAndResumeDoesNotRestartTimedSet() {
        let app = launch("timed-navigation")
        app.buttons["START SET 1"].tap()
        let remaining = app.staticTexts["runner.timer.remaining"]
        XCTAssertTrue(remaining.waitForExistence(timeout: 5))
        let initial = Int(remaining.label.dropLast())!
        app.buttons["runner.minimize"].tap()
        XCTAssertTrue(app.buttons["runner.resume"].waitForExistence(timeout: 5))
        app.buttons["runner.resume"].tap()
        XCTAssertTrue(remaining.waitForExistence(timeout: 5))
        XCTAssertLessThan(Int(remaining.label.dropLast())!, initial)
        XCTAssertTrue(app.buttons["STOP & LOG"].exists)
        XCTAssertFalse(app.buttons["START SET 1"].exists)
        XCTAssertEqual(app.staticTexts["fixture.scenario"].value as? String,
                       "bike:0;other:0;seconds:0;warmup:0")
    }

    func testMinimizedLastTimedSetKeepsReviewRouteOnAnotherTab() throws {
        let url = try XCTUnwrap(Bundle(for: Self.self).url(forResource: "ExerciseGroups", withExtension: "json"))
        var contract = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
        var slot = try XCTUnwrap((contract["slots"] as? [[String: Any]])?.first)
        slot["exercise_name"] = "Timed hold"
        slot["exercise_modality"] = "timed"
        slot["target_sets"] = 1
        slot["target_reps"] = 15
        slot["is_warmup"] = 0
        slot["group_id"] = NSNull()
        contract["slots"] = [slot]
        let encoded = String(data: try JSONSerialization.data(withJSONObject: contract), encoding: .utf8)!
        let app = launch(groupContract: encoded, tickingClock: true)
        app.buttons["START SET 1"].tap()
        app.buttons["runner.minimize"].tap()
        XCTAssertTrue(app.buttons["runner.resume"].waitForExistence(timeout: 5))
        app.tabBars.buttons["Progress"].tap()
        let resume = app.buttons["workout.resume"]
        XCTAssertTrue(resume.waitForExistence(timeout: 5))
        expectation(for: NSPredicate(format: "label CONTAINS %@", "Review workout"), evaluatedWith: resume)
        waitForExpectations(timeout: 25)
        XCTAssertTrue(resume.isHittable)
        resume.tap()
        XCTAssertTrue(app.buttons["FINISH"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["READY TO FINISH"].exists)
        XCTAssertFalse(app.staticTexts["WORKOUT COMPLETE"].exists)
    }

    func testBodyweightOffersCompactLoadDisclosureAndSignedEntry() {
        let app = launch("bodyweight")
        let add = app.buttons["runner.addBodyweightLoad"]
        XCTAssertTrue(add.isHittable)
        XCTAssertFalse(app.buttons["runner.weight"].exists)
        XCTAssertTrue(app.buttons["Increase reps by 1"].isHittable)
        add.tap()
        let weight = app.buttons["runner.weight"]
        XCTAssertTrue(weight.isHittable); weight.tap()
        let entry = app.textFields["weight.entry"]
        XCTAssertTrue(entry.waitForExistence(timeout: 5))
        entry.doubleTap()
        entry.typeText("-10")
        XCTAssertEqual(entry.value as? String, "-10")
        app.buttons["Save"].tap()
        XCTAssertEqual(weight.value as? String, "-10")
        capture("bodyweight-assistance-entry")
    }

    func testCircuitRosterAndNextTargetStayAheadOfInputs() throws {
        let contractURL = try XCTUnwrap(Bundle(for: Self.self).url(forResource: "ExerciseGroups", withExtension: "json"))
        var contract = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: contractURL)) as? [String: Any])
        var slots = try XCTUnwrap(contract["slots"] as? [[String: Any]])
        for index in slots.indices {
            slots[index]["group_id"] = "focus-circuit"
            slots[index]["group_rest_seconds"] = 60
            slots[index]["group_transition_seconds"] = 15
            slots[index]["is_warmup"] = 0
        }
        contract["slots"] = slots
        let encoded = String(data: try JSONSerialization.data(withJSONObject: contract), encoding: .utf8)!
        let app = launch("groups", groupContract: encoded)
        XCTAssertTrue(app.staticTexts["runner.group"].label.contains("Round 1 of 2"))
        for id in ["group-pushup", "group-squat", "group-bench", "group-row"] {
            let member = app.descendants(matching: .any)["runner.group.member.\(id)"]
            XCTAssertTrue(member.exists)
            XCTAssertTrue(app.frame.contains(member.frame))
        }
        let next = app.staticTexts["runner.group.next"]
        XCTAssertTrue(next.label.contains("Bodyweight Squat"))
        XCTAssertTrue(next.label.contains("10"))
        XCTAssertLessThan(next.frame.maxY, app.buttons["runner.addBodyweightLoad"].frame.minY)
        XCTAssertTrue(app.buttons["Increase reps by 1"].isHittable)
        XCTAssertTrue(app.buttons["LOG SET 1"].isHittable)
        capture("focus-four-member-circuit")
    }

    func testExpandedRestIsExplicitAndEndRestNeverBecomesLog() {
        let app = launch()
        app.buttons["LOG SET 1"].tap()
        let expand = app.buttons["Expand rest timer"]
        XCTAssertTrue(expand.waitForExistence(timeout: 5)); expand.tap()
        XCTAssertTrue(app.staticTexts["rest.status"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.buttons["LOG SET 2"].isHittable)
        let minimize = app.buttons["rest.minimize"]
        minimize.tap()
        expectation(for: NSPredicate(format: "exists == false"), evaluatedWith: minimize)
        waitForExpectations(timeout: 5)
        let end = app.buttons["rest.done"]
        XCTAssertTrue(end.isHittable)
        let endFrame = end.frame
        let endPoint = app.coordinate(withNormalizedOffset: .zero)
            .withOffset(CGVector(dx: endFrame.midX, dy: endFrame.midY))
        end.tap()
        endPoint.tap()
        XCTAssertTrue(app.buttons["LOG SET 2"].exists)
        XCTAssertFalse(app.buttons["LOG SET 3"].exists)
    }

    func testOneSavedSetUsesSingularCompletionSummary() {
        let app = launch()
        app.buttons["LOG SET 1"].tap()
        XCTAssertTrue(app.buttons["rest.done"].waitForExistence(timeout: 5))
        app.buttons["rest.done"].tap()
        app.buttons["today.workoutActions"].tap()
        app.buttons["Finish workout"].tap()
        let finish = app.buttons["feedback.finishWithoutChanges"]
        XCTAssertTrue(finish.waitForExistence(timeout: 5)); finish.tap()
        let summary = app.staticTexts["today.completedSummary"]
        XCTAssertTrue(summary.waitForExistence(timeout: 10))
        XCTAssertEqual(summary.label, "1 working set · 1 exercise")
    }
}
