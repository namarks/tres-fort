import Foundation
import UserNotifications
import XCTest
@testable import TresFort

private final class AgendaTokenStore: AppTokenStore {
    var token: String?
    init(_ token: String?) { self.token = token }
    func save(_ token: String) { self.token = token }
    func load() -> String? { token }
    func clear() { token = nil }
}

@MainActor
private final class AgendaAuthAPI: AuthAPI {
    func authApple(identityToken: String, authorizationCode: String?, fullName: String?) async throws -> AuthResponse {
        throw URLError(.badServerResponse)
    }
    func renewAppSession(jwt: String) async throws -> SessionRenewalResponse { throw URLError(.badServerResponse) }
    func deleteAccount(jwt: String, idempotencyKey: String) async throws -> AccountDeletionResponse {
        throw URLError(.badServerResponse)
    }
    func downloadAccountExport(jwt: String) async throws -> AccountExportFile { throw URLError(.badServerResponse) }
}

@MainActor
private final class ReminderCenterStub: WorkoutReminderCenter {
    var status: UNAuthorizationStatus = .authorized
    var grant = true
    var pending: [String: UNNotificationRequest] = [:]
    var delivered: Set<String> = []
    var addEntered: (() -> Void)?

    func authorizationStatus() async -> UNAuthorizationStatus { status }
    func requestAuthorization() async -> Bool {
        status = grant ? .authorized : .denied
        return grant
    }
    func add(_ request: UNNotificationRequest) async throws {
        addEntered?()
        pending[request.identifier] = request
    }
    func pendingIdentifiers() async -> [String] { Array(pending.keys) }
    func deliveredIdentifiers() async -> [String] { Array(delivered) }
    func removePending(_ identifiers: [String]) { identifiers.forEach { pending[$0] = nil } }
    func removeDelivered(_ identifiers: [String]) { identifiers.forEach { delivered.remove($0) } }
}

@MainActor
final class TrainingAgendaTests: XCTestCase {
    private let fixedDate = Date(timeIntervalSince1970: 2_000_000_000)
    private var retained: [AnyObject] = []

    // MARK: fixtures

    private func persistence() -> LocalPersistence {
        let name = "TrainingAgendaTests.\(UUID().uuidString)"
        let defaults = LocalPersistence(suiteName: name)!
        addTeardownBlock { [preferences = defaults.preferences, directory = defaults.trainingStore.directory] in
            preferences.removePersistentDomain(forName: name)
            try? FileManager.default.removeItem(at: directory)
        }
        return defaults
    }

    private func userDefaults() -> UserDefaults {
        let name = "TrainingAgendaTests.shared.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        addTeardownBlock { defaults.removePersistentDomain(forName: name) }
        return defaults
    }

    private func jwt(subject: String) -> String {
        func base64URL(_ data: Data) -> String {
            data.base64EncodedString()
                .replacingOccurrences(of: "+", with: "-")
                .replacingOccurrences(of: "/", with: "_")
                .replacingOccurrences(of: "=", with: "")
        }
        let header = try! JSONSerialization.data(withJSONObject: ["alg": "HS256"])
        let payload = try! JSONSerialization.data(withJSONObject: [
            "exp": Int(Date.distantFuture.timeIntervalSince1970), "sub": subject,
        ])
        return "\(base64URL(header)).\(base64URL(payload)).signature"
    }

    private func auth(_ defaults: LocalPersistence) -> AuthModel {
        defaults.set("user-a", forKey: AuthModel.userIDKey)
        let model = AuthModel(api: AgendaAuthAPI(), tokenStore: AgendaTokenStore(jwt(subject: "user-a")),
                              defaults: defaults, now: { self.fixedDate })
        retained.append(model)
        return model
    }

    private func slot(_ id: String, _ name: String, warmup: Bool = false) -> TemplateExercise {
        TemplateExercise(
            id: id, exercise_id: "exercise-\(id)", exercise_name: name, exercise_unit: "lb",
            order_index: 0, target_sets: 3, target_reps: 5, target_reps_max: nil, target_rpe: nil,
            rest_seconds: 90, target_weight: 100, cues: nil, exercise_modality: "barbell",
            exercise_laterality: "bilateral", exercise_load_mode: "total", exercise_demo_slug: nil,
            target_duration_s: nil, is_warmup: warmup ? 1 : 0, target_weight_unit: nil,
            group_id: nil, group_rest_seconds: nil, group_transition_seconds: nil)
    }

    private func date(_ offset: Int, from today: String) -> String {
        let start = CalendarProjection.date(from: today)!
        return CalendarProjection.dateString(
            CalendarProjection.calendar.date(byAdding: .day, value: offset, to: start)!)
    }

    /// A plan whose weekly schedule puts "Upper" on today's weekday and on the
    /// weekday two days later; every other day is rest.
    private func model(sessions: [SessionRow] = [], sets: [SetLog] = [],
                       defaults: LocalPersistence? = nil) -> SyncModel {
        let defaults = defaults ?? persistence()
        let model = SyncModel(auth: auth(defaults), defaults: defaults, now: { self.fixedDate })
        let today = model.todayString
        let todayKey = CalendarProjection.weekdayKey(forDateString: today)!
        let laterKey = CalendarProjection.weekdayKey(forDateString: date(2, from: today))!
        let upper = Workout(id: "upper", name: "Upper", day_label: "A", order_index: 0, exercises: [
            slot("warm", "Band Pull-Apart", warmup: true), slot("bench", "Bench Press"),
            slot("row", "Barbell Row"), slot("press", "Overhead Press"), slot("pull", "Pull-Up"),
        ])
        model.plan = PlanTree(
            id: "plan-a", name: "Plan", version: 1, workouts: [upper],
            meta: #"{"schedule":{"version":1,"week":{"\#(todayKey)":"upper","\#(laterKey)":"upper"}}}"#)
        model.sessions = sessions
        model.sets = sets
        return model
    }

    private func setLog(session: String) -> SetLog {
        SetLog(id: UUID().uuidString, session_id: session, exercise_id: "exercise-bench",
               template_exercise_id: "bench", set_index: 0, weight: 100, reps: 5, rpe: nil,
               is_warmup: 0, logged_at: 1, duration_s: nil, is_timed: 0, deleted_at: nil)
    }

    private func day(_ ymd: String, _ status: TrainingAgendaDay.Status, _ name: String? = "Upper",
                     _ exercises: [String] = ["Bench Press"]) -> TrainingAgendaDay {
        TrainingAgendaDay(date: ymd, status: status, workoutName: name, exerciseNames: exercises)
    }

    // MARK: snapshot

    func testSnapshotFollowsTheCalendarProjection() throws {
        let model = model()
        let today = model.todayString
        let snapshot = try XCTUnwrap(model.trainingAgendaSnapshot(dayCount: 4))

        XCTAssertEqual(snapshot.days.map(\.date), (0..<4).map { date($0, from: today) })
        XCTAssertEqual(snapshot.days.map(\.status), [.workout, .rest, .workout, .rest])
        XCTAssertEqual(snapshot.days[0].workoutName, "Upper")
        XCTAssertEqual(snapshot.days[0].exerciseNames,
                       ["Bench Press", "Barbell Row", "Overhead Press", "Pull-Up"],
                       "prescribed warm-ups are not listed")
        XCTAssertNil(snapshot.days[1].workoutName)
    }

    func testSnapshotIsNilBeforeAPlanIsRead() {
        let model = model()
        model.plan = nil
        XCTAssertNil(model.trainingAgendaSnapshot(),
                     "a cold launch must not replace the widget with an empty rest week")
    }

    func testCompletedSkippedAndStartedSessionsWin() throws {
        let probe = model()
        let today = probe.todayString
        let later = date(2, from: today)
        let completed = model(sessions: [
            SessionRow(id: "s-today", date: today, status: "completed", workout_id: "upper"),
            SessionRow(id: "s-later", date: later, status: "skipped", workout_id: "upper"),
        ])
        let done = try XCTUnwrap(completed.trainingAgendaSnapshot(dayCount: 3))
        XCTAssertEqual(done.days.map(\.status), [.completed, .rest, .skipped])
        XCTAssertEqual(done.days[0].workoutName, "Upper")

        let started = model(sessions: [SessionRow(id: "s-today", date: today, status: "in_progress",
                                                  workout_id: "upper")],
                            sets: [setLog(session: "s-today")])
        XCTAssertEqual(try XCTUnwrap(started.trainingAgendaSnapshot(dayCount: 1)).days[0].status, .inProgress)

        let phantom = model(sessions: [SessionRow(id: "s-today", date: today, status: "in_progress",
                                                  workout_id: "upper")])
        XCTAssertEqual(try XCTUnwrap(phantom.trainingAgendaSnapshot(dayCount: 1)).days[0].status, .workout,
                       "an in-progress row with no live sets is still the planned workout")
    }

    func testMountedRunnerIsInProgressBeforeItsFirstSet() throws {
        let model = model()
        model.selectedDayID = "upper"
        model.running = true
        let today = try XCTUnwrap(model.trainingAgendaSnapshot(dayCount: 1)).days[0]
        XCTAssertEqual(today.status, .inProgress, "a started workout gets no reminder and no Ready state")
        XCTAssertEqual(today.workoutName, "Upper")
    }

    func testFreestyleSessionIsNamed() throws {
        let probe = model()
        let today = probe.todayString
        let model = model(sessions: [SessionRow(kind: "freestyle", id: "s-free", date: today,
                                                status: "completed", workout_id: nil)])
        let first = try XCTUnwrap(model.trainingAgendaSnapshot(dayCount: 1)).days[0]
        XCTAssertEqual(first.status, .completed)
        XCTAssertEqual(first.workoutName, "Freestyle workout")
    }

    // MARK: reminders

    func testRemindersCoverOnlyWorkoutsStillToStart() {
        let calendar = TrainingAgendaCalendar.calendar(timeZone: TimeZone(identifier: "America/Los_Angeles")!)
        let snapshot = TrainingAgendaSnapshot(days: [
            day("2033-05-17", .workout), day("2033-05-18", .completed), day("2033-05-19", .skipped),
            day("2033-05-20", .rest, nil, []), day("2033-05-21", .inProgress), day("2033-05-22", .unavailable, nil, []),
            day("2033-05-23", .workout, "Lower", ["Squat", "Deadlift", "Lunge", "Calf Raise", "Plank"]),
        ])
        // 06:00 on the first day, local time.
        let now = calendar.date(from: DateComponents(year: 2033, month: 5, day: 17, hour: 6))!
        let reminders = WorkoutReminderPlan.reminders(snapshot: snapshot, now: now,
                                                      minutesAfterMidnight: 7 * 60 + 30, calendar: calendar)

        XCTAssertEqual(reminders.map(\.id), ["workout-reminder-2033-05-17", "workout-reminder-2033-05-23"])
        XCTAssertEqual(reminders[0].fireComponents.hour, 7)
        XCTAssertEqual(reminders[0].fireComponents.minute, 30)
        XCTAssertEqual(reminders[0].fireComponents.day, 17)
        XCTAssertEqual(reminders[0].title, "Today: Upper")
        XCTAssertEqual(reminders[0].body, "Bench Press")
        XCTAssertEqual(reminders[1].body, "Squat · Deadlift · Lunge + 2 more")

        let afterTime = calendar.date(from: DateComponents(year: 2033, month: 5, day: 17, hour: 8))!
        XCTAssertEqual(WorkoutReminderPlan.reminders(snapshot: snapshot, now: afterTime,
                                                     minutesAfterMidnight: 7 * 60 + 30, calendar: calendar).map(\.date),
                       ["2033-05-23"], "a time already past today is not scheduled")
    }

    func testReminderTimeIsWallClockAcrossDaylightSaving() {
        let calendar = TrainingAgendaCalendar.calendar(timeZone: TimeZone(identifier: "America/Los_Angeles")!)
        // US clocks spring forward on 2033-03-13.
        let snapshot = TrainingAgendaSnapshot(days: [day("2033-03-13", .workout)])
        let now = calendar.date(from: DateComponents(year: 2033, month: 3, day: 12, hour: 12))!
        let reminder = WorkoutReminderPlan.reminders(snapshot: snapshot, now: now,
                                                     minutesAfterMidnight: 7 * 60, calendar: calendar).first
        XCTAssertEqual(reminder?.fireComponents.hour, 7)
        XCTAssertEqual(reminder?.fireComponents.minute, 0)
    }

    func testReminderBodyWithoutExercises() {
        XCTAssertEqual(WorkoutReminderPlan.body(for: day("2033-05-17", .workout, nil, [])),
                       "Your workout is ready in Très Fort.")
    }

    func testCoordinatorReplacesRemindersAndKeepsOnlyTodaysDelivered() async {
        let center = ReminderCenterStub()
        center.pending = ["rest-cue-x": UNNotificationRequest(identifier: "rest-cue-x",
                                                              content: UNNotificationContent(), trigger: nil)]
        center.delivered = ["workout-reminder-2033-05-16", "workout-reminder-2033-05-17", "rest-cue-y"]
        let coordinator = WorkoutReminderCoordinator(center: center)
        let calendar = TrainingAgendaCalendar.calendar()
        let snapshot = TrainingAgendaSnapshot(days: [day("2033-05-18", .workout), day("2033-05-19", .workout)])
        let reminders = WorkoutReminderPlan.reminders(snapshot: snapshot, now: .distantPast,
                                                      minutesAfterMidnight: 420, calendar: calendar)

        coordinator.apply(reminders, keepDelivered: ["2033-05-17"])
        await coordinator.waitForTests()
        XCTAssertEqual(Set(center.pending.keys),
                       ["rest-cue-x", "workout-reminder-2033-05-18", "workout-reminder-2033-05-19"],
                       "other notifications are never touched")
        XCTAssertEqual(center.delivered, ["workout-reminder-2033-05-17", "rest-cue-y"])
        let trigger = center.pending["workout-reminder-2033-05-18"]?.trigger as? UNCalendarNotificationTrigger
        XCTAssertEqual(trigger?.repeats, false)
        XCTAssertEqual(trigger?.dateComponents.hour, 7)

        coordinator.apply(Array(reminders.prefix(1)))
        await coordinator.waitForTests()
        XCTAssertEqual(Set(center.pending.keys), ["rest-cue-x", "workout-reminder-2033-05-18"])
        XCTAssertEqual(center.delivered, ["rest-cue-y"])

        coordinator.clear()
        await coordinator.waitForTests()
        XCTAssertEqual(Set(center.pending.keys), ["rest-cue-x"])
    }

    func testCoordinatorSchedulesNothingWithoutPermission() async {
        let center = ReminderCenterStub()
        center.status = .denied
        let coordinator = WorkoutReminderCoordinator(center: center)
        let snapshot = TrainingAgendaSnapshot(days: [day("2033-05-18", .workout)])
        coordinator.apply(WorkoutReminderPlan.reminders(snapshot: snapshot, now: .distantPast,
                                                        minutesAfterMidnight: 420,
                                                        calendar: TrainingAgendaCalendar.calendar()))
        await coordinator.waitForTests()
        XCTAssertTrue(center.pending.isEmpty)
        let granted = await coordinator.requestAuthorization()
        XCTAssertFalse(granted, "a denied permission is not requested again")
    }

    func testSupersededApplyCannotOutliveSignOutClear() async {
        let center = ReminderCenterStub()
        let coordinator = WorkoutReminderCoordinator(center: center)
        let snapshot = TrainingAgendaSnapshot(days: [day("2033-05-18", .workout), day("2033-05-19", .workout)])
        center.addEntered = { [weak coordinator] in
            center.addEntered = nil
            coordinator?.clear()
        }
        coordinator.apply(WorkoutReminderPlan.reminders(snapshot: snapshot, now: .distantPast,
                                                        minutesAfterMidnight: 420,
                                                        calendar: TrainingAgendaCalendar.calendar()))
        await coordinator.waitForTests()
        XCTAssertTrue(center.pending.isEmpty, "the clear that superseded an in-flight apply runs last")
    }

    // MARK: widget timeline and storage

    func testTimelineTurnsOverAtEachMidnightAndThenAsksForTheApp() {
        let calendar = TrainingAgendaCalendar.calendar(timeZone: TimeZone(identifier: "Europe/Paris")!)
        let snapshot = TrainingAgendaSnapshot(days: [
            day("2033-05-17", .rest, nil, []), day("2033-05-18", .workout), day("2033-05-19", .rest, nil, []),
        ])
        let now = calendar.date(from: DateComponents(year: 2033, month: 5, day: 17, hour: 15))!
        let entries = TrainingAgendaTimeline.entries(snapshot: snapshot, now: now, calendar: calendar)

        XCTAssertEqual(entries.map(\.date), [
            now,
            calendar.date(from: DateComponents(year: 2033, month: 5, day: 18))!,
            calendar.date(from: DateComponents(year: 2033, month: 5, day: 19))!,
            calendar.date(from: DateComponents(year: 2033, month: 5, day: 20))!,
        ])
        XCTAssertEqual(entries.map { $0.day?.status }, [.rest, .workout, .rest, nil])
        XCTAssertEqual(entries[0].next?.date, "2033-05-18", "a rest day points at the next workout")
        XCTAssertNil(entries[2].next)
    }

    func testStaleOrMissingSnapshotShowsNoDay() {
        let calendar = TrainingAgendaCalendar.calendar()
        let now = calendar.date(from: DateComponents(year: 2033, month: 6, day: 1, hour: 9))!
        let stale = TrainingAgendaSnapshot(days: [day("2033-05-17", .workout)])
        XCTAssertEqual(TrainingAgendaTimeline.entries(snapshot: stale, now: now, calendar: calendar),
                       [TrainingAgendaTimeline.Entry(date: now, day: nil, next: nil)])
        XCTAssertEqual(TrainingAgendaTimeline.entries(snapshot: nil, now: now, calendar: calendar),
                       [TrainingAgendaTimeline.Entry(date: now, day: nil, next: nil)])
    }

    func testStoreReportsChangesAndRejectsOtherVersions() {
        let defaults = userDefaults()
        let snapshot = TrainingAgendaSnapshot(days: [day("2033-05-17", .workout)])
        XCTAssertTrue(TrainingAgendaStore.save(snapshot, to: defaults))
        XCTAssertFalse(TrainingAgendaStore.save(snapshot, to: defaults), "an identical write reloads nothing")
        XCTAssertEqual(TrainingAgendaStore.load(from: defaults), snapshot)
        XCTAssertTrue(TrainingAgendaStore.save(nil, to: defaults))
        XCTAssertFalse(TrainingAgendaStore.save(nil, to: defaults))
        XCTAssertNil(TrainingAgendaStore.load(from: defaults))

        var future = snapshot
        future.version = TrainingAgendaSnapshot.currentVersion + 1
        defaults.set(try! JSONEncoder().encode(future), forKey: TrainingAgendaStore.snapshotKey)
        XCTAssertNil(TrainingAgendaStore.load(from: defaults))
    }

    func testTodayLinkIsNavigationOnly() {
        XCTAssertTrue(TrainingAgendaLink.isTodayURL(TrainingAgendaLink.todayURL))
        XCTAssertTrue(TrainingAgendaLink.isTodayURL(URL(string: "tresfort://today/")!))
        XCTAssertFalse(TrainingAgendaLink.isTodayURL(URL(string: "tresfort://today/start")!))
        XCTAssertFalse(TrainingAgendaLink.isTodayURL(URL(string: "https://today")!))
        XCTAssertFalse(TrainingAgendaLink.isTodayURL(URL(string: "tresfort://ipad-display")!))
        XCTAssertTrue(WorkoutReminderPlan.isReminderID("workout-reminder-2033-05-17"))
        XCTAssertFalse(WorkoutReminderPlan.isReminderID("rest-cue-abc"))
    }

    // MARK: publisher

    func testReturningToTheAppReappliesRemindersAfterPermissionIsGranted() async {
        let model = model()
        let settings = userDefaults()
        settings.set(true, forKey: WorkoutReminderSettings.enabledKey)
        let center = ReminderCenterStub()
        center.status = .denied
        let coordinator = WorkoutReminderCoordinator(center: center)
        let publisher = TrainingAgendaPublisher(
            sync: model, auth: retained.compactMap { $0 as? AuthModel }.last!,
            sharedDefaults: userDefaults(), settings: settings, reminders: coordinator,
            reloadWidgets: {}, now: { .distantPast }, notificationCenter: NotificationCenter())

        publisher.refresh()
        await coordinator.waitForTests()
        XCTAssertTrue(center.pending.isEmpty)

        center.status = .authorized
        publisher.refresh()
        await coordinator.waitForTests()
        XCTAssertTrue(center.pending.isEmpty, "an unchanged agenda alone does not reschedule")

        publisher.refresh(reapplyReminders: true)
        await coordinator.waitForTests()
        XCTAssertFalse(center.pending.isEmpty, "returning to the app picks up permission granted in Settings")
    }

    func testPublisherWritesSnapshotSchedulesRemindersAndClearsAtSignOut() async throws {
        let defaults = persistence()
        let model = model(defaults: defaults)
        let shared = userDefaults()
        let settings = userDefaults()
        settings.set(true, forKey: WorkoutReminderSettings.enabledKey)
        settings.set(23 * 60 + 59, forKey: WorkoutReminderSettings.minutesKey)
        let center = ReminderCenterStub()
        let coordinator = WorkoutReminderCoordinator(center: center)
        var reloads = 0
        let publisher = TrainingAgendaPublisher(
            sync: model, auth: retained.compactMap { $0 as? AuthModel }.last!,
            sharedDefaults: shared, settings: settings, reminders: coordinator,
            reloadWidgets: { reloads += 1 }, now: { .distantPast },
            notificationCenter: NotificationCenter())

        publisher.refresh()
        await coordinator.waitForTests()
        let snapshot = try XCTUnwrap(TrainingAgendaStore.load(from: shared))
        XCTAssertEqual(snapshot, model.trainingAgendaSnapshot())
        XCTAssertEqual(reloads, 1)
        let workoutDays = snapshot.days.filter { $0.status == .workout }.map { "workout-reminder-" + $0.date }
        XCTAssertFalse(workoutDays.isEmpty)
        XCTAssertEqual(Set(center.pending.keys), Set(workoutDays))

        publisher.refresh()
        await coordinator.waitForTests()
        XCTAssertEqual(reloads, 1, "an unchanged agenda neither reloads the widget nor reschedules")

        settings.set(false, forKey: WorkoutReminderSettings.enabledKey)
        publisher.refresh()
        await coordinator.waitForTests()
        XCTAssertTrue(center.pending.isEmpty, "turning reminders off removes them")

        settings.set(true, forKey: WorkoutReminderSettings.enabledKey)
        publisher.refresh()
        await coordinator.waitForTests()
        XCTAssertFalse(center.pending.isEmpty)

        let auth = try XCTUnwrap(retained.compactMap { $0 as? AuthModel }.last)
        auth.signOut()
        await coordinator.waitForTests()
        XCTAssertTrue(publisher.isRetired)
        XCTAssertNil(TrainingAgendaStore.load(from: shared))
        XCTAssertEqual(reloads, 2)
        XCTAssertTrue(center.pending.isEmpty)

        publisher.refresh()
        XCTAssertNil(TrainingAgendaStore.load(from: shared), "a retired publisher never writes again")
    }
}
