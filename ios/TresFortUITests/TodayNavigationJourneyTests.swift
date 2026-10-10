import XCTest

final class TodayNavigationJourneyTests: XCTestCase {
    override func setUpWithError() throws { continueAfterFailure = false }
    override func tearDownWithError() throws {
        if (testRun?.failureCount ?? 0) > 0 {
            print(XCUIApplication().debugDescription)
            capture("today-navigation-failure")
        }
    }
    private func launch(unassignedDate: Bool = false, createRefreshFailure: Bool = false, moveConflict: Bool = false, creationFailure: String? = nil, restCues: Bool = false) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchEnvironment["TRESFORT_UI_FIXTURE"] = "app-store"
        if unassignedDate { app.launchEnvironment["TRESFORT_UI_UNASSIGNED_DATE"] = "1" }
        if createRefreshFailure { app.launchEnvironment["TRESFORT_UI_CREATE_REFRESH_FAILURE"] = "1" }
        if moveConflict { app.launchEnvironment["TRESFORT_UI_MOVE_CONFLICT"] = "1" }
        if let creationFailure { app.launchEnvironment["TRESFORT_UI_CREATE_FAILURE"] = creationFailure }
        app.launchArguments = ["-AppleLanguages", "(en)", "-AppleLocale", "en_US", "-restAudioCuesEnabled", restCues ? "YES" : "NO"]
        app.launch()
        XCTAssertTrue(app.buttons["today.viewWorkout"].waitForExistence(timeout: 10))
        return app
    }
    private func tap(_ element: XCUIElement, in app: XCUIApplication) {
        XCTAssertTrue(element.waitForExistence(timeout: 5))
        for _ in 0..<6 where !element.isHittable { app.swipeUp() }
        XCTAssertTrue(element.isHittable); element.tap()
    }
    /// The calendar lives behind Today's week strip.
    private func openCalendar(in app: XCUIApplication) {
        tap(app.tabBars.buttons["Today"], in: app)
        tap(app.buttons["today.calendar"], in: app)
    }
    /// A tap that lands while the review screen is still animating in can
    /// leave the name field without keyboard focus. Retry the tap until it
    /// has focus, then type.
    private func type(_ text: String, into field: XCUIElement, in app: XCUIApplication) {
        let focused = NSPredicate(format: "hasKeyboardFocus == true")
        for _ in 0..<3 {
            tap(field, in: app)
            let wait = XCTNSPredicateExpectation(predicate: focused, object: field)
            if XCTWaiter.wait(for: [wait], timeout: 2) == .completed { break }
        }
        field.typeText(text)
    }
    private func capture(_ name: String) {
        let image = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        image.name = name; image.lifetime = .keepAlways; add(image)
    }

    func testTodayButtonsOpenNamedDetailsLibraryCreatorAndActivity() {
        let app = launch()
        XCTAssertFalse(app.buttons["Workout options"].exists)
        XCTAssertFalse(app.buttons["today.createWorkout"].exists)
        let displayConnection = app.navigationBars["Today"].buttons["today.ipadDisplay"]
        XCTAssertTrue(displayConnection.waitForExistence(timeout: 5))
        XCTAssertEqual(displayConnection.label, "iPad display")
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
        type("Hotel session", into: name, in: app)
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
        openCalendar(in: app)
        tap(app.buttons["calendar.date.2026-09-08"], in: app)
        tap(app.buttons["calendar.dateActions"], in: app)
        tap(app.buttons["calendar.moveWorkout"], in: app)
        let date = app.datePickers["calendar.moveDate"]
        tap(date.buttons.matching(NSPredicate(format: "label CONTAINS 'September 9'")).firstMatch, in: app)
        tap(app.buttons["calendar.confirmMove"], in: app)
        // Moving/removing a workout writes an explicit skipped session; the
        // agenda preserves that distinction from an unscheduled rest day.
        XCTAssertTrue(app.staticTexts["SKIPPED"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.buttons["calendar.startWorkout"].exists,
                       "A skipped date must be assigned again before it can start")
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
        openCalendar(in: app)
        tap(app.buttons["calendar.date.2026-09-08"], in: app)
        XCTAssertTrue(app.staticTexts["2×8 · 25 lb each hand"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["2×8 · 45 lb"].exists)
        capture("calendar-prescribed-weights")
    }

    func testCalendarPrioritizesGroupedWorkoutAndMatchesLibraryPreview() throws {
        let app = try launchGroupedPreview()
        openCalendar(in: app)
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
        XCTAssertTrue(app.buttons["workoutPicker.schedule"].isEnabled,
                      "Changing an assigned date starts with its current workout selected")
        tap(app.buttons["workoutPicker.workout.synthetic-day"], in: app)
        tap(app.buttons["workoutPicker.preview"], in: app)
        XCTAssertFalse(app.buttons["workoutDetails.edit"].exists)
        assertGroupedPreview()
        capture("picker-matching-grouped-workout")
    }

    func testCalendarPickerSchedulesOnlySelectedDateWithoutManagementTools() {
        let app = launch()
        openCalendar(in: app)
        tap(app.buttons["calendar.date.2026-09-09"], in: app)
        XCTAssertFalse(app.buttons["calendar.startWorkout"].exists, "Future workouts cannot be started")
        tap(app.buttons["calendar.dateActions"], in: app)
        tap(app.buttons["calendar.chooseWorkout"], in: app)
        XCTAssertTrue(app.navigationBars["Choose a workout"].waitForExistence(timeout: 5))
        XCTAssertEqual(app.staticTexts["workoutPicker.date"].label, "For 2026-09-09")
        XCTAssertFalse(app.buttons["workoutPicker.schedule"].isEnabled)
        XCTAssertFalse(app.buttons["library.scope"].exists)
        XCTAssertFalse(app.buttons["library.tagFilter"].exists)
        XCTAssertFalse(app.buttons["Actions for Strength B"].exists)
        XCTAssertFalse(app.buttons["Add workout"].exists)
        XCTAssertFalse(app.staticTexts["Changes"].exists)
        tap(app.buttons["workoutPicker.workout.strength-b"], in: app)
        XCTAssertTrue(app.buttons["workoutPicker.schedule"].isEnabled)
        capture("date-workout-picker")
        tap(app.buttons["workoutPicker.schedule"], in: app)
        XCTAssertTrue(app.navigationBars["Workout date"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["STRENGTH B"].exists)
        tap(app.navigationBars["Workout date"].buttons["Done"], in: app)
        tap(app.buttons["calendar.date.2026-09-08"], in: app)
        XCTAssertTrue(app.staticTexts["STRENGTH A"].waitForExistence(timeout: 5))
        tap(app.navigationBars["Workout date"].buttons["Done"], in: app)
        tap(app.buttons["calendar.date.2026-09-05"], in: app)
        XCTAssertFalse(app.buttons["calendar.startWorkout"].exists, "Historical records cannot be started")
    }

    func testChangeTodayUsesDatePickerAndPreservesLibraryManagementRoute() {
        let app = launch()
        tap(app.buttons["today.changeWorkout"], in: app)
        XCTAssertTrue(app.navigationBars["Choose a workout"].waitForExistence(timeout: 5))
        XCTAssertEqual(app.staticTexts["workoutPicker.date"].label, "For 2026-09-08")
        XCTAssertFalse(app.buttons["Actions for Strength A"].exists)
        XCTAssertFalse(app.buttons["Add workout"].exists)
        XCTAssertFalse(app.staticTexts["Changes"].exists)
        tap(app.buttons["workoutPicker.workout.strength-b"], in: app)
        tap(app.buttons["workoutPicker.schedule"], in: app)
        XCTAssertTrue(app.buttons["today.startWorkout"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["Strength B"].exists)
        XCTAssertFalse(app.buttons["LOG SET 1"].exists, "Changing the date must not start a workout")
        tap(app.buttons["today.chooseWorkout"], in: app)
        XCTAssertTrue(app.navigationBars["Workouts"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["Actions for Strength B"].exists)
        XCTAssertTrue(app.buttons["Add workout"].exists)
    }

    func testCompletedExercisesExpandToCorrectionControls() throws {
        let url = try XCTUnwrap(Bundle(for: Self.self).url(forResource: "WorkoutSummaryPresentation", withExtension: "json"))
        let app = XCUIApplication()
        app.launchEnvironment["TRESFORT_UI_FIXTURE"] = "workout-summary"
        app.launchEnvironment["TRESFORT_UI_SUMMARY_CONTRACT"] = try String(contentsOf: url)
        app.launchArguments = ["-AppleLanguages", "(en)", "-AppleLocale", "en_US"]
        app.launch()
        XCTAssertTrue(app.staticTexts["workoutSummary.duration"].waitForExistence(timeout: 10))
        XCTAssertFalse(app.buttons["edit-set-squat-1"].exists)
        // Tap the header text itself. The native DisclosureGroup button's
        // accessibility frame includes expanded content on some iOS versions.
        let exercise = app.staticTexts["calendar.exercise.squat"]
        tap(exercise, in: app)
        let edit = app.buttons["edit-set-squat-1"]
        tap(edit, in: app)
        XCTAssertTrue(app.navigationBars["Correct set"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.textFields["Weight"].exists)
        XCTAssertTrue(app.buttons["Delete set 1 of Goblet Squat"].exists)
        tap(app.navigationBars["Correct set"].buttons["Cancel"], in: app)
        tap(exercise, in: app)
        XCTAssertFalse(edit.exists)
        XCTAssertTrue(app.staticTexts["calendar.exercise.pushup"].exists)
        capture("completed-exercise-disclosures")
    }

    func testCalendarStartsAndContinuesTheSameTodaysWorkout() {
        let app = launch()
        openCalendar(in: app)
        tap(app.buttons["calendar.date.2026-09-08"], in: app)
        let start = app.buttons["calendar.startWorkout"]
        XCTAssertEqual(start.label, "Start workout")
        tap(start, in: app)
        XCTAssertTrue(app.buttons["LOG SET 1"].waitForExistence(timeout: 5))
        let exerciseName = app.staticTexts["runner.exerciseTitle"].label
        tap(app.buttons["LOG SET 1"], in: app)
        XCTAssertTrue(app.buttons["rest.done"].waitForExistence(timeout: 5))
        tap(app.buttons["runner.minimize"], in: app)
        openCalendar(in: app)
        tap(app.buttons["calendar.date.2026-09-08"], in: app)
        XCTAssertEqual(app.buttons["calendar.startWorkout"].label, "Continue workout")
        tap(app.buttons["calendar.startWorkout"], in: app)
        XCTAssertTrue(app.buttons["rest.done"].waitForExistence(timeout: 5))
        XCTAssertEqual(app.staticTexts["runner.exerciseTitle"].label, exerciseName)
        XCTAssertFalse(app.tabBars.buttons["Today"].isHittable)
        capture("calendar-continued-workout")
    }

    func testCalendarStartPreparesRestNotificationsBeforeLogging() {
        let app = launch(restCues: true)
        openCalendar(in: app)
        tap(app.buttons["calendar.date.2026-09-08"], in: app)
        tap(app.buttons["calendar.startWorkout"], in: app)
        // The OS prompts only once per installation. A fresh simulator must
        // finish this permission boundary before the first set can be logged.
        let allow = XCUIApplication(bundleIdentifier: "com.apple.springboard").alerts.buttons["Allow"]
        if allow.waitForExistence(timeout: 3) {
            XCTAssertFalse(app.buttons["LOG SET 1"].exists)
            allow.tap()
        }
        tap(app.buttons["LOG SET 1"], in: app)
        XCTAssertTrue(app.buttons["rest.done"].waitForExistence(timeout: 5))
        XCTAssertFalse(allow.exists, "Logging must not trigger a permission prompt")
    }

    func testCalendarCanRemoveAPlannedDateWithoutASavedWorkoutIdentity() {
        let app = launch(unassignedDate: true)
        openCalendar(in: app)
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
        openCalendar(in: app)
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
        type("Hotel session", into: name, in: app)
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
            type("Hotel session", into: name, in: app)
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
            type("First workout", into: name, in: app)
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
                XCTAssertTrue(app.staticTexts["IN PROGRESS"].exists)
                let exercise = app.staticTexts["calendar.exercise.squat"]
                XCTAssertTrue(exercise.waitForExistence(timeout: 5))
                XCTAssertEqual(exercise.label, "Barbell Squat")
                XCTAssertTrue(app.staticTexts["1 working set · 5 reps"].exists)
                XCTAssertFalse(app.staticTexts["Set 1"].exists)
                let edit = app.buttons["edit-set-unresolved-set"]
                XCTAssertFalse(edit.exists)
                tap(exercise, in: app)
                XCTAssertTrue(app.staticTexts["Set 1"].waitForExistence(timeout: 5))
                tap(edit, in: app)
                XCTAssertTrue(app.navigationBars["Correct set"].waitForExistence(timeout: 5))
                XCTAssertEqual(app.textFields["Reps"].value as? String, "5")
                XCTAssertTrue(app.buttons["Delete set 1 of Barbell Squat"].exists)
                tap(app.navigationBars["Correct set"].buttons["Cancel"], in: app)
                tap(exercise, in: app)
                XCTAssertFalse(edit.exists)
                XCTAssertTrue(app.staticTexts["1 working set · 5 reps"].exists)
                XCTAssertFalse(app.staticTexts["No sets logged."].exists)
            } else {
                tap(app.buttons["calendar.dateActions"], in: app)
                XCTAssertTrue(app.buttons["calendar.removeWorkout"].exists)
            }
            app.terminate()
        }
    }
}
