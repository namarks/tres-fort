import XCTest

final class WorkoutLibraryJourneyTests: XCTestCase {
    override func setUpWithError() throws { continueAfterFailure = false }

    private func launch() -> XCUIApplication {
        let app = XCUIApplication()
        app.launchEnvironment["TRESFORT_UI_FIXTURE"] = "library"
        app.launchArguments = ["-AppleLanguages", "(en)", "-AppleLocale", "en_US"]
        app.launch()
        XCTAssertTrue(app.buttons["today.chooseWorkout"].waitForExistence(timeout: 10))
        app.buttons["today.chooseWorkout"].tap()
        XCTAssertTrue(app.navigationBars["Workouts"].waitForExistence(timeout: 5))
        return app
    }

    func testTagsArchiveCancelAndRestore() {
        let app = launch()
        app.buttons["Actions for Gym"].tap()
        app.buttons["Edit tags"].tap()
        let input = app.textViews["workoutTags.input"]
        if input.waitForExistence(timeout: 3) { input.tap(); input.typeText("quick, travel") }
        else {
            let field = app.textFields["workoutTags.input"]
            XCTAssertTrue(field.waitForExistence(timeout: 3)); field.tap(); field.typeText("quick, travel")
        }
        app.buttons["workoutTags.save"].tap()
        XCTAssertTrue(app.staticTexts["workoutTags-synthetic-day"].waitForExistence(timeout: 5))
        XCTAssertEqual(app.staticTexts["workoutTags-synthetic-day"].label, "quick · travel")
        app.buttons["library.tagFilter"].tap()
        app.buttons["quick"].tap()
        XCTAssertTrue(app.buttons["library.workout.synthetic-day"].exists)
        XCTAssertFalse(app.buttons["library.workout.hotel"].exists)
        app.buttons["library.tagFilter"].tap()
        app.buttons["All tags"].tap()
        XCTAssertTrue(app.buttons["library.workout.hotel"].exists)
        app.buttons["Actions for Gym"].tap(); app.buttons["Archive workout"].tap()
        let confirm = app.alerts["Archive Gym?"]
        XCTAssertTrue(confirm.waitForExistence(timeout: 5))
        confirm.buttons["Cancel"].tap()
        XCTAssertTrue(app.buttons["library.workout.synthetic-day"].exists)
        app.buttons["Actions for Gym"].tap(); app.buttons["Archive workout"].tap()
        confirm.buttons["Archive workout"].tap()
        expectation(for: NSPredicate(format: "exists == false"), evaluatedWith: app.buttons["library.workout.synthetic-day"])
        waitForExpectations(timeout: 5)
        app.segmentedControls.buttons["Archived"].tap()
        XCTAssertTrue(app.buttons["library.workout.synthetic-day"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.buttons["library.workout.hotel"].exists)
        let image = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        image.name = "workout-archive"; image.lifetime = .keepAlways; add(image)
        app.buttons["Actions for Gym"].tap()
        XCTAssertFalse(app.buttons["Use on a date"].exists)
        app.buttons["Restore workout"].tap()
        expectation(for: NSPredicate(format: "exists == false"), evaluatedWith: app.buttons["library.workout.synthetic-day"])
        waitForExpectations(timeout: 5)
        app.segmentedControls.buttons["Active"].tap()
        XCTAssertTrue(app.buttons["library.workout.synthetic-day"].waitForExistence(timeout: 5))
        XCTAssertEqual(app.staticTexts["workoutSchedule-synthetic-day"].label, "On demand")
        XCTAssertEqual(app.staticTexts["workoutTags-synthetic-day"].label, "quick · travel")
    }

    func testLibraryBadgesUnscheduleAndDateAssignment() {
        let app = launch()
        XCTAssertEqual(app.staticTexts["workoutSchedule-synthetic-day"].label, "Tue")
        XCTAssertEqual(app.staticTexts["workoutSchedule-hotel"].label, "On demand")
        app.buttons["Actions for Gym"].tap()
        app.buttons["Unschedule"].tap()
        let onDemand = NSPredicate(format: "label == %@", "On demand")
        expectation(for: onDemand, evaluatedWith: app.staticTexts["workoutSchedule-synthetic-day"])
        waitForExpectations(timeout: 5)
        XCTAssertTrue(app.buttons["Actions for Gym"].exists)
        app.buttons["Actions for Hotel"].tap()
        app.buttons["Use on a date"].tap()
        XCTAssertTrue(app.buttons["assignLibraryWorkout"].waitForExistence(timeout: 5))
        app.buttons["assignLibraryWorkout"].tap()
        XCTAssertTrue(app.navigationBars["Workouts"].waitForExistence(timeout: 5))
        XCTAssertEqual(app.staticTexts["workoutSchedule-hotel"].label, "On demand")
        let image = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        image.name = "workout-library"; image.lifetime = .keepAlways; add(image)
        app.navigationBars["Workouts"].buttons["Done"].tap()
        XCTAssertTrue(app.staticTexts["Hotel"].waitForExistence(timeout: 5))
    }

    func testDeletingLastTaggedWorkoutClearsFilter() {
        let app = launch()
        app.buttons["Actions for Hotel"].tap()
        app.buttons["Edit tags"].tap()
        let input = app.textViews["workoutTags.input"]
        if input.waitForExistence(timeout: 3) { input.tap(); input.typeText("quick") }
        else {
            let field = app.textFields["workoutTags.input"]
            XCTAssertTrue(field.waitForExistence(timeout: 3)); field.tap(); field.typeText("quick")
        }
        app.buttons["workoutTags.save"].tap()
        XCTAssertTrue(app.buttons["library.tagFilter"].waitForExistence(timeout: 5))
        app.buttons["library.tagFilter"].tap(); app.buttons["quick"].tap()
        XCTAssertFalse(app.buttons["library.workout.synthetic-day"].exists)
        app.buttons["Actions for Hotel"].tap(); app.buttons["Delete workout"].tap()
        let confirmation = app.alerts["Delete Hotel?"]
        XCTAssertTrue(confirmation.waitForExistence(timeout: 5))
        confirmation.buttons["Delete workout"].tap()
        XCTAssertTrue(app.buttons["library.workout.synthetic-day"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.buttons["library.tagFilter"].exists)
    }

    func testDeleteIsExplicitAndSeparateFromUnschedule() {
        let app = launch()
        app.buttons["Actions for Hotel"].tap()
        XCTAssertFalse(app.buttons["Unschedule"].isEnabled)
        app.buttons["Delete workout"].tap()
        let confirmation = app.alerts["Delete Hotel?"]
        XCTAssertTrue(confirmation.waitForExistence(timeout: 5))
        confirmation.buttons["Delete workout"].tap()
        let gone = NSPredicate(format: "exists == false")
        expectation(for: gone, evaluatedWith: app.buttons["Actions for Hotel"])
        waitForExpectations(timeout: 5)
        XCTAssertTrue(app.buttons["Actions for Gym"].exists)
        XCTAssertEqual(app.staticTexts["workoutSchedule-synthetic-day"].label, "Tue")
    }

    func testWorkoutOpensFromEmptyRowSpaceAndDisclosure() {
        let app = launch()
        let row = app.buttons["library.workout.hotel"]
        // Exercise blank horizontal space, vertical padding, and the chevron.
        // A label-center tap alone does not catch the original plain-button gap.
        for point in [CGVector(dx: 0.7, dy: 0.5), CGVector(dx: 0.5, dy: 0.08),
                      CGVector(dx: 0.96, dy: 0.5)] {
            XCTAssertTrue(row.waitForExistence(timeout: 5))
            row.coordinate(withNormalizedOffset: point).tap()
            let details = app.navigationBars["Hotel"]
            XCTAssertTrue(details.waitForExistence(timeout: 5))
            XCTAssertTrue(app.buttons["workoutDetails.edit"].exists)
            details.buttons["Done"].tap()
        }
        let image = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        image.name = "workout-library-row-navigation"; image.lifetime = .keepAlways; add(image)
        let actions = app.buttons["Actions for Hotel"]
        XCTAssertGreaterThanOrEqual(actions.frame.width, 44)
        XCTAssertGreaterThanOrEqual(actions.frame.height, 44)
        actions.coordinate(withNormalizedOffset: CGVector(dx: 0.1, dy: 0.1)).tap()
        XCTAssertTrue(app.buttons["Use on a date"].waitForExistence(timeout: 5))
    }

    func testSwipeDeleteRequiresConfirmationAndCancelKeepsWorkout() {
        let app = launch()
        let row = app.buttons["library.workout.hotel"]
        row.swipeLeft()
        XCTAssertTrue(app.buttons["Delete"].waitForExistence(timeout: 5))
        XCTAssertTrue(row.exists, "Swiping must not remove a workout")
        XCTAssertFalse(app.alerts["Delete Hotel?"].exists, "Full swipe must not execute Delete")
        app.buttons["Delete"].tap()
        let confirmation = app.alerts["Delete Hotel?"]
        XCTAssertTrue(confirmation.waitForExistence(timeout: 5))
        let image = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        image.name = "workout-library-delete-confirmation"; image.lifetime = .keepAlways; add(image)
        confirmation.buttons["Cancel"].tap()
        XCTAssertTrue(row.waitForExistence(timeout: 5))
        row.tap()
        XCTAssertTrue(app.navigationBars["Hotel"].waitForExistence(timeout: 5))
        app.navigationBars["Hotel"].buttons["Done"].tap()
        row.swipeLeft()
        app.buttons["Delete"].tap()
        XCTAssertTrue(confirmation.waitForExistence(timeout: 5))
        confirmation.buttons["Delete workout"].tap()
        expectation(for: NSPredicate(format: "exists == false"), evaluatedWith: row)
        waitForExpectations(timeout: 5)
        XCTAssertTrue(app.buttons["library.workout.synthetic-day"].exists)
        XCTAssertEqual(app.staticTexts["workoutSchedule-synthetic-day"].label, "Tue")
    }

    func testCreateStartsWithFilteredExercisesAndSavesWithoutNaming() {
        let app = launch()
        app.buttons["Add workout"].tap()
        XCTAssertTrue(app.navigationBars["Add exercises"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.textFields["createWorkout.name"].exists)
        XCTAssertFalse(app.buttons["createWorkout.review"].isEnabled)
        app.buttons["Lower body"].tap()
        app.buttons["exercisePicker.exercise.synthetic-exercise"].tap()
        app.buttons["Upper body"].tap()
        XCTAssertFalse(app.buttons["exercisePicker.exercise.synthetic-exercise"].exists)
        let search = app.textFields["exercisePicker.search"]
        search.tap(); search.typeText("bp")
        app.buttons["exercisePicker.exercise.synthetic-upper"].tap()
        search.tap(); search.typeText("zzzzz")
        XCTAssertTrue(app.staticTexts["No matching exercises"].waitForExistence(timeout: 5))
        app.buttons["Clear search and filters"].tap()
        app.buttons["Core"].tap()
        app.buttons["exercisePicker.exercise.synthetic-core"].tap()
        XCTAssertEqual(app.buttons["createWorkout.review"].label, "Review workout (3)")
        let picker = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        picker.name = "exercise-first-filtered-picker"; picker.lifetime = .keepAlways; add(picker)
        app.buttons["createWorkout.review"].tap()
        XCTAssertTrue(app.textFields["createWorkout.name"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["Barbell Squat"].exists)
        XCTAssertTrue(app.staticTexts["Bench Press"].exists)
        XCTAssertTrue(app.staticTexts["Plank"].exists)
        let review = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        review.name = "exercise-first-review"; review.lifetime = .keepAlways; add(review)
        let create = app.buttons["createWorkout.create"]
        for _ in 0..<4 where !create.isHittable { app.swipeUp() }
        create.tap()
        XCTAssertTrue(app.navigationBars["Edit Workout 1"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["Barbell Squat"].exists)
        XCTAssertTrue(app.staticTexts["Bench Press"].exists)
        XCTAssertTrue(app.staticTexts["Plank"].exists)
    }

    func testCancelSelectionLeavesLibraryUnchangedAndExistingEditorUsesFilters() {
        let app = launch()
        app.buttons["Add workout"].tap()
        let squat = app.buttons["exercisePicker.exercise.synthetic-exercise"]
        XCTAssertTrue(squat.waitForExistence(timeout: 5)); squat.tap()
        app.navigationBars["Add exercises"].buttons["Cancel"].tap()
        XCTAssertTrue(app.navigationBars["Workouts"].waitForExistence(timeout: 5))
        XCTAssertEqual(app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "library.workout.")).count, 2)
        app.buttons["Actions for Gym"].tap()
        app.buttons["Edit exercises"].tap()
        app.buttons["editor.actions"].tap()
        app.buttons["Add exercise"].tap()
        XCTAssertTrue(app.navigationBars["Add exercise"].waitForExistence(timeout: 5))
        app.buttons["Core"].tap()
        XCTAssertFalse(app.staticTexts["Barbell Squat"].exists)
        app.staticTexts["Plank"].tap()
        XCTAssertTrue(app.navigationBars["Plank"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["Add to workout"].exists)
    }

}
