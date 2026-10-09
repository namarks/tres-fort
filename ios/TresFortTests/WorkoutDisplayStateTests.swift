import XCTest
@testable import TresFort

private final class DisplayTokenStore: AppTokenStore {
    var token: String?
    init(_ token: String) { self.token = token }
    func save(_ token: String) { self.token = token }
    func load() -> String? { token }
    func clear() { token = nil }
}

@MainActor
final class WorkoutDisplayStateTests: XCTestCase {
    private var retainedAuth: [AuthModel] = []

    private func model(_ exercises: [TemplateExercise]) -> SyncModel {
        let suite = "WorkoutDisplayStateTests.\(UUID().uuidString)"
        let defaults = LocalPersistence(suiteName: suite)!
        addTeardownBlock { defaults.removePersistentDomain(forName: suite) }
        let payload = Data(#"{"sub":"display-test","exp":4000000000}"#.utf8)
            .base64EncodedString().replacingOccurrences(of: "=", with: "")
        defaults.set("display-test", forKey: AuthModel.userIDKey)
        let auth = AuthModel(tokenStore: DisplayTokenStore("eyJhbGciOiJIUzI1NiJ9.\(payload).signature"), defaults: defaults)
        retainedAuth.append(auth)
        let sync = SyncModel(auth: auth, defaults: defaults)
        sync.plan = PlanTree(id: "plan", name: "Plan", version: 1,
            workouts: [Workout(id: "workout", name: "Strength", day_label: "A",
                               order_index: 0, exercises: exercises)], meta: nil)
        sync.selectedDayID = "workout"
        sync.todaySession = SessionRow(id: "session", date: sync.todayString,
                                      status: "in_progress", workout_id: "workout")
        sync.running = true
        sync.workoutStart = Date()
        sync.weight = 24
        sync.reps = 8
        sync.holdDurationSeconds = 45
        return sync
    }

    private func exercise(_ id: String, sets: Int = 3, modality: String = "reps",
                          group: String? = nil, perHand: Bool = false) -> TemplateExercise {
        TemplateExercise(id: id, exercise_id: "exercise-\(id)", exercise_name: "Exercise \(id)",
            exercise_unit: "lb", order_index: 0, target_sets: sets, target_reps: 6,
            target_reps_max: nil, target_rpe: nil, rest_seconds: 90, target_weight: 20,
            cues: nil, exercise_modality: modality, exercise_laterality: "bilateral",
            exercise_load_mode: perHand ? "per_hand" : "total", exercise_demo_slug: nil,
            target_duration_s: modality == "cardio" ? 300 : nil, is_warmup: 0,
            target_weight_unit: "kg", group_id: group, group_rest_seconds: group == nil ? nil : 60,
            group_transition_seconds: group == nil ? nil : 15)
    }

    private func logged(_ exercise: TemplateExercise, index: Int, slotless: Bool = false) -> SetLog {
        SetLog(id: "\(exercise.id)-\(index)", session_id: "session", exercise_id: exercise.exercise_id,
            template_exercise_id: slotless ? nil : exercise.id, set_index: index, weight: 20, reps: 6,
            rpe: nil, is_warmup: 0, logged_at: index, duration_s: nil, is_timed: 0,
            deleted_at: nil, updated_at: index)
    }

    func testReadyUsesDraftValuesSlotUnitsAndNextPhysicalSet() throws {
        let ex = exercise("a", perHand: true)
        let sync = model([ex, exercise("b")])
        sync.sets = [logged(ex, index: 1)]
        let state = WorkoutDisplayState.project(sync: sync)
        XCTAssertEqual(state.phase, .ready)
        XCTAssertEqual(state.current?.weight, 24)
        XCTAssertEqual(state.current?.weightUnit, .kg, "Catalog lb does not change the slot's kg load")
        XCTAssertEqual(state.current?.reps, 8, "Show the values that the next tap will log")
        XCTAssertEqual(state.current?.setNumber, 2)
        XCTAssertEqual(state.current?.isPerHand, true)
        XCTAssertEqual(state.next?.slotID, "a")
        XCTAssertEqual(state.next?.setNumber, 3)
        let converted = WorkoutDisplayState.project(sync: sync, displayUnit: .lb)
        XCTAssertEqual(try XCTUnwrap(converted.current?.weight), WeightUnit.kg.convert(24, to: .lb), accuracy: 0.001)
        XCTAssertEqual(converted.current?.weightUnit, .lb)
        XCTAssertEqual(sync.weight, 24, "Display preference never edits the runner draft")
    }

    func testLastSetPreviewsNextUnskippedExerciseAndFinalSetHasNoNext() {
        let a = exercise("a", sets: 1), b = exercise("b"), c = exercise("c", sets: 1)
        let sync = model([a, b, c])
        sync.skipped = [b.id]
        XCTAssertEqual(WorkoutDisplayState.project(sync: sync).next?.slotID, c.id)
        sync.exerciseIndex = 2
        sync.sets = [logged(a, index: 1)]
        XCTAssertNil(WorkoutDisplayState.project(sync: sync).next)
    }

    func testRevisitingCompletedExerciseDoesNotSuggestAnotherSetOrFinishTheWorkout() {
        let completed = exercise("squat"), remaining = exercise("row")
        let sync = model([completed, remaining])
        sync.sets = (1...3).map { logged(completed, index: $0) }
        sync.jump(to: 1)
        XCTAssertEqual(WorkoutDisplayState.project(sync: sync).phase, .ready)
        sync.jump(to: 0)
        sync.restEndDate = Date().addingTimeInterval(60)
        let state = WorkoutDisplayState.project(sync: sync)
        XCTAssertFalse(sync.finished, "Other exercises still need sets")
        XCTAssertEqual(sync.runnerSetsDone(completed), 3)
        XCTAssertEqual(state.phase, .exerciseComplete)
        XCTAssertNil(state.current)
        XCTAssertNil(state.next)
        XCTAssertNil(state.restEndDate)
        XCTAssertNil(state.timedEndDate)
        XCTAssertEqual(state.message, "Choose another exercise to continue.")
    }

    func testNextPreviewPreservesEditedSlotDraftAndMatchesNavigatingThere() {
        let a = exercise("a", sets: 1), b = exercise("b")
        let sync = model([a, b])
        sync.jump(to: 1)
        XCTAssertTrue(sync.setRunnerValues(SetCorrectionValues(weight: 32, reps: 11, rpe: nil,
                                                               durationSeconds: nil), expected: RunnerPrescription(b)))
        sync.jump(to: 0)
        let preview = WorkoutDisplayState.project(sync: sync).next
        XCTAssertEqual(preview?.slotID, b.id)
        XCTAssertEqual(preview?.weight, 32)
        XCTAssertEqual(preview?.reps, 11)
        sync.jump(to: 1)
        let actual = WorkoutDisplayState.project(sync: sync).current
        XCTAssertEqual(preview, actual)
    }

    func testRestUsesAbsoluteDeadlineAndPreparesTheAlreadyAdvancedSet() throws {
        let a = exercise("a", sets: 1), b = exercise("b")
        let sync = model([a, b])
        sync.exerciseIndex = 1
        let deadline = Date(timeIntervalSince1970: 2_000_000_090)
        sync.restEndDate = deadline
        let state = WorkoutDisplayState.project(sync: sync)
        XCTAssertEqual(state.phase, .rest)
        XCTAssertEqual(state.restEndDate, deadline)
        XCTAssertEqual(state.next?.slotID, b.id)
        XCTAssertEqual(state.next, state.current)
        XCTAssertEqual(try JSONDecoder().decode(WorkoutDisplayState.self, from: JSONEncoder().encode(state)), state)
    }

    func testGroupPreviewUsesLeastCompleteMemberAndSeparatesRoundFromPhysicalSet() {
        let a = exercise("a", group: "group"), b = exercise("b", group: "group")
        let sync = model([a, b])
        sync.exerciseIndex = 1
        sync.sets = [logged(b, index: 1)]
        let state = WorkoutDisplayState.project(sync: sync)
        XCTAssertEqual(state.current?.setNumber, 2)
        XCTAssertEqual(state.current?.roundNumber, 1)
        XCTAssertEqual(state.current?.groupTitle, "Superset A")
        XCTAssertEqual(state.next?.slotID, a.id)
        XCTAssertEqual(state.next?.roundNumber, 1)
        XCTAssertEqual(state.next?.setNumber, 1)
        sync.exerciseIndex = 0
        XCTAssertEqual(WorkoutDisplayState.project(sync: sync).next?.slotID, a.id,
                       "The next round can repeat the member that is behind")
        XCTAssertEqual(WorkoutDisplayState.project(sync: sync).next?.roundNumber, 2)
    }

    func testTimedCardioCarriesDurationAndDeadlinesWithoutInventingLoadOrReps() {
        let sync = model([exercise("erg", modality: "cardio")])
        sync.timedActive = true
        sync.timedStartDate = Date(timeIntervalSince1970: 2_000_000_000)
        sync.timedEndDate = sync.timedStartDate?.addingTimeInterval(45)
        let state = WorkoutDisplayState.project(sync: sync)
        XCTAssertEqual(state.phase, .active)
        XCTAssertEqual(state.current?.durationSeconds, 45)
        XCTAssertNil(state.current?.weight)
        XCTAssertNil(state.current?.reps)
        XCTAssertEqual(state.timedEndDate, sync.timedEndDate)
        XCTAssertEqual(state.timedStartDate, sync.timedStartDate)
    }

    func testAssistedAndUnloadedHoldsKeepBodyweightMeaningAcrossUnits() throws {
        let sync = model([exercise("hold", modality: "timed")])
        sync.weight = -10
        let assisted = WorkoutDisplayState.project(sync: sync, displayUnit: .lb)
        XCTAssertEqual(try XCTUnwrap(assisted.current?.weight), WeightUnit.kg.convert(-10, to: .lb), accuracy: 0.001)
        XCTAssertEqual(assisted.current?.isBodyweight, true)
        XCTAssertEqual(assisted.next?.weight, assisted.current?.weight)
        sync.weight = 0
        let unloaded = WorkoutDisplayState.project(sync: sync)
        XCTAssertEqual(unloaded.current?.weight, 0)
        XCTAssertEqual(unloaded.current?.isBodyweight, true)
    }

    func testReviewIsDistinctFromSavedCompletionAndPauseWithdrawsGuidance() {
        let sync = model([exercise("a")])
        sync.finished = true
        XCTAssertEqual(WorkoutDisplayState.project(sync: sync).phase, .review)
        XCTAssertNil(WorkoutDisplayState.project(sync: sync).current)
        XCTAssertEqual(WorkoutDisplayState.project(sync: sync, paused: true).phase, .paused)
        sync.todaySession = SessionRow(id: "session", date: sync.todayString,
                                      status: "completed", workout_id: "workout")
        XCTAssertEqual(WorkoutDisplayState.project(sync: sync).phase, .finished)
    }

    func testBlockedAndInvalidatedAccountHaveNoActiveGuidanceOrTimer() {
        let sync = model([exercise("a")])
        sync.restEndDate = Date().addingTimeInterval(60)
        sync.partnerReserved = true
        let blocked = WorkoutDisplayState.project(sync: sync)
        XCTAssertEqual(blocked.phase, .blocked)
        XCTAssertNil(blocked.current)
        XCTAssertNil(blocked.restEndDate)
        sync.partnerReserved = false
        retainedAuth.last?.requireReauthentication()
        let stale = WorkoutDisplayState.project(sync: sync)
        XCTAssertEqual(stale.phase, .blocked)
        XCTAssertNil(stale.current)
    }

    func testFreestyleKeepsOpenSetCountAndDoesNotInventAFinalSet() {
        let ex = exercise("a", modality: "bw")
        let sync = model([ex])
        sync.todaySession?.kind = "freestyle"
        sync.selectedDayID = "freestyle:session"
        sync.catalog = [ExerciseCatalog(id: ex.exercise_id, name: ex.exercise_name, primary_muscle: "legs",
            modality: "bw", unit: "lb", laterality: "bilateral", load_mode: "total", demo_slug: nil)]
        sync.sets = [logged(ex, index: 1, slotless: true)]
        let state = WorkoutDisplayState.project(sync: sync)
        XCTAssertEqual(state.phase, .ready)
        XCTAssertTrue(state.isFreestyle)
        XCTAssertEqual(state.current?.setNumber, 2)
        XCTAssertNil(state.current?.totalSets)
        XCTAssertEqual(state.next?.slotID, state.current?.slotID)
        XCTAssertEqual(state.next?.setNumber, 3)
    }
}
