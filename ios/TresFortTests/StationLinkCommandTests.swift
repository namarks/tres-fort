import XCTest
@testable import TresFort

private final class CommandTokenStore: AppTokenStore {
    var token: String?
    init(_ token: String) { self.token = token }
    func save(_ token: String) { self.token = token }
    func load() -> String? { token }
    func clear() { token = nil }
}

private final class CommandClock {
    var now = Date(timeIntervalSince1970: 2_000_000_000)
}

/// A gym without signal: every set waits in the iPhone's queue.
@MainActor
private final class OfflineSetWrites: SetWriteAPI {
    func createSession(date: String, workoutID: String?, jwt: String) async throws -> SessionRow {
        throw URLError(.notConnectedToInternet)
    }

    func logSet(sessionId: String, body: SetRequestBody, jwt: String) async throws -> APIClient.SetLogResult {
        throw URLError(.notConnectedToInternet)
    }

    func deleteSet(setId: String, jwt: String) async throws {
        throw URLError(.notConnectedToInternet)
    }

    func getState(jwt: String) async throws -> StateResponse {
        throw URLError(.notConnectedToInternet)
    }
}

/// Controls tapped on a linked iPad reach the iPhone's own runner through the
/// guarded actions its buttons use, and only for the set the iPad showed.
@MainActor
final class StationLinkCommandTests: XCTestCase {
    private let clock = CommandClock()
    private var retainedAuth: [AuthModel] = []

    private var today: String {
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = .current
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter.string(from: clock.now)
    }

    private func jwt(subject: String) -> String {
        func base64URL(_ data: Data) -> String {
            data.base64EncodedString()
                .replacingOccurrences(of: "+", with: "-")
                .replacingOccurrences(of: "/", with: "_")
                .replacingOccurrences(of: "=", with: "")
        }
        let header = try! JSONSerialization.data(withJSONObject: ["alg": "HS256"])
        let payload = try! JSONSerialization.data(withJSONObject: ["exp": 4_000_000_000, "sub": subject])
        return "\(base64URL(header)).\(base64URL(payload)).signature"
    }

    private func slot(_ id: String, order: Int = 0, timed: Bool = false, unit: String = "lb") -> TemplateExercise {
        TemplateExercise(id: id, exercise_id: "exercise-\(id)", exercise_name: timed ? "Plank" : "Exercise \(id)",
            exercise_unit: "lb", order_index: order, target_sets: 3, target_reps: timed ? 30 : 5,
            target_reps_max: nil, target_rpe: nil, rest_seconds: 90, target_weight: timed ? 0 : 20,
            cues: nil, exercise_modality: timed ? "timed" : "barbell", exercise_laterality: "bilateral",
            exercise_load_mode: "total", exercise_demo_slug: nil, target_duration_s: timed ? 30 : nil,
            is_warmup: 0, target_weight_unit: unit, group_id: nil, group_rest_seconds: nil,
            group_transition_seconds: nil)
    }

    /// The iPhone's runner for today's workout, offline.
    private func runner(_ slots: [TemplateExercise], start: Bool = true) -> SyncModel {
        let suite = "StationLinkCommandTests.\(UUID().uuidString)"
        let defaults = LocalPersistence(suiteName: suite)!
        addTeardownBlock { [preferences = defaults.preferences, directory = defaults.trainingStore.directory] in
            preferences.removePersistentDomain(forName: suite)
            try? FileManager.default.removeItem(at: directory)
        }
        defaults.set("command-user", forKey: AuthModel.userIDKey)
        let clock = self.clock
        let auth = AuthModel(tokenStore: CommandTokenStore(jwt(subject: "command-user")), defaults: defaults,
                             now: { clock.now })
        retainedAuth.append(auth)
        let sync = SyncModel(auth: auth, setWriteAPI: OfflineSetWrites(), defaults: defaults,
                             now: { clock.now },
                             restActivityUpdater: { _, _ in }, restActivityEnder: {},
                             timedCuePlayer: { _, _ in false }, restNotificationCanceller: {})
        let workout = Workout(id: "day", name: "Strength", day_label: "A", order_index: 0, exercises: slots)
        sync.replaceState(with: StateResponse(
            plan: PlanTree(id: "plan", name: "Plan", version: 1, workouts: [workout], meta: nil),
            plan_version: 1,
            sessions: [SessionRow(id: "session", date: today, status: "in_progress", workout_id: "day", attempt: 0)],
            sets: [], external_events: [], external_activities: [], activities: [],
            server_time: 2_000_000_000_000, planGroupsVersion: 1))
        if start { sync.startWorkout() }
        return sync
    }

    /// The set the iPhone shows, which the iPad shows too.
    private func shown(_ sync: SyncModel, in unit: WeightUnit? = nil) throws -> WorkoutDisplayState.Step {
        try XCTUnwrap(WorkoutDisplayState.project(sync: sync, displayUnit: unit).current)
    }

    /// Lets the queued set's background delivery attempt run.
    private func settle() async {
        for _ in 0..<10 { await Task.yield() }
    }

    func testLogsOnlyTheSetTheIpadShowedAndOnlyOnce() async throws {
        let sync = runner([slot("squat"), slot("row", order: 1)])
        XCTAssertTrue(sync.running)
        let first = try shown(sync)
        XCTAssertEqual(first.setNumber, 1)
        let log = StationLinkCommand(.logSet, step: first)
        let logged = await StationLinkCommandRunner.apply(log, to: sync)
        XCTAssertEqual(logged, .accepted(log))
        XCTAssertEqual(sync.setOutbox.pending.map(\.body.set_index), [1])
        XCTAssertNotNil(sync.restEndDate, "Rest starts as after a tap on the iPhone")
        await settle()

        let again = StationLinkCommand(.logSet, step: first)
        let repeated = await StationLinkCommandRunner.apply(again, to: sync)
        XCTAssertEqual(repeated, .refused(again, StationLinkCommandReceipt.movedOn))
        XCTAssertEqual(sync.setOutbox.pending.count, 1, "A repeated tap never logs another set")
        XCTAssertEqual(try shown(sync).setNumber, 2)
    }

    func testEndingRestAndChoosingAnExerciseMoveTheRunnerWithoutSkippingAnything() async throws {
        let squat = slot("squat"), row = slot("row", order: 1)
        let sync = runner([squat, row])
        _ = await StationLinkCommandRunner.apply(StationLinkCommand(.logSet, step: try shown(sync)), to: sync)
        XCTAssertNotNil(sync.restEndDate)
        let endRest = StationLinkCommand(.endRest)
        let ended = await StationLinkCommandRunner.apply(endRest, to: sync)
        XCTAssertEqual(ended, .accepted(endRest))
        XCTAssertNil(sync.restEndDate)
        let endAgain = await StationLinkCommandRunner.apply(StationLinkCommand(.endRest), to: sync)
        XCTAssertTrue(endAgain.accepted, "A rest that already ended stays ended")

        let choose = StationLinkCommand(.select(slotID: row.id))
        let chosen = await StationLinkCommandRunner.apply(choose, to: sync)
        XCTAssertEqual(chosen, .accepted(choose))
        XCTAssertEqual(sync.currentExercise?.id, row.id)
        XCTAssertFalse(sync.isSkipped(squat), "Moving ahead never skips the exercise left")
        let missing = await StationLinkCommandRunner.apply(StationLinkCommand(.select(slotID: "removed")), to: sync)
        XCTAssertEqual(missing.message, "That exercise is no longer in this workout.")
        XCTAssertEqual(sync.currentExercise?.id, row.id)
    }

    func testEditedValuesKeepAnUnchangedLoadExactAndConvertAChangedOne() async throws {
        let sync = runner([slot("squat", unit: "kg")])
        XCTAssertEqual(sync.weight, 20)
        // This iPhone shows pounds, so the iPad does too.
        let step = try shown(sync, in: .lb)
        let shownLoad = try XCTUnwrap(step.weight)
        let reps = StationLinkCommand(.setValues(SetCorrectionValues(weight: shownLoad, reps: 9, rpe: 8,
                                                                     durationSeconds: nil), unit: .lb), step: step)
        let kept = await StationLinkCommandRunner.apply(reps, to: sync)
        XCTAssertEqual(kept, .accepted(reps))
        XCTAssertEqual(sync.weight, 20, "An unchanged load stays exactly 20 kg, not a round trip through pounds")
        XCTAssertEqual(sync.reps, 9)
        XCTAssertEqual(sync.rpe, 8)

        let heavier = StationLinkCommand(.setValues(SetCorrectionValues(weight: 50, reps: 9, rpe: nil,
                                                                        durationSeconds: nil), unit: .lb), step: step)
        let changed = await StationLinkCommandRunner.apply(heavier, to: sync)
        XCTAssertEqual(changed, .accepted(heavier))
        XCTAssertEqual(sync.weight, WeightUnit.lb.convert(50, to: .kg), accuracy: 0.000_001)
        XCTAssertNil(sync.rpe)

        let log = StationLinkCommand(.logSet, step: step)
        let logged = await StationLinkCommandRunner.apply(log, to: sync)
        XCTAssertEqual(logged, .accepted(log))
        let body = try XCTUnwrap(sync.setOutbox.pending.first?.body)
        XCTAssertEqual(body.weight, WeightUnit.lb.convert(50, to: .kg), accuracy: 0.000_001)
        XCTAssertEqual(body.weight_unit, "kg", "The set is logged in the slot's unit")
        XCTAssertEqual(body.reps, 9)
    }

    func testATimedSetStartsFromTheIpadAndStopsOnlyOnceItHasRun() async throws {
        let plank = slot("plank", timed: true), row = slot("row", order: 1)
        let sync = runner([plank, row])
        let step = try shown(sync)
        XCTAssertEqual(step.durationSeconds, 30)
        let start = StationLinkCommand(.startTimer, step: step)
        let started = await StationLinkCommandRunner.apply(start, to: sync)
        XCTAssertEqual(started, .accepted(start))
        XCTAssertTrue(sync.timedActive)

        let early = await StationLinkCommandRunner.apply(StationLinkCommand(.stopTimer, step: step), to: sync)
        XCTAssertEqual(early.message, "Let the timer run a few seconds before stopping it.")
        let elsewhere = await StationLinkCommandRunner.apply(StationLinkCommand(.select(slotID: row.id)), to: sync)
        XCTAssertEqual(elsewhere.message, "Stop the timer before choosing another exercise.")
        let edit = await StationLinkCommandRunner.apply(StationLinkCommand(.setValues(
            SetCorrectionValues(weight: 0, reps: 20, rpe: nil, durationSeconds: 20), unit: .lb), step: step), to: sync)
        XCTAssertEqual(edit.message, "Stop the timer before changing this set.")
        XCTAssertTrue(sync.timedActive)
        XCTAssertTrue(sync.setOutbox.pending.isEmpty)

        clock.now = clock.now.addingTimeInterval(10)
        let stop = StationLinkCommand(.stopTimer, step: step)
        let stopped = await StationLinkCommandRunner.apply(stop, to: sync)
        XCTAssertEqual(stopped, .accepted(stop))
        XCTAssertFalse(sync.timedActive)
        XCTAssertEqual(sync.setOutbox.pending.map(\.body.duration_s), [10], "The hold logs as long as it ran")
    }

    func testAnIphoneWithoutARunningWorkoutTakesNoControls() async {
        let sync = runner([slot("squat")], start: false)
        let endRest = StationLinkCommand(.endRest)
        let refused = await StationLinkCommandRunner.apply(endRest, to: sync)
        XCTAssertEqual(refused, .refused(endRest, StationLinkCommandReceipt.openWorkout))
    }
}
