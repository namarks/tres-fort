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
}
