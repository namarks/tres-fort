import XCTest

final class ProgressJourneyTests: XCTestCase {
    override func setUpWithError() throws { continueAfterFailure = false }

    private func launch(largeText: Bool = false, empty: Bool = false, shared: Bool = false, profileFailure: Bool = false,
                        openProgress: Bool = true) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchEnvironment["TRESFORT_UI_FIXTURE"] = "progress"
        if shared { app.launchEnvironment["TRESFORT_UI_HEALTH_SHARED"] = "1" }
        if profileFailure { app.launchEnvironment["TRESFORT_UI_HEALTH_PROFILE_FAIL"] = "1" }
        if empty { app.launchEnvironment["TRESFORT_UI_PROGRESS_EMPTY"] = "1" }
        if largeText { app.launchEnvironment["TRESFORT_UI_LARGE_TEXT"] = "1" }
        app.launchArguments = ["-AppleLanguages", "(en)", "-AppleLocale", "en_US"]
        app.launch()
        XCTAssertTrue(app.tabBars.buttons["Activity"].waitForExistence(timeout: 15))
        app.tabBars.buttons["Activity"].tap()
        guard openProgress else { return app }
        let progress = app.segmentedControls["activity.side"].buttons["Progress"]
        XCTAssertTrue(progress.waitForExistence(timeout: UITestWait.screen))
        progress.tap()
        return app
    }

    private func tap(_ element: XCUIElement, in app: XCUIApplication) {
        for _ in 0..<10 where !element.exists || !element.isHittable { app.swipeUp() }
        XCTAssertTrue(element.waitForExistence(timeout: UITestWait.screen))
        XCTAssertTrue(element.isHittable)
        if element.elementType == .switch {
            element.coordinate(withNormalizedOffset: CGVector(dx: 0.9, dy: 0.5)).tap()
        } else { element.tap() }
    }

    private func capture(_ name: String, app: XCUIApplication) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    func testActivityHistoryListsWorkoutsAndLoggedActivitiesAndOpensTheirRecord() {
        let app = launch(openProgress: false)
        let side = app.segmentedControls["activity.side"]
        XCTAssertTrue(side.buttons["History"].waitForExistence(timeout: UITestWait.screen))
        XCTAssertTrue(side.buttons["History"].isSelected, "Activity opens on History")
        let soccer = app.descendants(matching: .any)["activityHistory.entry.logged:synthetic-soccer"]
        let workout = app.descendants(matching: .any)["activityHistory.entry.workout:sample-session-3"]
        XCTAssertTrue(soccer.waitForExistence(timeout: UITestWait.screen))
        XCTAssertTrue(workout.exists)
        XCTAssertLessThan(soccer.frame.minY, workout.frame.minY, "Newest first: Sep 7 before Sep 5")
        capture("Activity history — synthetic training", app: app)

        tap(app.buttons["activityHistory.filter.other"], in: app)
        XCTAssertTrue(soccer.waitForExistence(timeout: UITestWait.screen))
        XCTAssertFalse(workout.exists, "The Other filter leaves workouts out")
        tap(app.buttons["activityHistory.filter.workouts"], in: app)
        XCTAssertTrue(workout.waitForExistence(timeout: UITestWait.screen))
        XCTAssertFalse(soccer.exists)
        tap(app.buttons["activityHistory.filter.all"], in: app)
        XCTAssertTrue(soccer.waitForExistence(timeout: UITestWait.screen))

        tap(workout, in: app)
        XCTAssertTrue(app.staticTexts["Exercises"].waitForExistence(timeout: UITestWait.screen),
                      "A workout opens its record with the logged sets")
        capture("Activity history — workout record", app: app)
        app.navigationBars.buttons.element(boundBy: 0).tap()
        tap(soccer, in: app)
        XCTAssertTrue(app.staticTexts["LOGGED ACTIVITIES"].waitForExistence(timeout: UITestWait.screen))
        app.navigationBars.buttons.element(boundBy: 0).tap()

        tap(side.buttons["Progress"], in: app)
        XCTAssertTrue(app.buttons["progress.consistency"].waitForExistence(timeout: UITestWait.screen))
        tap(side.buttons["History"], in: app)
        XCTAssertTrue(soccer.waitForExistence(timeout: UITestWait.screen))
    }

    func testEmptyActivityHistorySaysWhatWillAppear() {
        let app = launch(empty: true, openProgress: false)
        XCTAssertTrue(app.staticTexts["activityHistory.empty"].waitForExistence(timeout: UITestWait.screen))
        XCTAssertFalse(app.buttons["activityHistory.filter.all"].exists)
    }

    func testProgressTabLeadsWithConsistencyThenStrengthAndOptionalHealthWeight() {
        let app = launch()
        let consistency = app.buttons["progress.consistency"]
        XCTAssertTrue(consistency.waitForExistence(timeout: UITestWait.screen))
        XCTAssertTrue(app.buttons["progress.strength"].exists)
        XCTAssertLessThan(consistency.frame.minY, app.buttons["progress.strength"].frame.minY,
                          "Consistency is the first thing Progress shows")
        XCTAssertTrue(consistency.label.contains("week streak"))
        capture("Progress overview — synthetic training", app: app)
        consistency.tap()
        XCTAssertTrue(app.staticTexts["consistency.total"].waitForExistence(timeout: UITestWait.screen))
        XCTAssertTrue(app.descendants(matching: .any)["consistency.heatmap"].firstMatch.exists)
        app.buttons["26 weeks"].tap()
        capture("Consistency — synthetic completed workouts", app: app)
        // The by-week list sits below the grid and chart in a lazy List.
        let thisWeek = app.staticTexts["This week so far"]
        for _ in 0..<6 where !thisWeek.exists { app.swipeUp() }
        XCTAssertTrue(thisWeek.exists)
        app.navigationBars.buttons.element(boundBy: 0).tap()
        tap(app.buttons["progress.strength"], in: app)
        XCTAssertTrue(app.navigationBars["Strength"].waitForExistence(timeout: UITestWait.screen))
        let exercise = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'history.exercise.'")).firstMatch
        XCTAssertTrue(exercise.waitForExistence(timeout: UITestWait.screen))
        exercise.tap()
        XCTAssertTrue(app.otherElements["history.progress.chart"].waitForExistence(timeout: UITestWait.screen))
        app.navigationBars.buttons.element(boundBy: 0).tap()
        app.navigationBars.buttons.element(boundBy: 0).tap()
        tap(app.buttons["progress.weightSettings"], in: app)
        XCTAssertTrue(app.navigationBars["Apple Health"].waitForExistence(timeout: UITestWait.screen))
        tap(app.switches["health.readWeight"], in: app)
        XCTAssertTrue(app.staticTexts["View measurements in Activity → Progress → Weight."].waitForExistence(timeout: UITestWait.screen))
        app.buttons["Done"].tap()
        tap(app.buttons["progress.weight"], in: app)
        XCTAssertTrue(app.otherElements["weight.chart"].waitForExistence(timeout: UITestWait.screen))
        XCTAssertFalse(app.buttons["Connect weight"].exists)
        capture("Weight in Progress — synthetic measurements", app: app)
        app.buttons["weight.settings"].tap()
        tap(app.switches["health.readWeight"], in: app)
        app.buttons["Done"].tap()
        XCTAssertTrue(app.buttons["weight.manageAccess"].waitForExistence(timeout: UITestWait.screen))
        XCTAssertFalse(app.otherElements["weight.chart"].exists)
        app.tabBars.buttons["Today"].tap()
        tap(app.buttons["today.calendar"], in: app)
        XCTAssertTrue(app.buttons["calendar.weeklySchedule"].waitForExistence(timeout: UITestWait.screen))
        XCTAssertFalse(app.buttons["calendar.exerciseProgress"].exists)
        XCTAssertFalse(app.buttons["history.weight"].exists)
    }

    func testHealthShortcutLoadsSharingBeforeProfileAndCanDisableIt() {
        let app = launch(shared: true)
        tap(app.buttons["progress.weightSettings"], in: app)
        let sharing = app.switches["health.workoutSharing"]
        for _ in 0..<10 where !sharing.exists || !sharing.isHittable { app.swipeUp() }
        XCTAssertTrue(sharing.waitForExistence(timeout: UITestWait.screen))
        XCTAssertEqual(sharing.value as? String, "1")
        tap(sharing, in: app)
        XCTAssertTrue(app.staticTexts["health.sharingOff"].waitForExistence(timeout: UITestWait.screen))
        app.buttons["Done"].tap()
        tap(app.buttons["progress.weightSettings"], in: app)
        let off = app.staticTexts["health.sharingOff"]
        for _ in 0..<10 where !off.exists || !off.isHittable { app.swipeUp() }
        XCTAssertTrue(off.waitForExistence(timeout: UITestWait.screen), "Reopening must confirm the server saved the opt-out")
        XCTAssertFalse(app.switches["health.workoutSharing"].exists)
    }

    func testHealthShortcutKeepsFailedSharingReadUnknownAfterRetry() {
        let app = launch(shared: true, profileFailure: true)
        tap(app.buttons["progress.weightSettings"], in: app)
        let retry = app.buttons["health.retrySharing"]
        for _ in 0..<10 where !retry.exists || !retry.isHittable { app.swipeUp() }
        XCTAssertTrue(retry.waitForExistence(timeout: UITestWait.screen))
        XCTAssertFalse(app.staticTexts["health.sharingOff"].exists)
        XCTAssertFalse(app.switches["health.workoutSharing"].exists)
        tap(retry, in: app)
        XCTAssertTrue(retry.waitForExistence(timeout: UITestWait.screen))
        XCTAssertFalse(app.staticTexts["health.sharingOff"].exists)
        XCTAssertFalse(app.switches["health.workoutSharing"].exists)
    }

    func testEmptyProgressExplainsHowTrainingStartsWithoutRequiringWeight() {
        let app = launch(empty: true)
        XCTAssertTrue(app.staticTexts["Your first working set starts your progress."].waitForExistence(timeout: UITestWait.screen))
        tap(app.buttons["progress.consistency"], in: app)
        XCTAssertEqual(app.staticTexts["consistency.total"].label, "0 completed workouts")
        app.navigationBars.buttons.element(boundBy: 0).tap()
        XCTAssertFalse(app.buttons["progress.weight"].exists)
        XCTAssertTrue(app.buttons["progress.weightSettings"].exists)
        capture("Progress — empty training history", app: app)
    }

    func testProgressAndHealthSettingsRemainReachableAtAccessibilityTextSize() {
        let app = launch(largeText: true)
        XCTAssertTrue(app.buttons["progress.strength"].waitForExistence(timeout: UITestWait.screen))
        capture("Progress overview — accessibility text", app: app)
        tap(app.buttons["progress.consistency"], in: app)
        XCTAssertTrue(app.staticTexts["consistency.total"].waitForExistence(timeout: UITestWait.screen))
        app.navigationBars.buttons.element(boundBy: 0).tap()
        tap(app.buttons["progress.weightSettings"], in: app)
        tap(app.switches["health.readWeight"], in: app)
        app.buttons["Done"].tap()
        tap(app.buttons["progress.weight"], in: app)
        XCTAssertTrue(app.descendants(matching: .any)["weight.latest"].firstMatch.waitForExistence(timeout: UITestWait.screen))
        capture("Progress weight — accessibility text", app: app)
    }
}
