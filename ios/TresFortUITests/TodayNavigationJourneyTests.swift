import XCTest

final class TodayNavigationJourneyTests: XCTestCase {
    override func setUpWithError() throws { continueAfterFailure = false }
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
        tap(app.navigationBars["Choose a workout"].buttons["Done"], in: app)
        tap(app.buttons["today.createWorkout"], in: app)
        let name = app.textFields["createWorkout.name"]
        tap(name, in: app); name.typeText("Hotel session")
        tap(app.buttons["createWorkout.create"], in: app)
        XCTAssertTrue(app.navigationBars["Edit Hotel session"].waitForExistence(timeout: 5))
        tap(app.navigationBars["Edit Hotel session"].buttons["Done"], in: app)
        XCTAssertTrue(app.navigationBars["Hotel session"].waitForExistence(timeout: 5))
        tap(app.navigationBars["Hotel session"].buttons["Done"], in: app)
        XCTAssertTrue(app.staticTexts["Strength A"].exists, "Creation must not replace today's scheduled workout")
        tap(app.buttons["today.logActivity"], in: app)
        XCTAssertTrue(app.navigationBars["Log activity"].waitForExistence(timeout: 5))
        capture("activity-destination")
    }

    func testCalendarMovesAndRemovesOneDateWithoutChangingWeeklySchedule() {
        let app = launch()
        tap(app.tabBars.buttons["Calendar"], in: app)
        tap(app.buttons["calendar.date.2026-09-08"], in: app)
        tap(app.buttons["calendar.moveWorkout"], in: app)
        let date = app.datePickers["calendar.moveDate"]
        tap(date.buttons.matching(NSPredicate(format: "label CONTAINS 'September 9'")).firstMatch, in: app)
        tap(app.buttons["calendar.confirmMove"], in: app)
        XCTAssertTrue(app.buttons["calendar.chooseWorkout"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.buttons["calendar.moveWorkout"].exists)
        tap(app.navigationBars["Workout date"].buttons["Done"], in: app)
        tap(app.buttons["calendar.date.2026-09-09"], in: app)
        XCTAssertTrue(app.buttons["calendar.removeWorkout"].waitForExistence(timeout: 5))
        capture("moved-workout-date")
        tap(app.buttons["calendar.removeWorkout"], in: app)
        tap(app.buttons["Remove workout"], in: app)
        XCTAssertTrue(app.buttons["calendar.chooseWorkout"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.buttons["calendar.removeWorkout"].exists)
        tap(app.navigationBars["Workout date"].buttons["Done"], in: app)
        tap(app.buttons["calendar.weeklySchedule"], in: app)
        XCTAssertTrue(app.navigationBars["Weekly schedule"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons.matching(NSPredicate(format: "label CONTAINS 'Tuesday' AND label CONTAINS 'Strength A'")).firstMatch.exists)
        capture("unchanged-weekly-schedule")
    }

    func testCalendarCanRemoveAPlannedDateWithoutASavedWorkoutIdentity() {
        let app = launch(unassignedDate: true)
        tap(app.tabBars.buttons["Calendar"], in: app)
        tap(app.buttons["calendar.date.2026-09-09"], in: app)
        XCTAssertFalse(app.buttons["calendar.moveWorkout"].exists)
        tap(app.buttons["calendar.removeWorkout"], in: app)
        tap(app.buttons["Remove workout"], in: app)
        XCTAssertTrue(app.buttons["calendar.chooseWorkout"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.buttons["calendar.removeWorkout"].exists)
    }

    func testCalendarMoveConflictRefreshesAndAllowsARevisedRequest() {
        let app = launch(moveConflict: true)
        tap(app.tabBars.buttons["Calendar"], in: app)
        tap(app.buttons["calendar.date.2026-09-08"], in: app)
        tap(app.buttons["calendar.moveWorkout"], in: app)
        let picker = app.datePickers["calendar.moveDate"]
        tap(picker.buttons.matching(NSPredicate(format: "label CONTAINS 'September 9'")).firstMatch, in: app)
        tap(app.buttons["calendar.confirmMove"], in: app)
        XCTAssertTrue(app.buttons["Refresh calendar"].waitForExistence(timeout: 5))
        XCTAssertTrue(picker.isEnabled)
        XCTAssertEqual(app.buttons["calendar.confirmMove"].label, "Move workout")
        tap(app.buttons["calendar.confirmMove"], in: app)
        XCTAssertTrue(app.buttons["calendar.chooseWorkout"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.buttons["calendar.moveWorkout"].exists)
    }

    func testAcknowledgedCreationRecoversThroughRefreshWithoutCreatingAgain() {
        let app = launch(createRefreshFailure: true)
        tap(app.buttons["today.createWorkout"], in: app)
        let name = app.textFields["createWorkout.name"]
        tap(name, in: app); name.typeText("Hotel session")
        tap(app.buttons["createWorkout.create"], in: app)
        XCTAssertTrue(app.navigationBars["Workout unavailable"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.buttons["createWorkout.create"].exists)
        tap(app.buttons["Refresh"], in: app)
        XCTAssertTrue(app.navigationBars["Edit Hotel session"].waitForExistence(timeout: 5))
        tap(app.navigationBars["Edit Hotel session"].buttons["Done"], in: app)
        tap(app.navigationBars["Hotel session"].buttons["Done"], in: app)
        tap(app.buttons["today.chooseWorkout"], in: app)
        XCTAssertEqual(app.buttons.matching(identifier: "library.workout.created-workout").count, 1)
    }

    func testCreationConflictAllowsFreshAuthorityWithoutDuplicatingAnUncertainCreation() {
        for failure in ["conflict", "lost-response"] {
            let app = launch(creationFailure: failure)
            tap(app.buttons["today.createWorkout"], in: app)
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
            tap(app.buttons["today.chooseWorkout"], in: app)
            XCTAssertEqual(app.buttons.matching(identifier: "library.workout.created-workout").count, 1)
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
        for status in ["planned", "in_progress"] {
            let app = XCUIApplication()
            app.launchEnvironment["TRESFORT_UI_FIXTURE"] = "app-store"
            app.launchEnvironment["TRESFORT_UI_UNRESOLVED_TODAY"] = status
            app.launchArguments = ["-AppleLanguages", "(en)", "-AppleLocale", "en_US"]
            app.launch()
            XCTAssertTrue(app.staticTexts["Workout needs review"].waitForExistence(timeout: 10))
            XCTAssertFalse(app.staticTexts["Nothing scheduled"].exists)
            XCTAssertFalse(app.buttons["today.startWorkout"].exists)
            tap(app.buttons["today.viewUnresolvedWorkout"], in: app)
            XCTAssertTrue(app.navigationBars["Workout record"].waitForExistence(timeout: 5))
            if status == "in_progress" {
                XCTAssertTrue(app.staticTexts["SET 1"].exists)
                XCTAssertFalse(app.staticTexts["No sets logged."].exists)
            } else {
                XCTAssertTrue(app.buttons["calendar.removeWorkout"].exists)
            }
            app.terminate()
        }
    }
}
