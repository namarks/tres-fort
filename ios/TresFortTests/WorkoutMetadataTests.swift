import XCTest
@testable import TresFort

final class WorkoutMetadataTests: XCTestCase {
    func testLegacyDecodeAndArchivedHistoryRemainAvailable() throws {
        let raw = #"{"id":"p","name":"Library","version":2,"workouts":[{"id":"a","name":"Gym","order_index":0,"exercises":[]},{"id":"b","name":"Hotel","order_index":1,"tags":"[\"travel\",\"quick\"]","archived_at":123,"exercises":[]}]}"#
        let plan = try JSONDecoder().decode(PlanTree.self, from: Data(raw.utf8))
        XCTAssertEqual(plan.workouts.count, 2)
        XCTAssertEqual(plan.availableWorkouts.map(\.id), ["a"])
        XCTAssertEqual(plan.workouts[1].workoutTags, ["travel", "quick"])
        XCTAssertEqual(plan.workouts[1].name, "Hotel")
        XCTAssertEqual(try JSONDecoder().decode(PlanTree.self, from: JSONEncoder().encode(plan)), plan)
        let projected = CalendarProjection.project(dateString: "2026-09-21", today: "2026-09-21",
            sessionByDate: [:], schedule: PlanSchedule(version: 1, week: ["mon": "b"]),
            templateIDs: Set(plan.availableWorkouts.map(\.id)))
        XCTAssertEqual(projected, .rest)
        let done = SessionRow(id: "s", date: "2026-09-21", status: "completed", workout_id: "b")
        let history = CalendarProjection.project(dateString: done.date, today: done.date,
            sessionByDate: [done.date: done], schedule: nil, templateIDs: Set(plan.availableWorkouts.map(\.id)))
        XCTAssertEqual(history, .session(status: "completed", hardBlackoutTripType: nil))
    }

    func testTripChoicesPrioritizeTravelAndExcludeArchivedWithoutReorderingOthers() {
        let gym = Workout(id: "gym", name: "Gym", day_label: nil, order_index: 0, exercises: [])
        let travel = Workout(tags: #"["travel"]"#, id: "hotel", name: "Hotel", day_label: nil, order_index: 1, exercises: [])
        let retired = Workout(tags: #"["travel"]"#, archived_at: 123, id: "retired", name: "Retired", day_label: nil, order_index: 2, exercises: [])
        let plan = PlanTree(id: "p", name: "Library", version: 2, workouts: [gym, travel, retired],
            meta: #"{"trips":[{"id":"trip","start":"2026-09-21","end":"2026-09-23","type":"travel","can_train_light":true}]}"#)
        XCTAssertEqual(WorkoutLibraryPolicy.choices(plan: plan, date: "2026-09-20").map(\.id), ["gym", "hotel"])
        XCTAssertEqual(WorkoutLibraryPolicy.choices(plan: plan, date: "2026-09-21").map(\.id), ["hotel", "gym"])
        XCTAssertEqual(WorkoutLibraryPolicy.choices(plan: plan, date: "2026-09-23").map(\.id), ["hotel", "gym"])
    }

    func testPlanWeekShowsEachWeekdayAndTreatsMissingOrArchivedWorkoutsAsRest() {
        let gym = Workout(id: "gym", name: "Gym", day_label: nil, order_index: 0, exercises: [])
        let retired = Workout(archived_at: 123, id: "retired", name: "Retired", day_label: nil, order_index: 1, exercises: [])
        let plan = PlanTree(id: "p", name: "Library", version: 2, workouts: [gym, retired],
            meta: #"{"schedule":{"version":1,"week":{"mon":"gym","wed":"retired","fri":"gone","sat":"gym"}}}"#)
        let rows = WorkoutLibraryPolicy.weekRows(plan: plan)
        XCTAssertEqual(rows.map(\.weekdayKey), ["mon", "tue", "wed", "thu", "fri", "sat", "sun"])
        XCTAssertEqual(rows.map(\.workoutName), ["Gym", nil, nil, nil, nil, "Gym", nil])
        XCTAssertEqual(rows.map(\.workoutID), ["gym", nil, nil, nil, nil, "gym", nil])
        XCTAssertTrue(WorkoutLibraryPolicy.hasScheduledDay(plan: plan))

        let unscheduled = PlanTree(id: "p", name: "Library", version: 2, workouts: [gym], meta: nil)
        XCTAssertEqual(WorkoutLibraryPolicy.weekRows(plan: unscheduled).compactMap(\.workoutName), [])
        XCTAssertFalse(WorkoutLibraryPolicy.hasScheduledDay(plan: unscheduled))
        XCTAssertEqual(WorkoutLibraryPolicy.weekRows(plan: nil).count, 7)
        XCTAssertFalse(WorkoutLibraryPolicy.hasScheduledDay(plan: nil))
    }

    func testChangingOneWeekdayKeepsTheOthersAndClearsDeadReferences() {
        let gym = Workout(id: "gym", name: "Gym", day_label: nil, order_index: 0, exercises: [])
        let soccer = Workout(id: "soccer", name: "Soccer", day_label: nil, order_index: 1, exercises: [])
        let retired = Workout(archived_at: 123, id: "retired", name: "Retired", day_label: nil, order_index: 2, exercises: [])
        let plan = PlanTree(id: "p", name: "Library", version: 4, workouts: [gym, soccer, retired],
            meta: #"{"schedule":{"version":1,"week":{"mon":"gym","wed":"retired","fri":"gone","sat":"gym"}}}"#)

        let week = WorkoutLibraryPolicy.week(plan, setting: "mon", to: "soccer")
        XCTAssertEqual(week, ["mon": "soccer", "tue": "", "wed": "", "thu": "",
                              "fri": "", "sat": "gym", "sun": ""])
        XCTAssertEqual(WorkoutLibraryPolicy.week(plan, setting: "sat", to: nil)["sat"], "")
        XCTAssertEqual(WorkoutLibraryPolicy.week(plan, setting: "sat", to: nil)["mon"], "gym")
    }

    func testAPlannedActivityIsAWorkoutWithoutExercisesLoggedByItsName() {
        let slot = TemplateExercise(id: "slot", exercise_id: "squat", exercise_name: "Squat",
            exercise_unit: "lb", order_index: 0, target_sets: 3, target_reps: 5,
            target_reps_max: nil, target_rpe: nil, rest_seconds: 90,
            target_weight: nil, cues: nil, exercise_modality: "barbell",
            exercise_laterality: nil, exercise_load_mode: nil, exercise_demo_slug: nil,
            target_duration_s: nil, is_warmup: 0)
        let soccer = Workout(id: "soccer", name: "Soccer", day_label: nil, order_index: 0, exercises: [])
        let lift = Workout(id: "lift", name: "Lift", day_label: nil, order_index: 1, exercises: [slot])
        XCTAssertTrue(PlannedActivity.isActivity(soccer))
        XCTAssertFalse(PlannedActivity.isActivity(lift))

        XCTAssertEqual(PlannedActivity.kind(for: "Soccer"), "soccer")
        XCTAssertEqual(PlannedActivity.kind(for: "Board games"), "other")
        XCTAssertEqual(PlannedActivity.kind(for: " yoga "), "yoga")
        XCTAssertEqual(PlannedActivity.kind(for: "Hike"), "hike")

        func row(_ title: String?, deleted: Int? = nil) -> ActivityRow {
            ActivityRow(id: UUID().uuidString, user_id: "u", date: "2026-11-02", type: "other",
                        title: title, duration_minutes: 90, notes: nil, logged_at: 1,
                        source: "ios", deleted_at: deleted)
        }
        XCTAssertTrue(PlannedActivity.isLogged("Soccer", manual: [row("soccer ")], synced: []))
        XCTAssertFalse(PlannedActivity.isLogged("Soccer", manual: [row("Pilates"), row(nil)], synced: []))
        XCTAssertFalse(PlannedActivity.isLogged("  ", manual: [row("")], synced: []))

        let plan = PlanTree(id: "p", name: "Library", version: 1, workouts: [soccer, lift], meta: nil)
        XCTAssertEqual(PlannedActivity.existing(named: "SOCCER", in: plan)?.id, "soccer")
        XCTAssertNil(PlannedActivity.existing(named: "Tennis", in: plan))
        XCTAssertNil(PlannedActivity.existing(named: "", in: plan))
    }

    func testANewRunFromAWeekdayIsAWorkoutWithOneOutdoorRun() {
        func slot(_ id: String, _ exerciseID: String) -> TemplateExercise {
            TemplateExercise(id: id, exercise_id: exerciseID, exercise_name: exerciseID,
                exercise_unit: "min", order_index: 0, target_sets: 1, target_reps: 30,
                target_reps_max: nil, target_rpe: nil, rest_seconds: 0,
                target_weight: nil, cues: nil, exercise_modality: "cardio",
                exercise_laterality: nil, exercise_load_mode: nil, exercise_demo_slug: nil,
                target_duration_s: 1800, is_warmup: 0)
        }
        let intervals = Workout(id: "intervals", name: "Intervals", day_label: nil, order_index: 0,
                                exercises: [slot("run-slot", RunPlan.exerciseID)])
        let tempo = Workout(id: "tempo", name: "Tempo run", day_label: nil, order_index: 1,
                            exercises: [slot("tempo-run", RunPlan.exerciseID), slot("plank", "plank")])
        let soccer = Workout(id: "soccer", name: "Soccer", day_label: nil, order_index: 2, exercises: [])
        let plan = PlanTree(id: "p", name: "Library", version: 4, workouts: [intervals, tempo, soccer], meta: nil)

        XCTAssertEqual(PlannedRunCreation.name("  "), "Run")
        XCTAssertEqual(PlannedRunCreation.name(" Long run "), "Long run")

        XCTAssertTrue(PlannedRunCreation.isRun(intervals))
        XCTAssertFalse(PlannedRunCreation.isRun(tempo), "A run with other exercises is a workout")
        XCTAssertFalse(PlannedRunCreation.isRun(soccer), "An activity has no run to plan")

        XCTAssertEqual(PlannedRunCreation.match(named: "intervals ", in: plan), .run(intervals))
        XCTAssertEqual(PlannedRunCreation.match(named: "Tempo run", in: plan), .taken(tempo))
        XCTAssertEqual(PlannedRunCreation.match(named: "Soccer", in: plan), .taken(soccer))
        XCTAssertEqual(PlannedRunCreation.match(named: "Easy run", in: plan), .available)
        XCTAssertEqual(PlannedRunCreation.match(named: "Easy run", in: nil), .available)

        XCTAssertEqual(PlannedRunCreation.runSlot(in: intervals)?.id, "run-slot")
        XCTAssertEqual(PlannedRunCreation.runSlot(in: tempo)?.id, "tempo-run")
        XCTAssertNil(PlannedRunCreation.runSlot(in: soccer))
        XCTAssertNil(PlannedRunCreation.runSlot(in: nil))

        XCTAssertEqual(WeekdayPlanSheet.detail(for: intervals), "Run")
        XCTAssertEqual(WeekdayPlanSheet.detail(for: soccer), "Activity")
        XCTAssertEqual(WeekdayPlanSheet.detail(for: tempo), "2 exercises")
    }
}
