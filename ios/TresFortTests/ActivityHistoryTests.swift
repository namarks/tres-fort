import XCTest
@testable import TresFort

final class ActivityHistoryTests: XCTestCase {
    private func session(_ id: String, _ date: String, _ status: String = "completed",
                         workout: String? = "lift", revision: Int = 1, kind: String? = nil,
                         started: Int? = nil, completed: Int? = nil) -> SessionRow {
        var row = SessionRow(id: id, date: date, status: status, workout_id: workout, updated_at: revision)
        row.kind = kind
        row.started_at = started
        row.completed_at = completed
        return row
    }

    private func activity(_ id: String, _ date: String, kind: String = "run", name: String? = nil,
                          source: String = "intervals", seconds: Int? = 1_537, meters: Double? = 5_296,
                          deleted: Bool = false) -> ExternalActivity {
        ExternalActivity(
            id: id, source: source, external_id: id, date: date, kind: kind, name: name,
            moving_time_sec: seconds, elapsed_time_sec: nil, distance_m: meters, average_watts: nil,
            weighted_avg_watts: nil, average_hr: nil, max_hr: nil, training_load: nil,
            intensity: nil, calories: nil, elevation_gain_m: nil, synced_at: 1, deleted_at: deleted ? 2 : nil)
    }

    private func logged(_ id: String, _ date: String, type: String = "other", title: String? = "Soccer",
                        minutes: Int? = 90, deleted: Bool = false) -> ActivityRow {
        ActivityRow(id: id, user_id: "user", date: date, type: type, title: title,
                    duration_minutes: minutes, notes: nil, logged_at: 1, source: "ios",
                    deleted_at: deleted ? 2 : nil)
    }

    private func history(sessions: [SessionRow] = [], activities: [ExternalActivity] = [],
                         logged: [ActivityRow] = [], today: String = "2026-11-03",
                         sets: [String: Int] = [:],
                         workouts: [String: ActivityHistory.WorkoutInfo] = [
                            "lift": .init(name: "Kettlebell A", isRunOnly: false),
                            "tempo": .init(name: "Tempo run", isRunOnly: true),
                         ],
                         hidden: Set<String> = []) -> ActivityHistory {
        ActivityHistory(sessions: sessions, activities: activities, logged: logged, today: today,
                        unit: .miles, setCount: { sets[$0] ?? 0 },
                        workout: { id in id.flatMap { workouts[$0] } },
                        isHidden: { hidden.contains($0) })
    }

    func testListsWorkoutsRunsAndLoggedActivitiesNewestFirst() {
        let result = history(
            sessions: [session("s1", "2026-11-02", started: 1_000, completed: 2_701_000)],
            activities: [activity("r1", "2026-11-01", name: "Easy run")],
            logged: [logged("l1", "2026-11-02")],
            sets: ["s1": 12])
        XCTAssertEqual(result.entries.map(\.id), ["workout:s1", "logged:l1", "activity:r1"])
        let workout = result.entries[0]
        XCTAssertEqual(workout.title, "Kettlebell A")
        XCTAssertEqual(workout.category, .workouts)
        XCTAssertEqual(workout.details, ["12 sets", "45m"])
        let run = result.entries[2]
        XCTAssertEqual(run.title, "Easy run")
        XCTAssertEqual(run.category, .runs)
        XCTAssertEqual(Array(run.details.prefix(2)), ["3.3 mi", "25m"])
        XCTAssertTrue(run.details.last?.hasSuffix("/mi") == true)
        let soccer = result.entries[1]
        XCTAssertEqual(soccer.title, "Soccer")
        XCTAssertEqual(soccer.category, .other)
        XCTAssertEqual(soccer.details, ["1h 30m", "Other"])
    }

    func testEntriesOnOneDateEachOpenThemselves() {
        // A workout and a run on one date: tapping the run must open the run,
        // not the workout listed above it.
        let result = history(
            sessions: [session("s1", "2026-11-02")],
            activities: [activity("r1", "2026-11-02"), activity("r2", "2026-11-02", name: "Second run")],
            logged: [logged("l1", "2026-11-02")],
            sets: ["s1": 12])
        let focus = Dictionary(uniqueKeysWithValues: result.entries.map { ($0.id, $0.focus) })
        XCTAssertEqual(focus.count, 4)
        XCTAssertEqual(focus["workout:s1"], .some(nil), "A workout opens its whole date")
        XCTAssertEqual(focus["activity:r1"], .activity("r1"))
        XCTAssertEqual(focus["activity:r2"], .activity("r2"))
        XCTAssertEqual(focus["logged:l1"], .logged("l1"))
        let opened = result.entries.map {
            ActivityHistoryDay(entryID: $0.id, date: $0.date, focus: $0.focus)
        }
        XCTAssertEqual(Set(opened).count, opened.count, "No two rows push the same value")
    }

    func testOnlyFinishedOrStartedWorkoutsUpToTodayAppearOnce() {
        let result = history(sessions: [
            session("done", "2026-11-01"),
            session("done", "2026-11-01"),
            session("gone", "2026-11-01"),
            session("gone", "2026-11-01", "discarded", revision: 2),
            session("planned", "2026-11-02", "planned"),
            session("skipped", "2026-11-02", "skipped"),
            session("live", "2026-11-03", "in_progress"),
            session("empty-live", "2026-11-03", "in_progress"),
            session("future", "2026-11-04"),
        ], sets: ["live": 3, "done": 5])
        XCTAssertEqual(result.entries.map(\.id), ["workout:live", "workout:done"])
        XCTAssertTrue(result.entries[0].inProgress)
        XCTAssertEqual(result.entries[0].details, ["3 sets"], "No duration until it ends")
    }

    func testFinishedRunWorkoutIsListedOnceAsItsRun() {
        let result = history(
            sessions: [session("run-workout", "2026-11-01", workout: "tempo"),
                       session("no-run-yet", "2026-10-30", workout: "tempo")],
            activities: [activity("recorded", "2026-11-01", name: "Tempo run", source: "recording")],
            sets: ["run-workout": 1, "no-run-yet": 1])
        XCTAssertEqual(result.entries.map(\.id), ["activity:recorded", "workout:no-run-yet"])
        XCTAssertTrue(result.entries[0].hasRoute, "A run recorded in the app has a route map")
        XCTAssertEqual(result.entries[1].title, "Tempo run")
    }

    func testDeletedFutureAndHiddenTripActivitiesStayOut() {
        let result = history(
            activities: [activity("deleted", "2026-11-01", deleted: true),
                         activity("future", "2026-11-04"),
                         activity("trip", "2026-10-20"),
                         activity("ride", "2026-10-21", kind: "ride", meters: 30_000)],
            logged: [logged("deleted", "2026-11-01", deleted: true),
                     logged("trip", "2026-10-20")],
            hidden: ["2026-10-20"])
        XCTAssertEqual(result.entries.map(\.id), ["activity:ride"])
        XCTAssertEqual(result.entries[0].title, "Ride")
        XCTAssertEqual(result.entries[0].hasRoute, false)
    }

    func testFreestyleAndRemovedWorkoutsKeepAReadableTitle() {
        let result = history(sessions: [
            session("free", "2026-11-02", workout: nil, kind: "freestyle"),
            session("removed", "2026-11-01", workout: "deleted-workout"),
        ], sets: ["free": 1, "removed": 2])
        XCTAssertEqual(result.entries.map(\.title), ["Freestyle workout", "Workout"])
        XCTAssertEqual(result.entries[0].details, ["1 set"])
    }

    func testCategoriesAndMonthsFollowTheFilter() {
        let result = history(
            sessions: [session("s1", "2026-11-02"), session("s2", "2026-10-28")],
            activities: [activity("r1", "2026-11-01"), activity("w1", "2026-10-02", kind: "hike")],
            logged: [logged("lift", "2026-09-30", type: "lift", title: nil, minutes: nil)],
            sets: ["s1": 1, "s2": 1])
        XCTAssertEqual(result.categories, [.workouts, .runs, .walks])
        XCTAssertEqual(result.months().map(\.id), ["2026-11", "2026-10", "2026-09"])
        XCTAssertEqual(result.months().map { $0.entries.count }, [2, 2, 1])
        let workouts = result.months(in: .workouts)
        XCTAssertEqual(workouts.map(\.id), ["2026-11", "2026-10", "2026-09"])
        XCTAssertEqual(workouts.flatMap(\.entries).map(\.id), ["workout:s1", "workout:s2", "logged:lift"])
        XCTAssertEqual(workouts.last?.entries.first?.title, "Lift (other)")
        XCTAssertEqual(result.months(in: .runs).flatMap(\.entries).map(\.id), ["activity:r1"])
        XCTAssertTrue(result.months(in: .swims).isEmpty)
    }

    func testMonthAndDayTitles() {
        XCTAssertEqual(ActivityHistory.monthTitle("2026-11"), "November 2026")
        XCTAssertFalse(ActivityHistory.dayTitle("2026-11-02").isEmpty)
        XCTAssertEqual(ActivityHistory.dayTitle("not-a-date"), "not-a-date")
    }
}
