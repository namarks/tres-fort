import XCTest

final class TodayNavigationJourneyTests: XCTestCase {
    override func setUpWithError() throws { continueAfterFailure = false }
    override func tearDownWithError() throws {
        if (testRun?.failureCount ?? 0) > 0 {
            print(XCUIApplication().debugDescription)
            capture("today-navigation-failure")
        }
    }
    private func launch(unassignedDate: Bool = false, createRefreshFailure: Bool = false, moveConflict: Bool = false, creationFailure: String? = nil) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchEnvironment["TRESFORT_UI_FIXTURE"] = "app-store"
        if unassignedDate { app.launchEnvironment["TRESFORT_UI_UNASSIGNED_DATE"] = "1" }
        if createRefreshFailure { app.launchEnvironment["TRESFORT_UI_CREATE_REFRESH_FAILURE"] = "1" }
        if moveConflict { app.launchEnvironment["TRESFORT_UI_MOVE_CONFLICT"] = "1" }
        if let creationFailure { app.launchEnvironment["TRESFORT_UI_CREATE_FAILURE"] = creationFailure }
        app.launchArguments = ["-AppleLanguages", "(en)", "-AppleLocale", "en_US", "-restAudioCuesEnabled", "NO"]
        app.launch()
        XCTAssertTrue(app.buttons["today.viewWorkout"].waitForExistence(timeout: 10))
        return app
    }
    private func tap(_ element: XCUIElement, in app: XCUIApplication) {
        XCTAssertTrue(element.waitForExistence(timeout: 5))
        for _ in 0..<6 where !element.isHittable { app.swipeUp() }
        XCTAssertTrue(element.isHittable); element.tap()
    }
    private func capture(_ name: String) {
        let image = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        image.name = name; image.lifetime = .keepAlways; add(image)
    }

    func testTodayButtonsOpenNamedDetailsLibraryCreatorAndActivity() {
        let app = launch()
        XCTAssertFalse(app.buttons["Workout options"].exists)
        XCTAssertFalse(app.buttons["today.createWorkout"].exists)
        XCTAssertEqual(app.navigationBars["Today"].buttons.count, 0)
        capture("today-navigation")
        tap(app.buttons["today.viewWorkout"], in: app)
        XCTAssertTrue(app.navigationBars["Strength A"].waitForExistence(timeout: 5))
        tap(app.buttons["workoutDetails.edit"], in: app)
        XCTAssertTrue(app.navigationBars["Edit Strength A"].waitForExistence(timeout: 5))
        tap(app.navigationBars["Edit Strength A"].buttons["Done"], in: app)
        tap(app.navigationBars["Strength A"].buttons["Done"], in: app)
        tap(app.buttons["today.chooseWorkout"], in: app)
        tap(app.buttons["library.workout.strength-b"], in: app)
        XCTAssertTrue(app.navigationBars["Strength B"].waitForExistence(timeout: 5))
        capture("chosen-workout-details")
        tap(app.navigationBars["Strength B"].buttons["Done"], in: app)
        XCTAssertTrue(app.navigationBars["Workouts"].waitForExistence(timeout: 5))
        tap(app.buttons["Add workout"], in: app)
        XCTAssertFalse(app.textFields["createWorkout.name"].exists)
        let selection = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "exercisePicker.exercise.")).firstMatch
        XCTAssertTrue(selection.waitForExistence(timeout: 5)); selection.tap()
        app.buttons["createWorkout.review"].tap()
        let name = app.textFields["createWorkout.name"]
        tap(name, in: app); name.typeText("Hotel session")
        tap(app.buttons["createWorkout.create"], in: app)
        XCTAssertTrue(app.navigationBars["Edit Hotel session"].waitForExistence(timeout: 5))
        tap(app.navigationBars["Edit Hotel session"].buttons["Done"], in: app)
        XCTAssertTrue(app.navigationBars["Hotel session"].waitForExistence(timeout: 5))
        tap(app.navigationBars["Hotel session"].buttons["Done"], in: app)
        XCTAssertTrue(app.navigationBars["Workouts"].waitForExistence(timeout: 5))
        XCTAssertEqual(app.buttons.matching(identifier: "library.workout.created-workout").count, 1)
        tap(app.navigationBars["Workouts"].buttons["Done"], in: app)
        XCTAssertTrue(app.staticTexts["Strength A"].exists, "Creation must not replace today's scheduled workout")
        tap(app.buttons["today.logActivity"], in: app)
        XCTAssertTrue(app.navigationBars["Log activity"].waitForExistence(timeout: 5))
        capture("activity-destination")
    }

    func testCalendarMovesAndRemovesOneDateWithoutChangingWeeklySchedule() {
        let app = launch()
        tap(app.tabBars.buttons["Calendar"], in: app)
        tap(app.buttons["calendar.date.2026-09-08"], in: app)
        tap(app.buttons["calendar.dateActions"], in: app)
        tap(app.buttons["calendar.moveWorkout"], in: app)
        let date = app.datePickers["calendar.moveDate"]
        tap(date.buttons.matching(NSPredicate(format: "label CONTAINS 'September 9'")).firstMatch, in: app)
        tap(app.buttons["calendar.confirmMove"], in: app)
        // Moving/removing a workout writes an explicit skipped session; the
        // agenda preserves that distinction from an unscheduled rest day.
        XCTAssertTrue(app.staticTexts["SKIPPED"].waitForExistence(timeout: 5))
        tap(app.buttons["calendar.dateActions"], in: app)
        XCTAssertTrue(app.buttons["calendar.chooseWorkout"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.buttons["calendar.moveWorkout"].exists)
        app.staticTexts["SKIPPED"].coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
        tap(app.navigationBars["Workout date"].buttons["Done"], in: app)
        tap(app.buttons["calendar.date.2026-09-09"], in: app)
        XCTAssertTrue(app.buttons["calendar.dateActions"].waitForExistence(timeout: 5))
        capture("moved-workout-date")
        tap(app.buttons["calendar.dateActions"], in: app)
        tap(app.buttons["calendar.removeWorkout"], in: app)
        // Native confirmation popovers omit the cancel row; tapping their
        // dismissal region cancels without changing the planned workout.
        let dismissRegion = app.otherElements["PopoverDismissRegion"]
        XCTAssertTrue(dismissRegion.waitForExistence(timeout: 5))
        dismissRegion.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.9)).tap()
        XCTAssertTrue(app.staticTexts["STRENGTH A"].waitForExistence(timeout: 5))
        tap(app.buttons["calendar.dateActions"], in: app)
        tap(app.buttons["calendar.removeWorkout"], in: app)
        tap(app.buttons["Remove workout"], in: app)
        XCTAssertTrue(app.staticTexts["SKIPPED"].waitForExistence(timeout: 5))
        tap(app.buttons["calendar.dateActions"], in: app)
        XCTAssertTrue(app.buttons["calendar.chooseWorkout"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.buttons["calendar.removeWorkout"].exists)
        app.staticTexts["SKIPPED"].coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
        tap(app.navigationBars["Workout date"].buttons["Done"], in: app)
        tap(app.buttons["calendar.weeklySchedule"], in: app)
        XCTAssertTrue(app.navigationBars["Weekly schedule"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons.matching(NSPredicate(format: "label CONTAINS 'Tuesday' AND label CONTAINS 'Strength A'")).firstMatch.exists)
        capture("unchanged-weekly-schedule")
    }

    private func launchGroupedPreview() throws -> XCUIApplication {
        let contractURL = try XCTUnwrap(Bundle(for: Self.self).url(forResource: "ExerciseGroups", withExtension: "json"))
        var contract = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: contractURL)) as? [String: Any])
        var slots = try XCTUnwrap(contract["slots"] as? [[String: Any]])
        let groups = try XCTUnwrap(contract["groups"] as? [[String: Any]])
        for (index, group) in groups.enumerated() {
            for member in try XCTUnwrap(group["member_indices"] as? [Int]) {
                slots[member]["group_id"] = "preview-\(index)"
                slots[member]["group_rest_seconds"] = group["round_rest"]
                slots[member]["group_transition_seconds"] = group["transition_rest"]
            }
        }
        slots[0]["cues"] = "Keep a steady tempo."
        slots[2]["exercise_name"] = "Dumbbell Push Press"
        slots[2]["exercise_modality"] = "dumbbell"
        slots[2]["exercise_load_mode"] = "per_hand"
        slots[2]["target_weight"] = 25
        contract["slots"] = slots
        let app = XCUIApplication()
        app.launchEnvironment["TRESFORT_UI_FIXTURE"] = "app-store"
        app.launchEnvironment["TRESFORT_UI_GROUP_CONTRACT"] = String(
            decoding: try JSONSerialization.data(withJSONObject: contract), as: UTF8.self)
        app.launchArguments = ["-AppleLanguages", "(en)", "-AppleLocale", "en_US",
                               "-com.nmarkspdx.tresfort.weight-entry-unit", "lb"]
        app.launch()
        XCTAssertTrue(app.buttons["today.viewWorkout"].waitForExistence(timeout: 10))
        return app
    }

    func testPrescribedWeightsAppearInLibraryAndCalendar() throws {
        let app = try launchGroupedPreview()
        tap(app.buttons["today.chooseWorkout"], in: app)
        tap(app.buttons["library.workout.synthetic-day"], in: app)
        XCTAssertTrue(app.navigationBars["Strength A"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["2×8 · 25 lb each hand"].exists)
        XCTAssertTrue(app.staticTexts["2×8 · 45 lb"].exists)
        capture("library-prescribed-weights")
        tap(app.navigationBars["Strength A"].buttons["Done"], in: app)
        tap(app.navigationBars["Workouts"].buttons["Done"], in: app)
        tap(app.tabBars.buttons["Calendar"], in: app)
        tap(app.buttons["calendar.date.2026-09-08"], in: app)
        XCTAssertTrue(app.staticTexts["2×8 · 25 lb each hand"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["2×8 · 45 lb"].exists)
        capture("calendar-prescribed-weights")
    }

    func testCalendarPrioritizesGroupedWorkoutAndMatchesLibraryPreview() throws {
        let app = try launchGroupedPreview()
        tap(app.tabBars.buttons["Calendar"], in: app)
        tap(app.buttons["calendar.date.2026-09-08"], in: app)
        XCTAssertTrue(app.staticTexts["Superset A"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["STRENGTH A"].exists)
        XCTAssertFalse(app.staticTexts["STRENGTH A · STRENGTH A"].exists)
        XCTAssertLessThan(app.staticTexts["Superset A"].frame.maxY, app.frame.height * 0.5,
                          "The workout should be visible in the top half without scrolling")
        XCTAssertFalse(app.buttons["calendar.moveWorkout"].exists)
        XCTAssertFalse(app.buttons["calendar.removeWorkout"].exists)
        let actions = app.buttons["calendar.dateActions"]
        XCTAssertGreaterThanOrEqual(actions.frame.width, 44)
        XCTAssertGreaterThanOrEqual(actions.frame.height, 44)
        XCTAssertTrue(actions.isHittable)

        func assertGroupedPreview() {
            let warmup = app.descendants(matching: .any)["workoutPreview.group:preview-0"].firstMatch
            XCTAssertTrue(warmup.waitForExistence(timeout: 5))
            XCTAssertTrue(warmup.staticTexts["Push-Up"].exists)
            XCTAssertTrue(warmup.staticTexts["Bodyweight Squat"].exists)
            XCTAssertEqual(warmup.staticTexts.matching(identifier: "WARM-UP").count, 2)
            XCTAssertTrue(warmup.staticTexts["2 rounds · 30s round rest"].exists)
            XCTAssertTrue(warmup.staticTexts["Keep a steady tempo."].exists)
            let working = app.descendants(matching: .any)["workoutPreview.group:preview-1"].firstMatch
            XCTAssertTrue(working.staticTexts["Dumbbell Push Press"].exists)
            XCTAssertTrue(working.staticTexts["Barbell Row"].exists)
            XCTAssertTrue(working.staticTexts["2 rounds · 60s round rest"].exists)
            XCTAssertTrue(working.staticTexts["15s between exercises"].exists)
            XCTAssertTrue(working.staticTexts["2×8 · 25 lb each hand"].exists)
            XCTAssertTrue(working.staticTexts["2×8 · 45 lb"].exists)
        }

        assertGroupedPreview()
        capture("calendar-grouped-workout")
        tap(app.buttons["Exercise information for Push-Up"], in: app)
        let demoTitle = app.staticTexts["PUSH-UP"]
        XCTAssertTrue(demoTitle.waitForExistence(timeout: 5))
        tap(app.buttons["exerciseInfo.done"], in: app)
        expectation(for: NSPredicate(format: "exists == false"), evaluatedWith: demoTitle)
        waitForExpectations(timeout: 5)
        XCTAssertTrue(actions.waitForExistence(timeout: 5))
        XCTAssertTrue(actions.isHittable)
        // A large accessibility frame alone does not prove the full target
        // receives touches. Exercise the bottom edge of the 44pt area.
        actions.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
            .withOffset(CGVector(dx: 0, dy: 21)).tap()
        XCTAssertTrue(app.buttons["calendar.moveWorkout"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["calendar.removeWorkout"].exists)
        tap(app.buttons["calendar.chooseWorkout"], in: app)
        XCTAssertTrue(app.navigationBars["Choose a workout"].waitForExistence(timeout: 5))
        tap(app.buttons["library.workout.synthetic-day"], in: app)
        XCTAssertTrue(app.navigationBars["Strength A"].waitForExistence(timeout: 5))
        assertGroupedPreview()
        capture("library-matching-grouped-workout")
    }

    func testCalendarCanRemoveAPlannedDateWithoutASavedWorkoutIdentity() {
        let app = launch(unassignedDate: true)
        tap(app.tabBars.buttons["Calendar"], in: app)
        tap(app.buttons["calendar.date.2026-09-09"], in: app)
        tap(app.buttons["calendar.dateActions"], in: app)
        XCTAssertFalse(app.buttons["calendar.moveWorkout"].exists)
        tap(app.buttons["calendar.removeWorkout"], in: app)
        tap(app.buttons["Remove workout"], in: app)
        XCTAssertTrue(app.staticTexts["SKIPPED"].waitForExistence(timeout: 5))
        tap(app.buttons["calendar.dateActions"], in: app)
        XCTAssertTrue(app.buttons["calendar.chooseWorkout"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.buttons["calendar.removeWorkout"].exists)
    }

    func testCalendarMoveConflictRefreshesAndAllowsARevisedRequest() {
        let app = launch(moveConflict: true)
        tap(app.tabBars.buttons["Calendar"], in: app)
        tap(app.buttons["calendar.date.2026-09-08"], in: app)
        tap(app.buttons["calendar.dateActions"], in: app)
        tap(app.buttons["calendar.moveWorkout"], in: app)
        let picker = app.datePickers["calendar.moveDate"]
        tap(picker.buttons.matching(NSPredicate(format: "label CONTAINS 'September 9'")).firstMatch, in: app)
        tap(app.buttons["calendar.confirmMove"], in: app)
        XCTAssertTrue(app.buttons["Refresh calendar"].waitForExistence(timeout: 5))
        XCTAssertTrue(picker.isEnabled)
        XCTAssertEqual(app.buttons["calendar.confirmMove"].label, "Move workout")
        tap(app.buttons["calendar.confirmMove"], in: app)
        XCTAssertTrue(app.staticTexts["SKIPPED"].waitForExistence(timeout: 5))
        tap(app.buttons["calendar.dateActions"], in: app)
        XCTAssertTrue(app.buttons["calendar.chooseWorkout"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.buttons["calendar.moveWorkout"].exists)
    }

    func testAcknowledgedCreationRecoversThroughRefreshWithoutCreatingAgain() {
        let app = launch(createRefreshFailure: true)
        tap(app.buttons["today.chooseWorkout"], in: app)
        tap(app.buttons["Add workout"], in: app)
        XCTAssertFalse(app.textFields["createWorkout.name"].exists)
        let selection = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "exercisePicker.exercise.")).firstMatch
        XCTAssertTrue(selection.waitForExistence(timeout: 5)); selection.tap()
        app.buttons["createWorkout.review"].tap()
        let name = app.textFields["createWorkout.name"]
        tap(name, in: app); name.typeText("Hotel session")
        tap(app.buttons["createWorkout.create"], in: app)
        XCTAssertTrue(app.navigationBars["Workout unavailable"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.buttons["createWorkout.create"].exists)
        tap(app.buttons["Refresh"], in: app)
        XCTAssertTrue(app.navigationBars["Edit Hotel session"].waitForExistence(timeout: 5))
        tap(app.navigationBars["Edit Hotel session"].buttons["Done"], in: app)
        tap(app.navigationBars["Hotel session"].buttons["Done"], in: app)
        XCTAssertTrue(app.navigationBars["Workouts"].waitForExistence(timeout: 5))
        XCTAssertEqual(app.buttons.matching(identifier: "library.workout.created-workout").count, 1)
        tap(app.navigationBars["Workouts"].buttons["Done"], in: app)
        XCTAssertTrue(app.staticTexts["Strength A"].exists, "Creation must preserve today's scheduled workout")
    }

    func testCreationConflictAllowsFreshAuthorityWithoutDuplicatingAnUncertainCreation() {
        for failure in ["conflict", "lost-response"] {
            let app = launch(creationFailure: failure)
            tap(app.buttons["today.chooseWorkout"], in: app)
            tap(app.buttons["Add workout"], in: app)
            XCTAssertFalse(app.textFields["createWorkout.name"].exists)
            let selection = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "exercisePicker.exercise.")).firstMatch
            XCTAssertTrue(selection.waitForExistence(timeout: 5)); selection.tap()
            app.buttons["createWorkout.review"].tap()
            let name = app.textFields["createWorkout.name"]
            tap(name, in: app); name.typeText("Hotel session")
            let create = app.buttons["createWorkout.create"]
            tap(create, in: app)
            let expectedLabel = failure == "conflict" ? "Create workout" : "Retry creation"
            expectation(for: NSPredicate(format: "label == %@ AND enabled == true", expectedLabel), evaluatedWith: create)
            waitForExpectations(timeout: 10)
            XCTAssertEqual(name.isEnabled, failure == "conflict")
            XCTAssertEqual(name.value as? String, "Hotel session")
            tap(create, in: app)
            if failure == "conflict" {
                XCTAssertTrue(app.navigationBars["Edit Hotel session"].waitForExistence(timeout: 5))
                tap(app.navigationBars["Edit Hotel session"].buttons["Done"], in: app)
                tap(app.navigationBars["Hotel session"].buttons["Done"], in: app)
            } else {
                XCTAssertTrue(app.staticTexts["The earlier request may have saved. Close this screen and check your workout library before creating another workout."].waitForExistence(timeout: 5))
                XCTAssertFalse(create.isEnabled)
                tap(app.buttons["Cancel"], in: app)
            }
            XCTAssertTrue(app.navigationBars["Workouts"].waitForExistence(timeout: 5))
            XCTAssertEqual(app.buttons.matching(identifier: "library.workout.created-workout").count, 1)
            tap(app.navigationBars["Workouts"].buttons["Done"], in: app)
            XCTAssertTrue(app.staticTexts["Strength A"].exists, "Creation must preserve today's scheduled workout")
            app.terminate()
        }
    }

    func testDiscardRemainsReachableAfterFinishFails() {
        let app = XCUIApplication()
        app.launchEnvironment["TRESFORT_UI_FIXTURE"] = "ready-to-finish"
        app.launchEnvironment["TRESFORT_UI_FINISH_FAILURE"] = "1"
        app.launchArguments = ["-AppleLanguages", "(en)", "-AppleLocale", "en_US", "-restAudioCuesEnabled", "NO"]
        app.launch()
        tap(app.buttons["FINISH"], in: app)
        XCTAssertTrue(app.staticTexts["WORKOUT FINISH WAITING TO SYNC"].waitForExistence(timeout: 10))
        tap(app.buttons["today.workoutActions"], in: app)
        let discard = app.buttons["today.discardWorkout"]
        XCTAssertTrue(discard.isEnabled)
        tap(discard, in: app)
        XCTAssertTrue(app.buttons["Discard — don't save"].waitForExistence(timeout: 5))
    }

    func testFirstWorkoutCreationRetainsTheFormThroughPlanRecovery() {
        for failure in ["request", "refresh"] {
            let app = XCUIApplication()
            app.launchEnvironment["TRESFORT_UI_FIXTURE"] = "empty"
            app.launchEnvironment["TRESFORT_UI_ENSURE_FAILURE"] = failure
            app.launchArguments = ["-AppleLanguages", "(en)", "-AppleLocale", "en_US"]
            app.launch()
            tap(app.buttons["today.createWorkout"], in: app)
            XCTAssertFalse(app.textFields["createWorkout.name"].exists)
            let selection = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "exercisePicker.exercise.")).firstMatch
            XCTAssertTrue(selection.waitForExistence(timeout: 5)); selection.tap()
            app.buttons["createWorkout.review"].tap()
            let name = app.textFields["createWorkout.name"]
            tap(name, in: app); name.typeText("First workout")
            tap(app.buttons["createWorkout.create"], in: app)
            tap(app.buttons["createWorkout.refreshPlan"], in: app)
            XCTAssertEqual(name.value as? String, "First workout")
            tap(app.buttons["createWorkout.create"], in: app)
            XCTAssertTrue(app.navigationBars["Edit First workout"].waitForExistence(timeout: 5))
            app.terminate()
        }
    }

    func testUnresolvedRealWorkoutRemainsVisibleWithItsRecord() {
        for (status, emptyLibrary) in [("planned", false), ("in_progress", false), ("planned", true), ("in_progress", true)] {
            let app = XCUIApplication()
            app.launchEnvironment["TRESFORT_UI_FIXTURE"] = "app-store"
            app.launchEnvironment["TRESFORT_UI_UNRESOLVED_TODAY"] = status
            if emptyLibrary { app.launchEnvironment["TRESFORT_UI_EMPTY_WORKOUT_LIBRARY"] = "1" }
            app.launchArguments = ["-AppleLanguages", "(en)", "-AppleLocale", "en_US"]
            app.launch()
            XCTAssertTrue(app.staticTexts["Workout needs review"].waitForExistence(timeout: 10))
            XCTAssertFalse(app.staticTexts["Nothing scheduled"].exists)
            XCTAssertFalse(app.buttons["today.starterWorkout"].exists)
            XCTAssertFalse(app.buttons["today.startWorkout"].exists)
            tap(app.buttons["today.viewUnresolvedWorkout"], in: app)
            XCTAssertTrue(app.navigationBars["Workout record"].waitForExistence(timeout: 5))
            if status == "in_progress" {
                XCTAssertTrue(app.staticTexts["SET 1"].exists)
                XCTAssertFalse(app.staticTexts["No sets logged."].exists)
            } else {
                tap(app.buttons["calendar.dateActions"], in: app)
                XCTAssertTrue(app.buttons["calendar.removeWorkout"].exists)
            }
            app.terminate()
        }
    }
}
