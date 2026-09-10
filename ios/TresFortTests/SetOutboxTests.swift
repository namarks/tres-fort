import Foundation
import UserNotifications
import XCTest
@testable import TresFort

private final class SetMemoryTokenStore: AppTokenStore {
    var token: String?
    init(_ token: String? = nil) { self.token = token }
    func save(_ token: String) { self.token = token }
    func load() -> String? { token }
    func clear() { token = nil }
}

@MainActor
private final class SetAuthAPIStub: AuthAPI {
    var authResult: Result<AuthResponse, Error> = .failure(URLError(.badServerResponse))
    var renewalResult: Result<SessionRenewalResponse, Error> =
        .failure(URLError(.badServerResponse))
    var deletionResult: Result<AccountDeletionResponse, Error> =
        .failure(URLError(.badServerResponse))
    var deletionHandler: ((String, String) async throws -> AccountDeletionResponse)?

    func authApple(
        identityToken: String,
        authorizationCode: String?,
        fullName: String?
    ) async throws -> AuthResponse { try authResult.get() }

    func renewAppSession(jwt: String) async throws -> SessionRenewalResponse {
        try renewalResult.get()
    }

    func deleteAccount(
        jwt: String,
        idempotencyKey: String
    ) async throws -> AccountDeletionResponse {
        if let deletionHandler {
            return try await deletionHandler(jwt, idempotencyKey)
        }
        return try deletionResult.get()
    }

    func downloadAccountExport(jwt: String) async throws -> AccountExportFile {
        throw URLError(.badServerResponse)
    }
}

@MainActor
private final class SetWriteAPIStub: SetWriteAPI {
    struct CreateCall: Equatable {
        let date: String
        let workoutID: String?
        let expectedAttempt: Int?
        let restartDiscardedAttempt: Int?
        let jwt: String
    }
    struct LogCall: Equatable {
        let sessionID: String
        let body: SetRequestBody
        let jwt: String
    }

    var createHandler: ((String, String?, String) async throws -> SessionRow)?
    var logHandler: ((String, SetRequestBody, String) async throws -> APIClient.SetLogResult)?
    var reopenHandler: ((String, String?, Int?, String) async throws -> SessionRow)?
    var deleteHandler: ((String, String) async throws -> Void)?
    var correctionHandler: ((PendingSetCorrection, String) async throws -> SetCorrectionResult)?
    var summaryHandler: ((String, String) async throws -> WorkoutSummary)?
    private(set) var correctionCalls: [PendingSetCorrection] = []
    var stateHandler: ((String) async throws -> StateResponse)?
    var stateWatermarkHandler:
        ((String, StateSyncWatermarks) async throws -> StateResponse)?
    private(set) var createCalls: [CreateCall] = []
    private(set) var logCalls: [LogCall] = []
    private(set) var reopenCalls: [(
        sessionID: String,
        workoutID: String?,
        expectedAttempt: Int?,
        jwt: String
    )] = []
    private(set) var deleteCalls: [(setID: String, jwt: String)] = []
    private(set) var stateCalls = 0
    private(set) var stateWatermarkCalls: [StateSyncWatermarks] = []

    func createSession(
        date: String,
        workoutID: String?,
        jwt: String
    ) async throws -> SessionRow {
        createCalls.append(.init(
            date: date, workoutID: workoutID,
            expectedAttempt: nil, restartDiscardedAttempt: nil, jwt: jwt))
        guard let createHandler else { throw URLError(.badServerResponse) }
        return try await createHandler(date, workoutID, jwt)
    }

    func createSession(
        date: String,
        workoutID: String?,
        expectedAttempt: Int?,
        restartDiscardedAttempt: Int?,
        jwt: String
    ) async throws -> SessionRow {
        createCalls.append(.init(
            date: date, workoutID: workoutID,
            expectedAttempt: expectedAttempt,
            restartDiscardedAttempt: restartDiscardedAttempt,
            jwt: jwt))
        guard let createHandler else { throw URLError(.badServerResponse) }
        return try await createHandler(date, workoutID, jwt)
    }

    func logSet(
        sessionId: String,
        body: SetRequestBody,
        jwt: String
    ) async throws -> APIClient.SetLogResult {
        logCalls.append(.init(sessionID: sessionId, body: body, jwt: jwt))
        guard let logHandler else { throw URLError(.badServerResponse) }
        return try await logHandler(sessionId, body, jwt)
    }

    func reopenSkippedSession(
        sessionId: String,
        workoutID: String?,
        expectedAttempt: Int?,
        jwt: String
    ) async throws -> SessionRow {
        reopenCalls.append((sessionId, workoutID, expectedAttempt, jwt))
        guard let reopenHandler else { throw URLError(.badServerResponse) }
        return try await reopenHandler(
            sessionId, workoutID, expectedAttempt, jwt)
    }

    func getState(jwt: String) async throws -> StateResponse {
        try await getState(jwt: jwt, watermarks: .fullReload)
    }

    func getState(
        jwt: String,
        watermarks: StateSyncWatermarks
    ) async throws -> StateResponse {
        stateCalls += 1
        stateWatermarkCalls.append(watermarks)
        if let stateWatermarkHandler {
            return try await stateWatermarkHandler(jwt, watermarks)
        }
        guard let stateHandler else { throw URLError(.badServerResponse) }
        return try await stateHandler(jwt)
    }

    func getWorkoutSummary(sessionID: String, jwt: String) async throws -> WorkoutSummary {
        guard let summaryHandler else { throw URLError(.notConnectedToInternet) }
        return try await summaryHandler(sessionID, jwt)
    }

    func correctSet(_ intent: PendingSetCorrection, jwt: String) async throws -> SetCorrectionResult {
        correctionCalls.append(intent)
        guard let correctionHandler else { throw URLError(.badServerResponse) }
        return try await correctionHandler(intent, jwt)
    }

    func deleteSet(setId: String, jwt: String) async throws {
        deleteCalls.append((setId, jwt))
        guard let deleteHandler else { throw URLError(.badServerResponse) }
        try await deleteHandler(setId, jwt)
    }
}

@MainActor
private final class SetTerminalAPIStub: WorkoutTerminalAPI {
    var feedbackHandler: ((WorkoutFeedback?) async throws -> SessionRow)?
    private(set) var feedbackCalls: [WorkoutFeedback?] = []
    func completeSession(sessionId: String, expectedAttempt: Int?, feedback: WorkoutFeedback?, jwt: String) async throws -> SessionRow {
        feedbackCalls.append(feedback)
        if let feedbackHandler { return try await feedbackHandler(feedback) }
        return try await completeSession(sessionId: sessionId, expectedAttempt: expectedAttempt, jwt: jwt)
    }

    var completeHandler: ((String, String) async throws -> SessionRow)?
    var discardHandler: ((String, String) async throws -> SessionRow)?
    private(set) var completeCalls: [(sessionID: String, jwt: String)] = []
    private(set) var discardCalls: [(sessionID: String, jwt: String)] = []
    private(set) var completeExpectedAttempts: [Int?] = []
    private(set) var discardExpectedAttempts: [Int?] = []

    func completeSession(sessionId: String, jwt: String) async throws -> SessionRow {
        completeCalls.append((sessionId, jwt))
        completeExpectedAttempts.append(nil)
        guard let completeHandler else { throw URLError(.badServerResponse) }
        return try await completeHandler(sessionId, jwt)
    }

    func discardSession(sessionId: String, jwt: String) async throws -> SessionRow {
        discardCalls.append((sessionId, jwt))
        discardExpectedAttempts.append(nil)
        guard let discardHandler else { throw URLError(.badServerResponse) }
        return try await discardHandler(sessionId, jwt)
    }

    func completeSession(
        sessionId: String,
        expectedAttempt: Int?,
        jwt: String
    ) async throws -> SessionRow {
        completeCalls.append((sessionId, jwt))
        completeExpectedAttempts.append(expectedAttempt)
        guard let completeHandler else { throw URLError(.badServerResponse) }
        return try await completeHandler(sessionId, jwt)
    }

    func discardSession(
        sessionId: String,
        expectedAttempt: Int?,
        jwt: String
    ) async throws -> SessionRow {
        discardCalls.append((sessionId, jwt))
        discardExpectedAttempts.append(expectedAttempt)
        guard let discardHandler else { throw URLError(.badServerResponse) }
        return try await discardHandler(sessionId, jwt)
    }
}

@MainActor
private final class SetCatalogAPIStub: ExerciseCatalogAPI {
    var result: Result<[ExerciseCatalog], Error> = .success([])
    private(set) var jwtCalls: [String] = []

    func getExercises(jwt: String) async throws -> [ExerciseCatalog] {
        jwtCalls.append(jwt)
        return try result.get()
    }
}

@MainActor
private final class SetPlanEditingAPIStub: PlanEditingAPI {
    var replaceHandler: ((String, String, String, Int, String) async throws -> APIClient.SlotIDRow)?
    private(set) var replaceCalls = 0
    func replaceExerciseSlot(dayID: String, teID: String, exercise: String,
                             expectedVersion: Int, jwt: String) async throws -> APIClient.SlotIDRow {
        replaceCalls += 1
        guard let replaceHandler else { throw URLError(.badServerResponse) }
        return try await replaceHandler(dayID, teID, exercise, expectedVersion, jwt)
    }
    var addHandler: (() async throws -> APIClient.SlotIDRow)?
    var updateHandler: (() async throws -> APIClient.SlotIDRow)?
    var deleteHandler: (() async throws -> Void)?
    private(set) var addCalls = 0
    private(set) var updateCalls = 0
    private(set) var deleteCalls = 0
    private(set) var updatedFields: [String: Any] = [:]
    struct GroupCall {
        let dayID: String
        let groupID: String
        let memberIDs: [String]
        let expectedVersion: Int
        let roundRest: Int
        let transitionRest: Int
        let targetSets: Int
        let orderIndex: Int?
        let jwt: String
    }
    var groupHandler: ((GroupCall) async throws -> APIClient.ExerciseGroupAcknowledgement)?
    var clearGroupHandler: ((String, String, Int, String) async throws -> APIClient.ExerciseGroupAcknowledgement)?
    private(set) var groupCalls: [GroupCall] = []
    private(set) var clearGroupCalls = 0

    func setExerciseGroup(dayID: String, groupID: String, memberIDs: [String],
                          expectedVersion: Int, roundRest: Int, transitionRest: Int,
                          targetSets: Int, orderIndex: Int?, jwt: String) async throws
        -> APIClient.ExerciseGroupAcknowledgement {
        let call = GroupCall(dayID: dayID, groupID: groupID, memberIDs: memberIDs,
                             expectedVersion: expectedVersion, roundRest: roundRest,
                             transitionRest: transitionRest, targetSets: targetSets,
                             orderIndex: orderIndex, jwt: jwt)
        groupCalls.append(call)
        guard let groupHandler else { throw URLError(.badServerResponse) }
        return try await groupHandler(call)
    }

    func clearExerciseGroup(dayID: String, groupID: String, expectedVersion: Int, jwt: String)
        async throws -> APIClient.ExerciseGroupAcknowledgement {
        clearGroupCalls += 1
        guard let clearGroupHandler else { throw URLError(.badServerResponse) }
        return try await clearGroupHandler(dayID, groupID, expectedVersion, jwt)
    }

    func addExercise(
        dayID: String,
        exercise: String,
        isWarmup: Bool,
        targetSets: Int,
        targetReps: Int,
        targetRepsMax: Int?,
        restSeconds: Int,
        targetDurationS: Int?,
        jwt: String
    ) async throws -> APIClient.SlotIDRow {
        addCalls += 1
        guard let addHandler else { throw URLError(.badServerResponse) }
        return try await addHandler()
    }

    func updateExerciseSlot(
        dayID: String,
        teID: String,
        fields: [String: Any],
        jwt: String
    ) async throws -> APIClient.SlotIDRow {
        updateCalls += 1
        updatedFields = fields
        guard let updateHandler else { throw URLError(.badServerResponse) }
        return try await updateHandler()
    }

    func deleteExerciseSlot(
        dayID: String,
        teID: String,
        jwt: String
    ) async throws {
        deleteCalls += 1
        guard let deleteHandler else { throw URLError(.badServerResponse) }
        try await deleteHandler()
    }
}

@MainActor
private final class SetRoutineEditingAPIStub: RoutineEditingAPI {
    var historyHandler: ((Int, Int?, String) async throws -> PlanHistoryResponse)?
    var comparisonHandler: ((Int, Int, String) async throws -> PlanComparisonResponse)?
    var restoreHandler: ((Int, String, Int, String?, String) async throws -> APIClient.RestorePlanResult)?
    var ensureHandler: ((String, String) async throws -> APIClient.EnsureActivePlanResult)?
    var addDayHandler: ((String, String, Int, String) async throws -> APIClient.WorkoutIDRow)?
    var updateDayHandler: ((String, [String: Any], Int, String) async throws -> APIClient.WorkoutIDRow)?
    var deleteDayHandler: ((String, Int, String) async throws -> APIClient.DeleteWorkoutResult)?
    var scheduleHandler: (([String: String], String, Int, String) async throws -> APIClient.ScheduleWriteResult)?
    var calendarHandler: ((String, String?, Int?, String) async throws -> APIClient.CalendarWriteResult)?
    private(set) var updateDayCalls = 0
    private(set) var deleteDayCalls = 0
    private(set) var scheduleCalls = 0
    private(set) var calendarCalls = 0
    private(set) var restoreCalls = 0

    func getPlanHistory(limit: Int, beforeVersion: Int?, jwt: String) async throws
        -> PlanHistoryResponse
    {
        guard let historyHandler else { throw URLError(.badServerResponse) }
        return try await historyHandler(limit, beforeVersion, jwt)
    }

    func comparePlanVersion(_ version: Int, toVersion: Int, jwt: String) async throws
        -> PlanComparisonResponse
    {
        guard let comparisonHandler else { throw URLError(.badServerResponse) }
        return try await comparisonHandler(version, toVersion, jwt)
    }

    func restorePlanVersion(
        _ version: Int, expectedPlanID: String, expectedVersion: Int,
        reason: String?, jwt: String
    ) async throws -> APIClient.RestorePlanResult {
        restoreCalls += 1
        guard let restoreHandler else { throw URLError(.badServerResponse) }
        return try await restoreHandler(version, expectedPlanID, expectedVersion, reason, jwt)
    }

    func ensureActivePlan(name: String, jwt: String) async throws
        -> APIClient.EnsureActivePlanResult
    {
        guard let ensureHandler else { throw URLError(.badServerResponse) }
        return try await ensureHandler(name, jwt)
    }

    func addWorkout(
        name: String,
        expectedPlanID: String,
        expectedVersion: Int,
        jwt: String
    ) async throws
        -> APIClient.WorkoutIDRow
    {
        guard let addDayHandler else { throw URLError(.badServerResponse) }
        return try await addDayHandler(name, expectedPlanID, expectedVersion, jwt)
    }

    func updateWorkout(
        dayID: String,
        fields: [String: Any],
        expectedVersion: Int,
        jwt: String
    ) async throws -> APIClient.WorkoutIDRow {
        updateDayCalls += 1
        guard let updateDayHandler else { throw URLError(.badServerResponse) }
        return try await updateDayHandler(dayID, fields, expectedVersion, jwt)
    }

    func deleteWorkout(dayID: String, expectedVersion: Int, jwt: String) async throws
        -> APIClient.DeleteWorkoutResult
    {
        deleteDayCalls += 1
        guard let deleteDayHandler else { throw URLError(.badServerResponse) }
        return try await deleteDayHandler(dayID, expectedVersion, jwt)
    }

    func setSchedule(
        _ week: [String: String],
        expectedPlanID: String,
        expectedVersion: Int,
        jwt: String
    ) async throws -> APIClient.ScheduleWriteResult {
        scheduleCalls += 1
        guard let scheduleHandler else { throw URLError(.badServerResponse) }
        return try await scheduleHandler(week, expectedPlanID, expectedVersion, jwt)
    }

    func setCalendarDate(
        _ date: String,
        dayID: String?,
        expectedAttempt: Int?,
        jwt: String
    ) async throws -> APIClient.CalendarWriteResult {
        calendarCalls += 1
        guard let calendarHandler else { throw URLError(.badServerResponse) }
        return try await calendarHandler(date, dayID, expectedAttempt, jwt)
    }
}

private actor SetAsyncLatch {
    private var isOpen = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func wait() async {
        if isOpen { return }
        await withCheckedContinuation { waiters.append($0) }
    }

    func open() {
        guard !isOpen else { return }
        isOpen = true
        let current = waiters
        waiters.removeAll()
        current.forEach { $0.resume() }
    }
}

@MainActor
private final class RestNotificationCenterStub: RestNotificationCenterProviding {
    var status: UNAuthorizationStatus = .authorized
    var addEntered: SetAsyncLatch?
    var releaseAdd: SetAsyncLatch?
    private(set) var pendingIDs: [String] = []
    private(set) var deliveredIDs: [String] = []
    var deliverDuringPendingRemoval = false

    func authorizationStatus() async -> UNAuthorizationStatus { status }

    func requestAuthorization(
        options: UNAuthorizationOptions
    ) async throws -> Bool {
        status = .authorized
        return true
    }

    func add(_ request: UNNotificationRequest) async throws {
        await addEntered?.open()
        await releaseAdd?.wait()
        pendingIDs.append(request.identifier)
    }

    func pendingNotificationIdentifiers() async -> [String] { pendingIDs }
    func deliveredNotificationIdentifiers() async -> [String] { deliveredIDs }

    func installPendingForTests(_ identifier: String) {
        pendingIDs.append(identifier)
    }

    func removePendingNotificationRequests(withIdentifiers identifiers: [String]) {
        if deliverDuringPendingRemoval {
            deliveredIDs.append(contentsOf: pendingIDs.filter(
                Set(identifiers).contains))
        }
        pendingIDs.removeAll(where: Set(identifiers).contains)
    }

    func removeDeliveredNotifications(withIdentifiers identifiers: [String]) {
        deliveredIDs.removeAll(where: Set(identifiers).contains)
    }
}

@MainActor
final class SetOutboxTests: XCTestCase {
    private let fixedDate = Date(timeIntervalSince1970: 2_000_000_000)
    private let fixedUUID = UUID(uuidString: "11111111-1111-4111-8111-111111111111")!

    private var fixedCivilDate: String {
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = .current
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter.string(from: fixedDate)
    }

    func testAttemptProtocolHeaderIsPresentOnlyWithGenerationToken() {
        XCTAssertEqual(
            APIClient.attemptProtocolHeaders(expectedAttempt: nil),
            [:])
        XCTAssertEqual(
            APIClient.attemptProtocolHeaders(expectedAttempt: 0),
            ["X-TresFort-Write-Protocol": "attempt-v1"])
    }

    func testCancelledRestNotificationCannotBeResurrectedByInFlightAdd() async {
        let center = RestNotificationCenterStub()
        let addEntered = SetAsyncLatch()
        let releaseAdd = SetAsyncLatch()
        center.addEntered = addEntered
        center.releaseAdd = releaseAdd
        center.deliverDuringPendingRemoval = true
        let coordinator = RestNotificationCoordinator(
            center: center,
            now: { self.fixedDate },
            requestIDFactory: { "stale-request" })

        coordinator.schedule(at: fixedDate.addingTimeInterval(60))
        await addEntered.wait()
        coordinator.cancel()
        await releaseAdd.open()
        await coordinator.waitForSchedulingForTests()

        XCTAssertTrue(center.pendingIDs.isEmpty)
        XCTAssertTrue(center.deliveredIDs.isEmpty)
    }

    func testCancellationRemovesNotificationThatTransitionsToDelivered() async {
        let center = RestNotificationCenterStub()
        center.installPendingForTests("rest-cue-racing")
        center.deliverDuringPendingRemoval = true
        let coordinator = RestNotificationCoordinator(center: center)

        coordinator.cancel()
        await coordinator.waitForSchedulingForTests()

        XCTAssertTrue(center.pendingIDs.isEmpty)
        XCTAssertTrue(center.deliveredIDs.isEmpty)
    }

    private func defaults() -> LocalPersistence {
        let name = "SetOutboxTests.\(UUID().uuidString)"
        let defaults = LocalPersistence(suiteName: name)!
        defaults.removePersistentDomain(forName: name)
        addTeardownBlock { [preferences = defaults.preferences, directory = defaults.trainingStore.directory] in
            preferences.removePersistentDomain(forName: name)
            try? FileManager.default.removeItem(at: directory)
        }
        return defaults
    }

    private func jwt(subject: String, expiration: Date = .distantFuture) -> String {
        func base64URL(_ data: Data) -> String {
            data.base64EncodedString()
                .replacingOccurrences(of: "+", with: "-")
                .replacingOccurrences(of: "/", with: "_")
                .replacingOccurrences(of: "=", with: "")
        }
        let header = try! JSONSerialization.data(withJSONObject: ["alg": "HS256"])
        let payload = try! JSONSerialization.data(withJSONObject: [
            "exp": Int(expiration.timeIntervalSince1970),
            "sub": subject,
        ])
        return "\(base64URL(header)).\(base64URL(payload)).signature"
    }

    private func authResponse(jwt: String, userID: String) -> AuthResponse {
        AuthResponse(
            jwt: jwt,
            user: UserDTO(
                id: userID,
                display_name: "Test",
                email: "test@example.com"))
    }

    private func auth(
        userID: String = "user-a",
        defaults: LocalPersistence,
        api: SetAuthAPIStub? = nil,
        token: String? = nil
    ) -> AuthModel {
        defaults.set(userID, forKey: AuthModel.userIDKey)
        return AuthModel(
            api: api ?? SetAuthAPIStub(),
            tokenStore: SetMemoryTokenStore(token ?? jwt(subject: userID)),
            defaults: defaults,
            now: { self.fixedDate })
    }

    /// SyncModel intentionally holds AuthModel unowned. Tests that need only
    /// the default auth fixture retain it here for the lifetime of this test
    /// case instead of passing a temporary that deallocates after init.
    private var retainedAuthModels: [AuthModel] = []

    private func retainedAuth(defaults: LocalPersistence) -> AuthModel {
        let model = auth(defaults: defaults)
        retainedAuthModels.append(model)
        return model
    }

    private func exercise(
        id: String = "slot-a",
        exerciseID: String = "exercise-a",
        timed: Bool = false,
        bodyweight: Bool = false,
        targetSets: Int = 3,
        warmup: Bool = false,
        modality: String? = nil,
        targetWeight: Double? = nil,
        groupID: String? = nil,
        roundRest: Int = 75,
        transitionRest: Int = 10
    ) -> TemplateExercise {
        let resolvedModality = modality ?? (timed ? "timed" : (bodyweight ? "bw" : "barbell"))
        let resolvedBodyweight = bodyweight || resolvedModality == "bw"
        return TemplateExercise(
            id: id,
            exercise_id: exerciseID,
            exercise_name: timed ? "Plank" : "Squat",
            exercise_unit: "lb",
            order_index: 0,
            target_sets: targetSets,
            target_reps: timed ? 30 : 5,
            target_reps_max: nil,
            target_rpe: nil,
            rest_seconds: 90,
            target_weight: targetWeight ?? (timed || resolvedBodyweight ? 0 : 100),
            cues: nil,
            exercise_modality: resolvedModality,
            exercise_laterality: "bilateral",
            exercise_load_mode: "total",
            exercise_demo_slug: nil,
            target_duration_s: timed ? 30 : nil,
            is_warmup: warmup ? 1 : 0,
            group_id: groupID,
            group_rest_seconds: groupID == nil ? nil : roundRest,
            group_transition_seconds: groupID == nil ? nil : transitionRest)
    }

    private func day(with exercises: [TemplateExercise]) -> Workout {
        Workout(
            id: "day-a", name: "Day A", day_label: "A",
            order_index: 0, exercises: exercises)
    }

    private func prepare(
        _ model: SyncModel,
        exercise: TemplateExercise,
        session: SessionRow? = nil,
        running: Bool = false
    ) {
        model.plan = PlanTree(
            id: "plan-a", name: "Plan A", version: 1,
            workouts: [day(with: [exercise])], meta: nil)
        model.selectedDayID = "day-a"
        model.todaySession = session
        if running { model.startWorkout() }
    }

    private func session(
        id: String = "session-a",
        date: String? = nil,
        status: String = "in_progress",
        updatedAt: Int? = nil,
        attempt: Int? = nil
    ) -> SessionRow {
        SessionRow(
            id: id, date: date ?? fixedCivilDate, status: status,
            workout_id: "day-a", updated_at: updatedAt,
            attempt: attempt)
    }

    private func setLog(
        body: SetRequestBody,
        sessionID: String = "session-a",
        updatedAt: Int? = 2_000_000_000_001,
        deletedAt: Int? = nil
    ) -> SetLog {
        SetLog(
            id: body.id,
            session_id: sessionID,
            exercise_id: body.exercise_id,
            template_exercise_id: body.template_exercise_id,
            set_index: body.set_index,
            weight: body.weight,
            reps: body.reps,
            rpe: body.rpe,
            is_warmup: body.is_warmup ? 1 : 0,
            logged_at: body.logged_at,
            duration_s: body.duration_s,
            is_timed: body.is_timed ? 1 : 0,
            deleted_at: deletedAt,
            updated_at: updatedAt)
    }

    private func state(
        session: SessionRow,
        sets: [SetLog],
        exercise: TemplateExercise
    ) -> StateResponse {
        state(session: session, sets: sets, exercises: [exercise])
    }

    private func state(
        session: SessionRow,
        sets: [SetLog],
        exercises: [TemplateExercise]
    ) -> StateResponse {
        state(
            session: session,
            sets: sets,
            workouts: [day(with: exercises)])
    }

    private func state(
        session: SessionRow,
        sets: [SetLog],
        workouts: [Workout],
        serverTime: Int = 2_000_000_000_000,
        planID: String = "plan-a",
        planName: String = "Plan A",
        planVersion: Int = 1,
        planMeta: String? = nil,
        externalSyncCursorsVersion: Int? = nil
    ) -> StateResponse {
        StateResponse(
            plan: PlanTree(
                id: planID, name: planName, version: planVersion,
                workouts: workouts, meta: planMeta),
            plan_version: planVersion,
            sessions: [session],
            sets: sets,
            external_events: [],
            external_activities: [],
            activities: [],
            server_time: serverTime,
            externalSyncCursorsVersion:
                externalSyncCursorsVersion,
            planGroupsVersion: 1)
    }

    private func configureSuccess(
        _ api: SetWriteAPIStub,
        exercise: TemplateExercise,
        session: SessionRow
    ) {
        var serverSets: [SetLog] = []
        api.createHandler = { _, _, _ in session }
        api.logHandler = { [self] _, body, _ in
            let row = setLog(body: body, sessionID: session.id)
            if !serverSets.contains(where: { $0.id == row.id }) { serverSets.append(row) }
            return .init(set: row, deduped: false)
        }
        api.stateHandler = { [self] _ in
            state(session: session, sets: serverSets, exercise: exercise)
        }
    }

    func testDiskFailureDoesNotSendOrAdvanceSetAndRetrySavesSameTap() async {
        let h = LocalPersistenceTestHarness()
        addTeardownBlock { h.cleanup() }
        let defaults = h.open(), ex = exercise()
        let api = SetWriteAPIStub()
        let auth = auth(defaults: defaults)
        let model = SyncModel(auth: auth, setWriteAPI: api, defaults: defaults,
                              uuidFactory: { self.fixedUUID }, now: { self.fixedDate })
        prepare(model, exercise: ex)
        h.faults.failWrites = true
        let saved = await model.logSet(ex, weight: 135, reps: 5)
        XCTAssertFalse(saved)
        XCTAssertTrue(api.createCalls.isEmpty)
        XCTAssertTrue(api.logCalls.isEmpty)
        XCTAssertTrue(model.setOutbox.isEmpty)
        XCTAssertTrue(model.sets.isEmpty)
        XCTAssertNil(auth.featureJWT)
        XCTAssertNotNil(model.loadError)
        h.faults.failWrites = false
        XCTAssertTrue(defaults.retry(userID: "user-a"))
        configureSuccess(api, exercise: ex, session: session())
        let acknowledged = await model.logSet(ex, weight: 135, reps: 5)
        XCTAssertTrue(acknowledged)
        XCTAssertEqual(api.logCalls.count, 1)
        XCTAssertEqual(api.logCalls.first?.body.id, fixedUUID.uuidString)
    }

    func testFailedFinishAndDiscardDoNotSendOrEraseQueuedSets() async throws {
        for discard in [false, true] {
            let h = LocalPersistenceTestHarness()
            addTeardownBlock { h.cleanup() }
            let defaults = h.open(), ex = exercise(), s = session()
            let api = SetWriteAPIStub(), terminal = SetTerminalAPIStub()
            let auth = auth(defaults: defaults)
            let model = SyncModel(auth: auth, setWriteAPI: api, terminalAPI: terminal,
                                  defaults: defaults, now: { self.fixedDate })
            prepare(model, exercise: ex, session: s)
            _ = await model.logSet(ex, weight: 135, reps: 5)
            let savedQueue = try XCTUnwrap(defaults.data(forKey: SetOutboxStore.scopedKey(userID: "user-a")))
            h.faults.failWrites = true
            if discard { await model.discardWorkout() } else { await model.finishWorkout() }
            XCTAssertTrue(terminal.completeCalls.isEmpty)
            XCTAssertTrue(terminal.discardCalls.isEmpty)
            XCTAssertTrue(model.terminalOutbox.isEmpty)
            XCTAssertEqual(model.todaySession?.id, s.id)
            XCTAssertEqual(try h.store.data(forKey: SetOutboxStore.scopedKey(userID: "user-a")), savedQueue)
            XCTAssertNotNil(model.loadError)
        }
    }

    func testFailedFeedbackSaveKeepsRunnerAndPriorCheckpointForRetry() throws {
        let h = LocalPersistenceTestHarness()
        addTeardownBlock { h.cleanup() }
        let defaults = h.open(), ex = exercise(), s = session()
        let auth = auth(defaults: defaults)
        let model = SyncModel(auth: auth, defaults: defaults, now: { self.fixedDate })
        prepare(model, exercise: ex, session: s, running: true)
        let target = try XCTUnwrap(model.terminalActionTarget)
        let original = WorkoutFeedback(notes: "Saved feedback", perceivedFatigue: 5)
        let replacement = WorkoutFeedback(notes: "New feedback", perceivedFatigue: 6)
        XCTAssertTrue(model.saveWorkoutFeedback(original, expected: target, previous: nil))
        let previous = try XCTUnwrap(model.currentWorkoutFeedback)
        let checkpoint = WorkoutRunnerCheckpointStore.load(userID: "user-a", defaults: defaults)
        h.faults.failWrites = true
        XCTAssertFalse(model.saveWorkoutFeedback(replacement, expected: target, previous: previous))
        XCTAssertTrue(model.running)
        XCTAssertEqual(model.currentWorkoutFeedback, previous)
        XCTAssertEqual(WorkoutRunnerCheckpointStore.load(userID: "user-a", defaults: defaults), checkpoint)
        h.faults.failWrites = false
        XCTAssertTrue(defaults.retry(userID: "user-a"))
        XCTAssertTrue(model.saveWorkoutFeedback(replacement, expected: target, previous: previous))
        XCTAssertEqual(WorkoutRunnerCheckpointStore.load(userID: "user-a", defaults: defaults)?.feedback?.notes, replacement.notes)
    }

    func testFailedRunnerChangesRollBackBeforeStorageRetryAndModelReplacement() async throws {
        for action in ["skip", "finish", "next", "weight", "reps", "rpe", "duration"] {
            let h = LocalPersistenceTestHarness()
            addTeardownBlock { h.cleanup() }
            let defaults = h.open(), ex = exercise(timed: action == "duration"), s = session()
            let second = exercise(id: "slot-b", exerciseID: "exercise-b")
            let slots = action == "finish" ? [ex] : [ex, second]
            let auth = auth(defaults: defaults), api = SetWriteAPIStub()
            api.stateHandler = { [self] _ in state(session: s, sets: [], exercises: slots) }
            let model = SyncModel(auth: auth, setWriteAPI: api, defaults: defaults, now: { self.fixedDate })
            model.plan = PlanTree(id: "plan-a", name: "Plan A", version: 1,
                                  workouts: [day(with: slots)], meta: nil)
            model.selectedDayID = "day-a"
            model.todaySession = s
            model.startWorkout()
            let checkpoint = try XCTUnwrap(WorkoutRunnerCheckpointStore.load(userID: "user-a", defaults: defaults))
            let input = model.currentInputState
            h.faults.failWrites = true
            switch action {
            case "skip", "finish": model.skip()
            case "next": model.next()
            case "weight": model.setWeight(200)
            case "reps": model.setReps(12)
            case "rpe": model.setRPE(8)
            default: model.setHoldDuration(60)
            }
            XCTAssertTrue(defaults.hasFailure(userID: "user-a"), action)
            XCTAssertTrue(model.running, action)
            XCTAssertFalse(model.finished, action)
            XCTAssertFalse(model.isSkipped(ex), action)
            XCTAssertEqual(model.currentExercise?.id, ex.id, action)
            XCTAssertEqual(model.currentInputState, input, action)
            XCTAssertNotNil(model.loadError, action)
            XCTAssertEqual(WorkoutRunnerCheckpointStore.load(userID: "user-a", defaults: defaults), checkpoint, action)
            // A second tap while saving is blocked must not become another
            // in-memory-only change that disappears when the view remounts.
            model.next()
            XCTAssertEqual(model.currentExercise?.id, ex.id, action)
            h.faults.failWrites = false
            XCTAssertTrue(defaults.retry(userID: "user-a"), action)
            let replacement = SyncModel(auth: auth, setWriteAPI: api, catalogAPI: SetCatalogAPIStub(),
                                        defaults: defaults, now: { self.fixedDate })
            await replacement.load()
            replacement.resumeWorkout()
            XCTAssertTrue(replacement.running, action)
            XCTAssertFalse(replacement.finished, action)
            XCTAssertFalse(replacement.isSkipped(ex), action)
            XCTAssertEqual(replacement.currentExercise?.id, ex.id, action)
            XCTAssertEqual(replacement.currentInputState, input, action)
            XCTAssertTrue(api.createCalls.isEmpty, action)
            XCTAssertTrue(api.logCalls.isEmpty, action)
        }
    }

    func testPersistsImmutableBodyBeforeFirstSessionCreateAwait() async {
        let defaults = defaults()
        let ex = exercise()
        let api = SetWriteAPIStub()
        let model = SyncModel(
            auth: retainedAuth(defaults: defaults), setWriteAPI: api,
            defaults: defaults, uuidFactory: { self.fixedUUID },
            now: { self.fixedDate })
        prepare(model, exercise: ex)
        api.createHandler = { _, _, _ in
            let stored = SetOutboxStore.load(userID: "user-a", defaults: defaults)
            XCTAssertEqual(stored.count, 1)
            XCTAssertEqual(stored.pending[0].body.id, self.fixedUUID.uuidString)
            XCTAssertEqual(stored.pending[0].body.logged_at, 2_000_000_000_000)
            XCTAssertNil(stored.pending[0].resolvedSessionID)
            throw URLError(.notConnectedToInternet)
        }

        let acknowledged = await model.logSet(ex, weight: 135, reps: 5)

        XCTAssertFalse(acknowledged)
        XCTAssertEqual(api.createCalls.count, 1)
        XCTAssertEqual(model.setOutbox.count, 1)
        XCTAssertTrue(model.sets.isEmpty)
    }

    func testAcknowledgementRemovesIntentAndStartsRestOnlyAfterSuccess() async {
        let defaults = defaults()
        let ex = exercise()
        let s = session()
        let api = SetWriteAPIStub()
        configureSuccess(api, exercise: ex, session: s)
        api.logHandler = { [self] sessionID, body, _ in
            let stored = SetOutboxStore.load(
                userID: "user-a", defaults: defaults).pending.first?.body
            XCTAssertEqual(
                stored?.scoped(to: body.expected_attempt), body)
            XCTAssertNil(stored?.expected_attempt)
            return .init(set: setLog(body: body, sessionID: sessionID), deduped: false)
        }
        api.stateHandler = { [self] _ in
            let body = api.logCalls[0].body
            return state(session: s, sets: [setLog(body: body)], exercise: ex)
        }
        let model = SyncModel(
            auth: retainedAuth(defaults: defaults), setWriteAPI: api,
            defaults: defaults, uuidFactory: { self.fixedUUID },
            now: { self.fixedDate })
        prepare(model, exercise: ex, session: s, running: true)

        let acknowledged = await model.logSet(ex, weight: 135, reps: 5)

        XCTAssertTrue(acknowledged)
        XCTAssertTrue(model.setOutbox.isEmpty)
        XCTAssertEqual(model.sets.map(\.id), [fixedUUID.uuidString])
        XCTAssertNotNil(model.restEndDate)
    }

    func testAcknowledgedSetReconcilesWithPersistedDeltaWatermarks() async {
        let defaults = defaults()
        let ex = exercise()
        let baselineTime = 2_000_000_000_000
        let s = session(updatedAt: baselineTime - 1, attempt: 0)
        let api = SetWriteAPIStub()
        api.logHandler = { [self] sessionID, body, _ in
            .init(
                set: setLog(
                    body: body,
                    sessionID: sessionID,
                    updatedAt: baselineTime + 1),
                deduped: false)
        }
        api.stateWatermarkHandler = { [self] _, _ in
            let body = api.logCalls[0].body
            return StateResponse(
                plan: nil,
                plan_version: 1,
                sessions: [s],
                sets: [setLog(
                    body: body,
                    sessionID: s.id,
                    updatedAt: baselineTime + 1)],
                external_events: [],
                external_activities: [],
                activities: [],
                server_time: baselineTime + 100_000)
        }
        let model = SyncModel(
            auth: retainedAuth(defaults: defaults), setWriteAPI: api,
            defaults: defaults, uuidFactory: { self.fixedUUID },
            now: { self.fixedDate })
        model.replaceState(with: state(
            session: s,
            sets: [],
            workouts: [day(with: [ex])],
            serverTime: baselineTime))
        model.startWorkout()

        let acknowledged = await model.logSet(ex, weight: 135, reps: 5)

        XCTAssertTrue(acknowledged)
        XCTAssertEqual(api.stateWatermarkCalls, [StateSyncWatermarks(
            planVersion: 1,
            setsSince: baselineTime - 60_000,
            eventsSince: 0,
            activitiesSince: 0,
            logSince: baselineTime - 60_000)])
        XCTAssertEqual(model.sets.map(\.id), [fixedUUID.uuidString])
        XCTAssertNotNil(model.restEndDate)
        XCTAssertEqual(
            StateSnapshotStore.load(
                userID: "user-a", defaults: defaults)?.watermarks,
            StateSyncWatermarks(
                planVersion: 1,
                setsSince: baselineTime + 40_000,
                eventsSince: 0,
                activitiesSince: 0,
                logSince: baselineTime + 40_000))
    }

    func testMissingAcknowledgedIDPreservesAuthoritativeACKAndForcesFullReload() async {
        let defaults = defaults()
        let ex = exercise()
        let baselineTime = 2_000_000_000_000
        let s = session(updatedAt: baselineTime - 1, attempt: 0)
        let api = SetWriteAPIStub()
        api.logHandler = { [self] sessionID, body, _ in
            .init(
                set: setLog(
                    body: body,
                    sessionID: sessionID,
                    updatedAt: baselineTime + 1),
                deduped: false)
        }
        api.stateWatermarkHandler = { _, _ in
            StateResponse(
                plan: nil,
                plan_version: 1,
                sessions: [],
                sets: [],
                external_events: [],
                external_activities: [],
                activities: [],
                server_time: baselineTime + 100_000)
        }
        let model = SyncModel(
            auth: retainedAuth(defaults: defaults), setWriteAPI: api,
            defaults: defaults, uuidFactory: { self.fixedUUID },
            now: { self.fixedDate })
        model.replaceState(with: state(
            session: s,
            sets: [],
            workouts: [day(with: [ex])],
            serverTime: baselineTime))
        model.startWorkout()

        let acknowledged = await model.logSet(ex, weight: 135, reps: 5)

        XCTAssertTrue(acknowledged)
        XCTAssertTrue(model.setOutbox.isEmpty)
        XCTAssertTrue(model.sets.contains { $0.id == fixedUUID.uuidString })
        XCTAssertNotNil(model.restEndDate)
        XCTAssertTrue(model.loadError?.contains(
            "Set was saved") == true)
        let snapshot = StateSnapshotStore.load(
            userID: "user-a", defaults: defaults)
        XCTAssertEqual(
            snapshot?.state.sets.map(\.id), [fixedUUID.uuidString])
        XCTAssertNil(snapshot?.watermarks)
        XCTAssertEqual(
            StateSnapshotStore.reserveStateRequest(
                userID: "user-a", defaults: defaults)?.watermarks,
            .fullReload)
    }

    func testBatchReconciliationOmissionPreservesEveryAuthoritativeACK() async {
        let defaults = defaults()
        let baselineTime = 2_000_000_000_000
        let s = session(updatedAt: baselineTime - 1, attempt: 0)
        let exA = exercise(id: "slot-a", exerciseID: "exercise-a")
        let exB = exercise(id: "slot-b", exerciseID: "exercise-b")
        let bodies = [
            SetRequestBody(
                id: "11111111-1111-4111-8111-111111111111",
                exercise_id: exA.exercise_id,
                template_exercise_id: exA.id,
                set_index: 1,
                weight: 135,
                reps: 5,
                is_warmup: false,
                logged_at: baselineTime + 1,
                duration_s: nil,
                is_timed: false),
            SetRequestBody(
                id: "22222222-2222-4222-8222-222222222222",
                exercise_id: exB.exercise_id,
                template_exercise_id: exB.id,
                set_index: 1,
                weight: 95,
                reps: 8,
                is_warmup: false,
                logged_at: baselineTime + 2,
                duration_s: nil,
                is_timed: false),
        ]
        StateSnapshotStore.save(
            state(
                session: s,
                sets: [],
                exercises: [exA, exB]),
            userID: "user-a",
            defaults: defaults)
        var outbox = SetOutbox()
        for body in bodies {
            outbox.enqueue(.init(
                body: body,
                date: s.date,
                workoutID: "day-a",
                resolvedSessionID: s.id,
                deliveryState: .queued,
                failedHTTPStatus: nil,
                expectedAttempt: 0))
        }
        SetOutboxStore.save(
            outbox, userID: "user-a", defaults: defaults)
        let api = SetWriteAPIStub()
        api.logHandler = { [self] sessionID, body, _ in
            .init(
                set: setLog(
                    body: body,
                    sessionID: sessionID,
                    updatedAt: baselineTime + 10),
                deduped: false,
                session: s)
        }
        api.stateWatermarkHandler = { [self] _, _ in
            StateResponse(
                plan: nil,
                plan_version: 1,
                sessions: [],
                sets: [setLog(
                    body: bodies[0],
                    sessionID: s.id,
                    updatedAt: baselineTime + 10)],
                external_events: [],
                external_activities: [],
                activities: [],
                server_time: baselineTime + 100_000)
        }
        let model = SyncModel(
            auth: retainedAuth(defaults: defaults),
            setWriteAPI: api,
            defaults: defaults,
            now: { self.fixedDate })

        await model.drainSetOutbox()

        XCTAssertEqual(api.logCalls.map(\.body.id), bodies.map(\.id))
        XCTAssertTrue(model.setOutbox.isEmpty)
        XCTAssertEqual(Set(model.sets.map(\.id)), Set(bodies.map(\.id)))
        XCTAssertTrue(model.loadError?.contains("Sets were saved") == true)
        let snapshot = StateSnapshotStore.load(
            userID: "user-a", defaults: defaults)
        XCTAssertEqual(
            Set(snapshot?.state.sets.map(\.id) ?? []),
            Set(bodies.map(\.id)))
        XCTAssertNil(snapshot?.watermarks)
        XCTAssertEqual(
            StateSnapshotStore.reserveStateRequest(
                userID: "user-a", defaults: defaults)?.watermarks,
            .fullReload)
    }

    func testDedupedPersistedSetMayBeAbsentFromValidIncrementalDelta() async {
        let defaults = defaults()
        let baselineTime = 2_000_000_000_000
        let ex = exercise()
        let s = session(updatedAt: baselineTime - 1, attempt: 0)
        let body = SetRequestBody(
            id: fixedUUID.uuidString,
            exercise_id: ex.exercise_id,
            template_exercise_id: ex.id,
            set_index: 1,
            weight: 135,
            reps: 5,
            is_warmup: false,
            logged_at: baselineTime - 1_000,
            duration_s: nil,
            is_timed: false)
        let existing = setLog(
            body: body,
            sessionID: s.id,
            updatedAt: baselineTime - 500)
        XCTAssertTrue(StateSyncAccountStore.activate(
            userID: "user-a", defaults: defaults))
        StateSnapshotStore.save(
            state(
                session: s,
                sets: [existing],
                exercise: ex),
            userID: "user-a",
            defaults: defaults)
        var outbox = SetOutbox()
        outbox.enqueue(.init(
            body: body,
            date: s.date,
            workoutID: "day-a",
            resolvedSessionID: s.id,
            deliveryState: .queued,
            failedHTTPStatus: nil,
            expectedAttempt: 0))
        SetOutboxStore.save(
            outbox, userID: "user-a", defaults: defaults)
        let api = SetWriteAPIStub()
        api.logHandler = { _, _, _ in
            .init(set: existing, deduped: true, session: s)
        }
        api.stateWatermarkHandler = { _, watermarks in
            XCTAssertGreaterThan(watermarks.setsSince, 0)
            return StateResponse(
                plan: nil,
                plan_version: 1,
                sessions: [],
                sets: [],
                external_events: [],
                external_activities: [],
                activities: [],
                server_time: baselineTime + 100_000)
        }
        let model = SyncModel(
            auth: retainedAuth(defaults: defaults),
            setWriteAPI: api,
            defaults: defaults,
            now: { self.fixedDate })

        await model.drainSetOutbox()

        XCTAssertTrue(model.setOutbox.isEmpty)
        XCTAssertEqual(model.sets.map(\.id), [body.id])
        XCTAssertNil(model.loadError)
        let snapshot = StateSnapshotStore.load(
            userID: "user-a", defaults: defaults)
        XCTAssertEqual(snapshot?.state.sets.map(\.id), [body.id])
        XCTAssertEqual(
            snapshot?.watermarks?.setsSince,
            baselineTime + 40_000)
    }

    func testNewerDedupedCorrectionMissingFromDeltaPreservesACKAndForcesFullReload() async {
        let defaults = defaults()
        let baselineTime = 2_000_000_000_000
        let ex = exercise()
        let s = session(updatedAt: baselineTime - 1, attempt: 0)
        let body = SetRequestBody(
            id: fixedUUID.uuidString,
            exercise_id: ex.exercise_id,
            template_exercise_id: ex.id,
            set_index: 1,
            weight: 135,
            reps: 5,
            is_warmup: false,
            logged_at: baselineTime - 1_000,
            duration_s: nil,
            is_timed: false)
        let existing = setLog(
            body: body,
            sessionID: s.id,
            updatedAt: baselineTime - 500)
        let corrected = SetLog(
            id: existing.id,
            session_id: existing.session_id,
            exercise_id: existing.exercise_id,
            template_exercise_id: nil,
            set_index: existing.set_index,
            weight: 155,
            reps: 4,
            rpe: 8,
            is_warmup: existing.is_warmup,
            logged_at: existing.logged_at,
            duration_s: existing.duration_s,
            is_timed: existing.is_timed,
            deleted_at: nil,
            updated_at: baselineTime + 10)
        XCTAssertTrue(StateSyncAccountStore.activate(
            userID: "user-a", defaults: defaults))
        StateSnapshotStore.save(
            state(
                session: s,
                sets: [existing],
                exercise: ex),
            userID: "user-a",
            defaults: defaults)
        var outbox = SetOutbox()
        outbox.enqueue(.init(
            body: body,
            date: s.date,
            workoutID: "day-a",
            resolvedSessionID: s.id,
            deliveryState: .queued,
            failedHTTPStatus: nil,
            expectedAttempt: 0))
        SetOutboxStore.save(
            outbox, userID: "user-a", defaults: defaults)
        let api = SetWriteAPIStub()
        api.logHandler = { _, _, _ in
            .init(set: corrected, deduped: true, session: s)
        }
        api.stateWatermarkHandler = { _, watermarks in
            XCTAssertGreaterThan(watermarks.setsSince, 0)
            return StateResponse(
                plan: nil,
                plan_version: 1,
                sessions: [],
                sets: [],
                external_events: [],
                external_activities: [],
                activities: [],
                server_time: baselineTime + 100_000)
        }
        let model = SyncModel(
            auth: retainedAuth(defaults: defaults),
            setWriteAPI: api,
            defaults: defaults,
            now: { self.fixedDate })

        await model.drainSetOutbox()

        XCTAssertTrue(model.setOutbox.isEmpty)
        let live = model.sets.first { $0.id == body.id }
        XCTAssertEqual(live?.weight, 155)
        XCTAssertNil(live?.template_exercise_id)
        XCTAssertTrue(model.loadError?.contains("Set was saved") == true)
        let snapshot = StateSnapshotStore.load(
            userID: "user-a", defaults: defaults)
        XCTAssertEqual(
            snapshot?.state.sets.first { $0.id == body.id }?.weight,
            155)
        XCTAssertNil(snapshot?.watermarks)
        XCTAssertEqual(
            StateSnapshotStore.reserveStateRequest(
                userID: "user-a", defaults: defaults)?.watermarks,
            .fullReload)
    }

    func testDelayedLiveAcknowledgementAfterNewerTombstoneNeverResurrects() async {
        let defaults = defaults()
        let ex = exercise()
        let baselineTime = 2_000_000_000_000
        let s = session(updatedAt: baselineTime - 1, attempt: 0)
        let acknowledgementEntered = SetAsyncLatch()
        let releaseAcknowledgement = SetAsyncLatch()
        let api = SetWriteAPIStub()
        api.logHandler = { [self] sessionID, body, _ in
            await acknowledgementEntered.open()
            await releaseAcknowledgement.wait()
            return .init(
                set: setLog(
                    body: body,
                    sessionID: sessionID,
                    updatedAt: baselineTime + 10_000),
                deduped: true)
        }
        api.stateWatermarkHandler = { [self] _, _ in
            let body = api.logCalls[0].body
            let rows: [SetLog] = api.stateCalls == 1
                ? [setLog(
                    body: body,
                    sessionID: s.id,
                    updatedAt: baselineTime + 20_000,
                    deletedAt: baselineTime + 20_000)]
                : []
            return StateResponse(
                plan: nil,
                plan_version: 1,
                sessions: [],
                sets: rows,
                external_events: [],
                external_activities: [],
                activities: [],
                server_time: baselineTime + (api.stateCalls == 1 ? 100_000 : 200_000))
        }
        let model = SyncModel(
            auth: retainedAuth(defaults: defaults), setWriteAPI: api,
            defaults: defaults, uuidFactory: { self.fixedUUID },
            now: { self.fixedDate })
        model.replaceState(with: state(
            session: s,
            sets: [],
            workouts: [day(with: [ex])],
            serverTime: baselineTime))
        model.startWorkout()

        let write = Task { await model.logSet(ex, weight: 135, reps: 5) }
        await acknowledgementEntered.wait()
        let body = api.logCalls[0].body
        let tombstone = setLog(
            body: body,
            sessionID: s.id,
            updatedAt: baselineTime + 20_000,
            deletedAt: baselineTime + 20_000)
        let deltaTicket = try! XCTUnwrap(StateSnapshotStore.reserveStateRequest(
            userID: "user-a", defaults: defaults))
        XCTAssertNotNil(StateSnapshotStore.commitStateResponse(
            StateResponse(
                plan: nil,
                plan_version: 1,
                sessions: [],
                sets: [tombstone],
                external_events: [],
                external_activities: [],
                activities: [],
                server_time: baselineTime + 15_000),
            ticket: deltaTicket,
            defaults: defaults))
        await releaseAcknowledgement.open()

        let acknowledged = await write.value
        XCTAssertFalse(acknowledged)
        XCTAssertTrue(model.setOutbox.isEmpty)
        XCTAssertFalse(model.sets.contains { $0.id == fixedUUID.uuidString })
        XCTAssertNil(model.restEndDate)
        var snapshot = try! XCTUnwrap(StateSnapshotStore.load(
            userID: "user-a", defaults: defaults))
        XCTAssertEqual(
            snapshot.state.sets.first { $0.id == fixedUUID.uuidString }?.updated_at,
            baselineTime + 20_000)
        XCTAssertNotNil(
            snapshot.state.sets.first { $0.id == fixedUUID.uuidString }?.deleted_at)

        await model.load()

        snapshot = try! XCTUnwrap(StateSnapshotStore.load(
            userID: "user-a", defaults: defaults))
        XCTAssertNotNil(
            snapshot.state.sets.first { $0.id == fixedUUID.uuidString }?.deleted_at)
        XCTAssertFalse(model.sets.contains { $0.id == fixedUUID.uuidString })
    }

    func testEqualTimestampDelayedACKPreservesCorrectedDetachedDelta() async {
        let defaults = defaults()
        let ex = exercise()
        let baselineTime = 2_000_000_000_000
        let mutationTime = baselineTime + 10_000
        let s = session(updatedAt: mutationTime, attempt: 0)
        let remappedSession = SessionRow(
            id: s.id,
            date: s.date,
            status: s.status,
            workout_id: "day-remapped",
            updated_at: mutationTime,
            attempt: s.attempt)
        let acknowledgementEntered = SetAsyncLatch()
        let releaseAcknowledgement = SetAsyncLatch()
        let api = SetWriteAPIStub()
        api.logHandler = { [self] sessionID, body, _ in
            await acknowledgementEntered.open()
            await releaseAcknowledgement.wait()
            return .init(
                set: setLog(
                    body: body,
                    sessionID: sessionID,
                    updatedAt: mutationTime),
                deduped: true,
                session: s)
        }
        var corrected: SetLog?
        api.stateWatermarkHandler = { _, _ in
            StateResponse(
                plan: nil,
                plan_version: 1,
                sessions: [remappedSession],
                sets: corrected.map { [$0] } ?? [],
                external_events: [],
                external_activities: [],
                activities: [],
                server_time: baselineTime + 100_000)
        }
        let model = SyncModel(
            auth: retainedAuth(defaults: defaults), setWriteAPI: api,
            defaults: defaults, uuidFactory: { self.fixedUUID },
            now: { self.fixedDate })
        model.replaceState(with: state(
            session: s,
            sets: [],
            workouts: [day(with: [ex])],
            serverTime: baselineTime))

        let write = Task { await model.logSet(ex, weight: 135, reps: 5) }
        await acknowledgementEntered.wait()
        let body = api.logCalls[0].body
        corrected = SetLog(
            id: body.id,
            session_id: s.id,
            exercise_id: body.exercise_id,
            template_exercise_id: nil,
            set_index: body.set_index,
            weight: 225,
            reps: 3,
            rpe: 8,
            is_warmup: 0,
            logged_at: body.logged_at,
            duration_s: nil,
            is_timed: 0,
            deleted_at: nil,
            updated_at: mutationTime)
        let deltaTicket = try! XCTUnwrap(StateSnapshotStore.reserveStateRequest(
            userID: "user-a", defaults: defaults))
        XCTAssertNotNil(StateSnapshotStore.commitStateResponse(
            StateResponse(
                plan: nil,
                plan_version: 1,
                sessions: [remappedSession],
                sets: [corrected!],
                external_events: [],
                external_activities: [],
                activities: [],
                server_time: baselineTime + 5_000),
            ticket: deltaTicket,
            defaults: defaults))
        await releaseAcknowledgement.open()

        let acknowledged = await write.value
        XCTAssertTrue(acknowledged)
        let live = model.sets.first { $0.id == fixedUUID.uuidString }
        XCTAssertEqual(live?.weight, 225)
        XCTAssertEqual(live?.reps, 3)
        XCTAssertEqual(live?.template_exercise_id, nil)
        XCTAssertEqual(live?.updated_at, mutationTime)
        XCTAssertEqual(model.todaySession?.workout_id, "day-remapped")
        let persisted = StateSnapshotStore.load(
            userID: "user-a", defaults: defaults)?.state.sets.first {
                $0.id == self.fixedUUID.uuidString
            }
        XCTAssertEqual(persisted?.weight, 225)
        XCTAssertEqual(persisted?.template_exercise_id, nil)
        XCTAssertEqual(
            StateSnapshotStore.load(
                userID: "user-a", defaults: defaults)?.state.sessions.first?
                .workout_id,
            "day-remapped")
    }

    func testTimeoutQueuesWithoutCompletionOrRest() async {
        let defaults = defaults()
        let ex = exercise()
        let s = session()
        let api = SetWriteAPIStub()
        api.logHandler = { _, _, _ in throw URLError(.timedOut) }
        let model = SyncModel(
            auth: retainedAuth(defaults: defaults), setWriteAPI: api,
            defaults: defaults, uuidFactory: { self.fixedUUID },
            now: { self.fixedDate })
        prepare(model, exercise: ex, session: s, running: true)

        let acknowledged = await model.logSet(ex, weight: 135, reps: 5)

        XCTAssertFalse(acknowledged)
        XCTAssertEqual(model.queuedSetIntentCount, 1)
        XCTAssertEqual(model.setsDone(ex), 0)
        XCTAssertNil(model.restEndDate)
    }

    func testRunnerAdvancesAfterDurableEnqueueWithoutWaitingForServer() async {
        let defaults = defaults()
        let ex = exercise(targetSets: 1)
        let s = session(status: "in_progress")
        let api = SetWriteAPIStub()
        let entered = SetAsyncLatch()
        let release = SetAsyncLatch()
        api.logHandler = { [self] sessionID, body, _ in
            await entered.open()
            await release.wait()
            return .init(
                set: setLog(body: body, sessionID: sessionID),
                deduped: false,
                session: session(
                    id: sessionID, status: "in_progress", attempt: 0))
        }
        api.stateHandler = { [self] _ in
            let body = api.logCalls[0].body
            return state(
                session: s,
                sets: [setLog(body: body, sessionID: s.id)],
                exercise: ex)
        }
        let model = SyncModel(
            auth: retainedAuth(defaults: defaults), setWriteAPI: api,
            defaults: defaults, uuidFactory: { self.fixedUUID },
            now: { self.fixedDate })
        prepare(model, exercise: ex, session: s, running: true)

        await model.logCurrentSet(
            expected: ex, expectedSetNumber: 1)

        XCTAssertTrue(model.finished)
        XCTAssertNotNil(model.restEndDate)
        XCTAssertEqual(model.upNextName, "Done")
        XCTAssertEqual(model.runnerSetsDone(ex), 1)
        XCTAssertEqual(model.setOutbox.count, 1)
        XCTAssertEqual(
            SetOutboxStore.load(
                userID: "user-a", defaults: defaults).pending.first?.id,
            fixedUUID.uuidString)

        await entered.wait()
        XCTAssertEqual(model.setOutbox.count, 1)
        await release.open()
        await model.drainSetOutbox()

        XCTAssertTrue(model.setOutbox.isEmpty)
        XCTAssertEqual(model.sets.map(\.id), [fixedUUID.uuidString])
        XCTAssertTrue(model.finished)
    }

    func testRestActivityNamesCurrentExerciseAfterThreeSlotAdvance() async {
        let defaults = defaults()
        let first = exercise(targetSets: 1)
        let second = exercise(
            id: "slot-b", exerciseID: "exercise-b", timed: true,
            targetSets: 1)
        let third = exercise(
            id: "slot-c", exerciseID: "exercise-c", targetSets: 1)
        let s = session(status: "in_progress")
        let api = SetWriteAPIStub()
        api.logHandler = { _, _, _ in throw URLError(.notConnectedToInternet) }
        var updatedUpNext: String?
        let model = SyncModel(
            auth: retainedAuth(defaults: defaults), setWriteAPI: api,
            defaults: defaults, uuidFactory: { self.fixedUUID },
            now: { self.fixedDate },
            restActivityUpdater: { _, upNext in updatedUpNext = upNext })
        model.replaceState(with: state(
            session: s, sets: [], exercises: [first, second, third]))
        model.startWorkout()

        await model.logCurrentSet(
            expected: first, expectedSetNumber: 1)

        XCTAssertEqual(model.currentExercise?.id, second.id)
        XCTAssertEqual(model.upNextName, third.exercise_name)
        XCTAssertEqual(model.restActivityCurrentStepName,
                       second.exercise_name)
        XCTAssertEqual(updatedUpNext, second.exercise_name)
    }

    func testRestActivityKeepsCurrentExerciseBetweenSets() async {
        let defaults = defaults()
        let first = exercise(targetSets: 2)
        let second = exercise(
            id: "slot-b", exerciseID: "exercise-b", timed: true,
            targetSets: 1)
        let s = session(status: "in_progress")
        let api = SetWriteAPIStub()
        api.logHandler = { _, _, _ in throw URLError(.notConnectedToInternet) }
        var updatedUpNext: String?
        let model = SyncModel(
            auth: retainedAuth(defaults: defaults), setWriteAPI: api,
            defaults: defaults, uuidFactory: { self.fixedUUID },
            now: { self.fixedDate },
            restActivityUpdater: { _, upNext in updatedUpNext = upNext })
        model.replaceState(with: state(
            session: s, sets: [], exercises: [first, second]))
        model.startWorkout()

        await model.logCurrentSet(
            expected: first, expectedSetNumber: 1)

        XCTAssertEqual(model.currentExercise?.id, first.id)
        XCTAssertEqual(model.upNextName, second.exercise_name)
        XCTAssertEqual(model.restActivityCurrentStepName,
                       first.exercise_name)
        XCTAssertEqual(updatedUpNext, first.exercise_name)
    }

    func testRunnerRejectsImmediateDuplicateButAllowsNextSetWhileFirstSends() async {
        let defaults = defaults()
        let ex = exercise(targetSets: 2)
        let s = session(status: "in_progress")
        let api = SetWriteAPIStub()
        let firstEntered = SetAsyncLatch()
        let releaseFirst = SetAsyncLatch()
        let firstID = fixedUUID
        let secondID = UUID(uuidString: "22222222-2222-4222-8222-222222222222")!
        var generatedIDs = [firstID, secondID].makeIterator()
        api.logHandler = { [self] sessionID, body, _ in
            if body.id == firstID.uuidString {
                await firstEntered.open()
                await releaseFirst.wait()
            }
            return .init(
                set: setLog(body: body, sessionID: sessionID),
                deduped: false,
                session: session(
                    id: sessionID, status: "in_progress", attempt: 0))
        }
        api.stateHandler = { [self] _ in
            state(
                session: s,
                sets: api.logCalls.map {
                    setLog(body: $0.body, sessionID: $0.sessionID)
                },
                exercise: ex)
        }
        let model = SyncModel(
            auth: retainedAuth(defaults: defaults), setWriteAPI: api,
            defaults: defaults,
            uuidFactory: { generatedIDs.next()! },
            now: { self.fixedDate })
        prepare(model, exercise: ex, session: s, running: true)

        let firstTap = Task {
            await model.logCurrentSet(
                expected: ex, expectedSetNumber: 1)
        }
        let duplicateTap = Task {
            await model.logCurrentSet(
                expected: ex, expectedSetNumber: 1)
        }
        await firstTap.value
        await duplicateTap.value
        await firstEntered.wait()

        XCTAssertEqual(model.setOutbox.count, 1)
        XCTAssertEqual(model.runnerSetsDone(ex), 1)
        XCTAssertFalse(model.finished)

        await Task.yield()
        XCTAssertFalse(model.isSetEntryBlocked(ex))
        await model.logCurrentSet(
            expected: ex, expectedSetNumber: 2)

        XCTAssertEqual(model.setOutbox.count, 2)
        XCTAssertEqual(model.runnerSetsDone(ex), 2)
        XCTAssertTrue(model.finished)
        XCTAssertEqual(api.logCalls.count, 1)

        await releaseFirst.open()
        await model.drainSetOutbox()

        XCTAssertEqual(api.logCalls.map(\.body.id), [
            firstID.uuidString, secondID.uuidString,
        ])
        XCTAssertTrue(model.setOutbox.isEmpty)
        XCTAssertEqual(model.sets.count, 2)
        XCTAssertTrue(model.finished)
    }

    func testQueuedDuplicateCannotCrossIntoSuccessorExercise() async {
        let defaults = defaults()
        let first = exercise(targetSets: 1)
        let second = exercise(
            id: "slot-b", exerciseID: "exercise-b", targetSets: 1)
        let s = session(status: "in_progress")
        let api = SetWriteAPIStub()
        let entered = SetAsyncLatch()
        let release = SetAsyncLatch()
        let secondID = UUID(
            uuidString: "22222222-2222-4222-8222-222222222222")!
        var generatedIDs = [fixedUUID, secondID].makeIterator()
        var generatedIDCount = 0
        api.logHandler = { [self] sessionID, body, _ in
            await entered.open()
            await release.wait()
            return .init(
                set: setLog(body: body, sessionID: sessionID),
                deduped: false,
                session: session(
                    id: sessionID, status: "in_progress", attempt: 0))
        }
        api.stateHandler = { [self] _ in
            state(
                session: s,
                sets: api.logCalls.map {
                    setLog(body: $0.body, sessionID: $0.sessionID)
                },
                exercises: [first, second])
        }
        let model = SyncModel(
            auth: retainedAuth(defaults: defaults), setWriteAPI: api,
            defaults: defaults,
            uuidFactory: {
                generatedIDCount += 1
                return generatedIDs.next()!
            },
            now: { self.fixedDate })
        model.replaceState(with: state(
            session: s, sets: [], exercises: [first, second]))
        model.startWorkout()

        let firstTap = Task {
            await model.logCurrentSet(
                expected: first, expectedSetNumber: 1)
        }
        let queuedDuplicate = Task {
            await model.logCurrentSet(
                expected: first, expectedSetNumber: 1)
        }
        await firstTap.value
        await queuedDuplicate.value
        await entered.wait()

        XCTAssertEqual(model.currentExercise?.id, second.id)
        XCTAssertEqual(generatedIDCount, 1)
        XCTAssertEqual(model.setOutbox.pending.map(\.slotID), [first.id])
        XCTAssertEqual(api.logCalls.count, 1)

        await release.open()
        await model.drainSetOutbox()

        XCTAssertEqual(api.logCalls.map(\.body.template_exercise_id), [first.id])
        XCTAssertEqual(model.runnerSetsDone(first), 1)
        XCTAssertEqual(model.runnerSetsDone(second), 0)
    }

    func testSameSlotSwapDoesNotAttributeOldQueuedOrFailedIntents() {
        let defaults = defaults()
        let original = exercise(
            id: "slot-a", exerciseID: "exercise-original")
        let replacement = exercise(
            id: "slot-a", exerciseID: "exercise-replacement")
        let s = session(status: "in_progress")
        var outbox = SetOutbox()
        for (id, index, state) in [
            ("11111111-1111-4111-8111-111111111111", 1, SetIntentDeliveryState.queued),
            ("22222222-2222-4222-8222-222222222222", 2, SetIntentDeliveryState.failed),
        ] {
            outbox.enqueue(.init(
                body: .init(
                    id: id,
                    exercise_id: original.exercise_id,
                    template_exercise_id: original.id,
                    set_index: index,
                    weight: 100,
                    reps: 5,
                    is_warmup: false,
                    logged_at: 1_999_999_999_000 + index,
                    duration_s: nil,
                    is_timed: false),
                date: s.date,
                workoutID: "day-a",
                resolvedSessionID: s.id,
                deliveryState: state,
                failedHTTPStatus: state == .failed ? 422 : nil))
        }
        SetOutboxStore.save(outbox, userID: "user-a", defaults: defaults)
        let model = SyncModel(
            auth: retainedAuth(defaults: defaults),
            defaults: defaults,
            now: { self.fixedDate })
        prepare(model, exercise: replacement, session: s, running: true)

        XCTAssertTrue(model.pendingSetIntents(for: replacement).isEmpty)
        XCTAssertEqual(model.runnerSetsDone(replacement), 0)
        XCTAssertEqual(model.currentSetNumber, 1)
        XCTAssertFalse(model.isSetEntryBlocked(replacement))
    }

    func testPriorDateFailedIntentDoesNotBlockRecurringSlotToday() {
        let defaults = defaults()
        let ex = exercise()
        let s = session(status: "in_progress")
        var outbox = SetOutbox()
        outbox.enqueue(.init(
            body: .init(
                id: fixedUUID.uuidString,
                exercise_id: ex.exercise_id,
                template_exercise_id: ex.id,
                set_index: 1,
                weight: 100,
                reps: 5,
                is_warmup: false,
                logged_at: 1,
                duration_s: nil,
                is_timed: false),
            date: "1900-01-01",
            workoutID: "day-a",
            resolvedSessionID: "session-old",
            deliveryState: .failed,
            failedHTTPStatus: 422))
        SetOutboxStore.save(outbox, userID: "user-a", defaults: defaults)
        let model = SyncModel(
            auth: retainedAuth(defaults: defaults),
            defaults: defaults,
            now: { self.fixedDate })
        prepare(model, exercise: ex, session: s, running: true)

        XCTAssertEqual(model.failedSetIntentCount, 1)
        XCTAssertTrue(model.pendingSetIntents(for: ex).isEmpty)
        XCTAssertFalse(model.isSetEntryBlocked(ex))
    }

    func testLateFailureForSwappedExerciseCannotReopenReplacement() async {
        let defaults = defaults()
        let original = exercise(
            id: "slot-a", exerciseID: "exercise-original", targetSets: 1)
        let replacement = exercise(
            id: "slot-a", exerciseID: "exercise-replacement", targetSets: 1)
        let s = session(status: "in_progress")
        let api = SetWriteAPIStub()
        let sendEntered = SetAsyncLatch()
        let releaseSend = SetAsyncLatch()
        api.logHandler = { _, _, _ in
            await sendEntered.open()
            await releaseSend.wait()
            throw APIError.http(422, "stale_template_exercise")
        }
        api.stateHandler = { [self] _ in
            state(session: s, sets: [], exercise: replacement)
        }
        let model = SyncModel(
            auth: retainedAuth(defaults: defaults),
            setWriteAPI: api,
            catalogAPI: SetCatalogAPIStub(),
            defaults: defaults,
            uuidFactory: { self.fixedUUID },
            now: { self.fixedDate })
        prepare(model, exercise: original, session: s, running: true)

        await model.logCurrentSet(
            expected: original, expectedSetNumber: 1)
        await sendEntered.wait()
        XCTAssertTrue(model.finished)

        await model.load()
        XCTAssertEqual(model.currentExercise?.exercise_id, replacement.exercise_id)
        XCTAssertFalse(model.finished)
        await model.finishResolvedWorkout()
        XCTAssertTrue(model.terminalOutbox.intents.isEmpty)

        await releaseSend.open()
        await model.drainSetOutbox()

        XCTAssertFalse(model.finished)
        XCTAssertEqual(model.currentExercise?.exercise_id, replacement.exercise_id)
        XCTAssertEqual(model.failedSetIntentCount, 1)
        XCTAssertTrue(model.pendingSetIntents(for: replacement).isEmpty)
        XCTAssertFalse(model.isSetEntryBlocked(replacement))
    }

    func testLateAcknowledgementForSwappedExerciseKeepsReplacementOpen() async {
        let defaults = defaults()
        let original = exercise(
            id: "slot-a", exerciseID: "exercise-original", targetSets: 1)
        let replacement = exercise(
            id: "slot-a", exerciseID: "exercise-replacement", targetSets: 1)
        let s = session(status: "in_progress")
        let api = SetWriteAPIStub()
        let sendEntered = SetAsyncLatch()
        let releaseSend = SetAsyncLatch()
        var acknowledged: SetLog?
        api.logHandler = { [self] sessionID, body, _ in
            await sendEntered.open()
            await releaseSend.wait()
            let row = setLog(body: body, sessionID: sessionID)
            acknowledged = row
            return .init(set: row, deduped: false)
        }
        api.stateHandler = { [self] _ in
            state(
                session: s,
                sets: acknowledged.map { [$0] } ?? [],
                exercise: replacement)
        }
        let model = SyncModel(
            auth: retainedAuth(defaults: defaults),
            setWriteAPI: api,
            catalogAPI: SetCatalogAPIStub(),
            defaults: defaults,
            uuidFactory: { self.fixedUUID },
            now: { self.fixedDate })
        prepare(model, exercise: original, session: s, running: true)

        await model.logCurrentSet(
            expected: original, expectedSetNumber: 1)
        await sendEntered.wait()
        XCTAssertTrue(model.finished)

        await model.load()
        XCTAssertFalse(model.finished)
        XCTAssertEqual(model.currentExercise?.exercise_id, replacement.exercise_id)

        await releaseSend.open()
        await model.drainSetOutbox()

        XCTAssertFalse(model.finished)
        XCTAssertEqual(model.runnerSetsDone(replacement), 0)
        XCTAssertTrue(model.pendingSetIntents(for: replacement).isEmpty)
    }

    func testLiveBodyweightSwapReseedsAndLogsZeroWeight() async {
        let defaults = defaults()
        let original = exercise(
            id: "slot-a", exerciseID: "exercise-barbell", targetSets: 1)
        let replacement = exercise(
            id: "slot-a", exerciseID: "exercise-bodyweight",
            targetSets: 1, modality: "bw")
        let s = session(status: "in_progress")
        let api = SetWriteAPIStub()
        api.logHandler = { [self] sessionID, body, _ in
            .init(
                set: setLog(body: body, sessionID: sessionID),
                deduped: false)
        }
        api.stateHandler = { [self] _ in
            state(session: s, sets: [], exercise: replacement)
        }
        let model = SyncModel(
            auth: retainedAuth(defaults: defaults),
            setWriteAPI: api,
            catalogAPI: SetCatalogAPIStub(),
            defaults: defaults,
            uuidFactory: { self.fixedUUID },
            now: { self.fixedDate })
        prepare(model, exercise: original, session: s, running: true)
        model.setWeight(225)

        await model.load()

        XCTAssertEqual(model.currentExercise?.exercise_id, replacement.exercise_id)
        XCTAssertTrue(model.currentExercise?.isBodyweight == true)
        XCTAssertEqual(model.weight, 0)
        XCTAssertFalse(model.finished)

        await model.logCurrentSet(
            expected: replacement, expectedSetNumber: 1)
        await model.drainSetOutbox()

        XCTAssertEqual(api.logCalls.first?.body.exercise_id, replacement.exercise_id)
        XCTAssertEqual(api.logCalls.first?.body.weight, 0)
    }

    func testRenderedLogActionCannotCrossSameSlotExerciseSwap() async {
        let defaults = defaults()
        let original = exercise(
            id: "slot-a", exerciseID: "exercise-original", targetSets: 1)
        let replacement = exercise(
            id: "slot-a", exerciseID: "exercise-replacement", targetSets: 1)
        let s = session(status: "in_progress")
        let api = SetWriteAPIStub()
        api.stateHandler = { [self] _ in
            state(session: s, sets: [], exercise: replacement)
        }
        let model = SyncModel(
            auth: retainedAuth(defaults: defaults),
            setWriteAPI: api,
            catalogAPI: SetCatalogAPIStub(),
            defaults: defaults,
            now: { self.fixedDate })
        prepare(model, exercise: original, session: s, running: true)
        let releaseAction = SetAsyncLatch()
        let action = Task {
            await releaseAction.wait()
            await model.logCurrentSet(
                expected: original, expectedSetNumber: 1)
        }

        await model.load()
        await releaseAction.open()
        await action.value

        XCTAssertEqual(model.currentExercise?.exercise_id, replacement.exercise_id)
        XCTAssertTrue(model.setOutbox.isEmpty)
        XCTAssertTrue(api.logCalls.isEmpty)
    }

    func testRenderedLogActionCannotBypassFailedIntentRetry() async {
        let defaults = defaults()
        let ex = exercise(targetSets: 1)
        let s = session(status: "in_progress")
        let api = SetWriteAPIStub()
        api.logHandler = { _, _, _ in
            throw APIError.http(422, "invalid_set")
        }
        var uuids = [
            UUID(uuidString: "11111111-1111-4111-8111-111111111111")!,
            UUID(uuidString: "22222222-2222-4222-8222-222222222222")!,
        ]
        let model = SyncModel(
            auth: retainedAuth(defaults: defaults),
            setWriteAPI: api,
            defaults: defaults,
            uuidFactory: { uuids.removeFirst() },
            now: { self.fixedDate })
        prepare(model, exercise: ex, session: s, running: true)
        let releaseAction = SetAsyncLatch()
        let action = Task {
            await releaseAction.wait()
            await model.logCurrentSet(expected: ex, expectedSetNumber: 1)
        }

        _ = await model.logSet(ex, weight: 100, reps: 5)
        XCTAssertEqual(model.setOutbox.pending.first?.deliveryState, .failed)
        XCTAssertEqual(model.currentSetNumber, 1)

        await releaseAction.open()
        await action.value

        XCTAssertEqual(model.setOutbox.pending.map(\.id), [fixedUUID.uuidString])
        XCTAssertEqual(api.logCalls.count, 1)
    }

    func testRenderedLogActionCannotRunAfterLiveTerminalStop() async {
        let defaults = defaults()
        let ex = exercise(targetSets: 1)
        let active = session(status: "in_progress", updatedAt: 100)
        let completed = session(status: "completed", updatedAt: 200)
        let api = SetWriteAPIStub()
        api.stateHandler = { [self] _ in
            state(session: completed, sets: [], exercise: ex)
        }
        let model = SyncModel(
            auth: retainedAuth(defaults: defaults),
            setWriteAPI: api,
            catalogAPI: SetCatalogAPIStub(),
            defaults: defaults,
            now: { self.fixedDate })
        prepare(model, exercise: ex, session: active, running: true)
        let releaseAction = SetAsyncLatch()
        let action = Task {
            await releaseAction.wait()
            await model.logCurrentSet(expected: ex, expectedSetNumber: 1)
        }

        await model.load()
        XCTAssertFalse(model.running)
        await releaseAction.open()
        await action.value

        XCTAssertTrue(model.setOutbox.isEmpty)
        XCTAssertTrue(api.logCalls.isEmpty)
    }

    func testRenderedLogActionCannotRunAfterFinalSkip() async {
        let defaults = defaults()
        let ex = exercise(targetSets: 1)
        let model = SyncModel(
            auth: retainedAuth(defaults: defaults),
            defaults: defaults,
            now: { self.fixedDate })
        prepare(
            model,
            exercise: ex,
            session: session(status: "in_progress"),
            running: true)
        let releaseAction = SetAsyncLatch()
        let action = Task {
            await releaseAction.wait()
            await model.logCurrentSet(expected: ex, expectedSetNumber: 1)
        }

        model.skip()
        XCTAssertTrue(model.finished)
        await releaseAction.open()
        await action.value

        XCTAssertTrue(model.setOutbox.isEmpty)
    }

    func testRenderedTimedStartCannotRunAfterFinalSkip() async {
        let defaults = defaults()
        let ex = exercise(timed: true, targetSets: 1)
        let model = SyncModel(
            auth: retainedAuth(defaults: defaults),
            defaults: defaults,
            now: { self.fixedDate })
        prepare(
            model,
            exercise: ex,
            session: session(status: "in_progress"),
            running: true)
        let releaseAction = SetAsyncLatch()
        let action = Task {
            await releaseAction.wait()
            model.startTimedSet(expected: ex, expectedSetNumber: 1)
        }

        model.skip()
        XCTAssertTrue(model.finished)
        await releaseAction.open()
        await action.value

        XCTAssertFalse(model.timedActive)
        XCTAssertTrue(model.setOutbox.isEmpty)
    }

    func testRenderedTimedStartCannotCrossSameSlotExerciseSwap() async {
        let defaults = defaults()
        let original = exercise(
            id: "slot-a", exerciseID: "exercise-original",
            timed: true, targetSets: 1)
        let replacement = exercise(
            id: "slot-a", exerciseID: "exercise-replacement",
            timed: true, targetSets: 1)
        let s = session(status: "in_progress")
        let api = SetWriteAPIStub()
        api.stateHandler = { [self] _ in
            state(session: s, sets: [], exercise: replacement)
        }
        let model = SyncModel(
            auth: retainedAuth(defaults: defaults),
            setWriteAPI: api,
            catalogAPI: SetCatalogAPIStub(),
            defaults: defaults,
            now: { self.fixedDate })
        prepare(model, exercise: original, session: s, running: true)
        let releaseAction = SetAsyncLatch()
        let action = Task {
            await releaseAction.wait()
            model.startTimedSet(
                expected: original, expectedSetNumber: 1)
        }

        await model.load()
        await releaseAction.open()
        await action.value

        XCTAssertEqual(model.currentExercise?.exercise_id, replacement.exercise_id)
        XCTAssertFalse(model.timedActive)
        XCTAssertTrue(model.setOutbox.isEmpty)
    }

    func testOldModelCannotEnqueueAfterSameUserReauthentication() async {
        let defaults = defaults()
        let ex = exercise(targetSets: 1)
        let s = session(status: "in_progress")
        let oldToken = jwt(subject: "user-a")
        let newToken = jwt(
            subject: "user-a",
            expiration: fixedDate.addingTimeInterval(5_000_000))
        let authAPI = SetAuthAPIStub()
        authAPI.authResult = .success(authResponse(jwt: newToken, userID: "user-a"))
        let auth = auth(defaults: defaults, api: authAPI, token: oldToken)
        let api = SetWriteAPIStub()
        let model = SyncModel(
            auth: auth,
            setWriteAPI: api,
            defaults: defaults,
            now: { self.fixedDate })
        prepare(model, exercise: ex, session: s, running: true)
        model.skip()
        let skippedCheckpoint = WorkoutRunnerCheckpointStore.load(
            userID: "user-a", defaults: defaults)
        XCTAssertTrue(model.isSkipped(ex))
        XCTAssertEqual(skippedCheckpoint?.skippedSlotIDs, [ex.id])

        auth.signOut()
        await auth.exchange(identityToken: "same-user", fullName: nil)
        XCTAssertEqual(auth.featureJWT, newToken)

        await model.logCurrentSet(expected: ex, expectedSetNumber: 1)

        XCTAssertTrue(model.setOutbox.isEmpty)
        XCTAssertTrue(api.logCalls.isEmpty)
        XCTAssertTrue(model.isSkipped(ex))
        XCTAssertEqual(
            WorkoutRunnerCheckpointStore.load(
                userID: "user-a", defaults: defaults),
            skippedCheckpoint)
    }

    func testOldModelCannotChooseTerminalActionAfterSameUserReauthentication() async {
        let defaults = defaults()
        let ex = exercise()
        let s = session(status: "in_progress")
        let oldToken = jwt(subject: "user-a")
        let newToken = jwt(
            subject: "user-a",
            expiration: fixedDate.addingTimeInterval(5_000_000))
        let authAPI = SetAuthAPIStub()
        authAPI.authResult = .success(authResponse(jwt: newToken, userID: "user-a"))
        let auth = auth(defaults: defaults, api: authAPI, token: oldToken)
        let terminalAPI = SetTerminalAPIStub()
        let model = SyncModel(
            auth: auth,
            terminalAPI: terminalAPI,
            defaults: defaults,
            now: { self.fixedDate })
        prepare(model, exercise: ex, session: s, running: true)
        let checkpoint = WorkoutRunnerCheckpointStore.load(
            userID: "user-a", defaults: defaults)

        auth.signOut()
        await auth.exchange(identityToken: "same-user", fullName: nil)

        await model.finishWorkout()
        await model.discardWorkout()

        XCTAssertTrue(model.terminalOutbox.isEmpty)
        XCTAssertTrue(terminalAPI.completeCalls.isEmpty)
        XCTAssertTrue(terminalAPI.discardCalls.isEmpty)
        XCTAssertTrue(model.running)
        XCTAssertEqual(
            WorkoutRunnerCheckpointStore.load(
                userID: "user-a", defaults: defaults),
            checkpoint)
    }

    func testRenderedTerminalActionsCannotRetargetReplacementAttempt() async {
        let defaults = defaults()
        let ex = exercise()
        let original = session(status: "in_progress", updatedAt: 100, attempt: 0)
        let replacement = session(
            status: "in_progress", updatedAt: 200, attempt: 1)
        let setAPI = SetWriteAPIStub()
        setAPI.stateHandler = { [self] _ in
            state(session: replacement, sets: [], exercise: ex)
        }
        let terminalAPI = SetTerminalAPIStub()
        let model = SyncModel(
            auth: retainedAuth(defaults: defaults),
            setWriteAPI: setAPI,
            terminalAPI: terminalAPI,
            catalogAPI: SetCatalogAPIStub(),
            defaults: defaults,
            now: { self.fixedDate })
        prepare(model, exercise: ex, session: original, running: true)
        let renderedTarget = try! XCTUnwrap(model.terminalActionTarget)

        await model.load()
        XCTAssertEqual(model.todaySession?.attempt, 1)

        await model.finishWorkout(expected: renderedTarget)
        await model.discardWorkout(expected: renderedTarget)

        XCTAssertTrue(model.terminalOutbox.isEmpty)
        XCTAssertTrue(terminalAPI.completeCalls.isEmpty)
        XCTAssertTrue(terminalAPI.discardCalls.isEmpty)
        XCTAssertEqual(model.todaySession?.attempt, 1)
        XCTAssertEqual(model.todaySession?.status, "in_progress")
    }

    func testNilBoundTerminalActionRequiresSameRunnerCheckpoint() async {
        let defaults = defaults()
        let ex = exercise()
        let terminalAPI = SetTerminalAPIStub()
        let model = SyncModel(
            auth: retainedAuth(defaults: defaults),
            terminalAPI: terminalAPI,
            defaults: defaults,
            now: { self.fixedDate })
        prepare(model, exercise: ex, running: true)
        let renderedTarget = try! XCTUnwrap(model.terminalActionTarget)
        XCTAssertNil(renderedTarget.sessionID)

        model.skip()
        await model.discardWorkout(expected: renderedTarget)

        XCTAssertTrue(model.terminalOutbox.isEmpty)
        XCTAssertTrue(terminalAPI.discardCalls.isEmpty)
        XCTAssertNotEqual(
            WorkoutRunnerCheckpointStore.load(
                userID: "user-a", defaults: defaults),
            renderedTarget.nilBoundRunnerCheckpoint)
    }

    func testOldModelCannotRetryFailedWritesAfterSameUserReauthentication() async {
        let defaults = defaults()
        let ex = exercise()
        let s = session(status: "in_progress", attempt: 0)
        let body = SetRequestBody(
            id: fixedUUID.uuidString,
            exercise_id: ex.exercise_id,
            template_exercise_id: ex.id,
            set_index: 1,
            weight: 100,
            reps: 5,
            is_warmup: false,
            logged_at: 2_000_000_000_000,
            duration_s: nil,
            is_timed: false)
        var setOutbox = SetOutbox()
        setOutbox.enqueue(.init(
            body: body,
            date: fixedCivilDate,
            workoutID: "day-a",
            resolvedSessionID: s.id,
            deliveryState: .failed,
            failedHTTPStatus: 422,
            expectedAttempt: 0))
        SetOutboxStore.save(
            setOutbox, userID: "user-a", defaults: defaults)
        let terminalIntent = WorkoutTerminalIntent(
            id: "terminal-a",
            action: .finish,
            date: fixedCivilDate,
            workoutID: "day-a",
            resolvedSessionID: s.id,
            deliveryState: .failed,
            failedHTTPStatus: 422,
            expectedAttempt: 0)
        var terminalOutbox = WorkoutTerminalOutbox()
        terminalOutbox.enqueue(terminalIntent)
        WorkoutTerminalOutboxStore.save(
            terminalOutbox, userID: "user-a", defaults: defaults)

        let oldToken = jwt(subject: "user-a")
        let newToken = jwt(
            subject: "user-a",
            expiration: fixedDate.addingTimeInterval(5_000_000))
        let authAPI = SetAuthAPIStub()
        authAPI.authResult = .success(authResponse(jwt: newToken, userID: "user-a"))
        let auth = auth(defaults: defaults, api: authAPI, token: oldToken)
        let setAPI = SetWriteAPIStub()
        let terminalAPI = SetTerminalAPIStub()
        let model = SyncModel(
            auth: auth,
            setWriteAPI: setAPI,
            terminalAPI: terminalAPI,
            defaults: defaults,
            now: { self.fixedDate })

        auth.signOut()
        await auth.exchange(identityToken: "same-user", fullName: nil)

        await model.retrySetIntent(id: body.id)
        await model.retryFailedSetIntents()
        await model.retryTerminalIntent(id: terminalIntent.id)
        await model.retryFailedTerminalIntents()

        XCTAssertEqual(model.setOutbox.pending.first?.deliveryState, .failed)
        XCTAssertEqual(
            model.terminalOutbox.intents.first?.deliveryState, .failed)
        XCTAssertEqual(
            SetOutboxStore.load(
                userID: "user-a", defaults: defaults
            ).pending.first?.deliveryState,
            .failed)
        XCTAssertEqual(
            WorkoutTerminalOutboxStore.load(
                userID: "user-a", defaults: defaults
            ).intents.first?.deliveryState,
            .failed)
        XCTAssertTrue(setAPI.logCalls.isEmpty)
        XCTAssertTrue(terminalAPI.completeCalls.isEmpty)
        XCTAssertTrue(terminalAPI.discardCalls.isEmpty)
    }

    func testLiveTargetReductionBlocksStaleRepLogAction() async {
        let defaults = defaults()
        let original = exercise(targetSets: 2)
        let replacement = exercise(targetSets: 1)
        let s = session(status: "in_progress")
        let completedBody = SetRequestBody(
            id: fixedUUID.uuidString,
            exercise_id: original.exercise_id,
            template_exercise_id: original.id,
            set_index: 1,
            weight: 100,
            reps: 5,
            is_warmup: false,
            logged_at: 1,
            duration_s: nil,
            is_timed: false)
        let completed = setLog(body: completedBody, sessionID: s.id)
        let api = SetWriteAPIStub()
        api.stateHandler = { [self] _ in
            state(session: s, sets: [completed], exercise: replacement)
        }
        let model = SyncModel(
            auth: retainedAuth(defaults: defaults),
            setWriteAPI: api,
            catalogAPI: SetCatalogAPIStub(),
            defaults: defaults,
            now: { self.fixedDate })
        prepare(model, exercise: original, session: s)
        model.sets = [completed]
        model.startWorkout()
        XCTAssertEqual(model.currentSetNumber, 2)

        await model.load()
        XCTAssertTrue(model.finished)

        await model.logCurrentSet(expected: original, expectedSetNumber: 2)

        XCTAssertTrue(model.setOutbox.isEmpty)
        XCTAssertTrue(api.logCalls.isEmpty)
    }

    func testLiveTargetReductionBlocksStaleTimedStartAction() async {
        let defaults = defaults()
        let original = exercise(timed: true, targetSets: 2)
        let replacement = exercise(timed: true, targetSets: 1)
        let s = session(status: "in_progress")
        let completedBody = SetRequestBody(
            id: fixedUUID.uuidString,
            exercise_id: original.exercise_id,
            template_exercise_id: original.id,
            set_index: 1,
            weight: 0,
            reps: 30,
            is_warmup: false,
            logged_at: 1,
            duration_s: 30,
            is_timed: true)
        let completed = setLog(body: completedBody, sessionID: s.id)
        let api = SetWriteAPIStub()
        api.stateHandler = { [self] _ in
            state(session: s, sets: [completed], exercise: replacement)
        }
        let model = SyncModel(
            auth: retainedAuth(defaults: defaults),
            setWriteAPI: api,
            catalogAPI: SetCatalogAPIStub(),
            defaults: defaults,
            now: { self.fixedDate })
        prepare(model, exercise: original, session: s)
        model.sets = [completed]
        model.startWorkout()
        XCTAssertEqual(model.currentSetNumber, 2)

        await model.load()
        XCTAssertTrue(model.finished)

        model.startTimedSet(expected: original, expectedSetNumber: 2)

        XCTAssertFalse(model.timedActive)
        XCTAssertTrue(model.setOutbox.isEmpty)
    }

    func testLiveTargetReductionCancelsActiveTimedAttempt() async {
        let defaults = defaults()
        let original = exercise(timed: true, targetSets: 2)
        let replacement = exercise(timed: true, targetSets: 1)
        let s = session(status: "in_progress")
        let completedBody = SetRequestBody(
            id: fixedUUID.uuidString,
            exercise_id: original.exercise_id,
            template_exercise_id: original.id,
            set_index: 1,
            weight: 0,
            reps: original.holdSeconds,
            is_warmup: false,
            logged_at: 1,
            duration_s: original.holdSeconds,
            is_timed: true)
        let completed = setLog(body: completedBody, sessionID: s.id)
        let api = SetWriteAPIStub()
        api.stateHandler = { [self] _ in
            state(session: s, sets: [completed], exercise: replacement)
        }
        let model = SyncModel(
            auth: retainedAuth(defaults: defaults),
            setWriteAPI: api,
            catalogAPI: SetCatalogAPIStub(),
            defaults: defaults,
            now: { self.fixedDate })
        prepare(model, exercise: original, session: s)
        model.sets = [completed]
        model.startWorkout()
        XCTAssertEqual(model.currentSetNumber, 2)
        model.startTimedSet(
            expected: original, expectedSetNumber: 2, at: fixedDate)
        XCTAssertTrue(model.timedActive)

        await model.load()

        XCTAssertTrue(model.finished)
        XCTAssertFalse(model.timedActive)
        await model.finishTimedSetIfDue(
            at: fixedDate.addingTimeInterval(
                TimeInterval(original.holdSeconds + 1)))
        XCTAssertTrue(model.setOutbox.isEmpty)
        XCTAssertTrue(api.logCalls.isEmpty)
    }

    func testDuplicateTimedStartDoesNotRestartActiveAttempt() {
        let defaults = defaults()
        let ex = exercise(timed: true, targetSets: 1)
        let s = session(status: "in_progress")
        let model = SyncModel(
            auth: retainedAuth(defaults: defaults),
            defaults: defaults,
            now: { self.fixedDate })
        prepare(model, exercise: ex, session: s, running: true)
        model.startTimedSet(
            expected: ex, expectedSetNumber: 1, at: fixedDate)
        let originalStart = model.timedStartDate
        let originalEnd = model.timedEndDate

        model.startTimedSet(
            expected: ex,
            expectedSetNumber: 1,
            at: fixedDate.addingTimeInterval(10))

        XCTAssertTrue(model.timedActive)
        XCTAssertEqual(model.timedStartDate, originalStart)
        XCTAssertEqual(model.timedEndDate, originalEnd)
    }

    func testPermanentRunnerRejectionReopensFailedSlot() async {
        let defaults = defaults()
        let ex = exercise(targetSets: 1)
        let s = session(status: "in_progress")
        let api = SetWriteAPIStub()
        let releaseRejection = SetAsyncLatch()
        api.logHandler = { _, _, _ in
            await releaseRejection.wait()
            throw APIError.http(422, "stale_template_exercise")
        }
        let model = SyncModel(
            auth: retainedAuth(defaults: defaults), setWriteAPI: api,
            defaults: defaults, uuidFactory: { self.fixedUUID },
            now: { self.fixedDate })
        prepare(model, exercise: ex, session: s, running: true)

        await model.logCurrentSet(
            expected: ex, expectedSetNumber: 1)
        // Delivery runs in the background. Observe the optimistic state
        // before allowing the rejection to reopen the failed slot.
        XCTAssertTrue(model.finished)
        await releaseRejection.open()
        await model.drainSetOutbox()

        XCTAssertFalse(model.finished)
        XCTAssertEqual(model.exerciseIndex, 0)
        XCTAssertEqual(model.runnerSetsDone(ex), 0)
        XCTAssertEqual(model.currentSetNumber, 1)
        XCTAssertEqual(model.upNextName, ex.exercise_name)
        XCTAssertEqual(model.failedSetIntentCount, 1)
        XCTAssertTrue(model.isSetEntryBlocked(ex))
    }

    func testRetryingRejectedFinalSetReturnsRunnerToDone() async {
        let defaults = defaults()
        let ex = exercise(targetSets: 1)
        let s = session(status: "in_progress")
        let api = SetWriteAPIStub()
        let retryEntered = SetAsyncLatch()
        let releaseRetry = SetAsyncLatch()
        var calls = 0
        api.logHandler = { [self] sessionID, body, _ in
            calls += 1
            if calls == 1 {
                throw APIError.http(422, "stale_template_exercise")
            }
            await retryEntered.open()
            await releaseRetry.wait()
            return .init(
                set: setLog(body: body, sessionID: sessionID),
                deduped: false,
                session: session(
                    id: sessionID, status: "in_progress", attempt: 0))
        }
        api.stateHandler = { [self] _ in
            state(
                session: s,
                sets: api.logCalls.dropFirst().map {
                    setLog(body: $0.body, sessionID: $0.sessionID)
                },
                exercise: ex)
        }
        let model = SyncModel(
            auth: retainedAuth(defaults: defaults), setWriteAPI: api,
            defaults: defaults, uuidFactory: { self.fixedUUID },
            now: { self.fixedDate })
        prepare(model, exercise: ex, session: s, running: true)

        await model.logCurrentSet(
            expected: ex, expectedSetNumber: 1)
        await model.drainSetOutbox()
        XCTAssertFalse(model.finished)
        let intentID = model.setOutbox.pending[0].id

        let retry = Task { await model.retrySetIntent(id: intentID) }
        await retryEntered.wait()

        XCTAssertTrue(model.finished)
        XCTAssertEqual(model.upNextName, "Done")

        await releaseRetry.open()
        await retry.value
        XCTAssertTrue(model.setOutbox.isEmpty)
        XCTAssertTrue(model.finished)
    }

    func testDelayedPermanentFailurePreservesActiveSuccessorTimer() async {
        let defaults = defaults()
        let first = exercise(targetSets: 1)
        let timed = exercise(
            id: "slot-b", exerciseID: "exercise-b", timed: true,
            targetSets: 2)
        let s = session(status: "in_progress")
        let api = SetWriteAPIStub()
        let firstEntered = SetAsyncLatch()
        let releaseFirst = SetAsyncLatch()
        let firstID = fixedUUID
        let secondID = UUID(uuidString: "22222222-2222-4222-8222-222222222222")!
        var generatedIDs = [firstID, secondID].makeIterator()
        api.logHandler = { [self] sessionID, body, _ in
            if body.template_exercise_id == first.id {
                await firstEntered.open()
                await releaseFirst.wait()
                throw APIError.http(422, "stale_template_exercise")
            }
            return .init(
                set: setLog(body: body, sessionID: sessionID),
                deduped: false,
                session: session(
                    id: sessionID, status: "in_progress", attempt: 0))
        }
        api.stateHandler = { [self] _ in
            state(
                session: s,
                sets: api.logCalls.compactMap {
                    $0.body.template_exercise_id == timed.id
                        ? setLog(body: $0.body, sessionID: $0.sessionID)
                        : nil
                },
                exercises: [first, timed])
        }
        let model = SyncModel(
            auth: retainedAuth(defaults: defaults), setWriteAPI: api,
            defaults: defaults,
            uuidFactory: { generatedIDs.next()! },
            now: { self.fixedDate })
        model.replaceState(with: state(
            session: s, sets: [], exercises: [first, timed]))
        model.startWorkout()

        await model.logCurrentSet(
            expected: first, expectedSetNumber: 1)
        await firstEntered.wait()
        XCTAssertEqual(model.currentExercise?.id, timed.id)

        model.startTimedSet(
            expected: timed, expectedSetNumber: model.currentSetNumber)
        let timerEnd = model.timedEndDate
        XCTAssertTrue(model.timedActive)

        await releaseFirst.open()
        await model.drainSetOutbox()

        XCTAssertTrue(model.timedActive)
        XCTAssertEqual(model.timedEndDate, timerEnd)
        XCTAssertEqual(model.currentExercise?.id, timed.id)
        XCTAssertEqual(model.failedSetIntentCount, 1)

        await model.finishTimedSetAuto()

        XCTAssertFalse(model.timedActive)
        XCTAssertEqual(model.currentExercise?.id, first.id)
        XCTAssertEqual(model.restActivityCurrentStepName,
                       first.exercise_name)
        XCTAssertEqual(model.upNextName, timed.exercise_name)
        XCTAssertEqual(model.runnerSetsDone(first), 0)
        XCTAssertEqual(model.runnerSetsDone(timed), 1)
    }

    func testDelayedSameSlotFailurePreservesNextTimedSetAttempt() async {
        let defaults = defaults()
        let timed = exercise(timed: true, targetSets: 2)
        let s = session(status: "in_progress")
        let api = SetWriteAPIStub()
        let firstEntered = SetAsyncLatch()
        let releaseFirst = SetAsyncLatch()
        let firstID = fixedUUID
        let secondID = UUID(uuidString: "22222222-2222-4222-8222-222222222222")!
        var generatedIDs = [firstID, secondID].makeIterator()
        api.logHandler = { [self] sessionID, body, _ in
            if body.set_index == 1 {
                await firstEntered.open()
                await releaseFirst.wait()
                throw APIError.http(422, "stale_template_exercise")
            }
            return .init(
                set: setLog(body: body, sessionID: sessionID),
                deduped: false,
                session: session(
                    id: sessionID, status: "in_progress", attempt: 0))
        }
        api.stateHandler = { [self] _ in
            state(
                session: s,
                sets: api.logCalls.compactMap {
                    $0.body.set_index == 2
                        ? setLog(body: $0.body, sessionID: $0.sessionID)
                        : nil
                },
                exercise: timed)
        }
        let model = SyncModel(
            auth: retainedAuth(defaults: defaults), setWriteAPI: api,
            defaults: defaults,
            uuidFactory: { generatedIDs.next()! },
            now: { self.fixedDate })
        prepare(model, exercise: timed, session: s, running: true)

        await model.logCurrentSet(
            expected: timed, expectedSetNumber: 1)
        await firstEntered.wait()
        XCTAssertEqual(model.currentSetNumber, 2)
        model.startTimedSet(
            expected: timed, expectedSetNumber: model.currentSetNumber)
        XCTAssertTrue(model.timedActive)

        await releaseFirst.open()
        await model.drainSetOutbox()

        XCTAssertEqual(model.failedSetIntentCount, 1)
        XCTAssertEqual(model.currentSetNumber, 1)
        XCTAssertTrue(model.timedActive)

        await model.finishTimedSetAuto()
        await model.drainSetOutbox()

        XCTAssertFalse(model.timedActive)
        XCTAssertEqual(api.logCalls.map(\.body.set_index), [1, 2])
        XCTAssertEqual(model.failedSetIntentCount, 1)
        XCTAssertEqual(model.runnerSetsDone(timed), 1)
    }

    func testOldActivitySuccessRefreshesReplacementSyncAfterSameUserReauth() async {
        let defaults = defaults()
        let oldToken = jwt(subject: "user-a")
        let newToken = jwt(
            subject: "user-a",
            expiration: Date(timeIntervalSince1970: 2_100_000_000))
        let authAPI = SetAuthAPIStub()
        let auth = auth(
            defaults: defaults, api: authAPI, token: oldToken)
        let activityEntered = SetAsyncLatch()
        let releaseActivity = SetAsyncLatch()
        let oldGroup = GroupModel(
            auth: auth,
            defaults: defaults,
            activityLogger: { pending, token in
                XCTAssertEqual(token, oldToken)
                await activityEntered.open()
                await releaseActivity.wait()
                return ActivityRow(
                    id: pending.id,
                    user_id: "user-a",
                    date: pending.date,
                    type: pending.type,
                    title: pending.title,
                    duration_minutes: pending.duration_minutes,
                    notes: pending.notes,
                    logged_at: pending.logged_at,
                    source: "manual",
                    deleted_at: nil)
            })
        let accountID = auth.userID
        oldGroup.onActivityPersisted = { [weak auth] in
            auth?.noteActivityPersisted(for: accountID)
        }
        let pending = PendingActivity(
            id: "activity-a",
            date: fixedCivilDate,
            type: "walk",
            title: "Walk",
            duration_minutes: 20,
            notes: nil,
            logged_at: 2_000_000_000_000)

        let logging = Task { await oldGroup.logActivity(pending) }
        await activityEntered.wait()

        auth.signOut()
        authAPI.authResult = .success(
            authResponse(jwt: newToken, userID: "user-a"))
        await auth.exchange(identityToken: "apple-a", fullName: nil)

        let stateAPI = SetWriteAPIStub()
        let s = session(status: "in_progress")
        let ex = exercise()
        stateAPI.stateHandler = { [self] _ in
            state(session: s, sets: [], exercise: ex)
        }
        let replacement = SyncModel(
            auth: auth,
            setWriteAPI: stateAPI,
            catalogAPI: SetCatalogAPIStub(),
            defaults: defaults,
            now: { self.fixedDate })
        await replacement.load()
        XCTAssertEqual(stateAPI.stateCalls, 1)

        await releaseActivity.open()
        await logging.value
        while stateAPI.stateCalls < 2 { await Task.yield() }

        XCTAssertEqual(auth.activityPersistenceGeneration, 1)
        XCTAssertEqual(stateAPI.stateCalls, 2)
        XCTAssertNil(replacement.loadError)
    }

    func testOldActivityDeleteRefreshesReplacementSyncAfterSameUserReauth() async {
        let defaults = defaults()
        let oldToken = jwt(subject: "user-a")
        let newToken = jwt(
            subject: "user-a",
            expiration: Date(timeIntervalSince1970: 2_100_000_000))
        let authAPI = SetAuthAPIStub()
        let auth = auth(
            defaults: defaults, api: authAPI, token: oldToken)
        let deleteEntered = SetAsyncLatch()
        let releaseDelete = SetAsyncLatch()
        let oldGroup = GroupModel(
            auth: auth,
            defaults: defaults,
            activityDeleter: { id, token in
                XCTAssertEqual(id, "activity-a")
                XCTAssertEqual(token, oldToken)
                await deleteEntered.open()
                await releaseDelete.wait()
            })
        let accountID = auth.userID
        oldGroup.onActivityPersisted = { [weak auth] in
            auth?.noteActivityPersisted(for: accountID)
        }

        let deleting = Task {
            await oldGroup.deleteActivity(id: "activity-a")
        }
        await deleteEntered.wait()

        auth.signOut()
        authAPI.authResult = .success(
            authResponse(jwt: newToken, userID: "user-a"))
        await auth.exchange(identityToken: "apple-a", fullName: nil)

        let stateAPI = SetWriteAPIStub()
        let s = session(status: "in_progress")
        let ex = exercise()
        stateAPI.stateHandler = { [self] _ in
            state(session: s, sets: [], exercise: ex)
        }
        let replacement = SyncModel(
            auth: auth,
            setWriteAPI: stateAPI,
            catalogAPI: SetCatalogAPIStub(),
            defaults: defaults,
            now: { self.fixedDate })
        await replacement.load()
        XCTAssertEqual(stateAPI.stateCalls, 1)

        await releaseDelete.open()
        await deleting.value
        while stateAPI.stateCalls < 2 { await Task.yield() }

        XCTAssertEqual(auth.activityPersistenceGeneration, 1)
        XCTAssertEqual(stateAPI.stateCalls, 2)
        XCTAssertNil(replacement.loadError)
    }

    func testCommitThenTimeoutRetriesSameIDAndDedupes() async {
        let defaults = defaults()
        let ex = exercise()
        let s = session()
        let api = SetWriteAPIStub()
        var committed: SetLog?
        api.logHandler = { [self] sessionID, body, _ in
            let row = setLog(body: body, sessionID: sessionID)
            if committed == nil {
                committed = row
                throw URLError(.timedOut)
            }
            return .init(set: committed!, deduped: true)
        }
        api.stateHandler = { [self] _ in
            state(session: s, sets: [committed!], exercise: ex)
        }
        let model = SyncModel(
            auth: retainedAuth(defaults: defaults), setWriteAPI: api,
            defaults: defaults, uuidFactory: { self.fixedUUID },
            now: { self.fixedDate })
        prepare(model, exercise: ex, session: s)

        let firstAttempt = await model.logSet(ex, weight: 135, reps: 5)
        XCTAssertFalse(firstAttempt)
        await model.drainSetOutbox()

        XCTAssertEqual(api.logCalls.count, 2)
        XCTAssertEqual(api.logCalls[0].body, api.logCalls[1].body)
        XCTAssertEqual(api.logCalls[0].body.id, fixedUUID.uuidString)
        XCTAssertTrue(model.setOutbox.isEmpty)
        XCTAssertEqual(model.sets.count, 1)
    }

    func testConcurrentDoubleTapCreatesOnlyOneIntent() async {
        let defaults = defaults()
        let ex = exercise()
        let s = session()
        let api = SetWriteAPIStub()
        let entered = SetAsyncLatch()
        let release = SetAsyncLatch()
        api.logHandler = { [self] sessionID, body, _ in
            await entered.open()
            await release.wait()
            return .init(set: setLog(body: body, sessionID: sessionID), deduped: false)
        }
        api.stateHandler = { [self] _ in
            state(
                session: s,
                sets: [setLog(body: api.logCalls[0].body)],
                exercise: ex)
        }
        let model = SyncModel(
            auth: retainedAuth(defaults: defaults), setWriteAPI: api,
            defaults: defaults, now: { self.fixedDate })
        prepare(model, exercise: ex, session: s)

        let first = Task { await model.logSet(ex, weight: 135, reps: 5) }
        await entered.wait()
        let second = Task { await model.logSet(ex, weight: 135, reps: 5) }
        let secondResult = await second.value
        XCTAssertFalse(secondResult)
        await release.open()
        let firstResult = await first.value
        XCTAssertTrue(firstResult)

        XCTAssertEqual(api.logCalls.count, 1)
        XCTAssertEqual(model.sets.count, 1)
    }

    func testTimedCommitPersistsWhenOlderSameSlotIntentStartsSending() async {
        let defaults = defaults()
        let ex = exercise(timed: true)
        let s = session()
        let oldBody = SetRequestBody(
            id: "11111111-1111-4111-8111-111111111111",
            exercise_id: ex.exercise_id,
            template_exercise_id: ex.id,
            set_index: 1,
            weight: 0,
            reps: 30,
            is_warmup: false,
            logged_at: 1_999_999_999_000,
            duration_s: 30,
            is_timed: true)
        var outbox = SetOutbox()
        outbox.enqueue(.init(
            body: oldBody,
            date: s.date,
            workoutID: "day-a",
            resolvedSessionID: s.id,
            deliveryState: .queued,
            failedHTTPStatus: nil))
        SetOutboxStore.save(outbox, userID: "user-a", defaults: defaults)
        let api = SetWriteAPIStub()
        let oldSendEntered = SetAsyncLatch()
        let releaseOldSend = SetAsyncLatch()
        var serverSets: [SetLog] = []
        api.logHandler = { [self] sessionID, request, _ in
            if api.logCalls.count == 1 {
                await oldSendEntered.open()
                await releaseOldSend.wait()
            }
            let row = setLog(body: request, sessionID: sessionID)
            serverSets.append(row)
            return .init(set: row, deduped: false)
        }
        api.stateHandler = { [self] _ in
            state(session: s, sets: serverSets, exercise: ex)
        }
        let newID = UUID(uuidString: "22222222-2222-4222-8222-222222222222")!
        let model = SyncModel(
            auth: retainedAuth(defaults: defaults), setWriteAPI: api,
            defaults: defaults, uuidFactory: { newID },
            now: { self.fixedDate })
        prepare(model, exercise: ex, session: s, running: true)
        model.startTimedSet(
            expected: ex, expectedSetNumber: model.currentSetNumber)

        let drain = Task { await model.drainSetOutbox() }
        await oldSendEntered.wait()
        let timedCommit = Task { await model.finishTimedSetAuto() }
        await Task.yield()
        XCTAssertTrue(model.setOutbox.pending.contains { $0.id == newID.uuidString })
        await releaseOldSend.open()
        await drain.value
        await timedCommit.value

        XCTAssertEqual(api.logCalls.map(\.body.set_index), [1, 2])
        XCTAssertFalse(model.timedActive)
        XCTAssertTrue(model.setOutbox.isEmpty)
        XCTAssertEqual(model.sets.count, 2)
    }

    func testTimedSetAutoCompletesWithoutRunnerView() async {
        let defaults = defaults()
        let ex = exercise(timed: true, targetSets: 1)
        let s = session()
        let api = SetWriteAPIStub()
        let sendEntered = SetAsyncLatch()
        let releaseSend = SetAsyncLatch()
        api.logHandler = { [self] sessionID, request, _ in
            await sendEntered.open()
            await releaseSend.wait()
            return .init(
                set: setLog(body: request, sessionID: sessionID),
                deduped: false)
        }
        api.stateHandler = { [self] _ in state(session: s, sets: [], exercise: ex) }
        let model = SyncModel(
            auth: retainedAuth(defaults: defaults),
            setWriteAPI: api,
            defaults: defaults,
            uuidFactory: { self.fixedUUID },
            now: { self.fixedDate })
        prepare(model, exercise: ex, session: s, running: true)

        // Starting with an already-elapsed deadline makes the model-owned
        // task fire without mounting TimedSetView.
        model.startTimedSet(
            expected: ex,
            expectedSetNumber: model.currentSetNumber,
            at: fixedDate.addingTimeInterval(-30))
        await sendEntered.wait()
        XCTAssertFalse(model.timedActive)
        await releaseSend.open()
        await model.drainSetOutbox()

        XCTAssertEqual(api.logCalls.count, 1)
        XCTAssertEqual(api.logCalls.first?.body.duration_s, 30)
        XCTAssertEqual(api.logCalls.first?.body.is_timed, true)
        XCTAssertTrue(model.setOutbox.isEmpty)
    }

    func testForegroundCatchUpCompletesOnlyWhenTimedSetIsDue() async {
        let defaults = defaults()
        let ex = exercise(timed: true, targetSets: 1)
        let s = session()
        let api = SetWriteAPIStub()
        api.logHandler = { [self] sessionID, request, _ in
            .init(
                set: setLog(body: request, sessionID: sessionID),
                deduped: false)
        }
        api.stateHandler = { [self] _ in state(session: s, sets: [], exercise: ex) }
        let model = SyncModel(
            auth: retainedAuth(defaults: defaults),
            setWriteAPI: api,
            defaults: defaults,
            uuidFactory: { self.fixedUUID },
            now: { self.fixedDate })
        prepare(model, exercise: ex, session: s, running: true)

        model.setWeight(-20)
        model.startTimedSet(
            expected: ex, expectedSetNumber: model.currentSetNumber)
        // Load controls prepare the next set while the active hold retains
        // the exact signed load it started with.
        model.setWeight(-30)
        await model.finishTimedSetIfDue(at: fixedDate.addingTimeInterval(29))
        XCTAssertTrue(model.timedActive)
        XCTAssertTrue(api.logCalls.isEmpty)

        await model.finishTimedSetIfDue(at: fixedDate.addingTimeInterval(30))
        XCTAssertFalse(model.timedActive)
        XCTAssertEqual(model.runnerSetsDone(ex), 1)

        // Timed completion shares the runner's offline-first contract: the
        // intent is durable and progress advances before model-owned delivery.
        await model.drainSetOutbox()
        XCTAssertEqual(api.logCalls.count, 1)
        XCTAssertEqual(api.logCalls.first?.body.duration_s, 30)
        XCTAssertEqual(api.logCalls.first?.body.weight, -20)
    }

    func testRunnerAllowsSignedLoadOnlyForBodyweightAndTimedWork() {
        let defaults = defaults()
        let model = SyncModel(
            auth: retainedAuth(defaults: defaults),
            defaults: defaults,
            now: { self.fixedDate })
        let bodyweight = exercise(bodyweight: true)
        prepare(model, exercise: bodyweight, running: true)

        model.setWeight(-30)
        XCTAssertEqual(model.weight, -30)
        model.adjustWeight(-5)
        XCTAssertEqual(model.weight, -35)

        let loaded = exercise()
        prepare(model, exercise: loaded, running: true)
        model.setWeight(-30)
        XCTAssertEqual(model.weight, 0)
        model.adjustWeight(-5)
        XCTAssertEqual(model.weight, 0)

        let cardio = exercise(timed: true, modality: "cardio", targetWeight: 100)
        prepare(model, exercise: cardio, running: true)
        XCTAssertFalse(cardio.showsLoadControl)
        XCTAssertEqual(model.weight, 0)
        model.setWeight(-30)
        XCTAssertEqual(model.weight, 0)
    }

    func testTimedExpiryCannotCrossSameUserReauthenticationEpoch() async {
        let defaults = defaults()
        let ex = exercise(timed: true, targetSets: 1)
        let s = session()
        let oldToken = jwt(subject: "user-a")
        let newToken = jwt(
            subject: "user-a",
            expiration: fixedDate.addingTimeInterval(5_000_000))
        let authAPI = SetAuthAPIStub()
        authAPI.authResult = .success(authResponse(jwt: newToken, userID: "user-a"))
        let auth = auth(defaults: defaults, api: authAPI, token: oldToken)

        let olderBody = SetRequestBody(
            id: "11111111-1111-4111-8111-111111111111",
            exercise_id: "exercise-b",
            template_exercise_id: "slot-b",
            set_index: 1,
            weight: 100,
            reps: 5,
            is_warmup: false,
            logged_at: 1_999_999_999_000,
            duration_s: nil,
            is_timed: false)
        var outbox = SetOutbox()
        outbox.enqueue(.init(
            body: olderBody,
            date: s.date,
            workoutID: "day-a",
            resolvedSessionID: s.id,
            deliveryState: .queued,
            failedHTTPStatus: nil))
        SetOutboxStore.save(outbox, userID: "user-a", defaults: defaults)

        let api = SetWriteAPIStub()
        let sendEntered = SetAsyncLatch()
        let releaseSend = SetAsyncLatch()
        api.logHandler = { [self] sessionID, body, _ in
            await sendEntered.open()
            await releaseSend.wait()
            return .init(
                set: setLog(body: body, sessionID: sessionID),
                deduped: false)
        }
        api.stateHandler = { [self] _ in
            state(session: s, sets: [setLog(body: olderBody)], exercise: ex)
        }
        let model = SyncModel(
            auth: auth, setWriteAPI: api, defaults: defaults,
            now: { self.fixedDate })
        prepare(model, exercise: ex, session: s, running: true)
        model.startTimedSet(
            expected: ex, expectedSetNumber: model.currentSetNumber)

        let drain = Task { await model.drainSetOutbox() }
        await sendEntered.wait()
        auth.signOut()
        await auth.exchange(identityToken: "same-user", fullName: nil)
        XCTAssertEqual(auth.featureJWT, newToken)

        await model.finishTimedSetIfDue(at: fixedDate.addingTimeInterval(30))
        XCTAssertFalse(model.timedActive)
        XCTAssertEqual(api.logCalls.count, 1)
        XCTAssertEqual(model.setOutbox.count, 1)

        await releaseSend.open()
        await drain.value
        XCTAssertTrue(model.setOutbox.isEmpty)
        XCTAssertEqual(api.logCalls.count, 1)
    }

    func testLiveRefreshRemovingTimedSlotCancelsItsAttempt() async {
        let defaults = defaults()
        let timed = exercise(
            id: "slot-timed", exerciseID: "exercise-timed",
            timed: true, targetSets: 1)
        let successor = exercise(
            id: "slot-successor", exerciseID: "exercise-successor")
        let s = session()
        let api = SetWriteAPIStub()
        api.stateHandler = { [self] _ in
            state(session: s, sets: [], exercises: [successor])
        }
        let model = SyncModel(
            auth: retainedAuth(defaults: defaults),
            setWriteAPI: api,
            catalogAPI: SetCatalogAPIStub(),
            defaults: defaults,
            now: { self.fixedDate })
        model.plan = PlanTree(
            id: "plan-a", name: "Plan A", version: 1,
            workouts: [day(with: [timed, successor])], meta: nil)
        model.selectedDayID = "day-a"
        model.todaySession = s
        model.startWorkout()
        model.startTimedSet(
            expected: timed, expectedSetNumber: model.currentSetNumber)
        XCTAssertTrue(model.timedActive)

        await model.load()

        XCTAssertEqual(model.currentExercise?.id, successor.id)
        XCTAssertFalse(model.timedActive)
        await model.finishTimedSetIfDue(at: fixedDate.addingTimeInterval(30))
        XCTAssertTrue(api.logCalls.isEmpty)
        XCTAssertTrue(model.setOutbox.isEmpty)
    }

    func testLiveReorderAcknowledgingOtherSlotPreservesActiveTimer() async {
        let defaults = defaults()
        let timed = exercise(
            id: "slot-timed", exerciseID: "exercise-timed",
            timed: true, targetSets: 1)
        let other = exercise(
            id: "slot-other", exerciseID: "exercise-other", targetSets: 1)
        let s = session(status: "in_progress")
        let otherBody = SetRequestBody(
            id: fixedUUID.uuidString,
            exercise_id: other.exercise_id,
            template_exercise_id: other.id,
            set_index: 1,
            weight: 100,
            reps: 5,
            is_warmup: false,
            logged_at: 1,
            duration_s: nil,
            is_timed: false)
        var outbox = SetOutbox()
        outbox.enqueue(.init(
            body: otherBody,
            date: fixedCivilDate,
            workoutID: "day-a",
            resolvedSessionID: s.id,
            deliveryState: .queued,
            failedHTTPStatus: nil))
        SetOutboxStore.save(
            outbox, userID: "user-a", defaults: defaults)
        let api = SetWriteAPIStub()
        api.stateHandler = { [self] _ in
            state(
                session: s,
                sets: [setLog(body: otherBody, sessionID: s.id)],
                exercises: [other, timed])
        }
        let model = SyncModel(
            auth: retainedAuth(defaults: defaults),
            setWriteAPI: api,
            catalogAPI: SetCatalogAPIStub(),
            defaults: defaults,
            now: { self.fixedDate })
        model.plan = PlanTree(
            id: "plan-a", name: "Plan A", version: 1,
            workouts: [day(with: [timed, other])], meta: nil)
        model.selectedDayID = "day-a"
        model.todaySession = s
        model.startWorkout()
        model.startTimedSet(
            expected: timed, expectedSetNumber: 1, at: fixedDate)
        let originalStart = model.timedStartDate
        let originalEnd = model.timedEndDate

        await model.load()

        XCTAssertEqual(model.currentExercise?.id, timed.id)
        XCTAssertTrue(model.timedActive)
        XCTAssertEqual(model.timedStartDate, originalStart)
        XCTAssertEqual(model.timedEndDate, originalEnd)
        XCTAssertTrue(model.setOutbox.isEmpty)
    }

    func testLiveTimedSwapKeepingSlotAndDurationCancelsOriginalAttempt() async {
        let defaults = defaults()
        let original = exercise(
            id: "slot-timed", exerciseID: "exercise-original",
            timed: true, targetSets: 1)
        let replacement = exercise(
            id: "slot-timed", exerciseID: "exercise-replacement",
            timed: true, targetSets: 1)
        let s = session()
        let api = SetWriteAPIStub()
        api.stateHandler = { [self] _ in
            state(session: s, sets: [], exercise: replacement)
        }
        let model = SyncModel(
            auth: retainedAuth(defaults: defaults),
            setWriteAPI: api,
            catalogAPI: SetCatalogAPIStub(),
            defaults: defaults,
            now: { self.fixedDate })
        prepare(model, exercise: original, session: s, running: true)
        model.startTimedSet(
            expected: original, expectedSetNumber: model.currentSetNumber)
        XCTAssertTrue(model.timedActive)

        await model.load()

        XCTAssertEqual(model.currentExercise?.exercise_id, replacement.exercise_id)
        XCTAssertFalse(model.timedActive)
        await model.finishTimedSetIfDue(at: fixedDate.addingTimeInterval(30))
        XCTAssertTrue(api.logCalls.isEmpty)
        XCTAssertTrue(model.setOutbox.isEmpty)
    }

    func testPlanMoveOfOtherSlotPreservesActiveTimedAttempt() async {
        let defaults = defaults()
        let timed = exercise(
            id: "slot-timed", exerciseID: "exercise-timed",
            timed: true, targetSets: 1)
        let other = exercise(
            id: "slot-other", exerciseID: "exercise-other")
        let s = session(status: "in_progress", attempt: 0)
        let editor = SetPlanEditingAPIStub()
        editor.updateHandler = { .init(id: other.id) }
        let api = SetWriteAPIStub()
        api.stateHandler = { [self] _ in
            state(session: s, sets: [], exercises: [other, timed])
        }
        api.logHandler = { [self] sessionID, body, _ in
            .init(
                set: setLog(body: body, sessionID: sessionID),
                deduped: false,
                session: s)
        }
        let model = SyncModel(
            auth: retainedAuth(defaults: defaults),
            setWriteAPI: api,
            catalogAPI: SetCatalogAPIStub(),
            planEditingAPI: editor,
            defaults: defaults,
            now: { self.fixedDate })
        model.replaceState(with: state(
            session: s, sets: [], exercises: [timed, other]))
        model.startWorkout()
        model.startTimedSet(
            expected: timed, expectedSetNumber: 1, at: fixedDate)
        let originalStart = model.timedStartDate
        let originalEnd = model.timedEndDate

        await model.moveSlot(
            dayID: "day-a", teID: other.id, toIndex: 0)

        XCTAssertEqual(editor.updateCalls, 1)
        XCTAssertEqual(model.currentExercise?.id, timed.id)
        XCTAssertEqual(model.exerciseIndex, 1)
        XCTAssertTrue(model.timedActive)
        XCTAssertEqual(model.timedStartDate, originalStart)
        XCTAssertEqual(model.timedEndDate, originalEnd)

        await model.finishTimedSetIfDue(at: fixedDate.addingTimeInterval(30))
        for _ in 0..<1_000 where api.logCalls.isEmpty {
            await Task.yield()
        }

        XCTAssertEqual(api.logCalls.count, 1)
        XCTAssertEqual(api.logCalls.first?.body.exercise_id, timed.exercise_id)
        XCTAssertEqual(api.logCalls.first?.body.is_timed, true)
        XCTAssertEqual(api.logCalls.first?.body.duration_s, 30)
    }

    func testRepSetDoesNotCompleteSameSlotAfterTimedModeFlip() {
        let defaults = defaults()
        let rep = exercise(
            id: "slot-a", exerciseID: "exercise-a", targetSets: 1)
        let timed = exercise(
            id: "slot-a", exerciseID: "exercise-a",
            timed: true, targetSets: 1)
        let s = session(status: "in_progress", attempt: 0)
        let body = SetRequestBody(
            id: fixedUUID.uuidString,
            exercise_id: rep.exercise_id,
            template_exercise_id: rep.id,
            set_index: 1,
            weight: 100,
            reps: 5,
            is_warmup: false,
            logged_at: 2_000_000_000_000,
            duration_s: nil,
            is_timed: false)
        let model = SyncModel(
            auth: retainedAuth(defaults: defaults),
            defaults: defaults,
            now: { self.fixedDate })

        model.replaceState(with: state(
            session: s,
            sets: [setLog(body: body, sessionID: s.id)],
            exercise: timed))
        model.startWorkout()

        XCTAssertTrue(model.todaySlotSets(timed).isEmpty)
        XCTAssertEqual(model.runnerSetsDone(timed), 0)
        XCTAssertEqual(model.currentSetNumber, 1)
        XCTAssertFalse(model.finished)
    }

    func testLegacyRepSetWithIncidentalDurationStillCompletesRepSlot() {
        let defaults = defaults()
        let rep = exercise(
            id: "slot-a", exerciseID: "exercise-a", targetSets: 1)
        let s = session(status: "in_progress", attempt: 0)
        let legacy = SetLog(
            id: fixedUUID.uuidString,
            session_id: s.id,
            exercise_id: rep.exercise_id,
            template_exercise_id: rep.id,
            set_index: 1,
            weight: 100,
            reps: 5,
            rpe: nil,
            is_warmup: 0,
            logged_at: 2_000_000_000_000,
            duration_s: 12,
            is_timed: nil,
            deleted_at: nil)
        let model = SyncModel(
            auth: retainedAuth(defaults: defaults),
            defaults: defaults,
            now: { self.fixedDate })
        model.catalog = [ExerciseCatalog(
            id: rep.exercise_id,
            name: rep.exercise_name,
            primary_muscle: "legs",
            modality: "barbell",
            unit: "lb",
            laterality: "bilateral",
            load_mode: "total",
            demo_slug: nil)]

        model.replaceState(with: state(
            session: s, sets: [legacy], exercise: rep))

        XCTAssertEqual(model.todaySlotSets(rep).map(\.id), [legacy.id])
        XCTAssertEqual(model.setsDone(rep), 1)
        XCTAssertTrue(model.isComplete(rep))
    }

    func testLegacyTimedCatalogSetStillCompletesTimedSlot() {
        let defaults = defaults()
        let timed = exercise(
            id: "slot-a", exerciseID: "exercise-a",
            timed: true, targetSets: 1)
        let s = session(status: "in_progress", attempt: 0)
        let legacy = SetLog(
            id: fixedUUID.uuidString,
            session_id: s.id,
            exercise_id: timed.exercise_id,
            template_exercise_id: timed.id,
            set_index: 1,
            weight: 0,
            reps: 30,
            rpe: nil,
            is_warmup: 0,
            logged_at: 2_000_000_000_000,
            duration_s: 30,
            is_timed: nil,
            deleted_at: nil)
        let model = SyncModel(
            auth: retainedAuth(defaults: defaults),
            defaults: defaults,
            now: { self.fixedDate })
        model.catalog = [ExerciseCatalog(
            id: timed.exercise_id,
            name: timed.exercise_name,
            primary_muscle: "core",
            modality: "timed",
            unit: "seconds",
            laterality: "bilateral",
            load_mode: "total",
            demo_slug: nil)]

        model.replaceState(with: state(
            session: s, sets: [legacy], exercise: timed))

        XCTAssertEqual(model.todaySlotSets(timed).map(\.id), [legacy.id])
        XCTAssertEqual(model.setsDone(timed), 1)
        XCTAssertTrue(model.isComplete(timed))
    }

    func testTimedHistoryDoesNotSeedRepInputsAfterModeFlip() async {
        let defaults = defaults()
        let timed = exercise(
            id: "slot-a", exerciseID: "exercise-a",
            timed: true, targetSets: 2)
        let rep = exercise(
            id: "slot-a", exerciseID: "exercise-a", targetSets: 2)
        let s = session(status: "in_progress", attempt: 0)
        let timedBody = SetRequestBody(
            id: "22222222-2222-4222-8222-222222222222",
            exercise_id: timed.exercise_id,
            template_exercise_id: timed.id,
            set_index: 1,
            weight: 0,
            reps: 30,
            is_warmup: false,
            logged_at: 1_999_999_999_000,
            duration_s: 30,
            is_timed: true)
        let api = SetWriteAPIStub()
        api.logHandler = { [self] sessionID, body, _ in
            .init(
                set: setLog(body: body, sessionID: sessionID),
                deduped: false,
                session: s)
        }
        api.stateHandler = { [self] _ in
            state(
                session: s,
                sets: [setLog(body: timedBody, sessionID: s.id)],
                exercise: rep)
        }
        let model = SyncModel(
            auth: retainedAuth(defaults: defaults), setWriteAPI: api,
            defaults: defaults, uuidFactory: { self.fixedUUID },
            now: { self.fixedDate })
        model.catalog = [ExerciseCatalog(
            id: timed.exercise_id,
            name: timed.exercise_name,
            primary_muscle: "core",
            modality: "barbell",
            unit: "lb",
            laterality: "bilateral",
            load_mode: "total",
            demo_slug: nil)]
        model.replaceState(with: state(
            session: s,
            sets: [setLog(body: timedBody, sessionID: s.id)],
            exercise: timed))
        model.startWorkout()

        model.replaceState(with: state(
            session: s,
            sets: [setLog(body: timedBody, sessionID: s.id)],
            exercise: rep))

        XCTAssertEqual(model.currentExercise?.id, rep.id)
        XCTAssertEqual(model.runnerSetsDone(rep), 0)
        XCTAssertEqual(model.currentSetNumber, 1)
        XCTAssertEqual(model.weight, rep.target_weight)
        XCTAssertEqual(model.reps, rep.target_reps)

        await model.logCurrentSet(expected: rep, expectedSetNumber: 1)
        for _ in 0..<1_000 where api.logCalls.isEmpty {
            await Task.yield()
        }

        XCTAssertEqual(api.logCalls.count, 1)
        XCTAssertEqual(api.logCalls.first?.body.weight, rep.target_weight)
        XCTAssertEqual(api.logCalls.first?.body.reps, rep.target_reps)
        XCTAssertEqual(api.logCalls.first?.body.is_timed, false)
    }

    func testAccountDeletionPendingBlocksNewRunnerAndCancelsActiveHold() async {
        let defaults = defaults()
        let timed = exercise(timed: true, targetSets: 1)
        let s = session(status: "in_progress", attempt: 0)
        let deletionEntered = SetAsyncLatch()
        let deletionRelease = SetAsyncLatch()
        let authAPI = SetAuthAPIStub()
        authAPI.deletionHandler = { _, _ in
            await deletionEntered.open()
            await deletionRelease.wait()
            throw URLError(.notConnectedToInternet)
        }
        let auth = auth(defaults: defaults, api: authAPI)
        let setAPI = SetWriteAPIStub()
        let active = SyncModel(
            auth: auth, setWriteAPI: setAPI,
            defaults: defaults, now: { self.fixedDate })
        active.replaceState(with: state(
            session: s, sets: [], exercise: timed))
        active.startWorkout()
        active.startTimedSet(
            expected: timed, expectedSetNumber: 1, at: fixedDate)
        XCTAssertTrue(active.timedActive)

        let blocked = SyncModel(
            auth: auth, setWriteAPI: setAPI,
            defaults: defaults, now: { self.fixedDate })
        blocked.plan = active.plan
        blocked.selectedDayID = "day-a"
        blocked.todaySession = s

        let deletion = Task { try? await auth.deleteAccount() }
        await deletionEntered.wait()
        XCTAssertTrue(auth.accountDeletionPending)
        XCTAssertNil(auth.featureJWT)

        blocked.startWorkout()
        blocked.startTimedSet(
            expected: timed, expectedSetNumber: 1, at: fixedDate)
        await active.finishTimedSetIfDue(
            at: fixedDate.addingTimeInterval(30))

        XCTAssertFalse(blocked.running)
        XCTAssertFalse(blocked.timedActive)
        XCTAssertFalse(active.timedActive)
        XCTAssertTrue(setAPI.logCalls.isEmpty)
        XCTAssertTrue(active.setOutbox.isEmpty)

        await deletionRelease.open()
        await deletion.value
    }

    func testExpiredRestArtifactOwnerDoesNotFenceANewDefaultsNamespace() {
        weak var expiredDefaults: LocalPersistence?
        let owner = autoreleasepool { () -> RunnerArtifactOwnership.Owner in
            let oldDefaults = defaults()
            expiredDefaults = oldDefaults
            return RunnerArtifactOwnership.Owner(defaults: oldDefaults, id: UUID(), featureSessionEpoch: 9)
        }
        XCTAssertNil(expiredDefaults)
        XCTAssertTrue(owner.permitsClaim(featureSessionEpoch: 0, defaults: defaults()))
    }

    func testLiveRestArtifactOwnerRetainsItsEpochFence() {
        let namespace = defaults()
        let owner = RunnerArtifactOwnership.Owner(defaults: namespace, id: UUID(), featureSessionEpoch: 9)
        XCTAssertFalse(owner.permitsClaim(featureSessionEpoch: 8, defaults: namespace))
        XCTAssertTrue(owner.permitsClaim(featureSessionEpoch: 9, defaults: namespace))
        XCTAssertTrue(owner.permitsClaim(featureSessionEpoch: 10, defaults: namespace))
        XCTAssertFalse(owner.permitsClaim(featureSessionEpoch: 10, defaults: defaults()))
    }

    func testSignOutEndsOwnedRestArtifactsAndPreservesRunnerCheckpoint() {
        let defaults = defaults()
        let ex = exercise()
        let activeSession = session(status: "in_progress", attempt: 0)
        let auth = auth(defaults: defaults)
        var endedLiveActivities = 0
        var cancelledNotifications = 0
        let model = SyncModel(
            auth: auth, defaults: defaults, now: { self.fixedDate },
            restActivityEnder: { endedLiveActivities += 1 },
            restNotificationCanceller: { cancelledNotifications += 1 })
        prepare(
            model, exercise: ex, session: activeSession, running: true)
        model.restEndDate = fixedDate.addingTimeInterval(90)

        auth.signOut()

        XCTAssertNil(model.restEndDate)
        XCTAssertEqual(endedLiveActivities, 1)
        XCTAssertEqual(cancelledNotifications, 1)
        XCTAssertNotNil(WorkoutRunnerCheckpointStore.load(
            userID: "user-a", defaults: defaults))
    }

    func testSuccessfulDeletionEndsOwnedRestArtifactsBeforeRequest() async {
        let defaults = defaults()
        let ex = exercise()
        let activeSession = session(status: "in_progress", attempt: 0)
        let deletionEntered = SetAsyncLatch()
        let deletionRelease = SetAsyncLatch()
        let authAPI = SetAuthAPIStub()
        authAPI.deletionHandler = { _, _ in
            await deletionEntered.open()
            await deletionRelease.wait()
            return .init(
                ok: true, owner_tombstoned: false,
                apple_revocation: .revoked)
        }
        let auth = auth(defaults: defaults, api: authAPI)
        var endedLiveActivities = 0
        var cancelledNotifications = 0
        let model = SyncModel(
            auth: auth, defaults: defaults, now: { self.fixedDate },
            restActivityEnder: { endedLiveActivities += 1 },
            restNotificationCanceller: { cancelledNotifications += 1 })
        prepare(
            model, exercise: ex, session: activeSession, running: true)
        model.restEndDate = fixedDate.addingTimeInterval(90)

        let deletion = Task { try? await auth.deleteAccount() }
        await deletionEntered.wait()

        XCTAssertTrue(auth.accountDeletionPending)
        XCTAssertNil(model.restEndDate)
        XCTAssertEqual(endedLiveActivities, 1)
        XCTAssertEqual(cancelledNotifications, 1)
        XCTAssertNotNil(WorkoutRunnerCheckpointStore.load(
            userID: "user-a", defaults: defaults))

        await deletionRelease.open()
        await deletion.value

        XCTAssertNil(WorkoutRunnerCheckpointStore.load(
            userID: "user-a", defaults: defaults))
        XCTAssertEqual(endedLiveActivities, 1)
        XCTAssertEqual(cancelledNotifications, 1)
    }

    func testAccountDeletionPendingBlocksResumeWithoutClearingCheckpoint() async {
        let defaults = defaults()
        let ex = exercise()
        let s = session(status: "in_progress", attempt: 0)
        WorkoutRunnerCheckpointStore.save(
            .init(
                date: fixedCivilDate,
                sessionID: s.id,
                selectedDayID: "day-a",
                currentSlotID: ex.id,
                skippedSlotIDs: [],
                workoutStartedAtMS: 2_000_000_000_000,
                finished: false,
                sessionAttempt: 0),
            userID: "user-a", defaults: defaults)
        let deletionEntered = SetAsyncLatch()
        let deletionRelease = SetAsyncLatch()
        let authAPI = SetAuthAPIStub()
        authAPI.deletionHandler = { _, _ in
            await deletionEntered.open()
            await deletionRelease.wait()
            throw URLError(.notConnectedToInternet)
        }
        let auth = auth(defaults: defaults, api: authAPI)
        let model = SyncModel(
            auth: auth, defaults: defaults, now: { self.fixedDate })
        model.replaceState(with: state(
            session: s, sets: [], exercise: ex))
        XCTAssertTrue(model.hasResumableWorkout)

        let deletion = Task { try? await auth.deleteAccount() }
        await deletionEntered.wait()
        model.resumeWorkout()

        XCTAssertFalse(model.running)
        XCTAssertTrue(model.hasResumableWorkout)
        XCTAssertNotNil(WorkoutRunnerCheckpointStore.load(
            userID: "user-a", defaults: defaults))

        await deletionRelease.open()
        await deletion.value
    }

    func testFailedRepIntentDoesNotBlockSameSlotAfterTimedModeFlip() {
        let defaults = defaults()
        let rep = exercise(
            id: "slot-a", exerciseID: "exercise-a", targetSets: 1)
        let timed = exercise(
            id: "slot-a", exerciseID: "exercise-a",
            timed: true, targetSets: 1)
        let s = session(status: "in_progress", attempt: 0)
        let body = SetRequestBody(
            id: fixedUUID.uuidString,
            exercise_id: rep.exercise_id,
            template_exercise_id: rep.id,
            set_index: 1,
            weight: 100,
            reps: 5,
            is_warmup: false,
            logged_at: 2_000_000_000_000,
            duration_s: nil,
            is_timed: false)
        var outbox = SetOutbox()
        outbox.enqueue(.init(
            body: body,
            date: fixedCivilDate,
            workoutID: "day-a",
            resolvedSessionID: s.id,
            deliveryState: .failed,
            failedHTTPStatus: 422,
            expectedAttempt: 0))
        SetOutboxStore.save(outbox, userID: "user-a", defaults: defaults)
        let model = SyncModel(
            auth: retainedAuth(defaults: defaults),
            defaults: defaults,
            now: { self.fixedDate })

        model.replaceState(with: state(
            session: s, sets: [], exercise: timed))

        XCTAssertTrue(model.pendingSetIntents(for: timed).isEmpty)
        XCTAssertFalse(model.isSetEntryBlocked(timed))
        XCTAssertEqual(model.runnerSetsDone(timed), 0)
    }

    func testSameSlotReplacementDoesNotInheritSkippedExercise() async {
        let defaults = defaults()
        let original = exercise(
            id: "slot-a", exerciseID: "exercise-original", targetSets: 1)
        let replacement = exercise(
            id: "slot-a", exerciseID: "exercise-replacement", targetSets: 1)
        let s = session(status: "in_progress")
        let setAPI = SetWriteAPIStub()
        setAPI.stateHandler = { [self] _ in
            state(session: s, sets: [], exercise: replacement)
        }
        let terminalAPI = SetTerminalAPIStub()
        let model = SyncModel(
            auth: retainedAuth(defaults: defaults),
            setWriteAPI: setAPI,
            terminalAPI: terminalAPI,
            catalogAPI: SetCatalogAPIStub(),
            defaults: defaults,
            now: { self.fixedDate })
        prepare(model, exercise: original, session: s, running: true)
        model.skip()
        XCTAssertTrue(model.finished)
        XCTAssertTrue(model.isSkipped(original))

        await model.load()

        XCTAssertEqual(model.currentExercise?.exercise_id, replacement.exercise_id)
        XCTAssertFalse(model.isSkipped(replacement))
        XCTAssertFalse(model.finished)
        await model.finishResolvedWorkout()
        XCTAssertTrue(model.terminalOutbox.isEmpty)
        XCTAssertTrue(terminalAPI.completeCalls.isEmpty)
    }

    func testNonActiveSameSlotReplacementDoesNotInheritSkip() async {
        let defaults = defaults()
        let original = exercise(
            id: "slot-a", exerciseID: "exercise-original", targetSets: 1)
        let replacement = exercise(
            id: "slot-a", exerciseID: "exercise-replacement", targetSets: 1)
        let active = exercise(
            id: "slot-b", exerciseID: "exercise-active", targetSets: 1)
        let s = session(status: "in_progress")
        let api = SetWriteAPIStub()
        api.stateHandler = { [self] _ in
            state(session: s, sets: [], exercises: [replacement, active])
        }
        let model = SyncModel(
            auth: retainedAuth(defaults: defaults),
            setWriteAPI: api,
            catalogAPI: SetCatalogAPIStub(),
            defaults: defaults,
            now: { self.fixedDate })
        model.replaceState(with: state(
            session: s, sets: [], exercises: [original, active]))
        model.startWorkout()
        model.skip()
        XCTAssertEqual(model.currentExercise?.id, active.id)
        XCTAssertTrue(model.isSkipped(original))

        await model.load()
        model.skip()

        XCTAssertEqual(model.currentExercise?.exercise_id, replacement.exercise_id)
        XCTAssertFalse(model.isSkipped(replacement))
        XCTAssertFalse(model.finished)
    }

    func testColdCheckpointDropsSkipWithoutPriorPlanIdentity() async {
        let defaults = defaults()
        let replacement = exercise(
            id: "slot-a", exerciseID: "exercise-replacement", targetSets: 1)
        let active = exercise(
            id: "slot-b", exerciseID: "exercise-active", targetSets: 1)
        let s = session(status: "in_progress", attempt: 0)
        WorkoutRunnerCheckpointStore.save(
            .init(
                date: fixedCivilDate,
                sessionID: s.id,
                selectedDayID: "day-a",
                currentSlotID: active.id,
                skippedSlotIDs: [replacement.id],
                workoutStartedAtMS: 2_000_000_000_000,
                finished: false,
                sessionAttempt: 0),
            userID: "user-a",
            defaults: defaults)
        let api = SetWriteAPIStub()
        api.stateHandler = { [self] _ in
            state(session: s, sets: [], exercises: [replacement, active])
        }
        let model = SyncModel(
            auth: retainedAuth(defaults: defaults),
            setWriteAPI: api,
            catalogAPI: SetCatalogAPIStub(),
            defaults: defaults,
            now: { self.fixedDate })
        XCTAssertNil(model.plan)

        await model.load()

        XCTAssertEqual(
            WorkoutRunnerCheckpointStore.load(
                userID: "user-a", defaults: defaults)?.skippedSlotIDs,
            [])
        XCTAssertTrue(model.hasResumableWorkout)
        model.resumeWorkout()
        XCTAssertEqual(model.currentExercise?.id, active.id)
        model.skip()
        XCTAssertEqual(model.currentExercise?.id, replacement.id)
        XCTAssertFalse(model.finished)
    }

    func testLiveWarmupFlipCancelsOriginalTimedAttempt() async {
        let defaults = defaults()
        let original = exercise(timed: true, targetSets: 1)
        let replacement = exercise(timed: true, targetSets: 1, warmup: true)
        let s = session()
        let api = SetWriteAPIStub()
        api.stateHandler = { [self] _ in
            state(session: s, sets: [], exercise: replacement)
        }
        let model = SyncModel(
            auth: retainedAuth(defaults: defaults),
            setWriteAPI: api,
            catalogAPI: SetCatalogAPIStub(),
            defaults: defaults,
            now: { self.fixedDate })
        prepare(model, exercise: original, session: s, running: true)
        model.startTimedSet(
            expected: original, expectedSetNumber: model.currentSetNumber)
        XCTAssertTrue(model.timedActive)

        await model.load()

        XCTAssertTrue(model.currentExercise?.isWarmup == true)
        XCTAssertFalse(model.timedActive)
        await model.finishTimedSetIfDue(at: fixedDate.addingTimeInterval(30))
        XCTAssertTrue(api.logCalls.isEmpty)
        XCTAssertTrue(model.setOutbox.isEmpty)
    }

    func testManualScheduleWriteUsesCurrentPlanVersionAndReloadsSharedTree() async {
        let defaults = defaults()
        let ex = exercise()
        let s = session(status: "planned", attempt: 0)
        let routineAPI = SetRoutineEditingAPIStub()
        var capturedWeek: [String: String] = [:]
        var capturedPlanID: String?
        var capturedVersion: Int?
        routineAPI.scheduleHandler = { week, planID, version, _ in
            capturedWeek = week
            capturedPlanID = planID
            capturedVersion = version
            return APIClient.ScheduleWriteResult(
                ok: true,
                version: 2,
                schedule: PlanSchedule(version: 2, week: ["mon": "day-a"]))
        }
        let stateAPI = SetWriteAPIStub()
        let meta = #"{"schedule":{"version":2,"week":{"mon":"day-a","tue":null,"wed":null,"thu":null,"fri":null,"sat":null,"sun":null}}}"#
        stateAPI.stateHandler = { [self] _ in
            state(
                session: s, sets: [], workouts: [day(with: [ex])],
                planVersion: 2, planMeta: meta)
        }
        let model = SyncModel(
            auth: retainedAuth(defaults: defaults),
            setWriteAPI: stateAPI,
            catalogAPI: SetCatalogAPIStub(),
            routineEditingAPI: routineAPI,
            defaults: defaults,
            now: { self.fixedDate })
        model.replaceState(with: state(
            session: s, sets: [], workouts: [day(with: [ex])]))

        await model.saveRecurringSchedule(["mon": "day-a", "tue": ""])

        XCTAssertEqual(capturedPlanID, "plan-a")
        XCTAssertEqual(capturedVersion, 1)
        XCTAssertEqual(capturedWeek["mon"], "day-a")
        XCTAssertEqual(model.plan?.version, 2)
        XCTAssertEqual(model.plan?.schedule?.templateID(forWeekdayKey: "mon"), "day-a")
    }

    func testUnscheduleKeepsWorkoutAndDatedSessionAndOtherWeekdays() async {
        let defaults = defaults()
        let s = session(status: "planned", attempt: 3)
        let workouts = [day(with: [exercise()])]
        let before = #"{"schedule":{"version":1,"week":{"mon":"day-a","thu":"day-a","fri":"other"}}}"#
        let after = #"{"schedule":{"version":1,"week":{"mon":null,"thu":null,"fri":"other"}}}"#
        let routineAPI = SetRoutineEditingAPIStub()
        routineAPI.scheduleHandler = { week, planID, version, _ in
            XCTAssertEqual(planID, "plan-a"); XCTAssertEqual(version, 1)
            XCTAssertEqual(week["mon"], ""); XCTAssertEqual(week["thu"], "")
            XCTAssertEqual(week["fri"], "other")
            return APIClient.ScheduleWriteResult(ok: true, version: 2,
                schedule: PlanSchedule(version: 1, week: ["fri": "other"]))
        }
        let stateAPI = SetWriteAPIStub()
        stateAPI.stateHandler = { [self] _ in
            state(session: s, sets: [], workouts: workouts, planVersion: 2, planMeta: after)
        }
        let model = SyncModel(auth: retainedAuth(defaults: defaults), setWriteAPI: stateAPI,
            catalogAPI: SetCatalogAPIStub(), routineEditingAPI: routineAPI,
            defaults: defaults, now: { self.fixedDate })
        model.replaceState(with: state(session: s, sets: [], workouts: workouts, planMeta: before))
        await model.unscheduleWorkout(workoutID: "day-a")
        XCTAssertEqual(model.plan?.workouts, workouts)
        XCTAssertEqual(model.sessionsByDate[fixedCivilDate]?.attempt, 3)
        XCTAssertEqual(routineAPI.scheduleCalls, 1)
        XCTAssertEqual(routineAPI.deleteDayCalls, 0)
        XCTAssertEqual(routineAPI.calendarCalls, 0)
        await model.unscheduleWorkout(workoutID: "day-a")
        XCTAssertEqual(routineAPI.scheduleCalls, 1)
    }

    func testHistoryRestorePinsReviewedPlanIdentityAndVersionAndKeepsAcknowledgement() async {
        let defaults = defaults()
        let routineAPI = SetRoutineEditingAPIStub()
        var captured: (Int, String, Int, String?)?
        routineAPI.restoreHandler = { version, planID, expectedVersion, reason, _ in
            captured = (version, planID, expectedVersion, reason)
            return APIClient.RestorePlanResult(
                ok: true, plan_id: planID, restored_from_version: version,
                version: expectedVersion + 1)
        }
        let stateAPI = SetWriteAPIStub()
        stateAPI.stateHandler = { _ in throw URLError(.cannotConnectToHost) }
        let model = SyncModel(
            auth: retainedAuth(defaults: defaults),
            setWriteAPI: stateAPI,
            catalogAPI: SetCatalogAPIStub(),
            routineEditingAPI: routineAPI,
            defaults: defaults,
            now: { self.fixedDate })
        model.replaceState(with: state(
            session: session(status: "planned", attempt: 0), sets: [],
            workouts: [day(with: [exercise()])], planVersion: 11))

        let acknowledged = await model.restorePlanVersion(
            4, expectedPlanID: "plan-a", reviewedCurrentVersion: 9,
            reason: "Review restore")

        XCTAssertTrue(acknowledged)
        XCTAssertEqual(captured?.0, 4)
        XCTAssertEqual(captured?.1, "plan-a")
        XCTAssertEqual(captured?.2, 9)
        XCTAssertEqual(captured?.3, "Review restore")
        XCTAssertEqual(routineAPI.restoreCalls, 1)
        XCTAssertNotNil(model.loadError)
    }

    func testHistoryConflictIsNotAnAcknowledgedRestoreAndReloadsLatestState() async {
        let defaults = defaults()
        let routineAPI = SetRoutineEditingAPIStub()
        routineAPI.restoreHandler = { _, _, _, _, _ in
            throw APIError.http(409, #"{"conflict":true,"current_version":12}"#)
        }
        let stateAPI = SetWriteAPIStub()
        stateAPI.stateHandler = { [self] _ in
            state(session: session(status: "planned", attempt: 0), sets: [],
                  workouts: [day(with: [exercise()])], planVersion: 12)
        }
        let model = SyncModel(
            auth: retainedAuth(defaults: defaults), setWriteAPI: stateAPI,
            catalogAPI: SetCatalogAPIStub(), routineEditingAPI: routineAPI,
            defaults: defaults, now: { self.fixedDate })
        model.replaceState(with: state(
            session: session(status: "planned", attempt: 0), sets: [],
            workouts: [day(with: [exercise()])], planVersion: 9))

        let acknowledged = await model.restorePlanVersion(
            4, expectedPlanID: "plan-a", reviewedCurrentVersion: 9, reason: nil)
        XCTAssertFalse(acknowledged)
        XCTAssertEqual(model.plan?.version, 12)
        XCTAssertEqual(routineAPI.restoreCalls, 1)
    }

    func testRecentChangesDismissalPersistsWithoutRemovingEitherActorFromHistory() async throws {
        let defaults = defaults()
        let api = SetRoutineEditingAPIStub()
        let items = [
            PlanHistoryItem(version: 3, actor: "ios", operation: "update_exercise", reason: "Manual correction",
                            created_at: 3, summary: nil, previous_version: 2, affected: ["A · Squat"]),
            PlanHistoryItem(version: 2, actor: "mcp", operation: "update_exercise", reason: "Feedback",
                            created_at: 2, summary: nil, previous_version: 1, affected: ["A · Squat"]),
        ]
        api.historyHandler = { _, _, _ in
            PlanHistoryResponse(plan_id: "plan-a", current_version: 3, items: items, next_before_version: nil)
        }
        let auth = retainedAuth(defaults: defaults)
        let model = SyncModel(auth: auth, routineEditingAPI: api, defaults: defaults)
        let saved = state(session: session(status: "planned", attempt: 0), sets: [],
                          workouts: [day(with: [exercise()])], planVersion: 3)
        model.replaceState(with: saved)
        await model.refreshRecentPlanChanges()
        XCTAssertEqual(model.recentPlanChanges.map(\.actor), ["ios", "mcp"])
        model.dismissRecentPlanChanges(through: 3, planID: "plan-a")
        XCTAssertTrue(model.recentPlanChanges.isEmpty)
        let reopened = SyncModel(auth: auth, routineEditingAPI: api, defaults: defaults)
        reopened.replaceState(with: saved)
        await reopened.refreshRecentPlanChanges()
        XCTAssertTrue(reopened.recentPlanChanges.isEmpty)
        let history = await reopened.loadPlanHistory()
        XCTAssertEqual(history?.items, items)
        api.historyHandler = { _, _, _ in
            PlanHistoryResponse(plan_id: "plan-a", current_version: 4,
                items: [PlanHistoryItem(version: 4, actor: "mcp", operation: "update_plan", reason: nil,
                                       created_at: 4, summary: nil)] + items, next_before_version: nil)
        }
        await reopened.refreshRecentPlanChanges()
        XCTAssertTrue(reopened.recentPlanChanges.isEmpty)
        XCTAssertNotNil(reopened.planChangesError)
        reopened.dismissRecentPlanChanges(through: 4, planID: "plan-a")
        XCTAssertEqual(PlanChangeDismissalStore.load(userID: auth.userID, planID: "plan-a", defaults: defaults), 3)
        reopened.replaceState(with: state(session: session(status: "planned", attempt: 0), sets: [],
            workouts: [day(with: [exercise()])], planVersion: 4))
        await reopened.refreshRecentPlanChanges()
        XCTAssertEqual(reopened.recentPlanChanges.map(\.version), [4])
        // A tap rendered before the newer response can dismiss only what it showed.
        reopened.dismissRecentPlanChanges(through: 3, planID: "plan-a")
        XCTAssertEqual(reopened.recentPlanChanges.map(\.version), [4])
        reopened.dismissRecentPlanChanges(through: 4, planID: "other-plan")
        XCTAssertEqual(reopened.recentPlanChanges.map(\.version), [4])
    }

    func testRecentHistoryRejectsLateAccountAndPlanResponsesAndSeparatesReadFailure() async {
        let defaults = defaults()
        let auth = retainedAuth(defaults: defaults)
        let api = SetRoutineEditingAPIStub()
        let model = SyncModel(auth: auth, routineEditingAPI: api, defaults: defaults)
        model.replaceState(with: state(session: session(status: "planned", attempt: 0), sets: [],
                                       workouts: [day(with: [exercise()])]))
        api.historyHandler = { _, _, _ in throw URLError(.notConnectedToInternet) }
        await model.refreshRecentPlanChanges()
        XCTAssertNotNil(model.planChangesError)
        XCTAssertNil(model.loadError)
        var response: CheckedContinuation<PlanHistoryResponse, Error>?
        api.historyHandler = { _, _, _ in try await withCheckedThrowingContinuation { response = $0 } }
        let request = Task { await model.refreshRecentPlanChanges() }
        while response == nil { await Task.yield() }
        model.plan = PlanTree(id: "different", name: "Other plan", version: 8, workouts: [], meta: nil)
        response?.resume(returning: PlanHistoryResponse(plan_id: "plan-a", current_version: 1,
            items: [], next_before_version: nil))
        await request.value
        XCTAssertNil(model.recentPlanHistory)
        response = nil
        let switched = Task { await model.refreshRecentPlanChanges() }
        while response == nil { await Task.yield() }
        auth.signOut()
        response?.resume(returning: PlanHistoryResponse(plan_id: "different", current_version: 8,
            items: [], next_before_version: nil))
        await switched.value
        XCTAssertNil(model.recentPlanHistory)
        XCTAssertTrue(model.recentPlanChanges.isEmpty)
    }

    func testDismissalIsAccountAndPlanScopedMonotonicAndDeletedWithAccount() {
        let defaults = defaults()
        PlanChangeDismissalStore.dismiss(through: 8, userID: "one", planID: "plan", defaults: defaults)
        PlanChangeDismissalStore.dismiss(through: 3, userID: "one", planID: "plan", defaults: defaults)
        XCTAssertEqual(PlanChangeDismissalStore.load(userID: "one", planID: "plan", defaults: defaults), 8)
        XCTAssertEqual(PlanChangeDismissalStore.load(userID: "two", planID: "plan", defaults: defaults), 0)
        XCTAssertEqual(PlanChangeDismissalStore.load(userID: "one", planID: "other", defaults: defaults), 0)
        AccountLocalState.clear(userID: "one", defaults: defaults)
        XCTAssertEqual(PlanChangeDismissalStore.load(userID: "one", planID: "plan", defaults: defaults), 0)
    }

    func testLegacyHistoryDecodesWithoutInventingRationaleOrPredecessor() throws {
        let item = try JSONDecoder().decode(PlanHistoryItem.self, from: Data(
            #"{"version":5,"actor":"mcp","operation":"update_exercise","created_at":100}"#.utf8))
        XCTAssertNil(item.previous_version)
        XCTAssertNil(item.affected)
        XCTAssertEqual(PlanHistoryPresentation.rationale(item), "No reason recorded.")
        XCTAssertEqual(PlanHistoryPresentation.actor("mcp"), "Coach")
        XCTAssertEqual(PlanHistoryPresentation.actor("ios"), "You")
    }

    func testPlanHistoryPresentationUsesReadableValuesWithoutStoragePaths() {
        let change = PlanVersionChange(
            kind: "exercise", path: "days.day-a.exercises.slot-a.target_weight",
            before: .number(7.5), after: .number(5))
        XCTAssertEqual(PlanHistoryPresentation.fieldName(for: change), "Target load")
        XCTAssertEqual(PlanHistoryPresentation.value(change.before), "7.5")
        XCTAssertEqual(PlanHistoryPresentation.value(change.after), "5")
    }

    func testPlanHistoryPresentationRendersSemanticComparisonObjectsWithoutIDs() {
        let schedule = PlanVersionChange(
            kind: "schedule", path: "Weekly schedule · tue",
            before: .object([
                "day_id": .string("7FC654CD-DA28-4FD8-94EE-596F72D1F1BC"),
                "day_name": .string("Pull"), "day_label": .string("B"),
            ]),
            after: .object([
                "day_id": .string("3B74C775-92DC-4E61-BC82-18E8AD640627"),
                "day_name": .string("Legs"), "day_label": .string("C"),
            ]))
        XCTAssertEqual(PlanHistoryPresentation.fieldName(for: schedule), "Weekly schedule · tue")
        XCTAssertEqual(PlanHistoryPresentation.value(schedule.before), "Workout: Pull, Label: B")
        XCTAssertEqual(PlanHistoryPresentation.value(schedule.after), "Workout: Legs, Label: C")

        let addedWorkout = JSONValue.object([
            "day_id": .string("internal-day-id"), "day_name": .string("Conditioning"),
            "exercises": .array([.object([
                "id": .string("internal-slot-id"), "exercise_id": .string("internal-catalog-id"),
                "exercise_name": .string("Stationary Bike"), "target_duration_s": .number(900),
                "target_sets": .number(1),
            ])]),
        ])
        let rendered = PlanHistoryPresentation.value(addedWorkout)
        XCTAssertTrue(rendered.contains("Workout: Conditioning"))
        XCTAssertTrue(rendered.contains("Exercise: Stationary Bike"))
        XCTAssertTrue(rendered.contains("Duration: 900"))
        XCTAssertFalse(rendered.contains("internal"))
    }

    func testPlanHistoryNumberFormattingDoesNotTrapOutsideSwiftIntRange() {
        XCTAssertEqual(JSONValue.number(1e100).displayText, "1e+100")
        XCTAssertEqual(JSONValue.number(-1e100).displayText, "-1e+100")
        XCTAssertEqual(JSONValue.number(9_007_199_254_740_991).displayText, "9007199254740991")
    }

    func testPlanHistoryKeepsDuplicateExercisePathsAsDistinctRows() {
        let duplicate = PlanVersionChange(
            kind: "exercise", path: "Strength · Bench Press",
            before: .number(100), after: .number(105))
        let rows = PlanHistoryPresentation.indexedChanges([duplicate, duplicate])
        XCTAssertEqual(rows.map(\.offset), [0, 1])
        XCTAssertEqual(rows.map(\.change), [duplicate, duplicate])
    }

    func testFirstManualDayPinsTheExactEnsuredPlanIdentityAndVersion() async {
        let defaults = defaults()
        let ex = exercise()
        let s = session(status: "planned", attempt: 0)
        let routineAPI = SetRoutineEditingAPIStub()
        var capturedPlanID: String?
        var capturedVersion: Int?
        routineAPI.addDayHandler = { name, planID, version, _ in
            XCTAssertEqual(name, "First day")
            capturedPlanID = planID
            capturedVersion = version
            return APIClient.WorkoutIDRow(id: "day-new")
        }
        let stateAPI = SetWriteAPIStub()
        stateAPI.stateHandler = { [self] _ in
            state(
                session: s, sets: [], workouts: [day(with: [ex])],
                planName: "Concurrent coach plan", planVersion: 8)
        }
        let model = SyncModel(
            auth: retainedAuth(defaults: defaults),
            setWriteAPI: stateAPI,
            catalogAPI: SetCatalogAPIStub(),
            routineEditingAPI: routineAPI,
            defaults: defaults,
            now: { self.fixedDate })
        model.replaceState(with: state(
            session: s, sets: [], workouts: [day(with: [ex])]))

        let dayID = await model.addWorkoutDay(
            name: "First day",
            expectedPlanID: "ensured-plan",
            expectedVersion: 1)

        XCTAssertEqual(dayID, "day-new")
        XCTAssertEqual(capturedPlanID, "ensured-plan")
        XCTAssertEqual(capturedVersion, 1)
        XCTAssertEqual(model.plan?.name, "Concurrent coach plan")
    }

    func testRoutineCreationRetryCompletesAnEmptyEnsuredPlan() {
        XCTAssertTrue(RoutineCreationPolicy.shouldAddFirstDay(
            wasCreated: false,
            ensuredPlanID: "plan-a",
            loadedPlanID: "plan-a",
            loadedDayCount: 0))
    }

    func testRoutineCreationRetryDoesNotAppendToANonemptyOrDifferentPlan() {
        XCTAssertFalse(RoutineCreationPolicy.shouldAddFirstDay(
            wasCreated: false,
            ensuredPlanID: "plan-a",
            loadedPlanID: "plan-a",
            loadedDayCount: 1))
        XCTAssertFalse(RoutineCreationPolicy.shouldAddFirstDay(
            wasCreated: true,
            ensuredPlanID: "plan-a",
            loadedPlanID: "plan-b",
            loadedDayCount: 0))
    }

    func testReplacementPinsSlotAndVersionThenAdoptsServerState() async {
        let defaults = defaults()
        let original = exercise(bodyweight: true)
        let replacement = exercise(exerciseID: "ring-row", bodyweight: true)
        let s = session(status: "planned", attempt: 0)
        let editor = SetPlanEditingAPIStub()
        editor.replaceHandler = { dayID, slotID, exerciseID, version, _ in
            XCTAssertEqual(dayID, "day-a")
            XCTAssertEqual(slotID, original.id)
            XCTAssertEqual(exerciseID, "ring-row")
            XCTAssertEqual(version, 1)
            return APIClient.SlotIDRow(id: original.id)
        }
        let api = SetWriteAPIStub()
        api.stateHandler = { [self] _ in
            state(session: s, sets: [], workouts: [day(with: [replacement])], planVersion: 2)
        }
        let model = SyncModel(auth: retainedAuth(defaults: defaults), setWriteAPI: api,
                              planEditingAPI: editor, defaults: defaults, now: { self.fixedDate })
        model.replaceState(with: state(session: s, sets: [], exercise: original))
        let saved = await model.replaceSlot(dayID: "day-a", teID: original.id,
                                            exercise: "ring-row", expectedVersion: 1)
        XCTAssertTrue(saved)
        XCTAssertEqual(editor.replaceCalls, 1)
        XCTAssertEqual(model.plan?.workouts[0].exercises[0].exercise_id, "ring-row")
        XCTAssertEqual(model.plan?.version, 2)
        XCTAssertFalse(model.workoutEditorRefreshNeeded)
    }

    func testAcknowledgedReplacementBlocksFurtherEditsWhenRefreshFails() async {
        let defaults = defaults()
        let ex = exercise(bodyweight: true)
        let s = session(status: "planned", attempt: 0)
        let editor = SetPlanEditingAPIStub()
        editor.replaceHandler = { _, _, _, _, _ in APIClient.SlotIDRow(id: ex.id) }
        let api = SetWriteAPIStub()
        api.stateHandler = { _ in throw URLError(.timedOut) }
        let model = SyncModel(auth: retainedAuth(defaults: defaults), setWriteAPI: api,
                              planEditingAPI: editor, defaults: defaults, now: { self.fixedDate })
        model.replaceState(with: state(session: s, sets: [], exercise: ex))
        let saved = await model.replaceSlot(dayID: "day-a", teID: ex.id,
                                            exercise: "ring-row", expectedVersion: 1)
        let repeated = await model.replaceSlot(dayID: "day-a", teID: ex.id,
                                               exercise: "ring-row", expectedVersion: 1)
        XCTAssertTrue(saved)
        XCTAssertFalse(repeated)
        XCTAssertEqual(editor.replaceCalls, 1)
        XCTAssertTrue(model.workoutEditorRefreshNeeded)
        XCTAssertNotNil(model.loadError)
        XCTAssertEqual(model.plan?.workouts[0].exercises[0], ex)
    }

    func testReplacementConflictRefreshesWithoutReapplyingStaleSelection() async {
        let defaults = defaults()
        let ex = exercise(bodyweight: true)
        let changed = exercise(bodyweight: true, targetSets: 5)
        let s = session(status: "planned", attempt: 0)
        let editor = SetPlanEditingAPIStub()
        editor.replaceHandler = { _, _, _, _, _ in
            throw APIError.http(409, #"{"conflict":true,"current_version":2}"#)
        }
        let api = SetWriteAPIStub()
        api.stateHandler = { [self] _ in
            state(session: s, sets: [], workouts: [day(with: [changed])], planVersion: 2)
        }
        let model = SyncModel(auth: retainedAuth(defaults: defaults), setWriteAPI: api,
                              planEditingAPI: editor, defaults: defaults, now: { self.fixedDate })
        model.replaceState(with: state(session: s, sets: [], exercise: ex))
        let saved = await model.replaceSlot(dayID: "day-a", teID: ex.id,
                                            exercise: "ring-row", expectedVersion: 1)
        XCTAssertFalse(saved)
        XCTAssertEqual(editor.replaceCalls, 1)
        XCTAssertEqual(model.plan?.workouts[0].exercises[0], changed)
        XCTAssertTrue(model.loadError?.contains("Workout changed") == true)
    }

    func testRejectedReplacementKeepsOriginalSlotAndErrorVisible() async {
        let defaults = defaults()
        let ex = exercise(bodyweight: true)
        let s = session(status: "planned", attempt: 0)
        let editor = SetPlanEditingAPIStub()
        editor.replaceHandler = { _, _, _, _, _ in
            throw APIError.http(400, #"{"error":"invalid_fields","fields":["target_weight"]}"#)
        }
        let model = SyncModel(auth: retainedAuth(defaults: defaults), setWriteAPI: SetWriteAPIStub(),
                              planEditingAPI: editor, defaults: defaults, now: { self.fixedDate })
        model.replaceState(with: state(session: s, sets: [], exercise: ex))
        let saved = await model.replaceSlot(dayID: "day-a", teID: ex.id,
                                            exercise: "bench", expectedVersion: 1)
        XCTAssertFalse(saved)
        XCTAssertNotNil(model.loadError)
        XCTAssertEqual(model.plan?.workouts[0].exercises[0], ex)
        XCTAssertFalse(model.workoutEditorRefreshNeeded)
    }

    func testReplacementAcknowledgementCannotMutateSignedOutModel() async {
        let defaults = defaults()
        let ex = exercise(bodyweight: true)
        let s = session(status: "planned", attempt: 0)
        let auth = retainedAuth(defaults: defaults)
        let entered = SetAsyncLatch()
        let release = SetAsyncLatch()
        let editor = SetPlanEditingAPIStub()
        editor.replaceHandler = { _, _, _, _, _ in
            await entered.open()
            await release.wait()
            return APIClient.SlotIDRow(id: ex.id)
        }
        let api = SetWriteAPIStub()
        let model = SyncModel(auth: auth, setWriteAPI: api, planEditingAPI: editor,
                              defaults: defaults, now: { self.fixedDate })
        model.replaceState(with: state(session: s, sets: [], exercise: ex))
        let task = Task { await model.replaceSlot(dayID: "day-a", teID: ex.id,
                                                  exercise: "ring-row", expectedVersion: 1) }
        await entered.wait()
        auth.signOut()
        await release.open()
        let saved = await task.value
        XCTAssertFalse(saved)
        XCTAssertEqual(api.stateCalls, 0)
        XCTAssertFalse(model.workoutEditorRefreshNeeded)
    }

    func testAcknowledgedExerciseAddSucceedsWhenPostMutationRefreshFails() async {
        let defaults = defaults()
        let ex = exercise()
        let s = session(status: "planned", attempt: 0)
        let editor = SetPlanEditingAPIStub()
        editor.addHandler = { APIClient.SlotIDRow(id: "slot-new") }
        let stateAPI = SetWriteAPIStub()
        stateAPI.stateHandler = { _ in throw URLError(.timedOut) }
        let model = SyncModel(
            auth: retainedAuth(defaults: defaults),
            setWriteAPI: stateAPI,
            planEditingAPI: editor,
            defaults: defaults,
            now: { self.fixedDate })
        model.replaceState(with: state(session: s, sets: [], exercise: ex))

        let saved = await model.addExerciseToDay(
            "day-a",
            exercise: ex.exercise_id,
            isWarmup: false,
            targetSets: 3,
            targetReps: 8,
            targetRepsMax: nil,
            restSeconds: 90,
            targetDurationS: nil)

        XCTAssertTrue(saved)
        XCTAssertEqual(editor.addCalls, 1)
        XCTAssertNotNil(model.loadError)
    }

    func testFailedTargetSaveReportsFailureAndKeepsErrorVisible() async {
        let defaults = defaults()
        let ex = exercise()
        let s = session(status: "planned", attempt: 0)
        let editor = SetPlanEditingAPIStub()
        editor.updateHandler = {
            throw APIError.http(500, #"{"error":"write_failed"}"#)
        }
        let model = SyncModel(
            auth: retainedAuth(defaults: defaults),
            setWriteAPI: SetWriteAPIStub(),
            planEditingAPI: editor,
            defaults: defaults,
            now: { self.fixedDate })
        model.replaceState(with: state(session: s, sets: [], exercise: ex))

        let saved = await model.updateSlot(
            dayID: "day-a",
            teID: ex.id,
            isWarmup: false,
            targetSets: 3,
            targetReps: 8,
            targetRepsMax: 12,
            restSeconds: 90,
            targetDurationS: nil)

        XCTAssertFalse(saved)
        XCTAssertEqual(editor.updateCalls, 1)
        XCTAssertNotNil(model.loadError)
        XCTAssertTrue(model.loadError?.contains("write_failed") == true)
        XCTAssertFalse(model.workoutEditorRefreshNeeded)
    }

    func testAcknowledgedTargetSaveSucceedsWhenPostMutationRefreshFails() async {
        let defaults = defaults()
        let ex = exercise()
        let s = session(status: "planned", attempt: 0)
        let editor = SetPlanEditingAPIStub()
        editor.updateHandler = { APIClient.SlotIDRow(id: ex.id) }
        let stateAPI = SetWriteAPIStub()
        stateAPI.stateHandler = { _ in throw URLError(.timedOut) }
        let model = SyncModel(
            auth: retainedAuth(defaults: defaults),
            setWriteAPI: stateAPI,
            planEditingAPI: editor,
            defaults: defaults,
            now: { self.fixedDate })
        model.replaceState(with: state(session: s, sets: [], exercise: ex))

        let saved = await model.updateSlot(
            dayID: "day-a",
            teID: ex.id,
            isWarmup: false,
            targetSets: 4,
            targetReps: 10,
            targetRepsMax: nil,
            restSeconds: 90,
            targetDurationS: nil)

        XCTAssertTrue(saved)
        XCTAssertEqual(editor.updateCalls, 1)
        XCTAssertNotNil(model.loadError)
        XCTAssertTrue(model.workoutEditorRefreshNeeded)
        XCTAssertEqual(model.plan?.workouts[0].exercises[0].target_reps, ex.target_reps)
    }

    func testTargetSaveRefreshFailureCanReconcileNewerStateWithoutSecondWrite() async {
        let defaults = defaults()
        let original = exercise(targetSets: 3)
        let coachUpdate = exercise(targetSets: 6)
        let s = session(status: "planned", attempt: 0)
        let editor = SetPlanEditingAPIStub()
        editor.updateHandler = { APIClient.SlotIDRow(id: original.id) }
        let stateAPI = SetWriteAPIStub()
        stateAPI.stateHandler = { [self] _ in
            if stateAPI.stateCalls == 1 { throw URLError(.timedOut) }
            return state(
                session: s,
                sets: [],
                workouts: [day(with: [coachUpdate])],
                planVersion: 3)
        }
        let model = SyncModel(
            auth: retainedAuth(defaults: defaults),
            setWriteAPI: stateAPI,
            planEditingAPI: editor,
            defaults: defaults,
            now: { self.fixedDate })
        model.replaceState(with: state(session: s, sets: [], exercise: original))

        let saved = await model.updateSlot(
            dayID: "day-a",
            teID: original.id,
            isWarmup: false,
            targetSets: 4,
            targetReps: 10,
            targetRepsMax: nil,
            restSeconds: 90,
            targetDurationS: nil)

        XCTAssertTrue(saved)
        XCTAssertNotNil(model.loadError)
        XCTAssertTrue(model.workoutEditorRefreshNeeded)
        XCTAssertEqual(editor.updateCalls, 1)
        XCTAssertEqual(model.plan?.workouts[0].exercises[0].target_sets, 3)

        await model.load()

        XCTAssertNil(model.loadError)
        XCTAssertFalse(model.workoutEditorRefreshNeeded)
        XCTAssertEqual(stateAPI.stateCalls, 2)
        XCTAssertEqual(editor.updateCalls, 1)
        XCTAssertEqual(model.plan?.version, 3)
        XCTAssertEqual(model.plan?.workouts[0].exercises[0].target_sets, 6)
    }

    func testUnrelatedErrorDoesNotRequireWorkoutEditorRefresh() {
        let defaults = defaults()
        let model = SyncModel(
            auth: retainedAuth(defaults: defaults),
            setWriteAPI: SetWriteAPIStub(),
            defaults: defaults,
            now: { self.fixedDate })

        model.loadError = "A different operation failed."

        XCTAssertNotNil(model.loadError)
        XCTAssertFalse(model.workoutEditorRefreshNeeded)
    }

    func testDeletingActiveWorkoutDayShowsActionableConflict() async {
        let defaults = defaults()
        let ex = exercise()
        let s = session(status: "in_progress", attempt: 0)
        let routineAPI = SetRoutineEditingAPIStub()
        routineAPI.deleteDayHandler = { _, _, _ in
            throw APIError.http(409, #"{"error":"day_in_progress"}"#)
        }
        let stateAPI = SetWriteAPIStub()
        stateAPI.stateHandler = { [self] _ in
            state(session: s, sets: [], exercise: ex)
        }
        let model = SyncModel(
            auth: retainedAuth(defaults: defaults),
            setWriteAPI: stateAPI,
            catalogAPI: SetCatalogAPIStub(),
            routineEditingAPI: routineAPI,
            defaults: defaults,
            now: { self.fixedDate })
        model.replaceState(with: state(session: s, sets: [], exercise: ex))

        await model.deleteWorkoutDay(dayID: "day-a")

        XCTAssertEqual(
            model.loadError,
            "Finish or discard the active workout before removing this workout day.")
    }

    func testDeletingLocallyRunningWorkoutDayIsBlockedBeforeServerSessionStarts() async {
        let defaults = defaults()
        let ex = exercise()
        let planned = session(status: "planned", attempt: 0)
        let routineAPI = SetRoutineEditingAPIStub()
        routineAPI.deleteDayHandler = { _, _, _ in
            XCTFail("A locally running day must not reach deletion")
            return APIClient.DeleteWorkoutResult(ok: true, version: 2)
        }
        let model = SyncModel(
            auth: retainedAuth(defaults: defaults),
            setWriteAPI: SetWriteAPIStub(),
            catalogAPI: SetCatalogAPIStub(),
            routineEditingAPI: routineAPI,
            defaults: defaults,
            now: { self.fixedDate })
        model.replaceState(with: state(
            session: planned, sets: [], workouts: [day(with: [ex])]))
        model.startWorkout()
        XCTAssertTrue(model.running)

        await model.deleteWorkoutDay(dayID: "day-a")

        XCTAssertEqual(routineAPI.deleteDayCalls, 0)
        XCTAssertTrue(model.running)
        XCTAssertEqual(
            model.loadError,
            "Finish or discard the active workout before removing this workout day.")
    }

    func testManualCalendarOverrideUsesAttemptAndDoesNotChangePlanVersion() async {
        let defaults = defaults()
        let ex = exercise()
        let original = session(status: "planned", attempt: 3)
        let skipped = SessionRow(
            id: original.id,
            date: original.date,
            status: "skipped",
            workout_id: original.workout_id,
            updated_at: 2_000_000_000_100,
            attempt: 3)
        let routineAPI = SetRoutineEditingAPIStub()
        var capturedAttempt: Int?
        routineAPI.calendarHandler = { date, dayID, attempt, _ in
            XCTAssertEqual(date, self.fixedCivilDate)
            XCTAssertNil(dayID)
            capturedAttempt = attempt
            return APIClient.CalendarWriteResult(ok: true, session: skipped)
        }
        let stateAPI = SetWriteAPIStub()
        stateAPI.stateHandler = { [self] _ in
            state(session: skipped, sets: [], workouts: [day(with: [ex])])
        }
        let model = SyncModel(
            auth: retainedAuth(defaults: defaults),
            setWriteAPI: stateAPI,
            catalogAPI: SetCatalogAPIStub(),
            routineEditingAPI: routineAPI,
            defaults: defaults,
            now: { self.fixedDate })
        model.replaceState(with: state(
            session: original, sets: [], workouts: [day(with: [ex])]))

        await model.setCalendarOverride(date: fixedCivilDate, dayID: nil)

        XCTAssertEqual(capturedAttempt, 3)
        XCTAssertEqual(model.plan?.version, 1)
        XCTAssertEqual(model.sessionsByDate[fixedCivilDate]?.status, "skipped")
    }

    func testManualCalendarOverrideUsesZeroAsTheNoAssignmentToken() async {
        let defaults = defaults()
        let ex = exercise()
        let original = session(status: "planned", attempt: 3)
        let futureDate = "2037-01-05"
        let created = SessionRow(
            id: "future-session", date: futureDate,
            status: "planned", workout_id: "day-a", attempt: 1)
        let routineAPI = SetRoutineEditingAPIStub()
        var capturedAttempt: Int?
        routineAPI.calendarHandler = { date, dayID, attempt, _ in
            XCTAssertEqual(date, futureDate)
            XCTAssertEqual(dayID, "day-a")
            capturedAttempt = attempt
            return APIClient.CalendarWriteResult(ok: true, session: created)
        }
        let stateAPI = SetWriteAPIStub()
        stateAPI.stateHandler = { [self] _ in
            state(session: original, sets: [], workouts: [day(with: [ex])])
        }
        let model = SyncModel(
            auth: retainedAuth(defaults: defaults),
            setWriteAPI: stateAPI,
            catalogAPI: SetCatalogAPIStub(),
            routineEditingAPI: routineAPI,
            defaults: defaults,
            now: { self.fixedDate })
        model.replaceState(with: state(
            session: original, sets: [], workouts: [day(with: [ex])]))

        await model.setCalendarOverride(date: futureDate, dayID: "day-a")

        XCTAssertEqual(capturedAttempt, 0)
        XCTAssertEqual(routineAPI.calendarCalls, 1)
    }

    func testHardBlackoutBlocksCalendarOverrideBeforeServerWrite() async {
        let defaults = defaults()
        let ex = exercise()
        let original = session(status: "planned", attempt: 0)
        let blackoutDate = "2037-01-06"
        let planMeta = """
        {"trips":[{"id":"trip-a","start":"\(blackoutDate)",
        "end":"\(blackoutDate)","type":"travel","can_train_light":false}]}
        """
        let routineAPI = SetRoutineEditingAPIStub()
        routineAPI.calendarHandler = { _, _, _, _ in
            XCTFail("A hard-blackout date must not reach the calendar writer")
            return APIClient.CalendarWriteResult(ok: true, session: original)
        }
        let model = SyncModel(
            auth: retainedAuth(defaults: defaults),
            setWriteAPI: SetWriteAPIStub(),
            catalogAPI: SetCatalogAPIStub(),
            routineEditingAPI: routineAPI,
            defaults: defaults,
            now: { self.fixedDate })
        model.replaceState(with: state(
            session: original,
            sets: [],
            workouts: [day(with: [ex])],
            planMeta: planMeta))

        await model.setCalendarOverride(date: blackoutDate, dayID: "day-a")

        XCTAssertEqual(routineAPI.calendarCalls, 0)
        XCTAssertEqual(
            model.loadError,
            "This date is unavailable while the hard travel blackout is active.")
    }

    func testManualCalendarOverrideBlocksTodayWhileLocalRunnerIsActive() async {
        let defaults = defaults()
        let ex = exercise()
        let original = session(status: "planned", attempt: 0)
        let routineAPI = SetRoutineEditingAPIStub()
        routineAPI.calendarHandler = { _, _, _, _ in
            XCTFail("A running workout must fence out today's calendar override")
            return APIClient.CalendarWriteResult(ok: true, session: original)
        }
        let model = SyncModel(
            auth: retainedAuth(defaults: defaults),
            setWriteAPI: SetWriteAPIStub(),
            catalogAPI: SetCatalogAPIStub(),
            routineEditingAPI: routineAPI,
            defaults: defaults,
            now: { self.fixedDate })
        model.replaceState(with: state(
            session: original, sets: [], workouts: [day(with: [ex])]))
        model.startWorkout()
        XCTAssertTrue(model.running)

        await model.setCalendarOverride(date: fixedCivilDate, dayID: nil)

        XCTAssertEqual(routineAPI.calendarCalls, 0)
        XCTAssertEqual(
            model.loadError,
            "Finish or discard the active workout before changing today's assignment.")
    }

    func testScheduleDraftSurvivesUnrelatedReloadAndReconcilesRealScheduleChanges() {
        let ex = exercise()
        let meta = #"{"schedule":{"version":1,"week":{"mon":"day-a","tue":null}}}"#
        let original = PlanTree(
            id: "plan-a", name: "Plan A", version: 1,
            workouts: [day(with: [ex])], meta: meta)
        let unrelatedPlanEdit = PlanTree(
            id: "plan-a", name: "Renamed", version: 2,
            workouts: [day(with: [])], meta: meta)
        let removedWorkout = PlanTree(
            id: "plan-a", name: "Renamed", version: 3,
            workouts: [], meta: meta)
        let changedWeek = PlanTree(
            id: "plan-a", name: "Renamed", version: 3,
            workouts: [day(with: [])],
            meta: #"{"schedule":{"version":1,"week":{"mon":null,"tue":"day-a"}}}"#)
        let replacement = PlanTree(
            id: "plan-b", name: "Plan B", version: 1,
            workouts: [day(with: [ex])], meta: meta)

        let initial = RoutineScheduleDraftPolicy.reconcile(
            currentDraft: [:], loadedIdentity: [], plan: original)
        var unsaved = initial.draft
        unsaved["wed"] = "day-a"
        let unrelated = RoutineScheduleDraftPolicy.reconcile(
            currentDraft: unsaved,
            loadedIdentity: initial.identity,
            plan: unrelatedPlanEdit)
        XCTAssertEqual(unrelated.draft["wed"], "day-a")

        let changed = RoutineScheduleDraftPolicy.reconcile(
            currentDraft: unrelated.draft,
            loadedIdentity: unrelated.identity,
            plan: changedWeek)
        XCTAssertEqual(changed.draft["mon"], "")
        XCTAssertEqual(changed.draft["tue"], "day-a")

        let replaced = RoutineScheduleDraftPolicy.reconcile(
            currentDraft: changed.draft,
            loadedIdentity: changed.identity,
            plan: replacement)
        XCTAssertEqual(replaced.draft["mon"], "day-a")
        XCTAssertEqual(replaced.draft["tue"], "")

        let removedDay = RoutineScheduleDraftPolicy.reconcile(
            currentDraft: ["wed": "day-a"],
            loadedIdentity: initial.identity,
            plan: removedWorkout)
        XCTAssertEqual(removedDay.draft["wed"], "")
    }

    func testManualDayConflictReloadsInsteadOfOverwritingNewerRoutine() async {
        let defaults = defaults()
        let ex = exercise()
        let s = session(status: "planned", attempt: 0)
        let routineAPI = SetRoutineEditingAPIStub()
        routineAPI.updateDayHandler = { _, _, _, _ in
            throw APIError.http(409, #"{"conflict":true,"current_version":2}"#)
        }
        let stateAPI = SetWriteAPIStub()
        stateAPI.stateHandler = { [self] _ in
            state(
                session: s, sets: [], workouts: [day(with: [ex])],
                planName: "Coach Update", planVersion: 2)
        }
        let model = SyncModel(
            auth: retainedAuth(defaults: defaults),
            setWriteAPI: stateAPI,
            catalogAPI: SetCatalogAPIStub(),
            routineEditingAPI: routineAPI,
            defaults: defaults,
            now: { self.fixedDate })
        model.replaceState(with: state(
            session: s, sets: [], workouts: [day(with: [ex])]))

        await model.renameWorkoutDay(dayID: "day-a", name: "Stale Rename")

        XCTAssertEqual(model.plan?.version, 2)
        XCTAssertEqual(model.plan?.name, "Coach Update")
        XCTAssertEqual(
            model.loadError,
            "The routine changed elsewhere. Latest version loaded — review and try again.")
    }

    func testStaleDayNotFoundReloadsReplacementWithSameVersion() async {
        let defaults = defaults()
        let ex = exercise()
        let s = session(status: "planned", attempt: 0)
        let routineAPI = SetRoutineEditingAPIStub()
        routineAPI.updateDayHandler = { _, _, _, _ in
            throw APIError.http(404, #"{"error":"not_found"}"#)
        }
        let stateAPI = SetWriteAPIStub()
        stateAPI.stateHandler = { [self] _ in
            state(
                session: s, sets: [], workouts: [day(with: [ex])],
                planID: "plan-b", planName: "Replacement", planVersion: 1)
        }
        let model = SyncModel(
            auth: retainedAuth(defaults: defaults),
            setWriteAPI: stateAPI,
            catalogAPI: SetCatalogAPIStub(),
            routineEditingAPI: routineAPI,
            defaults: defaults,
            now: { self.fixedDate })
        model.replaceState(with: state(
            session: s, sets: [], workouts: [day(with: [ex])]))

        await model.renameWorkoutDay(dayID: "day-a", name: "Stale rename")

        XCTAssertEqual(model.plan?.id, "plan-b")
        XCTAssertEqual(model.plan?.version, 1)
        XCTAssertEqual(
            model.loadError,
            "The routine changed elsewhere. Latest version loaded — review and try again.")
    }

    func testStaleCalendarDayReferenceReloadsReplacementPlan() async {
        let defaults = defaults()
        let ex = exercise()
        let s = session(status: "planned", attempt: 0)
        let routineAPI = SetRoutineEditingAPIStub()
        routineAPI.calendarHandler = { _, _, _, _ in
            throw APIError.http(400, #"{"error":"unknown_day_ref"}"#)
        }
        let stateAPI = SetWriteAPIStub()
        stateAPI.stateHandler = { [self] _ in
            state(
                session: s, sets: [], workouts: [day(with: [ex])],
                planID: "plan-b", planName: "Replacement", planVersion: 1)
        }
        let model = SyncModel(
            auth: retainedAuth(defaults: defaults),
            setWriteAPI: stateAPI,
            catalogAPI: SetCatalogAPIStub(),
            routineEditingAPI: routineAPI,
            defaults: defaults,
            now: { self.fixedDate })
        model.replaceState(with: state(
            session: s, sets: [], workouts: [day(with: [ex])]))

        await model.setCalendarOverride(date: "2037-01-05", dayID: "day-a")

        XCTAssertEqual(routineAPI.calendarCalls, 1)
        XCTAssertEqual(model.plan?.id, "plan-b")
        XCTAssertEqual(
            model.loadError,
            "The routine changed elsewhere. Latest version loaded — review and try again.")
    }

    func testManualConflictKeepsReloadFailureInsteadOfClaimingLatestLoaded() async {
        let defaults = defaults()
        let ex = exercise()
        let s = session(status: "planned", attempt: 0)
        let routineAPI = SetRoutineEditingAPIStub()
        routineAPI.updateDayHandler = { _, _, _, _ in
            throw APIError.http(409, #"{"conflict":true,"current_version":2}"#)
        }
        let stateAPI = SetWriteAPIStub()
        stateAPI.stateHandler = { _ in throw URLError(.timedOut) }
        let model = SyncModel(
            auth: retainedAuth(defaults: defaults),
            setWriteAPI: stateAPI,
            catalogAPI: SetCatalogAPIStub(),
            routineEditingAPI: routineAPI,
            defaults: defaults,
            now: { self.fixedDate })
        model.replaceState(with: state(
            session: s, sets: [], workouts: [day(with: [ex])]))

        await model.renameWorkoutDay(dayID: "day-a", name: "Stale Rename")

        XCTAssertEqual(model.plan?.version, 1)
        XCTAssertNotNil(model.loadError)
        XCTAssertNotEqual(
            model.loadError,
            "The routine changed elsewhere. Latest version loaded — review and try again.")
    }

    func testRoutineMutationsQueueInsteadOfSilentlyDroppingSecondEdit() async {
        let defaults = defaults()
        let ex = exercise()
        let s = session(status: "planned", attempt: 0)
        let entered = SetAsyncLatch()
        let release = SetAsyncLatch()
        let routineAPI = SetRoutineEditingAPIStub()
        routineAPI.scheduleHandler = { _, _, _, _ in
            await entered.open()
            await release.wait()
            return APIClient.ScheduleWriteResult(
                ok: true,
                version: 2,
                schedule: PlanSchedule(version: 2, week: [:]))
        }
        routineAPI.updateDayHandler = { _, _, _, _ in
            APIClient.WorkoutIDRow(id: "day-a")
        }
        let stateAPI = SetWriteAPIStub()
        stateAPI.stateHandler = { [self] _ in
            state(session: s, sets: [], exercise: ex)
        }
        let model = SyncModel(
            auth: retainedAuth(defaults: defaults),
            setWriteAPI: stateAPI,
            catalogAPI: SetCatalogAPIStub(),
            routineEditingAPI: routineAPI,
            defaults: defaults,
            now: { self.fixedDate })
        model.replaceState(with: state(session: s, sets: [], exercise: ex))

        let schedule = Task { await model.saveRecurringSchedule([:]) }
        await entered.wait()
        let rename = Task {
            await model.renameWorkoutDay(dayID: "day-a", name: "Queued rename")
        }
        for _ in 0..<20 { await Task.yield() }
        XCTAssertEqual(routineAPI.scheduleCalls, 1)
        XCTAssertEqual(routineAPI.updateDayCalls, 0)

        await release.open()
        await schedule.value
        await rename.value

        XCTAssertEqual(routineAPI.updateDayCalls, 1)
    }

    func testSkippingFinalActiveTimedSlotCancelsAutoCompletion() async {
        let defaults = defaults()
        let ex = exercise(timed: true, targetSets: 1)
        let s = session()
        let api = SetWriteAPIStub()
        let model = SyncModel(
            auth: retainedAuth(defaults: defaults),
            setWriteAPI: api,
            defaults: defaults,
            now: { self.fixedDate })
        prepare(model, exercise: ex, session: s, running: true)
        model.startTimedSet(
            expected: ex, expectedSetNumber: model.currentSetNumber)

        model.skip()

        XCTAssertTrue(model.finished)
        XCTAssertTrue(model.skipped.contains(ex.id))
        XCTAssertFalse(model.timedActive)
        await model.finishTimedSetIfDue(at: fixedDate.addingTimeInterval(30))
        XCTAssertTrue(model.skipped.contains(ex.id))
        XCTAssertTrue(api.logCalls.isEmpty)
        XCTAssertTrue(model.setOutbox.isEmpty)
    }

    func testRestartingSkippedTimedSlotUnskipsBeforeLiveReconciliation() async {
        let defaults = defaults()
        let timed = exercise(
            id: "slot-timed", exerciseID: "exercise-timed",
            timed: true, targetSets: 1)
        let other = exercise(
            id: "slot-other", exerciseID: "exercise-other", targetSets: 2)
        let reducedOther = exercise(
            id: "slot-other", exerciseID: "exercise-other", targetSets: 1)
        let s = session(status: "in_progress")
        let completedBody = SetRequestBody(
            id: fixedUUID.uuidString,
            exercise_id: other.exercise_id,
            template_exercise_id: other.id,
            set_index: 1,
            weight: 100,
            reps: 5,
            is_warmup: false,
            logged_at: 1,
            duration_s: nil,
            is_timed: false)
        let completed = setLog(body: completedBody, sessionID: s.id)
        let setAPI = SetWriteAPIStub()
        setAPI.stateHandler = { [self] _ in
            state(
                session: s,
                sets: [completed],
                exercises: [timed, reducedOther])
        }
        let terminalAPI = SetTerminalAPIStub()
        let model = SyncModel(
            auth: retainedAuth(defaults: defaults),
            setWriteAPI: setAPI,
            terminalAPI: terminalAPI,
            catalogAPI: SetCatalogAPIStub(),
            defaults: defaults,
            now: { self.fixedDate })
        model.replaceState(with: state(
            session: s,
            sets: [completed],
            exercises: [timed, other]))
        model.startWorkout()
        model.skip()
        XCTAssertEqual(model.currentExercise?.id, other.id)
        XCTAssertTrue(model.isSkipped(timed))
        model.jump(to: 0)
        model.startTimedSet(
            expected: timed, expectedSetNumber: 1, at: fixedDate)
        XCTAssertFalse(model.isSkipped(timed))
        XCTAssertTrue(model.timedActive)

        await model.load()

        XCTAssertEqual(model.currentExercise?.id, timed.id)
        XCTAssertFalse(model.finished)
        XCTAssertTrue(model.timedActive)
        await model.finishResolvedWorkout()
        XCTAssertTrue(model.terminalOutbox.isEmpty)
        XCTAssertTrue(terminalAPI.completeCalls.isEmpty)
    }

    func testRelaunchLoadsAndDrainsUnresolvedIntent() async {
        let defaults = defaults()
        let ex = exercise()
        let s = session()
        let body = SetRequestBody(
            id: fixedUUID.uuidString,
            exercise_id: ex.exercise_id,
            template_exercise_id: ex.id,
            set_index: 1,
            weight: 135,
            reps: 5,
            is_warmup: false,
            logged_at: 2_000_000_000_000,
            duration_s: nil,
            is_timed: false)
        var outbox = SetOutbox()
        outbox.enqueue(.init(
            body: body,
            date: s.date,
            workoutID: "day-a",
            resolvedSessionID: nil,
            deliveryState: .queued,
            failedHTTPStatus: nil))
        SetOutboxStore.save(outbox, userID: "user-a", defaults: defaults)
        let api = SetWriteAPIStub()
        configureSuccess(api, exercise: ex, session: s)
        let model = SyncModel(
            auth: retainedAuth(defaults: defaults), setWriteAPI: api,
            defaults: defaults, now: { self.fixedDate })

        XCTAssertEqual(model.pendingSetIntentCount, 1)
        await model.drainSetOutbox()

        XCTAssertEqual(api.createCalls.count, 1)
        XCTAssertEqual(api.logCalls.first?.body, body.scoped(to: 0))
        XCTAssertTrue(model.setOutbox.isEmpty)
        XCTAssertEqual(model.sets.map(\.id), [body.id])
    }

    func testStaleWorkoutFallbackStopsWhenReplacementCannotBeSaved() async throws {
        let h = LocalPersistenceTestHarness()
        addTeardownBlock { h.cleanup() }
        let defaults = h.open(), ex = exercise()
        let s = SessionRow(id: "session-a", date: fixedCivilDate, status: "in_progress", workout_id: nil)
        let body = SetRequestBody(id: fixedUUID.uuidString, exercise_id: ex.exercise_id,
            template_exercise_id: ex.id, set_index: 1, weight: 135, reps: 5,
            is_warmup: false, logged_at: 2_000_000_000_000, duration_s: nil, is_timed: false)
        var outbox = SetOutbox()
        outbox.enqueue(.init(body: body, date: s.date, workoutID: "removed-day-id",
            resolvedSessionID: nil, deliveryState: .queued, failedHTTPStatus: nil))
        XCTAssertTrue(SetOutboxStore.save(outbox, userID: "user-a", defaults: defaults))
        let api = SetWriteAPIStub()
        var rejected = 0
        api.createHandler = { _, workoutID, _ in
            if workoutID != nil {
                rejected += 1
                if rejected == 1 { h.faults.failWrites = true }
                throw APIError.http(422, "unknown_day")
            }
            XCTAssertNil(SetOutboxStore.load(userID: "user-a", defaults: defaults).pending.first?.workoutID)
            return s
        }
        api.logHandler = { [self] sessionID, request, _ in
            .init(set: setLog(body: request, sessionID: sessionID), deduped: false)
        }
        api.stateHandler = { [self] _ in
            state(session: s, sets: [setLog(body: body, sessionID: s.id)], exercise: ex)
        }
        let auth = retainedAuth(defaults: defaults)
        let model = SyncModel(auth: auth, setWriteAPI: api, defaults: defaults, now: { self.fixedDate })
        await model.drainSetOutbox()
        XCTAssertEqual(api.createCalls.map(\.workoutID), ["removed-day-id"])
        XCTAssertTrue(api.logCalls.isEmpty)
        XCTAssertEqual(model.setOutbox.pending.first?.workoutID, "removed-day-id")
        XCTAssertEqual(SetOutboxStore.load(userID: "user-a", defaults: h.open()), outbox)
        XCTAssertNil(auth.featureJWT)
        XCTAssertNotNil(model.loadError)
        h.faults.failWrites = false
        XCTAssertTrue(defaults.retry(userID: "user-a"))
        await model.drainSetOutbox()
        XCTAssertEqual(api.createCalls.map(\.workoutID), ["removed-day-id", "removed-day-id", nil])
        XCTAssertEqual(api.logCalls.map { $0.body.id }, [body.id])
        XCTAssertTrue(model.setOutbox.isEmpty)
    }

    func testStaleWorkoutFallsBackBeforeRetryingSet() async {
        let defaults = defaults()
        let ex = exercise()
        let s = SessionRow(
            id: "session-a", date: fixedCivilDate, status: "in_progress",
            workout_id: nil)
        let body = SetRequestBody(
            id: fixedUUID.uuidString,
            exercise_id: ex.exercise_id,
            template_exercise_id: ex.id,
            set_index: 1,
            weight: 135,
            reps: 5,
            is_warmup: false,
            logged_at: 2_000_000_000_000,
            duration_s: nil,
            is_timed: false)
        var outbox = SetOutbox()
        outbox.enqueue(.init(
            body: body,
            date: s.date,
            workoutID: "removed-day-id",
            resolvedSessionID: nil,
            deliveryState: .queued,
            failedHTTPStatus: nil))
        SetOutboxStore.save(outbox, userID: "user-a", defaults: defaults)
        let api = SetWriteAPIStub()
        api.createHandler = { _, workoutID, _ in
            if workoutID != nil { throw APIError.http(422, "unknown_day") }
            let stored = SetOutboxStore.load(
                userID: "user-a", defaults: defaults)
            XCTAssertNil(stored.pending.first?.workoutID)
            return s
        }
        api.logHandler = { [self] sessionID, request, _ in
            .init(
                set: setLog(body: request, sessionID: sessionID),
                deduped: false)
        }
        api.stateHandler = { [self] _ in
            state(
                session: s,
                sets: [setLog(body: body, sessionID: s.id)],
                exercise: ex)
        }
        let model = SyncModel(
            auth: retainedAuth(defaults: defaults), setWriteAPI: api,
            defaults: defaults, now: { self.fixedDate })

        await model.drainSetOutbox()

        XCTAssertEqual(api.createCalls.map(\.workoutID), [
            "removed-day-id", nil,
        ])
        XCTAssertEqual(api.logCalls.first?.body, body.scoped(to: 0))
        XCTAssertTrue(model.setOutbox.isEmpty)
    }

    func testFullStateAcknowledgementRemovesMatchingPendingIntent() {
        let defaults = defaults()
        let ex = exercise()
        let s = session()
        let body = SetRequestBody(
            id: fixedUUID.uuidString,
            exercise_id: ex.exercise_id,
            template_exercise_id: ex.id,
            set_index: 1,
            weight: 135,
            reps: 5,
            is_warmup: false,
            logged_at: 2_000_000_000_000,
            duration_s: nil,
            is_timed: false)
        var outbox = SetOutbox()
        outbox.enqueue(.init(
            body: body,
            date: s.date,
            workoutID: "day-a",
            resolvedSessionID: s.id,
            deliveryState: .queued,
            failedHTTPStatus: nil))
        SetOutboxStore.save(outbox, userID: "user-a", defaults: defaults)
        let model = SyncModel(
            auth: retainedAuth(defaults: defaults), setWriteAPI: SetWriteAPIStub(),
            defaults: defaults, now: { self.fixedDate })

        model.replaceState(with: state(
            session: s,
            sets: [setLog(body: body, sessionID: s.id)],
            exercise: ex))

        XCTAssertTrue(model.setOutbox.isEmpty)
        XCTAssertTrue(
            SetOutboxStore.load(userID: "user-a", defaults: defaults).isEmpty)
        XCTAssertEqual(model.currentSetNumber, 2)
    }

    func testPermanent4xxRemainsFailedUntilExplicitRetry() async {
        let defaults = defaults()
        let ex = exercise()
        let s = session()
        let api = SetWriteAPIStub()
        api.logHandler = { _, _, _ in throw APIError.http(422, "invalid_fields") }
        var retrySleeps = 0
        let model = SyncModel(
            auth: retainedAuth(defaults: defaults), setWriteAPI: api,
            defaults: defaults, now: { self.fixedDate },
            automaticWorkoutWriteRetryEnabled: true,
            workoutWriteRetrySleeper: { _ in retrySleeps += 1 })
        prepare(model, exercise: ex, session: s)

        let firstAttempt = await model.logSet(ex, weight: 135, reps: 5)
        XCTAssertFalse(firstAttempt)
        XCTAssertEqual(model.setOutbox.pending.first?.deliveryState, .failed)
        await Task.yield()
        XCTAssertEqual(retrySleeps, 0)
        await model.drainSetOutbox()
        XCTAssertEqual(api.logCalls.count, 1)

        configureSuccess(api, exercise: ex, session: s)
        let id = model.setOutbox.pending[0].id
        await model.retrySetIntent(id: id)

        XCTAssertEqual(api.logCalls.count, 2)
        XCTAssertEqual(api.logCalls[0].body, api.logCalls[1].body)
        XCTAssertTrue(model.setOutbox.isEmpty)
    }

    func testUnauthorizedFailureRetainsQueuedIntentForSameAccountRecovery() async {
        let defaults = defaults()
        let ex = exercise()
        let s = session()
        let api = SetWriteAPIStub()
        api.logHandler = { _, _, _ in throw APIError.http(401, "invalid_token") }
        let auth = auth(defaults: defaults)
        let model = SyncModel(
            auth: auth, setWriteAPI: api, defaults: defaults,
            now: { self.fixedDate })
        prepare(model, exercise: ex, session: s)

        let acknowledged = await model.logSet(ex, weight: 135, reps: 5)

        XCTAssertFalse(acknowledged)
        XCTAssertNil(auth.jwt)
        XCTAssertEqual(auth.userID, "user-a")
        XCTAssertEqual(model.setOutbox.pending.first?.deliveryState, .queued)
        XCTAssertEqual(
            SetOutboxStore.load(userID: "user-a", defaults: defaults).count, 1)
    }

    func testCanonicalSessionAliasFromAcknowledgementIsPreserved() async {
        let defaults = defaults()
        let ex = exercise()
        let stale = session(id: "session-stale")
        let canonical = session(id: "session-canonical")
        let api = SetWriteAPIStub()
        api.logHandler = { [self] _, body, _ in
            .init(
                set: setLog(body: body, sessionID: canonical.id),
                deduped: false)
        }
        api.stateHandler = { [self] _ in
            state(
                session: canonical,
                sets: [setLog(body: api.logCalls[0].body, sessionID: canonical.id)],
                exercise: ex)
        }
        let model = SyncModel(
            auth: retainedAuth(defaults: defaults), setWriteAPI: api,
            defaults: defaults, now: { self.fixedDate })
        prepare(model, exercise: ex, session: stale)
        model.sessions = [stale]

        let acknowledged = await model.logSet(ex, weight: 135, reps: 5)

        XCTAssertTrue(acknowledged)
        XCTAssertEqual(model.todaySession?.id, canonical.id)
        XCTAssertEqual(model.sets.first?.session_id, canonical.id)
        XCTAssertFalse(model.sessions.contains { $0.id == stale.id })
    }

    func testSameAccountRenewalCanSettleInFlightWrite() async {
        let defaults = defaults()
        let ex = exercise()
        let s = session()
        let oldToken = jwt(subject: "user-a", expiration: fixedDate.addingTimeInterval(60))
        let newToken = jwt(subject: "user-a", expiration: fixedDate.addingTimeInterval(10_000_000))
        let authAPI = SetAuthAPIStub()
        authAPI.renewalResult = .success(.init(jwt: newToken))
        let auth = auth(defaults: defaults, api: authAPI, token: oldToken)
        let api = SetWriteAPIStub()
        let entered = SetAsyncLatch()
        let release = SetAsyncLatch()
        api.logHandler = { [self] sessionID, body, _ in
            await entered.open()
            await release.wait()
            return .init(set: setLog(body: body, sessionID: sessionID), deduped: false)
        }
        api.stateHandler = { [self] _ in
            state(
                session: s,
                sets: [setLog(body: api.logCalls[0].body)],
                exercise: ex)
        }
        let model = SyncModel(
            auth: auth, setWriteAPI: api, defaults: defaults,
            now: { self.fixedDate })
        prepare(model, exercise: ex, session: s)

        let write = Task { await model.logSet(ex, weight: 135, reps: 5) }
        await entered.wait()
        await auth.renewSessionIfNeeded(force: true)
        XCTAssertEqual(auth.jwt, newToken)
        await release.open()

        let writeResult = await write.value
        XCTAssertTrue(writeResult)
        XCTAssertTrue(model.setOutbox.isEmpty)
        XCTAssertEqual(model.sets.count, 1)
    }

    func testSameAccountRenewalCanApplyInFlightStateLoad() async {
        let defaults = defaults()
        let ex = exercise()
        let s = session()
        let oldToken = jwt(
            subject: "user-a",
            expiration: fixedDate.addingTimeInterval(60))
        let newToken = jwt(
            subject: "user-a",
            expiration: fixedDate.addingTimeInterval(10_000_000))
        let authAPI = SetAuthAPIStub()
        authAPI.renewalResult = .success(.init(jwt: newToken))
        let auth = auth(defaults: defaults, api: authAPI, token: oldToken)
        let api = SetWriteAPIStub()
        let entered = SetAsyncLatch()
        let release = SetAsyncLatch()
        api.stateHandler = { [self] token in
            XCTAssertEqual(token, oldToken)
            await entered.open()
            await release.wait()
            return state(session: s, sets: [], exercise: ex)
        }
        let catalog = SetCatalogAPIStub()
        let model = SyncModel(
            auth: auth,
            setWriteAPI: api,
            catalogAPI: catalog,
            defaults: defaults,
            now: { self.fixedDate })

        let loading = Task { await model.load() }
        await entered.wait()
        await auth.renewSessionIfNeeded(force: true)
        XCTAssertEqual(auth.jwt, newToken)
        await release.open()
        await loading.value

        XCTAssertEqual(model.plan?.id, "plan-a")
        XCTAssertEqual(model.todaySession?.id, s.id)
        XCTAssertEqual(catalog.jwtCalls, [newToken])
        XCTAssertNil(model.loadError)
        XCTAssertFalse(model.isLoading)
    }

    func testSameUserReauthLateCallbackDoesNotOverwriteNewQueue() async {
        let defaults = defaults()
        let ex = exercise()
        let s = session()
        let authAPI = SetAuthAPIStub()
        let oldToken = jwt(subject: "user-a")
        let newToken = jwt(
            subject: "user-a",
            expiration: fixedDate.addingTimeInterval(5_000_000))
        authAPI.authResult = .success(.init(
            jwt: newToken,
            user: .init(id: "user-a", display_name: nil, email: nil)))
        let auth = auth(
            defaults: defaults, api: authAPI, token: oldToken)
        let api = SetWriteAPIStub()
        let entered = SetAsyncLatch()
        let release = SetAsyncLatch()
        api.logHandler = { [self] sessionID, request, _ in
            await entered.open()
            await release.wait()
            return .init(
                set: setLog(body: request, sessionID: sessionID),
                deduped: false)
        }
        api.stateHandler = { [self] _ in
            state(
                session: s,
                sets: [setLog(body: api.logCalls[0].body)],
                exercise: ex)
        }
        let model = SyncModel(
            auth: auth, setWriteAPI: api, defaults: defaults,
            uuidFactory: { self.fixedUUID }, now: { self.fixedDate })
        prepare(model, exercise: ex, session: s)

        let oldWrite = Task { await model.logSet(ex, weight: 135, reps: 5) }
        await entered.wait()
        auth.signOut()
        await auth.exchange(identityToken: "same-user", fullName: nil)

        let replacementID = "22222222-2222-4222-8222-222222222222"
        var replacementQueue = SetOutboxStore.load(
            userID: "user-a", defaults: defaults)
        replacementQueue.enqueue(.init(
            body: .init(
                id: replacementID,
                exercise_id: "exercise-b",
                template_exercise_id: "slot-b",
                set_index: 1,
                weight: 100,
                reps: 8,
                is_warmup: false,
                logged_at: 2_000_000_000_001,
                duration_s: nil,
                is_timed: false),
            date: s.date,
            workoutID: "day-a",
            resolvedSessionID: s.id,
            deliveryState: .queued,
            failedHTTPStatus: nil))
        SetOutboxStore.save(
            replacementQueue, userID: "user-a", defaults: defaults)

        await release.open()
        let oldResult = await oldWrite.value

        XCTAssertTrue(oldResult)
        XCTAssertEqual(
            SetOutboxStore.load(userID: "user-a", defaults: defaults)
                .pending.map(\.id),
            [replacementID])
    }

    func testAccountSwitchCannotMutateOtherAccountOrRemoveOldIntent() async {
        let defaults = defaults()
        let ex = exercise()
        let s = session()
        let authAPI = SetAuthAPIStub()
        let auth = auth(defaults: defaults, api: authAPI)
        let api = SetWriteAPIStub()
        let entered = SetAsyncLatch()
        let release = SetAsyncLatch()
        api.logHandler = { [self] sessionID, body, _ in
            await entered.open()
            await release.wait()
            return .init(set: setLog(body: body, sessionID: sessionID), deduped: false)
        }
        let model = SyncModel(
            auth: auth, setWriteAPI: api, defaults: defaults,
            now: { self.fixedDate })
        prepare(model, exercise: ex, session: s)

        let write = Task { await model.logSet(ex, weight: 135, reps: 5) }
        await entered.wait()
        authAPI.authResult = .success(.init(
            jwt: jwt(subject: "user-b"),
            user: .init(id: "user-b", display_name: nil, email: nil)))
        await auth.exchange(identityToken: "apple-b", fullName: nil)
        await release.open()
        let writeResult = await write.value
        XCTAssertFalse(writeResult)

        XCTAssertEqual(
            SetOutboxStore.load(userID: "user-a", defaults: defaults).count, 1)
        XCTAssertTrue(
            SetOutboxStore.load(userID: "user-b", defaults: defaults).isEmpty)
    }

    func testConfirmedDeletionClearsQueueAndLateCallbackCannotRecreateIt() async {
        let defaults = defaults()
        let ex = exercise()
        let s = session()
        let authAPI = SetAuthAPIStub()
        authAPI.deletionResult = .success(.init(
            ok: true, owner_tombstoned: false, apple_revocation: .revoked))
        let auth = auth(defaults: defaults, api: authAPI)
        let api = SetWriteAPIStub()
        let entered = SetAsyncLatch()
        let release = SetAsyncLatch()
        api.logHandler = { [self] sessionID, body, _ in
            await entered.open()
            await release.wait()
            return .init(set: setLog(body: body, sessionID: sessionID), deduped: false)
        }
        let model = SyncModel(
            auth: auth, setWriteAPI: api, defaults: defaults,
            now: { self.fixedDate })
        prepare(model, exercise: ex, session: s)

        let write = Task { await model.logSet(ex, weight: 135, reps: 5) }
        await entered.wait()
        try? await auth.deleteAccount()
        XCTAssertTrue(
            SetOutboxStore.load(userID: "user-a", defaults: defaults).isEmpty)
        await release.open()
        let writeResult = await write.value
        XCTAssertFalse(writeResult)

        XCTAssertNil(defaults.data(
            forKey: SetOutboxStore.scopedKey(userID: "user-a")))
    }

    func testConcurrentDrainTriggersSerializeAndProcessFIFO() async {
        let defaults = defaults()
        let exA = exercise(id: "slot-a", exerciseID: "exercise-a")
        let exB = exercise(id: "slot-b", exerciseID: "exercise-b")
        let s = session()
        func intent(_ ex: TemplateExercise, id: String, index: Int) -> PendingSetIntent {
            .init(
                body: .init(
                    id: id,
                    exercise_id: ex.exercise_id,
                    template_exercise_id: ex.id,
                    set_index: index,
                    weight: 100,
                    reps: 5,
                    is_warmup: false,
                    logged_at: 2_000_000_000_000 + index,
                    duration_s: nil,
                    is_timed: false),
                date: s.date,
                workoutID: "day-a",
                resolvedSessionID: s.id,
                deliveryState: .queued,
                failedHTTPStatus: nil)
        }
        var outbox = SetOutbox()
        outbox.enqueue(intent(exA, id: "11111111-1111-4111-8111-111111111111", index: 1))
        outbox.enqueue(intent(exB, id: "22222222-2222-4222-8222-222222222222", index: 1))
        SetOutboxStore.save(outbox, userID: "user-a", defaults: defaults)
        let api = SetWriteAPIStub()
        let firstEntered = SetAsyncLatch()
        let releaseFirst = SetAsyncLatch()
        var serverSets: [SetLog] = []
        var inFlight = 0
        var maxInFlight = 0
        api.logHandler = { [self] sessionID, body, _ in
            inFlight += 1
            maxInFlight = max(maxInFlight, inFlight)
            if serverSets.isEmpty {
                await firstEntered.open()
                await releaseFirst.wait()
            }
            let row = setLog(body: body, sessionID: sessionID)
            serverSets.append(row)
            inFlight -= 1
            return .init(set: row, deduped: false)
        }
        api.stateHandler = { [self] _ in
            state(session: s, sets: serverSets, exercise: exA)
        }
        let model = SyncModel(
            auth: retainedAuth(defaults: defaults), setWriteAPI: api,
            defaults: defaults, now: { self.fixedDate })

        let first = Task { await model.drainSetOutbox() }
        await firstEntered.wait()
        let second = Task { await model.drainSetOutbox() }
        await releaseFirst.open()
        await first.value
        await second.value

        XCTAssertEqual(maxInFlight, 1)
        XCTAssertEqual(api.logCalls.map(\.body.id), outbox.pending.map(\.id))
        XCTAssertTrue(model.setOutbox.isEmpty)
    }

    func testIntentPersistedDuringFinalReconciliationJoinsActiveDrain() async {
        let defaults = defaults()
        let exA = exercise(id: "slot-a", exerciseID: "exercise-a")
        let exB = exercise(id: "slot-b", exerciseID: "exercise-b")
        let s = session()
        let api = SetWriteAPIStub()
        let reconciliationEntered = SetAsyncLatch()
        let releaseReconciliation = SetAsyncLatch()
        var serverSets: [SetLog] = []
        api.logHandler = { [self] sessionID, body, _ in
            let row = setLog(body: body, sessionID: sessionID)
            serverSets.append(row)
            return .init(set: row, deduped: false)
        }
        api.stateHandler = { [self] _ in
            if api.stateCalls == 1 {
                await reconciliationEntered.open()
                await releaseReconciliation.wait()
            }
            return state(session: s, sets: serverSets, exercise: exA)
        }
        var uuids = [
            UUID(uuidString: "11111111-1111-4111-8111-111111111111")!,
            UUID(uuidString: "22222222-2222-4222-8222-222222222222")!,
        ]
        let model = SyncModel(
            auth: retainedAuth(defaults: defaults), setWriteAPI: api,
            defaults: defaults, uuidFactory: { uuids.removeFirst() },
            now: { self.fixedDate })
        prepare(model, exercise: exA, session: s)
        model.plan = PlanTree(
            id: "plan-a", name: "Plan A", version: 1,
            workouts: [day(with: [exA, exB])], meta: nil)

        let first = Task { await model.logSet(exA, weight: 135, reps: 5) }
        await reconciliationEntered.wait()
        let second = Task { await model.logSet(exB, weight: 100, reps: 8) }

        // The second tap has persisted and is waiting on the first drain while
        // that owner is still inside its final state pull.
        await Task.yield()
        XCTAssertEqual(model.setOutbox.pending.map(\.slotID), [exB.id])
        XCTAssertEqual(
            SetOutboxStore.load(userID: "user-a", defaults: defaults)
                .pending.map(\.slotID),
            [exB.id])

        await releaseReconciliation.open()
        let firstResult = await first.value
        let secondResult = await second.value

        XCTAssertTrue(firstResult)
        XCTAssertTrue(secondResult)
        XCTAssertEqual(api.logCalls.map(\.body.id), [
            "11111111-1111-4111-8111-111111111111",
            "22222222-2222-4222-8222-222222222222",
        ])
        XCTAssertEqual(api.stateCalls, 2)
        XCTAssertTrue(model.setOutbox.isEmpty)
    }

    func testRecoveryTriggerDuringTransientAttemptGetsOneCoalescedRetry() async {
        let defaults = defaults()
        let ex = exercise()
        let s = session()
        let body = SetRequestBody(
            id: fixedUUID.uuidString,
            exercise_id: ex.exercise_id,
            template_exercise_id: ex.id,
            set_index: 1,
            weight: 135,
            reps: 5,
            is_warmup: false,
            logged_at: 2_000_000_000_000,
            duration_s: nil,
            is_timed: false)
        var outbox = SetOutbox()
        outbox.enqueue(.init(
            body: body,
            date: s.date,
            workoutID: "day-a",
            resolvedSessionID: s.id,
            deliveryState: .queued,
            failedHTTPStatus: nil))
        SetOutboxStore.save(outbox, userID: "user-a", defaults: defaults)
        let api = SetWriteAPIStub()
        let firstAttemptEntered = SetAsyncLatch()
        let releaseFirstAttempt = SetAsyncLatch()
        var serverSets: [SetLog] = []
        api.logHandler = { [self] sessionID, request, _ in
            if api.logCalls.count == 1 {
                await firstAttemptEntered.open()
                await releaseFirstAttempt.wait()
                throw URLError(.notConnectedToInternet)
            }
            let row = setLog(body: request, sessionID: sessionID)
            serverSets.append(row)
            return .init(set: row, deduped: false)
        }
        api.stateHandler = { [self] _ in
            state(session: s, sets: serverSets, exercise: ex)
        }
        let model = SyncModel(
            auth: retainedAuth(defaults: defaults), setWriteAPI: api,
            defaults: defaults, now: { self.fixedDate })

        let first = Task { await model.drainSetOutbox() }
        await firstAttemptEntered.wait()
        let recoveryTrigger = Task { await model.drainSetOutbox() }
        await releaseFirstAttempt.open()
        await first.value
        await recoveryTrigger.value

        XCTAssertEqual(
            api.logCalls.map(\.body),
            [body.scoped(to: 0), body.scoped(to: 0)])
        XCTAssertEqual(api.stateCalls, 1)
        XCTAssertTrue(model.setOutbox.isEmpty)
    }

    func testTransientFailureAutomaticallyRetriesWithoutNetworkPathChange() async {
        let defaults = defaults()
        let ex = exercise()
        let s = session()
        let api = SetWriteAPIStub()
        let retrySleepStarted = SetAsyncLatch()
        let releaseRetry = SetAsyncLatch()
        let retryRequestStarted = SetAsyncLatch()
        var serverSets: [SetLog] = []
        api.logHandler = { [self] sessionID, body, _ in
            if api.logCalls.count == 1 {
                throw URLError(.notConnectedToInternet)
            }
            let row = setLog(body: body, sessionID: sessionID)
            serverSets.append(row)
            await retryRequestStarted.open()
            return .init(set: row, deduped: false)
        }
        api.stateHandler = { [self] _ in
            state(session: s, sets: serverSets, exercise: ex)
        }
        let model = SyncModel(
            auth: retainedAuth(defaults: defaults),
            setWriteAPI: api,
            defaults: defaults,
            now: { self.fixedDate },
            automaticWorkoutWriteRetryEnabled: true,
            workoutWriteRetryDelaysNanoseconds: [123],
            workoutWriteRetrySleeper: { _ in
                await retrySleepStarted.open()
                await releaseRetry.wait()
            })
        prepare(model, exercise: ex, session: s)

        let firstAttempt = await model.logSet(ex, weight: 135, reps: 5)
        XCTAssertFalse(firstAttempt)
        await retrySleepStarted.wait()
        XCTAssertEqual(api.logCalls.count, 1)
        XCTAssertEqual(model.queuedSetIntentCount, 1)

        await releaseRetry.open()
        await retryRequestStarted.wait()
        // Join the model-owned retry if it is still reconciling state.
        await model.drainSetOutbox()

        XCTAssertEqual(api.logCalls.count, 2)
        XCTAssertEqual(api.logCalls[0].body, api.logCalls[1].body)
        XCTAssertEqual(api.stateCalls, 1)
        XCTAssertTrue(model.setOutbox.isEmpty)
    }

    func testRetiredModelDoesNotRearmRetryAfterSameUserReauthentication() async {
        let defaults = defaults()
        let ex = exercise()
        let s = session()
        let firstAttemptEntered = SetAsyncLatch()
        let releaseFirstAttempt = SetAsyncLatch()
        let api = SetWriteAPIStub()
        var serverSets: [SetLog] = []
        api.logHandler = { [self] sessionID, body, _ in
            if api.logCalls.count == 1 {
                await firstAttemptEntered.open()
                await releaseFirstAttempt.wait()
                throw URLError(.notConnectedToInternet)
            }
            let row = setLog(body: body, sessionID: sessionID)
            serverSets.append(row)
            return .init(set: row, deduped: false)
        }
        api.stateHandler = { [self] _ in
            state(session: s, sets: serverSets, exercise: ex)
        }
        let oldToken = jwt(subject: "user-a")
        let newToken = jwt(
            subject: "user-a",
            expiration: fixedDate.addingTimeInterval(5_000_000))
        let authAPI = SetAuthAPIStub()
        authAPI.authResult = .success(
            authResponse(jwt: newToken, userID: "user-a"))
        let sharedAuth = auth(
            defaults: defaults, api: authAPI, token: oldToken)
        var retiredRetrySleeps = 0
        let retired = SyncModel(
            auth: sharedAuth,
            setWriteAPI: api,
            defaults: defaults,
            now: { self.fixedDate },
            automaticWorkoutWriteRetryEnabled: true,
            workoutWriteRetryDelaysNanoseconds: [1],
            workoutWriteRetrySleeper: { _ in
                retiredRetrySleeps += 1
                throw CancellationError()
            })
        prepare(retired, exercise: ex, session: s)

        let initialWrite = Task {
            await retired.logSet(ex, weight: 135, reps: 5)
        }
        await firstAttemptEntered.wait()
        let coalescedOldModelTrigger = Task {
            await retired.drainSetOutbox()
        }
        // Let the second caller enter the in-flight drain and install its
        // coalesced waiter before the auth epoch changes.
        await Task.yield()
        await Task.yield()
        sharedAuth.signOut()
        await sharedAuth.exchange(
            identityToken: "same-user", fullName: nil)
        let replacement = SyncModel(
            auth: sharedAuth,
            setWriteAPI: api,
            defaults: defaults,
            now: { self.fixedDate },
            automaticWorkoutWriteRetryEnabled: true,
            workoutWriteRetryDelaysNanoseconds: [1])

        await releaseFirstAttempt.open()
        let acknowledged = await initialWrite.value
        await coalescedOldModelTrigger.value
        XCTAssertFalse(acknowledged)
        await Task.yield()
        await Task.yield()

        XCTAssertEqual(retiredRetrySleeps, 0)
        XCTAssertEqual(api.logCalls.count, 1)
        await replacement.drainSetOutbox()
        XCTAssertEqual(api.logCalls.count, 2)
        XCTAssertTrue(replacement.setOutbox.isEmpty)
    }

    func testRateLimitRemainsQueuedRatherThanPermanentlyFailed() async {
        let defaults = defaults()
        let ex = exercise()
        let s = session()
        let api = SetWriteAPIStub()
        let retryScheduled = SetAsyncLatch()
        var retryDelays: [UInt64] = []
        api.logHandler = { _, _, _ in
            throw APIError.httpWithRetryAfter(429, "rate_limited", 7)
        }
        let model = SyncModel(
            auth: retainedAuth(defaults: defaults), setWriteAPI: api,
            defaults: defaults, now: { self.fixedDate },
            automaticWorkoutWriteRetryEnabled: true,
            workoutWriteRetryDelaysNanoseconds: [2_000_000_000],
            workoutWriteRetrySleeper: { delay in
                retryDelays.append(delay)
                await retryScheduled.open()
                throw CancellationError()
            })
        prepare(model, exercise: ex, session: s)

        let acknowledged = await model.logSet(ex, weight: 135, reps: 5)
        await retryScheduled.wait()

        XCTAssertFalse(acknowledged)
        XCTAssertEqual(model.setOutbox.pending.first?.deliveryState, .queued)
        XCTAssertNil(model.setOutbox.pending.first?.failedHTTPStatus)
        XCTAssertEqual(retryDelays, [7_000_000_000])
    }

    func testServiceUnavailableRetryAfterCannotBeBypassedByTriggers() async {
        let defaults = defaults()
        let ex = exercise()
        let s = session()
        let api = SetWriteAPIStub()
        let firstRequestEntered = SetAsyncLatch()
        let releaseFirstRequest = SetAsyncLatch()
        let retrySleepStarted = SetAsyncLatch()
        let releaseRetrySleep = SetAsyncLatch()
        let retryRequestStarted = SetAsyncLatch()
        var retryDelays: [UInt64] = []
        var serverSets: [SetLog] = []
        api.logHandler = { [self] sessionID, body, _ in
            if api.logCalls.count == 1 {
                await firstRequestEntered.open()
                await releaseFirstRequest.wait()
                throw APIError.httpWithRetryAfter(
                    503, "write_protocol_not_active", 5)
            }
            let row = setLog(body: body, sessionID: sessionID)
            serverSets.append(row)
            await retryRequestStarted.open()
            return .init(set: row, deduped: false)
        }
        api.stateHandler = { [self] _ in
            state(session: s, sets: serverSets, exercise: ex)
        }
        let model = SyncModel(
            auth: retainedAuth(defaults: defaults), setWriteAPI: api,
            defaults: defaults, now: { self.fixedDate },
            automaticWorkoutWriteRetryEnabled: true,
            workoutWriteRetryDelaysNanoseconds: [2_000_000_000],
            workoutWriteRetrySleeper: { delay in
                retryDelays.append(delay)
                await retrySleepStarted.open()
                await releaseRetrySleep.wait()
            })
        prepare(model, exercise: ex, session: s)

        let initialWrite = Task {
            await model.logSet(ex, weight: 135, reps: 5)
        }
        await firstRequestEntered.wait()
        let triggerDuringRequest = Task {
            await model.drainSetOutbox()
        }
        await Task.yield()
        await releaseFirstRequest.open()
        let acknowledged = await initialWrite.value
        await triggerDuringRequest.value
        await retrySleepStarted.wait()

        XCTAssertFalse(acknowledged)
        XCTAssertEqual(model.queuedSetIntentCount, 1)
        XCTAssertEqual(api.logCalls.count, 1)
        XCTAssertEqual(retryDelays, [5_000_000_000])

        // A later manual/lifecycle trigger must join the existing server floor
        // instead of cancelling it and issuing an early second POST.
        await model.drainSetOutbox()
        XCTAssertEqual(api.logCalls.count, 1)

        await releaseRetrySleep.open()
        await retryRequestStarted.wait()
        await model.drainSetOutbox()

        XCTAssertEqual(api.logCalls.count, 2)
        XCTAssertTrue(model.setOutbox.isEmpty)
    }

    func testRetryAfterSurvivesSameUserReauthentication() async {
        let defaults = defaults()
        let ex = exercise()
        let s = session()
        let api = SetWriteAPIStub()
        let retiredSleepStarted = SetAsyncLatch()
        let releaseRetiredSleep = SetAsyncLatch()
        let replacementSleepStarted = SetAsyncLatch()
        let releaseReplacementSleep = SetAsyncLatch()
        let retryRequestStarted = SetAsyncLatch()
        var retiredDelays: [UInt64] = []
        var replacementDelays: [UInt64] = []
        var serverSets: [SetLog] = []
        api.logHandler = { [self] sessionID, body, _ in
            if api.logCalls.count == 1 {
                throw APIError.httpWithRetryAfter(
                    503, "write_protocol_not_active", 5)
            }
            let row = setLog(body: body, sessionID: sessionID)
            serverSets.append(row)
            await retryRequestStarted.open()
            return .init(set: row, deduped: false)
        }
        api.stateHandler = { [self] _ in
            state(session: s, sets: serverSets, exercise: ex)
        }
        let oldToken = jwt(subject: "user-a")
        let newToken = jwt(
            subject: "user-a",
            expiration: fixedDate.addingTimeInterval(5_000_000))
        let authAPI = SetAuthAPIStub()
        authAPI.authResult = .success(
            authResponse(jwt: newToken, userID: "user-a"))
        let sharedAuth = auth(
            defaults: defaults, api: authAPI, token: oldToken)
        let retired = SyncModel(
            auth: sharedAuth,
            setWriteAPI: api,
            defaults: defaults,
            now: { self.fixedDate },
            automaticWorkoutWriteRetryEnabled: true,
            workoutWriteRetryDelaysNanoseconds: [2_000_000_000],
            workoutWriteRetrySleeper: { delay in
                retiredDelays.append(delay)
                await retiredSleepStarted.open()
                await releaseRetiredSleep.wait()
            })
        prepare(retired, exercise: ex, session: s)

        let acknowledged = await retired.logSet(ex, weight: 135, reps: 5)
        await retiredSleepStarted.wait()
        XCTAssertFalse(acknowledged)
        XCTAssertEqual(retiredDelays, [5_000_000_000])
        XCTAssertEqual(api.logCalls.count, 1)

        sharedAuth.signOut()
        await sharedAuth.exchange(identityToken: "same-user", fullName: nil)
        await releaseRetiredSleep.open()
        let replacement = SyncModel(
            auth: sharedAuth,
            setWriteAPI: api,
            defaults: defaults,
            now: { self.fixedDate },
            automaticWorkoutWriteRetryEnabled: true,
            workoutWriteRetryDelaysNanoseconds: [2_000_000_000],
            workoutWriteRetrySleeper: { delay in
                replacementDelays.append(delay)
                await replacementSleepStarted.open()
                await releaseReplacementSleep.wait()
            })

        await replacement.drainSetOutbox()
        await replacementSleepStarted.wait()
        XCTAssertEqual(api.logCalls.count, 1)
        XCTAssertEqual(replacementDelays, [5_000_000_000])

        await releaseReplacementSleep.open()
        await retryRequestStarted.wait()
        await replacement.drainSetOutbox()

        XCTAssertEqual(api.logCalls.count, 2)
        XCTAssertTrue(replacement.setOutbox.isEmpty)
        XCTAssertNil(WorkoutWriteRetryDeadlineStore.load(
            userID: "user-a", defaults: defaults))
    }

    func testOversizedRetryAfterIsSafelyCapped() async {
        let defaults = defaults()
        let ex = exercise()
        let s = session()
        let api = SetWriteAPIStub()
        let retryScheduled = SetAsyncLatch()
        var retryDelays: [UInt64] = []
        api.logHandler = { _, _, _ in
            throw APIError.httpWithRetryAfter(
                503, "write_protocol_not_active", .greatestFiniteMagnitude)
        }
        let model = SyncModel(
            auth: retainedAuth(defaults: defaults), setWriteAPI: api,
            defaults: defaults, now: { self.fixedDate },
            automaticWorkoutWriteRetryEnabled: true,
            workoutWriteRetryDelaysNanoseconds: [2_000_000_000],
            workoutWriteRetrySleeper: { delay in
                retryDelays.append(delay)
                await retryScheduled.open()
                throw CancellationError()
            })
        prepare(model, exercise: ex, session: s)

        let acknowledged = await model.logSet(ex, weight: 135, reps: 5)
        await retryScheduled.wait()

        XCTAssertFalse(acknowledged)
        XCTAssertEqual(retryDelays, [86_400_000_000_000])
        XCTAssertEqual(
            WorkoutWriteRetryDeadlineStore.load(
                userID: "user-a", defaults: defaults),
            fixedDate.addingTimeInterval(24 * 60 * 60))
    }

    func testMultipleOfflineSetsReserveIndexesButDoNotCompleteSlot() async {
        let defaults = defaults()
        let ex = exercise(targetSets: 2)
        let s = session()
        let api = SetWriteAPIStub()
        api.logHandler = { _, _, _ in throw URLError(.notConnectedToInternet) }
        var uuids = [
            UUID(uuidString: "11111111-1111-4111-8111-111111111111")!,
            UUID(uuidString: "22222222-2222-4222-8222-222222222222")!,
        ]
        let model = SyncModel(
            auth: retainedAuth(defaults: defaults), setWriteAPI: api,
            defaults: defaults, uuidFactory: { uuids.removeFirst() },
            now: { self.fixedDate })
        prepare(model, exercise: ex, session: s)

        let firstAttempt = await model.logSet(ex, weight: 135, reps: 5)
        let secondAttempt = await model.logSet(ex, weight: 135, reps: 5)
        XCTAssertFalse(firstAttempt)
        XCTAssertFalse(secondAttempt)

        XCTAssertEqual(model.setOutbox.pending.map(\.body.set_index), [1, 2])
        XCTAssertEqual(model.currentSetNumber, 3)
        XCTAssertEqual(model.setsDone(ex), 0)
        XCTAssertFalse(model.isComplete(ex))
    }

    func testFinishQueuesBehindUnsettledSetAndDiscardSupersedesBoth() async {
        let defaults = defaults()
        let ex = exercise()
        let s = session()
        let setAPI = SetWriteAPIStub()
        setAPI.logHandler = { _, _, _ in
            throw URLError(.notConnectedToInternet)
        }
        let terminalAPI = SetTerminalAPIStub()
        terminalAPI.completeHandler = { [self] _, _ in
            session(status: "completed")
        }
        terminalAPI.discardHandler = { [self] _, _ in
            session(status: "discarded")
        }
        let model = SyncModel(
            auth: retainedAuth(defaults: defaults),
            setWriteAPI: setAPI,
            terminalAPI: terminalAPI,
            defaults: defaults, now: { self.fixedDate })
        prepare(model, exercise: ex, session: s, running: true)
        _ = await model.logSet(ex, weight: 135, reps: 5)

        await model.finishWorkout()
        XCTAssertTrue(model.running)
        XCTAssertEqual(model.currentTerminalIntent?.action, .finish)
        XCTAssertEqual(model.currentTerminalIntent?.deliveryState, .queued)
        XCTAssertTrue(terminalAPI.completeCalls.isEmpty)

        await model.discardWorkout()
        XCTAssertFalse(model.running)
        XCTAssertNil(model.todaySession)
        XCTAssertTrue(model.setOutbox.isEmpty)
        XCTAssertTrue(
            SetOutboxStore.load(userID: "user-a", defaults: defaults).isEmpty)
        XCTAssertEqual(model.currentTerminalIntent?.action, .discard)
        XCTAssertEqual(model.currentTerminalIntent?.deliveryState, .acknowledged)
        XCTAssertTrue(terminalAPI.completeCalls.isEmpty)
        XCTAssertEqual(terminalAPI.discardCalls.count, 1)
    }

    func testFinishPersistsBeforeAwaitAndStaysTruthfulOnTimeout() async {
        let defaults = defaults()
        let ex = exercise()
        let s = session()
        let terminalAPI = SetTerminalAPIStub()
        terminalAPI.completeHandler = { _, _ in
            let stored = WorkoutTerminalOutboxStore.load(
                userID: "user-a", defaults: defaults)
            XCTAssertEqual(stored.count, 1)
            XCTAssertEqual(stored.intents.first?.action, .finish)
            XCTAssertEqual(stored.intents.first?.resolvedSessionID, s.id)
            throw URLError(.timedOut)
        }
        let model = SyncModel(
            auth: retainedAuth(defaults: defaults),
            terminalAPI: terminalAPI,
            defaults: defaults,
            uuidFactory: { self.fixedUUID },
            now: { self.fixedDate })
        prepare(model, exercise: ex, session: s, running: true)
        model.finished = true

        await model.finishWorkout()

        XCTAssertTrue(model.running)
        XCTAssertTrue(model.finished)
        XCTAssertEqual(model.currentTerminalIntent?.id, fixedUUID.uuidString)
        XCTAssertEqual(model.currentTerminalIntent?.deliveryState, .queued)
        XCTAssertEqual(terminalAPI.completeCalls.count, 1)
    }

    func testFinishSurvivesUnauthorizedResponseAndSameUserReauthentication() async {
        let defaults = defaults()
        let ex = exercise()
        let s = session()
        let oldToken = jwt(subject: "user-a")
        let newToken = jwt(
            subject: "user-a",
            expiration: fixedDate.addingTimeInterval(5_000_000))
        let authAPI = SetAuthAPIStub()
        let auth = auth(
            defaults: defaults, api: authAPI, token: oldToken)
        let terminalAPI = SetTerminalAPIStub()
        terminalAPI.completeHandler = { [self] _, jwt in
            if jwt == oldToken {
                throw APIError.http(401, "invalid_token")
            }
            XCTAssertEqual(jwt, newToken)
            return session(status: "completed")
        }
        let model = SyncModel(
            auth: auth,
            terminalAPI: terminalAPI,
            defaults: defaults,
            now: { self.fixedDate })
        prepare(model, exercise: ex, session: s, running: true)

        await model.finishWorkout()

        XCTAssertNil(auth.jwt)
        XCTAssertEqual(auth.userID, "user-a")
        XCTAssertEqual(model.currentTerminalIntent?.deliveryState, .queued)
        XCTAssertEqual(
            WorkoutTerminalOutboxStore.load(
                userID: "user-a", defaults: defaults).count,
            1)

        authAPI.authResult = .success(.init(
            jwt: newToken,
            user: .init(id: "user-a", display_name: nil, email: nil)))
        await auth.exchange(identityToken: "same-user", fullName: nil)
        let replacement = SyncModel(
            auth: auth,
            terminalAPI: terminalAPI,
            defaults: defaults,
            now: { self.fixedDate })
        await replacement.drainWorkoutWriteOutboxes()

        XCTAssertEqual(terminalAPI.completeCalls.map(\.jwt), [oldToken, newToken])
        XCTAssertTrue(replacement.terminalOutbox.isEmpty)
        XCTAssertTrue(
            WorkoutTerminalOutboxStore.load(
                userID: "user-a", defaults: defaults).isEmpty)
    }

    func testFinishSendsOnlyAfterItsQueuedSetIsAcknowledged() async {
        let defaults = defaults()
        let ex = exercise()
        let s = session()
        let body = SetRequestBody(
            id: fixedUUID.uuidString,
            exercise_id: ex.exercise_id,
            template_exercise_id: ex.id,
            set_index: 1,
            weight: 135,
            reps: 5,
            is_warmup: false,
            logged_at: 2_000_000_000_000,
            duration_s: nil,
            is_timed: false)
        var persisted = SetOutbox()
        persisted.enqueue(.init(
            body: body,
            date: s.date,
            workoutID: "day-a",
            resolvedSessionID: s.id,
            deliveryState: .queued,
            failedHTTPStatus: nil))
        SetOutboxStore.save(persisted, userID: "user-a", defaults: defaults)
        let setAPI = SetWriteAPIStub()
        let terminalAPI = SetTerminalAPIStub()
        var order: [String] = []
        let committed = setLog(body: body, sessionID: s.id)
        setAPI.logHandler = { _, _, _ in
            order.append("set")
            return .init(set: committed, deduped: false)
        }
        setAPI.stateHandler = { [self] _ in
            state(session: s, sets: [committed], exercise: ex)
        }
        terminalAPI.completeHandler = { [self] _, _ in
            order.append("finish")
            return session(status: "completed")
        }
        let model = SyncModel(
            auth: retainedAuth(defaults: defaults),
            setWriteAPI: setAPI,
            terminalAPI: terminalAPI,
            defaults: defaults,
            now: { self.fixedDate })
        prepare(model, exercise: ex, session: s, running: true)

        await model.finishWorkout()

        XCTAssertEqual(order, ["set", "finish"])
        XCTAssertTrue(model.setOutbox.isEmpty)
        XCTAssertTrue(model.terminalOutbox.isEmpty)
        XCTAssertFalse(model.running)
    }

    func testDiscardRequestedDuringInFlightFinishIsFinalMutation() async {
        let defaults = defaults()
        let ex = exercise()
        let s = session()
        let setAPI = SetWriteAPIStub()
        let terminalAPI = SetTerminalAPIStub()
        let finishEntered = SetAsyncLatch()
        let releaseFinish = SetAsyncLatch()
        terminalAPI.completeHandler = { [self] _, _ in
            await finishEntered.open()
            await releaseFinish.wait()
            return session(status: "completed")
        }
        terminalAPI.discardHandler = { [self] _, _ in
            session(status: "discarded")
        }
        let model = SyncModel(
            auth: retainedAuth(defaults: defaults),
            setWriteAPI: setAPI,
            terminalAPI: terminalAPI,
            defaults: defaults,
            now: { self.fixedDate })
        prepare(model, exercise: ex, session: s, running: true)

        let finish = Task { await model.finishWorkout() }
        await finishEntered.wait()
        XCTAssertTrue(model.isTerminalMutationInFlight)
        let discard = Task { await model.discardWorkout() }
        await Task.yield()
        XCTAssertEqual(
            WorkoutTerminalOutboxStore.load(
                userID: "user-a", defaults: defaults).intents.first?.action,
            .discard)

        await releaseFinish.open()
        await finish.value
        await discard.value

        XCTAssertEqual(terminalAPI.completeCalls.count, 1)
        XCTAssertEqual(terminalAPI.discardCalls.count, 1)
        XCTAssertEqual(model.currentTerminalIntent?.action, .discard)
        XCTAssertEqual(model.currentTerminalIntent?.deliveryState, .acknowledged)
        XCTAssertFalse(model.running)
    }

    func testDiscardRequestedDuringInFlightSetMasksLateAcknowledgement() async {
        let defaults = defaults()
        let ex = exercise()
        let s = session()
        let setAPI = SetWriteAPIStub()
        let terminalAPI = SetTerminalAPIStub()
        let setEntered = SetAsyncLatch()
        let releaseSet = SetAsyncLatch()
        var committed: SetLog?
        setAPI.logHandler = { [self] sessionID, body, _ in
            await setEntered.open()
            await releaseSet.wait()
            let row = setLog(body: body, sessionID: sessionID)
            committed = row
            return .init(set: row, deduped: false)
        }
        setAPI.stateHandler = { [self] _ in
            state(session: s, sets: committed.map { [$0] } ?? [], exercise: ex)
        }
        terminalAPI.discardHandler = { [self] _, _ in
            session(status: "discarded")
        }
        let model = SyncModel(
            auth: retainedAuth(defaults: defaults),
            setWriteAPI: setAPI,
            terminalAPI: terminalAPI,
            defaults: defaults,
            now: { self.fixedDate })
        prepare(model, exercise: ex, session: s, running: true)

        let setTask = Task { await model.logSet(ex, weight: 135, reps: 5) }
        await setEntered.wait()
        let discard = Task { await model.discardWorkout() }
        await Task.yield()
        XCTAssertTrue(
            SetOutboxStore.load(userID: "user-a", defaults: defaults).isEmpty)

        await releaseSet.open()
        let setAcknowledged = await setTask.value
        await discard.value

        XCTAssertFalse(setAcknowledged)
        XCTAssertTrue(model.sets.isEmpty)
        XCTAssertTrue(model.setOutbox.isEmpty)
        XCTAssertEqual(model.currentTerminalIntent?.deliveryState, .acknowledged)
        XCTAssertEqual(terminalAPI.discardCalls.count, 1)
    }

    func testPermanentTerminalFailureRequiresExplicitRetry() async {
        let defaults = defaults()
        let ex = exercise()
        let s = session()
        let terminalAPI = SetTerminalAPIStub()
        terminalAPI.completeHandler = { [self] _, _ in
            if terminalAPI.completeCalls.count == 1 {
                throw APIError.http(422, "rejected")
            }
            return session(status: "completed")
        }
        let model = SyncModel(
            auth: retainedAuth(defaults: defaults),
            terminalAPI: terminalAPI,
            defaults: defaults,
            now: { self.fixedDate })
        prepare(model, exercise: ex, session: s, running: true)

        await model.finishWorkout()
        let id = try! XCTUnwrap(model.currentTerminalIntent?.id)
        XCTAssertEqual(model.currentTerminalIntent?.deliveryState, .failed)
        XCTAssertTrue(model.running)

        await model.retryTerminalIntent(id: id)

        XCTAssertEqual(terminalAPI.completeCalls.count, 2)
        XCTAssertTrue(model.terminalOutbox.isEmpty)
        XCTAssertFalse(model.running)
    }

    func testRelaunchDrainsPersistedFinishWithSameSessionAndAction() async {
        let defaults = defaults()
        let ex = exercise()
        let s = session()
        var terminal = WorkoutTerminalOutbox()
        terminal.enqueue(.init(
            id: fixedUUID.uuidString,
            action: .finish,
            date: s.date,
            workoutID: "day-a",
            resolvedSessionID: s.id,
            deliveryState: .queued,
            failedHTTPStatus: nil))
        WorkoutTerminalOutboxStore.save(
            terminal, userID: "user-a", defaults: defaults)
        let terminalAPI = SetTerminalAPIStub()
        terminalAPI.completeHandler = { [self] sessionID, _ in
            XCTAssertEqual(sessionID, s.id)
            return session(status: "completed")
        }
        let model = SyncModel(
            auth: retainedAuth(defaults: defaults),
            terminalAPI: terminalAPI,
            defaults: defaults,
            now: { self.fixedDate })
        prepare(model, exercise: ex, session: s, running: true)

        await model.drainWorkoutWriteOutboxes()

        XCTAssertEqual(terminalAPI.completeCalls.count, 1)
        XCTAssertTrue(model.terminalOutbox.isEmpty)
        XCTAssertTrue(
            WorkoutTerminalOutboxStore.load(
                userID: "user-a", defaults: defaults).isEmpty)
    }

    func testTerminalLateCallbackAfterAccountSwitchCannotTouchEitherQueue() async {
        let defaults = defaults()
        let ex = exercise()
        let s = session()
        let authAPI = SetAuthAPIStub()
        let auth = auth(defaults: defaults, api: authAPI)
        let terminalAPI = SetTerminalAPIStub()
        let entered = SetAsyncLatch()
        let release = SetAsyncLatch()
        terminalAPI.completeHandler = { [self] _, _ in
            await entered.open()
            await release.wait()
            return session(status: "completed")
        }
        let model = SyncModel(
            auth: auth,
            terminalAPI: terminalAPI,
            defaults: defaults,
            now: { self.fixedDate })
        prepare(model, exercise: ex, session: s, running: true)

        let finish = Task { await model.finishWorkout() }
        await entered.wait()
        authAPI.authResult = .success(.init(
            jwt: jwt(subject: "user-b"),
            user: .init(id: "user-b", display_name: nil, email: nil)))
        await auth.exchange(identityToken: "apple-b", fullName: nil)
        await release.open()
        await finish.value

        XCTAssertEqual(
            WorkoutTerminalOutboxStore.load(
                userID: "user-a", defaults: defaults).count,
            1)
        XCTAssertTrue(
            WorkoutTerminalOutboxStore.load(
                userID: "user-b", defaults: defaults).isEmpty)
    }

    func testDiscardInFlightExcludesNewSetAndTimedStart() async {
        let defaults = defaults()
        let ex = exercise(timed: true)
        let s = session()
        let setAPI = SetWriteAPIStub()
        let terminalAPI = SetTerminalAPIStub()
        let discardEntered = SetAsyncLatch()
        let releaseDiscard = SetAsyncLatch()
        terminalAPI.discardHandler = { [self] _, _ in
            await discardEntered.open()
            await releaseDiscard.wait()
            return session(status: "discarded")
        }
        let model = SyncModel(
            auth: retainedAuth(defaults: defaults),
            setWriteAPI: setAPI,
            terminalAPI: terminalAPI,
            defaults: defaults,
            now: { self.fixedDate })
        prepare(model, exercise: ex, session: s, running: true)

        let discard = Task { await model.discardWorkout() }
        await discardEntered.wait()
        XCTAssertTrue(model.isTerminalMutationInFlight)

        let acknowledged = await model.logSet(ex, weight: 0, reps: 30)
        model.startTimedSet(
            expected: ex, expectedSetNumber: model.currentSetNumber)

        XCTAssertFalse(acknowledged)
        XCTAssertFalse(model.timedActive)
        XCTAssertTrue(model.setOutbox.isEmpty)
        XCTAssertTrue(
            SetOutboxStore.load(userID: "user-a", defaults: defaults).isEmpty)
        XCTAssertTrue(setAPI.logCalls.isEmpty)
        XCTAssertTrue(terminalAPI.completeCalls.isEmpty)
        XCTAssertEqual(terminalAPI.discardCalls.count, 1)

        await releaseDiscard.open()
        await discard.value
        XCTAssertFalse(model.isTerminalMutationInFlight)
    }

    func testAcknowledgedDiscardBarrierMasksRevivalAndRequeuesDiscard() async {
        let defaults = defaults()
        let ex = exercise()
        let revived = session(status: "planned")
        var terminal = WorkoutTerminalOutbox()
        terminal.enqueue(.init(
            id: fixedUUID.uuidString,
            action: .discard,
            date: revived.date,
            workoutID: "day-a",
            resolvedSessionID: revived.id,
            deliveryState: .acknowledged,
            failedHTTPStatus: nil))
        WorkoutTerminalOutboxStore.save(
            terminal, userID: "user-a", defaults: defaults)
        let terminalAPI = SetTerminalAPIStub()
        terminalAPI.discardHandler = { [self] _, _ in
            session(status: "discarded")
        }
        let model = SyncModel(
            auth: retainedAuth(defaults: defaults),
            terminalAPI: terminalAPI,
            defaults: defaults,
            now: { self.fixedDate })
        prepare(model, exercise: ex)

        model.replaceState(with: state(
            session: revived, sets: [], exercise: ex))

        XCTAssertNil(model.todaySession)
        XCTAssertEqual(model.currentTerminalIntent?.deliveryState, .queued)
        await model.drainWorkoutWriteOutboxes()
        XCTAssertEqual(terminalAPI.discardCalls.count, 1)
        XCTAssertEqual(model.currentTerminalIntent?.deliveryState, .acknowledged)
    }

    func testExplicitStartClearsOnlyAcknowledgedDiscardBarrier() {
        let defaults = defaults()
        let ex = exercise()
        let discarded = session(status: "discarded")
        var terminal = WorkoutTerminalOutbox()
        terminal.enqueue(.init(
            id: fixedUUID.uuidString,
            action: .discard,
            date: discarded.date,
            workoutID: "day-a",
            resolvedSessionID: discarded.id,
            deliveryState: .acknowledged,
            failedHTTPStatus: nil))
        WorkoutTerminalOutboxStore.save(
            terminal, userID: "user-a", defaults: defaults)
        let model = SyncModel(
            auth: retainedAuth(defaults: defaults),
            defaults: defaults,
            now: { self.fixedDate })
        prepare(model, exercise: ex)
        model.replaceState(with: state(
            session: discarded, sets: [], exercise: ex))

        model.startWorkout()

        XCTAssertTrue(model.running)
        XCTAssertTrue(model.terminalOutbox.isEmpty)
        XCTAssertEqual(
            WorkoutRunnerCheckpointStore.load(
                userID: "user-a", defaults: defaults)?.restartDiscardedAttempt,
            0)
        XCTAssertTrue(
            WorkoutTerminalOutboxStore.load(
                userID: "user-a", defaults: defaults).isEmpty)
    }

    func testNilBoundOrdinaryRunnerStopsWhenRemoteDiscardAppears() {
        let defaults = defaults()
        let ex = exercise()
        let model = SyncModel(
            auth: retainedAuth(defaults: defaults),
            defaults: defaults,
            now: { self.fixedDate })
        prepare(model, exercise: ex, running: true)
        XCTAssertNil(WorkoutRunnerCheckpointStore.load(
            userID: "user-a", defaults: defaults)?.restartDiscardedAttempt)

        model.replaceState(with: state(
            session: session(
                status: "discarded", updatedAt: 100, attempt: 0),
            sets: [], exercise: ex))

        XCTAssertFalse(model.running)
        XCTAssertNil(WorkoutRunnerCheckpointStore.load(
            userID: "user-a", defaults: defaults))
    }

    func testMountedOrdinaryNilBoundRunnerRejectsNewerLiveAttempt() {
        let defaults = defaults()
        let ex = exercise()
        let model = SyncModel(
            auth: retainedAuth(defaults: defaults),
            defaults: defaults,
            now: { self.fixedDate })
        prepare(model, exercise: ex, running: true)
        let initial = WorkoutRunnerCheckpointStore.load(
            userID: "user-a", defaults: defaults)
        XCTAssertNil(initial?.sessionID)
        XCTAssertNil(initial?.sessionAttempt)
        XCTAssertNil(initial?.restartDiscardedAttempt)

        model.replaceState(with: state(
            session: session(
                status: "in_progress", updatedAt: 100, attempt: 1),
            sets: [], exercise: ex))

        XCTAssertFalse(model.running)
        XCTAssertNil(WorkoutRunnerCheckpointStore.load(
            userID: "user-a", defaults: defaults))
    }

    func testColdOrdinaryNilBoundCheckpointRejectsNewerLiveAttempt() {
        let defaults = defaults()
        let ex = exercise()
        WorkoutRunnerCheckpointStore.save(
            .init(
                date: fixedCivilDate,
                sessionID: nil,
                selectedDayID: "day-a",
                currentSlotID: ex.id,
                skippedSlotIDs: [],
                workoutStartedAtMS: 2_000_000_000_000,
                finished: false,
                sessionAttempt: nil,
                restartDiscardedAttempt: nil),
            userID: "user-a", defaults: defaults)
        let model = SyncModel(
            auth: retainedAuth(defaults: defaults),
            defaults: defaults,
            now: { self.fixedDate })

        model.replaceState(with: state(
            session: session(
                status: "in_progress", updatedAt: 100, attempt: 1),
            sets: [], exercise: ex))

        XCTAssertFalse(model.hasResumableWorkout)
        XCTAssertNil(WorkoutRunnerCheckpointStore.load(
            userID: "user-a", defaults: defaults))
    }

    func testColdBoundLegacyAttemptZeroCheckpointRejectsAttemptOne() {
        let defaults = defaults()
        let ex = exercise()
        WorkoutRunnerCheckpointStore.save(
            .init(
                date: fixedCivilDate,
                sessionID: "session-a",
                selectedDayID: "day-a",
                currentSlotID: ex.id,
                skippedSlotIDs: [],
                workoutStartedAtMS: 2_000_000_000_000,
                finished: false,
                sessionAttempt: nil,
                restartDiscardedAttempt: nil),
            userID: "user-a", defaults: defaults)
        let model = SyncModel(
            auth: retainedAuth(defaults: defaults),
            defaults: defaults,
            now: { self.fixedDate })

        model.replaceState(with: state(
            session: session(
                status: "in_progress", updatedAt: 100, attempt: 1),
            sets: [], exercise: ex))

        XCTAssertFalse(model.hasResumableWorkout)
        XCTAssertNil(WorkoutRunnerCheckpointStore.load(
            userID: "user-a", defaults: defaults))
    }

    func testExplicitRestartCheckpointBindsToRevivedAttemptOne() {
        let defaults = defaults()
        let ex = exercise()
        let discarded = session(
            status: "discarded", updatedAt: 100, attempt: 0)
        var terminal = WorkoutTerminalOutbox()
        terminal.enqueue(.init(
            id: fixedUUID.uuidString,
            action: .discard,
            date: discarded.date,
            workoutID: "day-a",
            resolvedSessionID: discarded.id,
            deliveryState: .acknowledged,
            failedHTTPStatus: nil,
            expectedAttempt: 0))
        WorkoutTerminalOutboxStore.save(
            terminal, userID: "user-a", defaults: defaults)
        let model = SyncModel(
            auth: retainedAuth(defaults: defaults),
            defaults: defaults,
            now: { self.fixedDate })
        model.replaceState(with: state(
            session: discarded, sets: [], exercise: ex))
        model.startWorkout()
        XCTAssertEqual(
            WorkoutRunnerCheckpointStore.load(
                userID: "user-a", defaults: defaults)?
                .restartDiscardedAttempt,
            0)

        model.replaceState(with: state(
            session: session(
                status: "planned", updatedAt: 200, attempt: 1),
            sets: [], exercise: ex))

        XCTAssertTrue(model.running)
        let rebound = WorkoutRunnerCheckpointStore.load(
            userID: "user-a", defaults: defaults)
        XCTAssertEqual(rebound?.sessionID, discarded.id)
        XCTAssertEqual(rebound?.sessionAttempt, 1)
        XCTAssertNil(rebound?.restartDiscardedAttempt)
    }

    func testSkippedOverrideReopensBeforeRunnerAndFirstSet() async {
        let defaults = defaults()
        let original = exercise()
        let override = exercise(id: "slot-b", exerciseID: "exercise-b")
        let overrideDay = Workout(
            id: "day-b", name: "Day B", day_label: "B",
            order_index: 1, exercises: [override])
        let skipped = session(
            status: "skipped", updatedAt: 100, attempt: 0)
        let entered = SetAsyncLatch()
        let release = SetAsyncLatch()
        let api = SetWriteAPIStub()
        api.reopenHandler = { sessionID, workoutID, expectedAttempt, _ in
            XCTAssertEqual(sessionID, skipped.id)
            XCTAssertEqual(workoutID, overrideDay.id)
            XCTAssertEqual(expectedAttempt, 0)
            await entered.open()
            await release.wait()
            return SessionRow(
                id: skipped.id,
                date: skipped.date,
                status: "planned",
                workout_id: overrideDay.id,
                updated_at: 200,
                attempt: 1)
        }
        api.logHandler = { [self] sessionID, body, _ in
            .init(
                set: setLog(body: body, sessionID: sessionID),
                deduped: false,
                session: SessionRow(
                    id: sessionID,
                    date: skipped.date,
                    status: "in_progress",
                    workout_id: overrideDay.id,
                    updated_at: 300,
                    attempt: 1))
        }
        api.stateHandler = { _ in throw URLError(.notConnectedToInternet) }
        let model = SyncModel(
            auth: retainedAuth(defaults: defaults), setWriteAPI: api,
            defaults: defaults, uuidFactory: { self.fixedUUID },
            now: { self.fixedDate })
        model.replaceState(with: state(
            session: skipped, sets: [],
            workouts: [day(with: [original]), overrideDay]))

        model.startOverride(dayID: overrideDay.id)
        // A same-turn live apply may restore the skipped row's original day
        // before the unstructured reopen task evaluates its request.
        model.replaceState(with: state(
            session: skipped, sets: [],
            workouts: [day(with: [original]), overrideDay]))
        await entered.wait()

        XCTAssertTrue(model.isReopeningSkippedWorkout)
        XCTAssertFalse(model.running)
        XCTAssertTrue(api.createCalls.isEmpty)
        await release.open()
        while model.isReopeningSkippedWorkout { await Task.yield() }

        XCTAssertTrue(model.running)
        XCTAssertEqual(model.selectedDayID, overrideDay.id)
        XCTAssertEqual(model.currentExercise?.id, override.id)
        XCTAssertEqual(model.todaySession?.workout_id, overrideDay.id)
        XCTAssertEqual(model.todaySession?.status, "planned")
        XCTAssertEqual(model.todaySession?.attempt, 1)
        XCTAssertEqual(
            WorkoutRunnerCheckpointStore.load(
                userID: "user-a", defaults: defaults)?.selectedDayID,
            overrideDay.id)
        XCTAssertEqual(
            WorkoutRunnerCheckpointStore.load(
                userID: "user-a", defaults: defaults)?.sessionAttempt,
            1)
        XCTAssertNil(WorkoutRunnerCheckpointStore.load(
            userID: "user-a", defaults: defaults)?.restartDiscardedAttempt)

        let acknowledged = await model.logSet(
            override, weight: 135, reps: 5)
        XCTAssertTrue(acknowledged)
        XCTAssertTrue(api.createCalls.isEmpty)
        XCTAssertEqual(api.logCalls.first?.body.expected_attempt, 1)
        XCTAssertEqual(model.todaySession?.status, "in_progress")
        XCTAssertEqual(model.todaySession?.attempt, 1)
    }

    func testDelayedSkippedReopenRefreshesReplacementAfterSameUserReauth() async {
        let defaults = defaults()
        let original = exercise()
        let override = exercise(id: "slot-b", exerciseID: "exercise-b")
        let overrideDay = Workout(
            id: "day-b", name: "Day B", day_label: "B",
            order_index: 1, exercises: [override])
        let skipped = session(
            status: "skipped", updatedAt: 100, attempt: 0)
        let planned = SessionRow(
            id: skipped.id,
            date: skipped.date,
            status: "planned",
            workout_id: overrideDay.id,
            updated_at: 200,
            attempt: 1)
        let entered = SetAsyncLatch()
        let release = SetAsyncLatch()
        let api = SetWriteAPIStub()
        api.reopenHandler = { _, _, _, _ in
            await entered.open()
            await release.wait()
            return planned
        }
        api.stateHandler = { [self] _ in
            state(
                session: planned,
                sets: [],
                workouts: [day(with: [original]), overrideDay])
        }
        let oldToken = jwt(subject: "user-a")
        let newToken = jwt(
            subject: "user-a",
            expiration: fixedDate.addingTimeInterval(5_000_000))
        let authAPI = SetAuthAPIStub()
        authAPI.authResult = .success(authResponse(jwt: newToken, userID: "user-a"))
        let auth = auth(defaults: defaults, api: authAPI, token: oldToken)
        let old = SyncModel(
            auth: auth,
            setWriteAPI: api,
            defaults: defaults,
            now: { self.fixedDate })
        old.replaceState(with: state(
            session: skipped,
            sets: [],
            workouts: [day(with: [original]), overrideDay]))

        old.startOverride(dayID: overrideDay.id)
        await entered.wait()
        auth.signOut()
        await auth.exchange(identityToken: "same-user", fullName: nil)
        let replacement = SyncModel(
            auth: auth,
            setWriteAPI: api,
            catalogAPI: SetCatalogAPIStub(),
            defaults: defaults,
            now: { self.fixedDate })

        await release.open()
        while old.isReopeningSkippedWorkout { await Task.yield() }
        for _ in 0..<100 where replacement.todaySession?.attempt != 1 {
            await Task.yield()
        }

        XCTAssertFalse(old.running)
        XCTAssertNil(WorkoutRunnerCheckpointStore.load(
            userID: "user-a", defaults: defaults))
        XCTAssertEqual(replacement.todaySession?.status, "planned")
        XCTAssertEqual(replacement.todaySession?.attempt, 1)
        XCTAssertEqual(replacement.todaySession?.workout_id, overrideDay.id)
        XCTAssertGreaterThanOrEqual(api.stateCalls, 1)
    }

    func testDelayedSkippedReopenConflictRefreshesReplacementAfterReauth() async {
        let defaults = defaults()
        let ex = exercise()
        let skipped = session(
            status: "skipped", updatedAt: 100, attempt: 0)
        let conflictSession = session(
            status: "completed", updatedAt: 200, attempt: 1)
        let encoded = try! JSONEncoder().encode(conflictSession)
        let object = String(data: encoded, encoding: .utf8)!
        let entered = SetAsyncLatch()
        let release = SetAsyncLatch()
        let api = SetWriteAPIStub()
        api.reopenHandler = { _, _, _, _ in
            await entered.open()
            await release.wait()
            throw APIError.http(
                409,
                "{\"error\":\"session_attempt_conflict\",\"current_session\":\(object)}")
        }
        api.stateHandler = { [self] _ in
            state(session: conflictSession, sets: [], exercise: ex)
        }
        let oldToken = jwt(subject: "user-a")
        let newToken = jwt(
            subject: "user-a",
            expiration: fixedDate.addingTimeInterval(5_000_000))
        let authAPI = SetAuthAPIStub()
        authAPI.authResult = .success(authResponse(jwt: newToken, userID: "user-a"))
        let auth = auth(defaults: defaults, api: authAPI, token: oldToken)
        let old = SyncModel(
            auth: auth,
            setWriteAPI: api,
            defaults: defaults,
            now: { self.fixedDate })
        old.replaceState(with: state(
            session: skipped, sets: [], exercise: ex))

        old.startOverride(dayID: "day-a")
        await entered.wait()
        auth.signOut()
        await auth.exchange(identityToken: "same-user", fullName: nil)
        let replacement = SyncModel(
            auth: auth,
            setWriteAPI: api,
            catalogAPI: SetCatalogAPIStub(),
            defaults: defaults,
            now: { self.fixedDate })

        await release.open()
        while old.isReopeningSkippedWorkout { await Task.yield() }
        for _ in 0..<100 where replacement.todaySession?.attempt != 1 {
            await Task.yield()
        }

        XCTAssertFalse(old.running)
        XCTAssertEqual(replacement.todaySession?.status, "completed")
        XCTAssertEqual(replacement.todaySession?.attempt, 1)
        XCTAssertGreaterThanOrEqual(api.stateCalls, 1)
    }

    func testDelayedPlanEditRefreshesReplacementAfterSameUserReauth() async {
        let defaults = defaults()
        let first = exercise(id: "slot-a", exerciseID: "exercise-a")
        let deleted = exercise(id: "slot-b", exerciseID: "exercise-b")
        let s = session(status: "in_progress")
        let entered = SetAsyncLatch()
        let release = SetAsyncLatch()
        let editor = SetPlanEditingAPIStub()
        editor.deleteHandler = {
            await entered.open()
            await release.wait()
        }
        let setAPI = SetWriteAPIStub()
        setAPI.stateHandler = { [self] _ in
            state(session: s, sets: [], exercise: first)
        }
        let oldToken = jwt(subject: "user-a")
        let newToken = jwt(
            subject: "user-a",
            expiration: fixedDate.addingTimeInterval(5_000_000))
        let authAPI = SetAuthAPIStub()
        authAPI.authResult = .success(authResponse(jwt: newToken, userID: "user-a"))
        let auth = auth(defaults: defaults, api: authAPI, token: oldToken)
        let old = SyncModel(
            auth: auth,
            setWriteAPI: setAPI,
            planEditingAPI: editor,
            defaults: defaults,
            now: { self.fixedDate })
        old.replaceState(with: state(
            session: s, sets: [], exercises: [first, deleted]))
        old.startWorkout()
        let edit = Task {
            await old.deleteSlot(dayID: "day-a", teID: deleted.id)
        }
        await entered.wait()

        auth.signOut()
        await auth.exchange(identityToken: "same-user", fullName: nil)
        let replacement = SyncModel(
            auth: auth,
            setWriteAPI: setAPI,
            catalogAPI: SetCatalogAPIStub(),
            defaults: defaults,
            now: { self.fixedDate })
        await release.open()
        await edit.value
        for _ in 0..<100 where replacement.plan?.workouts.first?.exercises.count != 1 {
            await Task.yield()
        }

        XCTAssertEqual(editor.deleteCalls, 1)
        XCTAssertEqual(replacement.plan?.workouts.first?.exercises.map(\.id), [first.id])
        XCTAssertGreaterThanOrEqual(setAPI.stateCalls, 1)
    }

    func testDelayedSetRemovalRefreshesReplacementAfterSameUserReauth() async {
        let defaults = defaults()
        let ex = exercise()
        let s = session(status: "in_progress", updatedAt: 100, attempt: 0)
        let body = SetRequestBody(
            id: fixedUUID.uuidString,
            exercise_id: ex.exercise_id,
            template_exercise_id: ex.id,
            set_index: 1,
            weight: 100,
            reps: 5,
            is_warmup: false,
            logged_at: 1,
            duration_s: nil,
            is_timed: false)
        let savedSet = setLog(body: body, sessionID: s.id)
        StateSnapshotStore.save(
            state(session: s, sets: [savedSet], exercise: ex),
            userID: "user-a",
            defaults: defaults)
        let entered = SetAsyncLatch()
        let release = SetAsyncLatch()
        let setAPI = SetWriteAPIStub()
        setAPI.correctionHandler = { [self] _, _ in
            await entered.open()
            await release.wait()
            return SetCorrectionResult(set: setLog(body: body, sessionID: s.id, deletedAt: 200),
                                       session: session(status: "planned", updatedAt: 200, attempt: 0))
        }
        setAPI.stateHandler = { [self] _ in
            state(session: s, sets: [], exercise: ex)
        }
        let oldToken = jwt(subject: "user-a")
        let newToken = jwt(
            subject: "user-a",
            expiration: fixedDate.addingTimeInterval(5_000_000))
        let authAPI = SetAuthAPIStub()
        authAPI.authResult = .success(authResponse(jwt: newToken, userID: "user-a"))
        let auth = auth(defaults: defaults, api: authAPI, token: oldToken)
        let old = SyncModel(
            auth: auth,
            setWriteAPI: setAPI,
            defaults: defaults,
            now: { self.fixedDate })
        let removal = Task { await old.removeSet(savedSet) }
        await entered.wait()

        auth.signOut()
        await auth.exchange(identityToken: "same-user", fullName: nil)
        let replacement = SyncModel(
            auth: auth,
            setWriteAPI: setAPI,
            catalogAPI: SetCatalogAPIStub(),
            defaults: defaults,
            now: { self.fixedDate })
        XCTAssertEqual(replacement.sets.map(\.id), [savedSet.id])
        await release.open()
        await removal.value
        for _ in 0..<100 where !replacement.sets.isEmpty {
            await Task.yield()
        }

        XCTAssertEqual(setAPI.correctionCalls.map(\.setID), [savedSet.id])
        XCTAssertTrue(replacement.sets.isEmpty)
        XCTAssertGreaterThanOrEqual(setAPI.stateCalls, 1)
        XCTAssertEqual(old.sets.map(\.id), [savedSet.id])
    }

    func testSkippedOverrideFailureLeavesRestStateRetryable() async {
        let defaults = defaults()
        let ex = exercise()
        let skipped = session(
            status: "skipped", updatedAt: 100, attempt: 0)
        let api = SetWriteAPIStub()
        api.reopenHandler = { _, _, _, _ in
            throw URLError(.notConnectedToInternet)
        }
        let model = SyncModel(
            auth: retainedAuth(defaults: defaults), setWriteAPI: api,
            defaults: defaults, now: { self.fixedDate })
        model.replaceState(with: state(
            session: skipped, sets: [], exercise: ex))

        model.startOverride(dayID: "day-a")
        while model.isReopeningSkippedWorkout { await Task.yield() }

        XCTAssertFalse(model.running)
        XCTAssertEqual(model.todaySession?.status, "skipped")
        XCTAssertEqual(model.todaySession?.attempt, 0)
        XCTAssertTrue(model.setOutbox.isEmpty)
        XCTAssertNil(WorkoutRunnerCheckpointStore.load(
            userID: "user-a", defaults: defaults))
        XCTAssertNotNil(model.loadError)
    }

    func testRefreshAfterExplicitRestartCreatesSessionBeforeFirstSet() async {
        let defaults = defaults()
        let ex = exercise()
        let discarded = session(status: "discarded", attempt: 0)
        var terminal = WorkoutTerminalOutbox()
        terminal.enqueue(.init(
            id: fixedUUID.uuidString,
            action: .discard,
            date: discarded.date,
            workoutID: "day-a",
            resolvedSessionID: discarded.id,
            deliveryState: .acknowledged,
            failedHTTPStatus: nil,
            expectedAttempt: 0))
        WorkoutTerminalOutboxStore.save(
            terminal, userID: "user-a", defaults: defaults)
        let setAPI = SetWriteAPIStub()
        let revived = session(status: "planned", attempt: 1)
        var committed: SetLog?
        setAPI.createHandler = { _, _, _ in revived }
        setAPI.logHandler = { [self] sessionID, body, _ in
            let row = setLog(body: body, sessionID: sessionID)
            committed = row
            return .init(set: row, deduped: false)
        }
        setAPI.stateHandler = { [self] _ in
            state(
                session: revived,
                sets: committed.map { [$0] } ?? [],
                exercise: ex)
        }
        let model = SyncModel(
            auth: retainedAuth(defaults: defaults),
            setWriteAPI: setAPI,
            defaults: defaults,
            now: { self.fixedDate })
        prepare(model, exercise: ex)
        model.replaceState(with: state(
            session: discarded, sets: [], exercise: ex))

        model.startWorkout()
        model.replaceState(with: state(
            session: discarded, sets: [], exercise: ex))

        XCTAssertNil(model.todaySession)
        let acknowledged = await model.logSet(ex, weight: 135, reps: 5)
        XCTAssertTrue(acknowledged)
        XCTAssertEqual(setAPI.createCalls.count, 1)
        XCTAssertEqual(setAPI.logCalls.first?.sessionID, revived.id)
    }

    func testRefreshAfterExplicitRestartCreatesSessionBeforeFinish() async {
        let defaults = defaults()
        let ex = exercise()
        let discarded = session(status: "discarded", attempt: 0)
        var terminal = WorkoutTerminalOutbox()
        terminal.enqueue(.init(
            id: fixedUUID.uuidString,
            action: .discard,
            date: discarded.date,
            workoutID: "day-a",
            resolvedSessionID: discarded.id,
            deliveryState: .acknowledged,
            failedHTTPStatus: nil,
            expectedAttempt: 0))
        WorkoutTerminalOutboxStore.save(
            terminal, userID: "user-a", defaults: defaults)
        let setAPI = SetWriteAPIStub()
        let terminalAPI = SetTerminalAPIStub()
        let revived = session(status: "planned", attempt: 1)
        var order: [String] = []
        setAPI.createHandler = { _, _, _ in
            order.append("create")
            return revived
        }
        terminalAPI.completeHandler = { [self] sessionID, _ in
            XCTAssertEqual(sessionID, revived.id)
            order.append("finish")
            return session(status: "completed", attempt: 1)
        }
        let model = SyncModel(
            auth: retainedAuth(defaults: defaults),
            setWriteAPI: setAPI,
            terminalAPI: terminalAPI,
            defaults: defaults,
            now: { self.fixedDate })
        prepare(model, exercise: ex)
        model.replaceState(with: state(
            session: discarded, sets: [], exercise: ex))

        model.startWorkout()
        model.replaceState(with: state(
            session: discarded, sets: [], exercise: ex))

        XCTAssertNil(model.todaySession)
        await model.finishWorkout()
        XCTAssertEqual(order, ["create", "finish"])
        XCTAssertEqual(setAPI.createCalls.first?.expectedAttempt, 0)
        XCTAssertEqual(setAPI.createCalls.first?.restartDiscardedAttempt, 0)
        XCTAssertEqual(terminalAPI.completeExpectedAttempts, [1])
        XCTAssertTrue(model.terminalOutbox.isEmpty)
        XCTAssertFalse(model.running)
    }

    func testColdLaunchRendersCachedStateWithoutAcknowledgingDurableWrites() {
        let defaults = defaults()
        let ex = exercise()
        let liveSession = session()
        let body = SetRequestBody(
            id: fixedUUID.uuidString,
            exercise_id: ex.exercise_id,
            template_exercise_id: ex.id,
            set_index: 1,
            weight: 135,
            reps: 5,
            is_warmup: false,
            logged_at: 2_000_000_000_000,
            duration_s: nil,
            is_timed: false)
        var outbox = SetOutbox()
        outbox.enqueue(.init(
            body: body,
            date: fixedCivilDate,
            workoutID: "day-a",
            resolvedSessionID: liveSession.id,
            deliveryState: .queued,
            failedHTTPStatus: nil))
        SetOutboxStore.save(outbox, userID: "user-a", defaults: defaults)
        WorkoutRunnerCheckpointStore.save(
            .init(
                date: fixedCivilDate,
                sessionID: liveSession.id,
                selectedDayID: "day-a",
                currentSlotID: ex.id,
                skippedSlotIDs: [],
                workoutStartedAtMS: 2_000_000_000_000,
                finished: false),
            userID: "user-a",
            defaults: defaults)
        // The cached response contains the same set id. Only a fresh server
        // response may use that row as an acknowledgement.
        StateSnapshotStore.save(
            state(
                session: liveSession,
                sets: [setLog(body: body)],
                exercise: ex),
            userID: "user-a",
            defaults: defaults)

        let model = SyncModel(
            auth: retainedAuth(defaults: defaults),
            defaults: defaults,
            now: { self.fixedDate })

        XCTAssertEqual(model.plan?.name, "Plan A")
        XCTAssertTrue(model.isUsingCachedState)
        XCTAssertTrue(model.needsLiveWorkoutValidation)
        XCTAssertFalse(model.hasResumableWorkout)
        XCTAssertEqual(model.pendingSetIntentCount, 1)
        XCTAssertEqual(
            SetOutboxStore.load(
                userID: "user-a", defaults: defaults).count,
            1)

        let savedCheckpoint = WorkoutRunnerCheckpointStore.load(
            userID: "user-a", defaults: defaults)
        model.startWorkout()
        model.startToday()
        model.startOverride(dayID: "different-day")

        XCTAssertFalse(model.running)
        XCTAssertEqual(model.selectedDayID, "day-a")
        XCTAssertEqual(
            WorkoutRunnerCheckpointStore.load(
                userID: "user-a", defaults: defaults),
            savedCheckpoint,
            "no alternate start path may erase recovery before live validation")
        XCTAssertTrue(model.loadError?.contains("Connect") == true)
    }

    func testEveryCachedStateIsBrowseOnlyUntilLiveValidation() {
        for includePlannedSession in [true, false] {
            let defaults = defaults()
            let ex = exercise()
            let planned = session(status: "planned")
            let base = state(session: planned, sets: [], exercise: ex)
            StateSnapshotStore.save(
                StateResponse(
                    plan: base.plan,
                    plan_version: base.plan_version,
                    sessions: includePlannedSession ? [planned] : [],
                    sets: [],
                    external_events: [],
                    external_activities: [],
                    activities: [],
                    server_time: base.server_time),
                userID: "user-a",
                defaults: defaults)
            let model = SyncModel(
                auth: retainedAuth(defaults: defaults),
                defaults: defaults,
                now: { self.fixedDate })
            let originalDay = model.selectedDayID

            model.startWorkout()
            model.startToday()
            model.startOverride(dayID: "different-day")

            XCTAssertTrue(model.isUsingCachedState)
            XCTAssertTrue(model.needsLiveWorkoutValidation)
            XCTAssertTrue(model.blocksNewWorkoutStart)
            XCTAssertFalse(model.running)
            XCTAssertEqual(model.selectedDayID, originalDay)
            XCTAssertTrue(model.setOutbox.isEmpty)
            XCTAssertNil(WorkoutRunnerCheckpointStore.load(
                userID: "user-a", defaults: defaults))
        }
    }

    func testColdLaunchRestoresCatalogSemanticsForOfflineHistory() throws {
        let defaults = defaults()
        let ex = exercise(exerciseID: "exercise-unilateral")
        let completed = session(status: "completed")
        let unilateralBody = SetRequestBody(
            id: "22222222-2222-4222-8222-222222222222",
            exercise_id: "exercise-unilateral",
            template_exercise_id: ex.id,
            set_index: 1,
            weight: 40,
            reps: 5,
            is_warmup: false,
            logged_at: 2_000_000_000_000,
            duration_s: nil,
            is_timed: false)
        let bodyweightBody = SetRequestBody(
            id: "33333333-3333-4333-8333-333333333333",
            exercise_id: "exercise-bodyweight",
            template_exercise_id: "bodyweight-slot",
            set_index: 1,
            weight: 0,
            reps: 10,
            is_warmup: false,
            logged_at: 2_000_000_000_001,
            duration_s: nil,
            is_timed: false)
        StateSnapshotStore.save(
            state(
                session: completed,
                sets: [
                    setLog(body: unilateralBody),
                    setLog(body: bodyweightBody),
                ],
                exercise: ex),
            userID: "user-a",
            defaults: defaults)
        ExerciseCatalogSnapshotStore.save(
            [
                ExerciseCatalog(
                    id: "exercise-unilateral",
                    name: "Split Squat",
                    primary_muscle: "legs",
                    modality: "dumbbell",
                    unit: "lb",
                    laterality: "unilateral",
                    load_mode: "per_hand",
                    demo_slug: nil),
                ExerciseCatalog(
                    id: "exercise-bodyweight",
                    name: "Push-Up",
                    primary_muscle: "chest",
                    modality: "bw",
                    unit: "reps",
                    laterality: "bilateral",
                    load_mode: "total",
                    demo_slug: nil),
            ],
            userID: "user-a",
            defaults: defaults)

        let model = SyncModel(
            auth: retainedAuth(defaults: defaults),
            defaults: defaults,
            now: { self.fixedDate })

        XCTAssertEqual(model.exerciseName("exercise-unilateral"), "Split Squat")
        XCTAssertEqual(model.sides(for: "exercise-unilateral"), 2)
        XCTAssertEqual(model.implements(for: "exercise-unilateral"), 2)
        XCTAssertEqual(
            try XCTUnwrap(model.history(for: "exercise-unilateral").first).volume,
            800)
        XCTAssertEqual(model.exerciseName("exercise-bodyweight"), "Push-Up")
        XCTAssertTrue(model.isBodyweightExercise("exercise-bodyweight"))
    }

    func testHistoryDurationUsesPerSetTimedFlagInsteadOfCatalogModality() throws {
        let defaults = defaults()
        let ex = exercise(exerciseID: "exercise-bodyweight")
        let s = session(status: "completed")
        let model = SyncModel(
            auth: retainedAuth(defaults: defaults),
            defaults: defaults,
            now: { self.fixedDate })
        prepare(model, exercise: ex, session: s)
        model.catalog = [ExerciseCatalog(
            id: ex.exercise_id,
            name: "Ring Row",
            primary_muscle: "back",
            modality: "bw",
            unit: "lb",
            laterality: "bilateral",
            load_mode: "total",
            demo_slug: nil)]
        model.sessions = [s]
        model.sets = [
            SetLog(
                id: "timed", session_id: s.id,
                exercise_id: ex.exercise_id,
                template_exercise_id: ex.id, set_index: 1,
                weight: 0, reps: 45, rpe: nil, is_warmup: 0,
                logged_at: 1, duration_s: nil, is_timed: 1,
                deleted_at: nil),
            SetLog(
                id: "rep", session_id: s.id,
                exercise_id: ex.exercise_id,
                template_exercise_id: ex.id, set_index: 2,
                weight: 0, reps: 8, rpe: nil, is_warmup: 0,
                logged_at: 2, duration_s: 99, is_timed: 0,
                deleted_at: nil),
        ]

        let stat = try XCTUnwrap(model.history(for: ex.exercise_id).first)
        XCTAssertEqual(stat.bestReps, 8)
        XCTAssertEqual(stat.bestHoldSeconds, 45)
    }

    func testSharedBodyweightFixturesInHistoryAndCompletion() throws {
        for fixture in try BodyweightProgressFixture.load() {
            let defaults = defaults()
            let model = SyncModel(auth: retainedAuth(defaults: defaults), defaults: defaults,
                                  now: { self.fixedDate })
            model.catalog = fixture.catalog
            model.sessions = [session(id: fixture.name, date: "2026-09-01", status: "completed")]
            model.sets = fixture.sets
            let stat = try XCTUnwrap(model.history(for: fixture.catalog[0].id).first)
            let completion = model.metricCohorts(for: model.sets)
            XCTAssertEqual(stat.cohorts.map(\.id), completion.map(\.id), fixture.name)
            XCTAssertEqual(stat.volume, fixture.expected_tonnage, fixture.name)
            XCTAssertEqual(stat.setCount, fixture.sets.filter { $0.is_warmup == 0 && $0.deleted_at == nil }.count)
            XCTAssertEqual(stat.est1RM, fixture.expected_cohorts.compactMap(\.est_1rm).max())
            for expected in fixture.expected_cohorts {
                let cohort = try XCTUnwrap(stat.cohorts.first {
                    $0.key.weight == expected.weight && $0.key.timed == expected.is_timed
                })
                XCTAssertEqual(cohort.bestReps, expected.best_reps, fixture.name)
                XCTAssertEqual(cohort.bestHoldSeconds, expected.best_duration_s, fixture.name)
                XCTAssertEqual(cohort.valueLabel, expected.value_label, fixture.name)
            }
            if fixture.name == "reps" {
                XCTAssertNil(stat.bestReps)
                XCTAssertEqual(stat.totalReps, 33)
            }
            if fixture.name == "holds" || fixture.name == "mixed" {
                XCTAssertNil(stat.bestHoldSeconds)
                XCTAssertNil(model.bestHoldSeconds(for: fixture.sets))
            }
        }
    }

    func testBodyweightBestRepsExcludeSeparateTimedOnlySessions() throws {
        let defaults = defaults()
        let ex = exercise(exerciseID: "exercise-bodyweight", bodyweight: true)
        let repSession = session(id: "rep-session", date: "2026-06-01", status: "completed")
        let holdSession = session(id: "hold-session", date: "2026-06-02", status: "completed")
        let model = SyncModel(
            auth: retainedAuth(defaults: defaults),
            defaults: defaults,
            now: { self.fixedDate })
        prepare(model, exercise: ex, session: repSession)
        model.catalog = [ExerciseCatalog(
            id: ex.exercise_id,
            name: "Pull-Up",
            primary_muscle: "back",
            modality: "bw",
            unit: "lb",
            laterality: "bilateral",
            load_mode: "total",
            demo_slug: nil)]
        model.sessions = [repSession, holdSession]
        model.sets = [
            SetLog(
                id: "rep", session_id: repSession.id,
                exercise_id: ex.exercise_id,
                template_exercise_id: ex.id, set_index: 1,
                weight: 0, reps: 12, rpe: nil, is_warmup: 0,
                logged_at: 1, duration_s: nil, is_timed: 0,
                deleted_at: nil),
            SetLog(
                id: "hold", session_id: holdSession.id,
                exercise_id: ex.exercise_id,
                template_exercise_id: ex.id, set_index: 1,
                weight: 0, reps: 45, rpe: nil, is_warmup: 0,
                logged_at: 2, duration_s: 45, is_timed: 1,
                deleted_at: nil),
        ]

        let stats = model.history(for: ex.exercise_id)
        XCTAssertEqual(stats.compactMap(\.bestReps).max(), 12)
        XCTAssertNil(stats[1].bestReps)
        XCTAssertEqual(stats[1].totalReps, 0)
        XCTAssertEqual(stats[1].bestHoldSeconds, 45)
    }

    func testDurationHistoryIncludesLegacyTimedFallbackAndOmitsRepOnlySessions() {
        let defaults = defaults()
        let ex = exercise(exerciseID: "exercise-mixed-history")
        let repSession = session(id: "session-reps", date: "2033-05-17", status: "completed")
        let holdSession = session(id: "session-hold", date: "2033-05-18", status: "completed")
        let model = SyncModel(
            auth: retainedAuth(defaults: defaults),
            defaults: defaults,
            now: { self.fixedDate })
        model.sessions = [repSession, holdSession]
        model.sets = [
            SetLog(
                id: "rep", session_id: repSession.id,
                exercise_id: ex.exercise_id,
                template_exercise_id: ex.id, set_index: 1,
                weight: 0, reps: 8, rpe: nil, is_warmup: 0,
                logged_at: 1, duration_s: nil, is_timed: 0,
                deleted_at: nil),
            SetLog(
                id: "hold", session_id: holdSession.id,
                exercise_id: ex.exercise_id,
                template_exercise_id: ex.id, set_index: 1,
                weight: 0, reps: 45, rpe: nil, is_warmup: 0,
                logged_at: 2, duration_s: nil, is_timed: 1,
                deleted_at: nil),
        ]

        let durationHistory = model.durationHistory(for: ex.exercise_id)

        XCTAssertEqual(durationHistory.map(\.id), [holdSession.id])
        XCTAssertEqual(durationHistory.map(\.avgDuration), [45])
    }

    func testTimedCatalogExercisesCannotChooseRepMeasure() {
        XCTAssertFalse(
            ExercisePrescriptionPolicy.canChooseMeasure(for: "timed"))
        XCTAssertFalse(
            ExercisePrescriptionPolicy.canChooseMeasure(for: "cardio"))
        XCTAssertTrue(
            ExercisePrescriptionPolicy.canChooseMeasure(for: "bw"))
        XCTAssertTrue(
            ExercisePrescriptionPolicy.canChooseMeasure(for: "barbell"))
        XCTAssertEqual(
            ExercisePrescriptionPolicy.initialEditableReps(
                targetReps: 45, isTimed: false, modality: "bw"),
            45)
        XCTAssertEqual(
            ExercisePrescriptionPolicy.editableRepUpperBound(
                reps: 45, repsMax: 60),
            1_000)
        XCTAssertEqual(
            ExercisePrescriptionPolicy.initialEditableReps(
                targetReps: 180, isTimed: true, modality: "bw"),
            8)
    }

    func testLiveLoadRefreshesCachedCatalogAndRetainsItOnLaterFailure() async {
        let defaults = defaults()
        let ex = exercise()
        let liveSession = session(status: "planned")
        let cached = ExerciseCatalog(
            id: ex.exercise_id,
            name: "Old Name",
            primary_muscle: "legs",
            modality: "barbell",
            unit: "lb",
            laterality: "bilateral",
            load_mode: "total",
            demo_slug: nil)
        let refreshed = ExerciseCatalog(
            id: ex.exercise_id,
            name: "Current Name",
            primary_muscle: "legs",
            modality: "barbell",
            unit: "lb",
            laterality: "unilateral",
            load_mode: "per_hand",
            demo_slug: nil)
        StateSnapshotStore.save(
            state(session: liveSession, sets: [], exercise: ex),
            userID: "user-a",
            defaults: defaults)
        ExerciseCatalogSnapshotStore.save(
            [cached], userID: "user-a", defaults: defaults)
        let setAPI = SetWriteAPIStub()
        setAPI.stateHandler = { [self] _ in
            state(session: liveSession, sets: [], exercise: ex)
        }
        let catalogAPI = SetCatalogAPIStub()
        catalogAPI.result = .success([refreshed])
        let model = SyncModel(
            auth: retainedAuth(defaults: defaults),
            setWriteAPI: setAPI,
            catalogAPI: catalogAPI,
            defaults: defaults,
            now: { self.fixedDate })
        XCTAssertEqual(model.exerciseName(ex.exercise_id), "Old Name")

        await model.load()

        XCTAssertEqual(model.exerciseName(ex.exercise_id), "Current Name")
        XCTAssertEqual(ExerciseCatalogSnapshotStore.load(
            userID: "user-a", defaults: defaults)?.first?.name, "Current Name")

        catalogAPI.result = .failure(URLError(.notConnectedToInternet))
        await model.load()

        XCTAssertEqual(model.exerciseName(ex.exercise_id), "Current Name")
        XCTAssertEqual(ExerciseCatalogSnapshotStore.load(
            userID: "user-a", defaults: defaults)?.first?.name, "Current Name")
    }

    func testFailedP2StatePullDoesNotAdvanceExternalCursors() async throws {
        let defaults = defaults()
        let ex = exercise()
        XCTAssertTrue(StateSyncAccountStore.activate(
            userID: "user-a", defaults: defaults))
        let liveSession = session(
            status: "planned",
            updatedAt: 2_000_000_000_001,
            attempt: 0)
        StateSnapshotStore.save(
            state(
                session: liveSession,
                sets: [],
                workouts: [day(with: [ex])],
                serverTime: 2_000_000_000_000,
                externalSyncCursorsVersion: 2),
            userID: "user-a",
            defaults: defaults)
        let priorWatermarks = try XCTUnwrap(StateSnapshotStore.load(
            userID: "user-a", defaults: defaults)?.watermarks)
        XCTAssertGreaterThan(priorWatermarks.eventsSince, 0)
        XCTAssertGreaterThan(priorWatermarks.activitiesSince, 0)

        let api = SetWriteAPIStub()
        api.stateWatermarkHandler = { _, watermarks in
            XCTAssertEqual(watermarks, priorWatermarks)
            throw URLError(.notConnectedToInternet)
        }
        let model = SyncModel(
            auth: retainedAuth(defaults: defaults),
            setWriteAPI: api,
            defaults: defaults,
            now: { self.fixedDate })

        await model.load()

        XCTAssertNotNil(model.loadError)
        XCTAssertEqual(
            StateSnapshotStore.load(
                userID: "user-a", defaults: defaults)?.watermarks,
            priorWatermarks)
    }

    func testLiveInProgressStateValidatesAndRestoresStableRunnerCheckpoint() {
        let defaults = defaults()
        let first = exercise(id: "slot-a", exerciseID: "exercise-a")
        let second = exercise(id: "slot-b", exerciseID: "exercise-b")
        let liveSession = session()
        let startedAtMS = Int(
            (fixedDate.addingTimeInterval(-600).timeIntervalSince1970 * 1_000)
                .rounded(.down))
        WorkoutRunnerCheckpointStore.save(
            .init(
                date: fixedCivilDate,
                sessionID: nil,
                selectedDayID: "day-a",
                currentSlotID: second.id,
                skippedSlotIDs: [first.id, "removed-slot"],
                workoutStartedAtMS: startedAtMS,
                finished: false),
            userID: "user-a",
            defaults: defaults)
        StateSnapshotStore.save(
            state(
                session: liveSession,
                sets: [],
                exercises: [first, second]),
            userID: "user-a",
            defaults: defaults)
        let model = SyncModel(
            auth: retainedAuth(defaults: defaults),
            defaults: defaults,
            now: { self.fixedDate })

        model.replaceState(with: state(
            session: liveSession, sets: [], exercises: [first, second]))

        XCTAssertTrue(model.hasResumableWorkout)
        XCTAssertFalse(model.isUsingCachedState)
        XCTAssertEqual(model.resumableCheckpoint?.sessionID, liveSession.id)
        XCTAssertEqual(model.resumableCheckpoint?.skippedSlotIDs, [first.id])

        let validatedCheckpoint = WorkoutRunnerCheckpointStore.load(
            userID: "user-a", defaults: defaults)
        model.startOverride(dayID: "different-day")
        XCTAssertFalse(model.running)
        XCTAssertEqual(model.selectedDayID, "day-a")
        XCTAssertEqual(
            WorkoutRunnerCheckpointStore.load(
                userID: "user-a", defaults: defaults),
            validatedCheckpoint,
            "a validated resume cannot be bypassed through a different-day start")

        model.resumeWorkout()

        XCTAssertTrue(model.running)
        XCTAssertEqual(model.currentExercise?.id, second.id)
        XCTAssertTrue(model.skipped.contains(first.id))
        XCTAssertEqual(
            Int((try! XCTUnwrap(model.workoutStart).timeIntervalSince1970 * 1_000)
                .rounded(.down)),
            startedAtMS)
        let persisted = WorkoutRunnerCheckpointStore.load(
            userID: "user-a", defaults: defaults)
        XCTAssertEqual(persisted?.sessionID, liveSession.id)
        XCTAssertEqual(persisted?.currentSlotID, second.id)
    }

    func testLiveAttemptReplacementStopsRunnerBeforeNormalizationPersists() {
        let defaults = defaults()
        let first = exercise(
            id: "slot-a", exerciseID: "exercise-a", targetSets: 1)
        let second = exercise(
            id: "slot-b", exerciseID: "exercise-b", targetSets: 1)
        let original = session(status: "in_progress", updatedAt: 100, attempt: 0)
        let replacement = session(
            status: "in_progress", updatedAt: 200, attempt: 1)
        let completedBody = SetRequestBody(
            id: fixedUUID.uuidString,
            exercise_id: first.exercise_id,
            template_exercise_id: first.id,
            set_index: 1,
            weight: 100,
            reps: 5,
            is_warmup: false,
            logged_at: 1,
            duration_s: nil,
            is_timed: false)
        let model = SyncModel(
            auth: retainedAuth(defaults: defaults),
            defaults: defaults,
            now: { self.fixedDate })
        model.replaceState(with: state(
            session: original, sets: [], exercises: [first, second]))
        model.startWorkout()
        XCTAssertEqual(
            WorkoutRunnerCheckpointStore.load(
                userID: "user-a", defaults: defaults)?.sessionAttempt,
            0)

        model.replaceState(with: state(
            session: replacement,
            sets: [setLog(body: completedBody, sessionID: replacement.id)],
            exercises: [first, second]))

        XCTAssertFalse(model.running)
        XCTAssertNil(WorkoutRunnerCheckpointStore.load(
            userID: "user-a", defaults: defaults))
        XCTAssertTrue(model.setOutbox.isEmpty)
    }

    func testOnlyLiveInProgressSessionCanMakeCheckpointResumable() {
        for status in ["planned", "completed", "skipped", "discarded"] {
            let defaults = defaults()
            let ex = exercise()
            WorkoutRunnerCheckpointStore.save(
                .init(
                    date: fixedCivilDate,
                    sessionID: "session-a",
                    selectedDayID: "day-a",
                    currentSlotID: ex.id,
                    skippedSlotIDs: [],
                    workoutStartedAtMS: 2_000_000_000_000,
                    finished: false),
                userID: "user-a",
                defaults: defaults)
            let model = SyncModel(
                auth: retainedAuth(defaults: defaults),
                defaults: defaults,
                now: { self.fixedDate })

            model.replaceState(with: state(
                session: session(status: status), sets: [], exercise: ex))

            XCTAssertFalse(
                model.hasResumableWorkout,
                "status \(status) must not validate a runner checkpoint")
            XCTAssertNil(WorkoutRunnerCheckpointStore.load(
                userID: "user-a", defaults: defaults))
        }
    }

    func testLiveTerminalRefreshStopsMountedRunnerAndClearsCheckpoint() {
        for status in ["completed", "discarded"] {
            let defaults = defaults()
            let ex = exercise()
            let active = session(status: "in_progress")
            let model = SyncModel(
                auth: retainedAuth(defaults: defaults),
                defaults: defaults,
                now: { self.fixedDate })
            prepare(model, exercise: ex, session: active, running: true)

            XCTAssertNotNil(WorkoutRunnerCheckpointStore.load(
                userID: "user-a", defaults: defaults))

            model.replaceState(with: state(
                session: session(status: status), sets: [], exercise: ex))

            XCTAssertFalse(
                model.running,
                "a mounted runner must stop after the server becomes \(status)")
            XCTAssertNil(model.resumableCheckpoint)
            XCTAssertNil(WorkoutRunnerCheckpointStore.load(
                userID: "user-a", defaults: defaults))
        }
    }

    func testLiveCompletionStopsRunnerThatHadNotWrittenItsFirstSet() {
        let defaults = defaults()
        let ex = exercise()
        let model = SyncModel(
            auth: retainedAuth(defaults: defaults),
            defaults: defaults,
            now: { self.fixedDate })
        prepare(model, exercise: ex, running: true)
        XCTAssertNil(WorkoutRunnerCheckpointStore.load(
            userID: "user-a", defaults: defaults)?.sessionID)

        model.replaceState(with: state(
            session: session(status: "completed"), sets: [], exercise: ex))

        XCTAssertFalse(model.running)
        XCTAssertNil(WorkoutRunnerCheckpointStore.load(
            userID: "user-a", defaults: defaults))
    }

    func testHardBlackoutSessionDoesNotInferNullTemplateFromSchedule() {
        let defaults = defaults()
        let first = exercise(id: "slot-a", exerciseID: "exercise-a")
        let scheduled = exercise(id: "slot-b", exerciseID: "exercise-b")
        let selectedDay = Workout(
            id: "day-a", name: "Selected Day", day_label: "A",
            order_index: 0, exercises: [first])
        let scheduledDay = Workout(
            id: "day-b", name: "Scheduled Day", day_label: "B",
            order_index: 1, exercises: [scheduled])
        let weekday = try! XCTUnwrap(
            CalendarProjection.weekdayKey(forDateString: fixedCivilDate))
        let meta = """
        {"schedule":{"version":1,"week":{"\(weekday)":"day-b"}},
         "trips":[{"id":"trip-a","start":"\(fixedCivilDate)",
         "end":"\(fixedCivilDate)","type":"travel","can_train_light":false}]}
        """
        let remoteSession = SessionRow(
            id: "session-a", date: fixedCivilDate,
            status: "in_progress", workout_id: nil)
        let model = SyncModel(
            auth: retainedAuth(defaults: defaults),
            defaults: defaults,
            now: { self.fixedDate })
        model.plan = PlanTree(
            id: "plan-a", name: "Plan A", version: 1,
            workouts: [selectedDay, scheduledDay], meta: meta)
        model.selectedDayID = selectedDay.id
        model.sessions = [remoteSession]
        model.todaySession = remoteSession

        XCTAssertEqual(
            model.todayProjection,
            .session(
                status: "in_progress",
                hardBlackoutTripType: "travel"))
        XCTAssertEqual(
            model.todayResolvedDay?.id,
            selectedDay.id,
            "hard blackout may retain the real session but cannot use the weekly schedule to label it")
    }

    func testHardBlackoutSuppressesNextDayRideConflict() throws {
        let defaults = defaults()
        let nextDate = try XCTUnwrap(
            RideConflict.nextDateString(after: fixedCivilDate))
        let meta = """
        {"trips":[{"id":"trip-a","start":"\(nextDate)","end":"\(nextDate)","type":"travel","can_train_light":false}]}
        """
        let model = SyncModel(
            auth: retainedAuth(defaults: defaults),
            defaults: defaults,
            now: { self.fixedDate })
        model.plan = PlanTree(
            id: "plan-a",
            name: "Plan A",
            version: 1,
            workouts: [day(with: [exercise()])],
            meta: meta)
        model.sessions = [session(status: "completed")]
        model.rides = [ExternalEvent(
            id: "intervals:hard",
            source: "intervals",
            external_id: "hard",
            date: nextDate,
            kind: "ride",
            title: "Hard Ride",
            description: nil,
            planned_duration_sec: 10_000,
            training_load: 200,
            intensity: 0.9,
            synced_at: 2_000_000_000_000,
            deleted_at: nil)]

        XCTAssertTrue(model.dateHasLift(fixedCivilDate))
        XCTAssertTrue(
            model.projection(for: nextDate).suppressesScheduleAndEndurance)
        XCTAssertEqual(model.rideConflict(for: fixedCivilDate), .none)
    }

    func testConcurrentLoadsCoalesceOntoOneModelOwnedRefresh() async {
        let defaults = defaults()
        let ex = exercise()
        let api = SetWriteAPIStub()
        let firstEntered = SetAsyncLatch()
        let releaseFirst = SetAsyncLatch()
        api.stateHandler = { [self] _ in
            await firstEntered.open()
            await releaseFirst.wait()
            return state(
                session: session(status: "planned"), sets: [], exercise: ex)
        }
        let model = SyncModel(
            auth: retainedAuth(defaults: defaults),
            setWriteAPI: api,
            defaults: defaults,
            now: { self.fixedDate })
        model.catalog = [ExerciseCatalog(
            id: ex.exercise_id,
            name: ex.exercise_name,
            primary_muscle: "legs",
            modality: "barbell",
            unit: "lb",
            laterality: "bilateral",
            load_mode: "total",
            demo_slug: nil)]

        let first = Task { await model.load() }
        await firstEntered.wait()
        let second = Task { await model.load() }
        await Task.yield()

        XCTAssertEqual(api.stateCalls, 1)
        XCTAssertTrue(model.isLoading)
        await releaseFirst.open()
        await first.value
        await second.value

        XCTAssertEqual(api.stateCalls, 1)
        XCTAssertFalse(model.isLoading)
        XCTAssertEqual(model.todaySession?.status, "planned")
        XCTAssertEqual(
            StateSnapshotStore.load(
                userID: "user-a", defaults: defaults)?.state.sessions.first?.status,
            "planned")
    }

    func testMutationRefreshRunsAfterOlderStateRequest() async {
        let defaults = defaults()
        let ex = exercise()
        let api = SetWriteAPIStub()
        let firstEntered = SetAsyncLatch()
        let releaseFirst = SetAsyncLatch()
        api.stateHandler = { [self] _ in
            if api.stateCalls == 1 {
                await firstEntered.open()
                await releaseFirst.wait()
                return state(
                    session: session(status: "planned"),
                    sets: [], exercise: ex)
            }
            return state(
                session: session(status: "completed"),
                sets: [], exercise: ex)
        }
        let model = SyncModel(
            auth: retainedAuth(defaults: defaults),
            setWriteAPI: api,
            defaults: defaults,
            now: { self.fixedDate })

        let older = Task { await model.load() }
        await firstEntered.wait()
        let postMutation = Task { await model.loadAfterMutation() }
        await Task.yield()

        XCTAssertEqual(api.stateCalls, 1)
        await releaseFirst.open()
        await older.value
        await postMutation.value

        XCTAssertEqual(api.stateCalls, 2)
        XCTAssertEqual(model.todaySession?.status, "completed")
    }

    func testPostMutationRefreshRetriesAfterConcurrentTerminalACK() async {
        let defaults = defaults()
        let original = exercise(
            id: "slot-a", exerciseID: "exercise-a")
        let replacement = exercise(
            id: "slot-b", exerciseID: "exercise-b")
        let activeSession = session(
            status: "in_progress", updatedAt: 100, attempt: 0)
        let completedSession = session(
            status: "completed", updatedAt: 200, attempt: 0)
        let initialState = state(
            session: activeSession,
            sets: [],
            workouts: [day(with: [original])],
            planName: "Old Plan")
        StateSnapshotStore.save(
            initialState, userID: "user-a", defaults: defaults)

        let firstEntered = SetAsyncLatch()
        let releaseFirst = SetAsyncLatch()
        let setAPI = SetWriteAPIStub()
        setAPI.stateHandler = { [self] _ in
            if setAPI.stateCalls == 1 {
                await firstEntered.open()
                await releaseFirst.wait()
            }
            return state(
                session: completedSession,
                sets: [],
                workouts: [day(with: [replacement])],
                planName: "New Plan")
        }
        let terminalAPI = SetTerminalAPIStub()
        terminalAPI.completeHandler = { _, _ in completedSession }
        let sharedAuth = retainedAuth(defaults: defaults)
        let old = SyncModel(
            auth: sharedAuth,
            setWriteAPI: setAPI,
            terminalAPI: terminalAPI,
            defaults: defaults,
            now: { self.fixedDate })
        old.replaceState(with: initialState)
        old.startWorkout()
        old.finished = true
        let replacementModel = SyncModel(
            auth: sharedAuth,
            setWriteAPI: setAPI,
            catalogAPI: SetCatalogAPIStub(),
            defaults: defaults,
            now: { self.fixedDate })

        let refresh = Task { await replacementModel.loadAfterMutation() }
        await firstEntered.wait()
        await old.finishWorkout()
        XCTAssertEqual(terminalAPI.completeCalls.count, 1)

        await releaseFirst.open()
        await refresh.value

        XCTAssertEqual(setAPI.stateCalls, 2)
        XCTAssertEqual(replacementModel.plan?.name, "New Plan")
        XCTAssertEqual(
            replacementModel.plan?.workouts.first?.exercises.map(\.id),
            [replacement.id])
        let snapshot = try! XCTUnwrap(StateSnapshotStore.load(
            userID: "user-a", defaults: defaults)?.state)
        XCTAssertEqual(snapshot.plan?.name, "New Plan")
        XCTAssertEqual(snapshot.sessions.first?.status, "completed")
    }

    func testNewBearerRefreshRunsAfterOlderBearerReturns401() async {
        let defaults = defaults()
        let ex = exercise()
        let oldToken = jwt(subject: "user-a")
        let newToken = jwt(
            subject: "user-a",
            expiration: fixedDate.addingTimeInterval(90 * 24 * 60 * 60))
        let authAPI = SetAuthAPIStub()
        authAPI.renewalResult = .success(SessionRenewalResponse(jwt: newToken))
        let auth = auth(
            defaults: defaults, api: authAPI, token: oldToken)
        let api = SetWriteAPIStub()
        let oldEntered = SetAsyncLatch()
        let releaseOld = SetAsyncLatch()
        api.stateHandler = { [self] token in
            if token == oldToken {
                await oldEntered.open()
                await releaseOld.wait()
                throw APIError.http(401, "invalid_token")
            }
            XCTAssertEqual(token, newToken)
            return state(
                session: session(status: "planned"),
                sets: [], exercise: ex)
        }
        let model = SyncModel(
            auth: auth, setWriteAPI: api,
            defaults: defaults, now: { self.fixedDate })

        let older = Task { await model.load() }
        await oldEntered.wait()
        await auth.renewSessionIfNeeded(force: true)
        XCTAssertEqual(auth.featureJWT, newToken)
        let current = Task { await model.load() }
        await Task.yield()
        XCTAssertEqual(api.stateCalls, 1)

        await releaseOld.open()
        await older.value
        await current.value

        XCTAssertEqual(api.stateCalls, 2)
        XCTAssertEqual(model.todaySession?.status, "planned")
        XCTAssertNil(model.loadError)
        XCTAssertEqual(auth.featureJWT, newToken)
    }

    func testOldLoadCannotApplyAfterSignOutAndSameUserSignIn() async {
        let defaults = defaults()
        let ex = exercise()
        let oldToken = jwt(subject: "user-a")
        let newToken = jwt(
            subject: "user-a",
            expiration: fixedDate.addingTimeInterval(90 * 24 * 60 * 60))
        let authAPI = SetAuthAPIStub()
        let auth = auth(
            defaults: defaults, api: authAPI, token: oldToken)
        let api = SetWriteAPIStub()
        let entered = SetAsyncLatch()
        let release = SetAsyncLatch()
        api.stateHandler = { [self] _ in
            await entered.open()
            await release.wait()
            return state(
                session: session(status: "planned"),
                sets: [], exercise: ex)
        }
        let model = SyncModel(
            auth: auth, setWriteAPI: api,
            defaults: defaults, now: { self.fixedDate })

        let oldLoad = Task { await model.load() }
        await entered.wait()
        auth.signOut()
        authAPI.authResult = .success(
            authResponse(jwt: newToken, userID: "user-a"))
        await auth.exchange(identityToken: "apple-a", fullName: nil)
        XCTAssertEqual(auth.featureJWT, newToken)

        await release.open()
        await oldLoad.value

        XCTAssertNil(model.plan)
        XCTAssertNil(StateSnapshotStore.load(
            userID: "user-a", defaults: defaults))
    }

    func testCancelledRefreshCallerDoesNotCancelModelOwnedValidation() async {
        let defaults = defaults()
        let ex = exercise()
        StateSnapshotStore.save(
            state(
                session: session(status: "planned"), sets: [], exercise: ex),
            userID: "user-a",
            defaults: defaults)
        let api = SetWriteAPIStub()
        let entered = SetAsyncLatch()
        let release = SetAsyncLatch()
        api.stateHandler = { [self] _ in
            await entered.open()
            await release.wait()
            try Task.checkCancellation()
            return state(
                session: session(status: "planned"), sets: [], exercise: ex)
        }
        let model = SyncModel(
            auth: retainedAuth(defaults: defaults),
            setWriteAPI: api,
            defaults: defaults,
            now: { self.fixedDate })

        XCTAssertTrue(model.isUsingCachedState)
        let refresh = Task { await model.load() }
        await entered.wait()
        refresh.cancel()
        await release.open()
        await refresh.value

        XCTAssertTrue(refresh.isCancelled)
        XCTAssertEqual(api.stateCalls, 1)
        XCTAssertEqual(model.plan?.name, "Plan A")
        XCTAssertFalse(model.isUsingCachedState)
        XCTAssertNil(model.loadError)
    }

    func testDelayedPreWriteLoadCannotRollBackAcknowledgedSetOrSnapshot() async {
        let defaults = defaults()
        let ex = exercise()
        let liveSession = session()
        let api = SetWriteAPIStub()
        let staleLoadEntered = SetAsyncLatch()
        let releaseStaleLoad = SetAsyncLatch()
        var committed: SetLog?
        api.logHandler = { [self] sessionID, body, _ in
            let row = setLog(body: body, sessionID: sessionID)
            committed = row
            return .init(set: row, deduped: false)
        }
        api.stateHandler = { [self] _ in
            if api.stateCalls == 1 {
                await staleLoadEntered.open()
                await releaseStaleLoad.wait()
                return state(session: liveSession, sets: [], exercise: ex)
            }
            return state(
                session: liveSession,
                sets: committed.map { [$0] } ?? [],
                exercise: ex)
        }
        let model = SyncModel(
            auth: retainedAuth(defaults: defaults),
            setWriteAPI: api,
            defaults: defaults,
            uuidFactory: { self.fixedUUID },
            now: { self.fixedDate })
        prepare(model, exercise: ex, session: liveSession)

        let staleLoad = Task { await model.load() }
        await staleLoadEntered.wait()
        let acknowledged = await model.logSet(ex, weight: 135, reps: 5)

        XCTAssertTrue(acknowledged)
        XCTAssertEqual(model.sets.map(\.id), [fixedUUID.uuidString])
        XCTAssertTrue(model.isLoading)

        await releaseStaleLoad.open()
        await staleLoad.value

        XCTAssertFalse(model.isLoading)
        XCTAssertEqual(model.sets.map(\.id), [fixedUUID.uuidString])
        XCTAssertEqual(
            StateSnapshotStore.load(
                userID: "user-a", defaults: defaults)?.state.sets.map(\.id),
            [fixedUUID.uuidString])
    }

    func testFullStateSetAcknowledgementLeavesOfflineSnapshotBeforeRemovingIntent() {
        let defaults = defaults()
        let ex = exercise()
        let liveSession = session()
        let body = SetRequestBody(
            id: fixedUUID.uuidString,
            exercise_id: ex.exercise_id,
            template_exercise_id: ex.id,
            set_index: 1,
            weight: 135,
            reps: 5,
            is_warmup: false,
            logged_at: 2_000_000_000_000,
            duration_s: nil,
            is_timed: false)
        var outbox = SetOutbox()
        outbox.enqueue(.init(
            body: body,
            date: fixedCivilDate,
            workoutID: "day-a",
            resolvedSessionID: liveSession.id,
            deliveryState: .queued,
            failedHTTPStatus: nil))
        SetOutboxStore.save(outbox, userID: "user-a", defaults: defaults)
        StateSnapshotStore.save(
            state(session: liveSession, sets: [], exercise: ex),
            userID: "user-a",
            defaults: defaults)
        let model = SyncModel(
            auth: retainedAuth(defaults: defaults),
            defaults: defaults,
            now: { self.fixedDate })

        model.replaceState(with: state(
            session: liveSession,
            sets: [setLog(body: body)],
            exercise: ex))

        XCTAssertTrue(model.setOutbox.isEmpty)
        let relaunched = SyncModel(
            auth: retainedAuth(defaults: defaults),
            defaults: defaults,
            now: { self.fixedDate })
        XCTAssertTrue(relaunched.setOutbox.isEmpty)
        XCTAssertEqual(relaunched.sets.map(\.id), [fixedUUID.uuidString])
    }

    func testFullStateFinishAcknowledgementLeavesCompletedSnapshotBeforeRemovingIntent() {
        let defaults = defaults()
        let ex = exercise()
        let active = session(status: "in_progress")
        var terminal = WorkoutTerminalOutbox()
        terminal.enqueue(.init(
            id: fixedUUID.uuidString,
            action: .finish,
            date: fixedCivilDate,
            workoutID: "day-a",
            resolvedSessionID: active.id,
            deliveryState: .queued,
            failedHTTPStatus: nil))
        WorkoutTerminalOutboxStore.save(
            terminal, userID: "user-a", defaults: defaults)
        WorkoutRunnerCheckpointStore.save(
            .init(
                date: fixedCivilDate,
                sessionID: active.id,
                selectedDayID: "day-a",
                currentSlotID: ex.id,
                skippedSlotIDs: [],
                workoutStartedAtMS: 2_000_000_000_000,
                finished: true),
            userID: "user-a",
            defaults: defaults)
        StateSnapshotStore.save(
            state(session: active, sets: [], exercise: ex),
            userID: "user-a",
            defaults: defaults)
        let model = SyncModel(
            auth: retainedAuth(defaults: defaults),
            defaults: defaults,
            now: { self.fixedDate })

        model.replaceState(with: state(
            session: session(status: "completed"),
            sets: [],
            exercise: ex))

        XCTAssertTrue(model.terminalOutbox.isEmpty)
        XCTAssertNil(WorkoutRunnerCheckpointStore.load(
            userID: "user-a", defaults: defaults))
        let relaunched = SyncModel(
            auth: retainedAuth(defaults: defaults),
            defaults: defaults,
            now: { self.fixedDate })
        XCTAssertTrue(relaunched.terminalOutbox.isEmpty)
        XCTAssertTrue(relaunched.todayIsCompleted)
        XCTAssertEqual(relaunched.todaySession?.status, "completed")
    }

    func testFinishAcknowledgementPersistsCompletedOfflineSnapshotBeforeIntentRemoval() async {
        let defaults = defaults()
        let ex = exercise()
        let active = session(status: "in_progress")
        let terminalAPI = SetTerminalAPIStub()
        terminalAPI.completeHandler = { [self] _, _ in
            session(status: "completed")
        }
        let model = SyncModel(
            auth: retainedAuth(defaults: defaults),
            terminalAPI: terminalAPI,
            defaults: defaults,
            now: { self.fixedDate })
        model.replaceState(with: state(
            session: active, sets: [], exercise: ex))
        model.startWorkout()
        model.finished = true

        await model.finishWorkout()

        XCTAssertTrue(model.terminalOutbox.isEmpty)
        XCTAssertNil(WorkoutRunnerCheckpointStore.load(
            userID: "user-a", defaults: defaults))
        XCTAssertEqual(
            StateSnapshotStore.load(
                userID: "user-a", defaults: defaults)?.state.sessions.first?.status,
            "completed")

        let relaunched = SyncModel(
            auth: retainedAuth(defaults: defaults),
            defaults: defaults,
            now: { self.fixedDate })
        XCTAssertTrue(relaunched.isUsingCachedState)
        XCTAssertTrue(relaunched.todayIsCompleted)
        XCTAssertEqual(relaunched.todaySession?.status, "completed")
        relaunched.startToday()
        XCTAssertFalse(relaunched.running)
        XCTAssertTrue(relaunched.loadError?.contains("completed") == true)
    }

    func testRecoveredOverrideCheckpointOwnsPreResumeDayAndCTAContent() {
        let defaults = defaults()
        let overrideSlot = exercise(id: "slot-a", exerciseID: "exercise-a")
        let overrideDay = Workout(
            id: "day-a", name: "Override", day_label: "A",
            order_index: 0, exercises: [overrideSlot])
        let pinnedDay = Workout(
            id: "day-b", name: "Pinned", day_label: "B",
            order_index: 1, exercises: [])
        let liveSession = SessionRow(
            id: "session-a", date: fixedCivilDate,
            status: "in_progress", workout_id: pinnedDay.id)
        WorkoutRunnerCheckpointStore.save(
            .init(
                date: fixedCivilDate,
                sessionID: liveSession.id,
                selectedDayID: overrideDay.id,
                currentSlotID: overrideSlot.id,
                skippedSlotIDs: [],
                workoutStartedAtMS: 2_000_000_000_000,
                finished: false),
            userID: "user-a",
            defaults: defaults)
        let model = SyncModel(
            auth: retainedAuth(defaults: defaults),
            defaults: defaults,
            now: { self.fixedDate })

        model.replaceState(with: state(
            session: liveSession,
            sets: [],
            workouts: [overrideDay, pinnedDay]))

        XCTAssertTrue(model.hasResumableWorkout)
        XCTAssertEqual(model.selectedDayID, overrideDay.id)
        XCTAssertEqual(model.todayResolvedDay?.id, overrideDay.id)
        XCTAssertFalse(try! XCTUnwrap(model.todayResolvedDay).exercises.isEmpty)

        model.resumeWorkout()
        XCTAssertTrue(model.running)
        XCTAssertEqual(model.selectedDayID, overrideDay.id)
        XCTAssertEqual(model.currentExercise?.id, overrideSlot.id)
    }

    func testCheckpointAdvancesPastSlotCompletedWhileAppWasDead() {
        let defaults = defaults()
        let first = exercise(
            id: "slot-a", exerciseID: "exercise-a", targetSets: 1)
        let second = exercise(
            id: "slot-b", exerciseID: "exercise-b", targetSets: 1)
        let liveSession = session()
        let body = SetRequestBody(
            id: fixedUUID.uuidString,
            exercise_id: first.exercise_id,
            template_exercise_id: first.id,
            set_index: 1,
            weight: 135,
            reps: 5,
            is_warmup: false,
            logged_at: 2_000_000_000_000,
            duration_s: nil,
            is_timed: false)
        WorkoutRunnerCheckpointStore.save(
            .init(
                date: fixedCivilDate,
                sessionID: liveSession.id,
                selectedDayID: "day-a",
                currentSlotID: first.id,
                skippedSlotIDs: [],
                workoutStartedAtMS: 2_000_000_000_000,
                finished: false),
            userID: "user-a",
            defaults: defaults)
        let model = SyncModel(
            auth: retainedAuth(defaults: defaults),
            defaults: defaults,
            now: { self.fixedDate })

        model.replaceState(with: state(
            session: liveSession,
            sets: [setLog(body: body)],
            exercises: [first, second]))

        XCTAssertEqual(model.resumableCheckpoint?.currentSlotID, second.id)
        XCTAssertEqual(model.resumableCheckpoint?.finished, false)
        model.resumeWorkout()
        XCTAssertEqual(model.currentExercise?.id, second.id)
    }

    func testLaunchDrainOfFinalSetRecoversDirectlyToFinishedRunner() async {
        let defaults = defaults()
        let ex = exercise(targetSets: 1)
        let liveSession = session()
        let body = SetRequestBody(
            id: fixedUUID.uuidString,
            exercise_id: ex.exercise_id,
            template_exercise_id: ex.id,
            set_index: 1,
            weight: 135,
            reps: 5,
            is_warmup: false,
            logged_at: 2_000_000_000_000,
            duration_s: nil,
            is_timed: false)
        var outbox = SetOutbox()
        outbox.enqueue(.init(
            body: body,
            date: fixedCivilDate,
            workoutID: "day-a",
            resolvedSessionID: liveSession.id,
            deliveryState: .queued,
            failedHTTPStatus: nil))
        SetOutboxStore.save(outbox, userID: "user-a", defaults: defaults)
        WorkoutRunnerCheckpointStore.save(
            .init(
                date: fixedCivilDate,
                sessionID: liveSession.id,
                selectedDayID: "day-a",
                currentSlotID: ex.id,
                skippedSlotIDs: [],
                workoutStartedAtMS: 2_000_000_000_000,
                finished: false),
            userID: "user-a",
            defaults: defaults)
        StateSnapshotStore.save(
            state(session: liveSession, sets: [], exercise: ex),
            userID: "user-a",
            defaults: defaults)
        let api = SetWriteAPIStub()
        let committed = setLog(body: body)
        api.logHandler = { _, _, _ in
            .init(set: committed, deduped: false)
        }
        api.stateHandler = { [self] _ in
            state(session: liveSession, sets: [committed], exercise: ex)
        }
        let model = SyncModel(
            auth: retainedAuth(defaults: defaults),
            setWriteAPI: api,
            defaults: defaults,
            now: { self.fixedDate })
        model.catalog = [ExerciseCatalog(
            id: ex.exercise_id,
            name: ex.exercise_name,
            primary_muscle: "legs",
            modality: "barbell",
            unit: "lb",
            laterality: "bilateral",
            load_mode: "total",
            demo_slug: nil)]

        await model.recoverWorkoutWrites()

        XCTAssertTrue(model.setOutbox.isEmpty)
        XCTAssertEqual(model.resumableCheckpoint?.currentSlotID, ex.id)
        XCTAssertEqual(model.resumableCheckpoint?.finished, true)
        model.resumeWorkout()
        XCTAssertTrue(model.running)
        XCTAssertTrue(model.finished)
    }

    func testRunnerNavigationPersistsStableSlotSkipAndFinishedState() {
        let defaults = defaults()
        let first = exercise(id: "slot-a", exerciseID: "exercise-a")
        let second = exercise(id: "slot-b", exerciseID: "exercise-b")
        let model = SyncModel(
            auth: retainedAuth(defaults: defaults),
            defaults: defaults,
            now: { self.fixedDate })
        model.plan = PlanTree(
            id: "plan-a", name: "Plan A", version: 1,
            workouts: [day(with: [first, second])], meta: nil)
        model.selectedDayID = "day-a"

        model.startWorkout()
        XCTAssertEqual(WorkoutRunnerCheckpointStore.load(
            userID: "user-a", defaults: defaults)?.currentSlotID, first.id)

        model.next()
        model.skip()

        var checkpoint = WorkoutRunnerCheckpointStore.load(
            userID: "user-a", defaults: defaults)
        XCTAssertEqual(checkpoint?.currentSlotID, first.id)
        XCTAssertEqual(checkpoint?.skippedSlotIDs, [second.id])
        XCTAssertEqual(checkpoint?.finished, false)

        model.skip()
        checkpoint = WorkoutRunnerCheckpointStore.load(
            userID: "user-a", defaults: defaults)
        XCTAssertEqual(checkpoint?.currentSlotID, first.id)
        XCTAssertEqual(checkpoint?.skippedSlotIDs, [first.id, second.id])
        XCTAssertEqual(checkpoint?.finished, true)
    }

    func testNewestFullStateRequestWinsAcrossTwoSyncModels() async {
        let defaults = defaults()
        let ex = exercise()
        let sharedAuth = retainedAuth(defaults: defaults)
        let firstAPI = SetWriteAPIStub()
        let secondAPI = SetWriteAPIStub()
        let firstEntered = SetAsyncLatch()
        let releaseFirst = SetAsyncLatch()
        let secondEntered = SetAsyncLatch()
        let releaseSecond = SetAsyncLatch()
        firstAPI.stateHandler = { [self] _ in
            await firstEntered.open()
            await releaseFirst.wait()
            return state(
                session: session(status: "planned", updatedAt: 300),
                sets: [], workouts: [day(with: [ex])],
                serverTime: 9_000, planName: "Stale Plan")
        }
        secondAPI.stateHandler = { [self] _ in
            await secondEntered.open()
            await releaseSecond.wait()
            return state(
                session: session(status: "completed", updatedAt: 400),
                sets: [], workouts: [day(with: [ex])],
                serverTime: 1_000, planName: "Current Plan")
        }
        let first = SyncModel(
            auth: sharedAuth, setWriteAPI: firstAPI,
            catalogAPI: SetCatalogAPIStub(), defaults: defaults,
            now: { self.fixedDate })
        let second = SyncModel(
            auth: sharedAuth, setWriteAPI: secondAPI,
            catalogAPI: SetCatalogAPIStub(), defaults: defaults,
            now: { self.fixedDate })

        let staleLoad = Task { await first.load() }
        await firstEntered.wait()
        let currentLoad = Task { await second.load() }
        await secondEntered.wait()
        await releaseSecond.open()
        await currentLoad.value
        await releaseFirst.open()
        await staleLoad.value

        XCTAssertNil(first.plan, "the superseded model cannot apply its response")
        XCTAssertEqual(second.plan?.name, "Current Plan")
        XCTAssertEqual(
            StateSnapshotStore.load(
                userID: "user-a", defaults: defaults)?.state.plan?.name,
            "Current Plan")
    }

    func testOlderModelSetACKMergesIntoNewerSnapshotWhenReconciliationFails() async {
        let defaults = defaults()
        let ex = exercise()
        let sharedAuth = retainedAuth(defaults: defaults)
        let api = SetWriteAPIStub()
        let entered = SetAsyncLatch()
        let release = SetAsyncLatch()
        api.logHandler = { [self] sessionID, body, _ in
            await entered.open()
            await release.wait()
            return .init(
                set: setLog(body: body, sessionID: sessionID),
                deduped: false,
                session: session(
                    id: sessionID, status: "in_progress", updatedAt: 300))
        }
        api.stateHandler = { _ in throw URLError(.notConnectedToInternet) }
        let older = SyncModel(
            auth: sharedAuth, setWriteAPI: api, defaults: defaults,
            uuidFactory: { self.fixedUUID }, now: { self.fixedDate })
        let active = session(
            status: "in_progress", updatedAt: 100, attempt: 0)
        prepare(older, exercise: ex, session: active)

        let write = Task { await older.logSet(ex, weight: 135, reps: 5) }
        await entered.wait()

        let replacement = SyncModel(
            auth: sharedAuth, defaults: defaults,
            now: { self.fixedDate })
        let unrelated = session(
            id: "session-next", date: "2099-01-03",
            status: "planned", updatedAt: 250)
        replacement.replaceState(with: StateResponse(
            plan: PlanTree(
                id: "plan-a", name: "Replacement Plan", version: 2,
                workouts: [day(with: [ex])], meta: nil),
            plan_version: 2,
            sessions: [active, unrelated],
            sets: [], external_events: [], external_activities: [],
            activities: [], server_time: 2_500))

        await release.open()
        let acknowledged = await write.value
        XCTAssertTrue(acknowledged)

        let snapshot = try! XCTUnwrap(StateSnapshotStore.load(
            userID: "user-a", defaults: defaults)?.state)
        XCTAssertEqual(snapshot.plan?.name, "Replacement Plan")
        XCTAssertTrue(snapshot.sessions.contains { $0.id == unrelated.id })
        XCTAssertEqual(snapshot.sets.map(\.id), [fixedUUID.uuidString])
        XCTAssertTrue(SetOutboxStore.load(
            userID: "user-a", defaults: defaults).isEmpty)
        let cold = SyncModel(
            auth: sharedAuth, defaults: defaults,
            now: { self.fixedDate })
        XCTAssertEqual(cold.plan?.name, "Replacement Plan")
        XCTAssertEqual(cold.sets.map(\.id), [fixedUUID.uuidString])
    }

    func testDelayedSetACKCannotOverwriteNewerDiscardedFullState() async {
        let defaults = defaults()
        let ex = exercise()
        let active = session(status: "in_progress", updatedAt: 100)
        let api = SetWriteAPIStub()
        let entered = SetAsyncLatch()
        let release = SetAsyncLatch()
        api.logHandler = { [self] sessionID, body, _ in
            await entered.open()
            await release.wait()
            return .init(
                set: setLog(body: body, sessionID: sessionID),
                deduped: false,
                session: session(
                    id: sessionID, status: "in_progress",
                    updatedAt: 200, attempt: 0))
        }
        api.stateHandler = { _ in throw URLError(.notConnectedToInternet) }
        let model = SyncModel(
            auth: retainedAuth(defaults: defaults), setWriteAPI: api,
            defaults: defaults, uuidFactory: { self.fixedUUID },
            now: { self.fixedDate })
        model.replaceState(with: state(
            session: active, sets: [], exercise: ex))
        model.startWorkout()

        let write = Task { await model.logSet(ex, weight: 135, reps: 5) }
        await entered.wait()
        model.replaceState(with: state(
            session: session(
                status: "discarded", updatedAt: 200, attempt: 0),
            sets: [], exercise: ex))
        await release.open()
        let acknowledged = await write.value
        XCTAssertFalse(acknowledged)

        let snapshot = try! XCTUnwrap(StateSnapshotStore.load(
            userID: "user-a", defaults: defaults)?.state)
        XCTAssertEqual(snapshot.sessions.first?.status, "discarded")
        XCTAssertTrue(snapshot.sets.isEmpty)
        XCTAssertFalse(model.running)
        XCTAssertTrue(model.sets.isEmpty)
    }

    func testDiscardedSessionSetRetryClearsWholeCachedWorkout() async {
        let defaults = defaults()
        let ex = exercise(targetSets: 3)
        let active = session(status: "in_progress", updatedAt: 100)
        let oldBody = SetRequestBody(
            id: "22222222-2222-4222-8222-222222222222",
            exercise_id: ex.exercise_id,
            template_exercise_id: ex.id,
            set_index: 1, weight: 125, reps: 5,
            is_warmup: false, logged_at: 1_999_999_999_999,
            duration_s: nil, is_timed: false)
        let api = SetWriteAPIStub()
        api.logHandler = { [self] sessionID, body, _ in
            var tombstone = setLog(body: body, sessionID: sessionID)
            tombstone = SetLog(
                id: tombstone.id, session_id: tombstone.session_id,
                exercise_id: tombstone.exercise_id,
                template_exercise_id: tombstone.template_exercise_id,
                set_index: tombstone.set_index, weight: tombstone.weight,
                reps: tombstone.reps, rpe: tombstone.rpe,
                is_warmup: tombstone.is_warmup,
                logged_at: tombstone.logged_at,
                duration_s: tombstone.duration_s,
                is_timed: tombstone.is_timed,
                deleted_at: 300)
            return .init(
                set: tombstone, deduped: true,
                session: session(
                    id: sessionID, status: "discarded", updatedAt: 300))
        }
        api.stateHandler = { _ in throw URLError(.notConnectedToInternet) }
        let model = SyncModel(
            auth: retainedAuth(defaults: defaults), setWriteAPI: api,
            defaults: defaults, uuidFactory: { self.fixedUUID },
            now: { self.fixedDate })
        model.replaceState(with: state(
            session: active, sets: [setLog(body: oldBody)], exercise: ex))
        model.startWorkout()

        let acknowledged = await model.logSet(ex, weight: 135, reps: 5)
        XCTAssertFalse(acknowledged)
        let snapshot = try! XCTUnwrap(StateSnapshotStore.load(
            userID: "user-a", defaults: defaults)?.state)
        XCTAssertEqual(snapshot.sessions.first?.status, "discarded")
        XCTAssertTrue(snapshot.sets.isEmpty)
        XCTAssertTrue(model.sets.isEmpty)
        XCTAssertFalse(model.running)
    }

    func testTerminalAliasACKRekeysSetsWithoutFollowUpPull() async {
        let defaults = defaults()
        let ex = exercise()
        let stale = session(
            id: "stale-session", status: "in_progress", updatedAt: 100)
        let body = SetRequestBody(
            id: fixedUUID.uuidString,
            exercise_id: ex.exercise_id,
            template_exercise_id: ex.id,
            set_index: 1, weight: 135, reps: 5,
            is_warmup: false, logged_at: 2_000_000_000_000,
            duration_s: nil, is_timed: false)
        let terminalAPI = SetTerminalAPIStub()
        terminalAPI.completeHandler = { [self] _, _ in
            session(
                id: "canonical-session", status: "completed", updatedAt: 200)
        }
        let model = SyncModel(
            auth: retainedAuth(defaults: defaults), terminalAPI: terminalAPI,
            defaults: defaults, now: { self.fixedDate })
        prepare(model, exercise: ex, session: stale, running: true)
        model.sessions = [stale]
        model.sets = [setLog(body: body, sessionID: stale.id)]
        model.finished = true

        await model.finishWorkout()

        XCTAssertEqual(model.todaySession?.id, "canonical-session")
        XCTAssertEqual(model.setsForSession("canonical-session").count, 1)
        XCTAssertTrue(model.setsForSession(stale.id).isEmpty)
        XCTAssertEqual(
            StateSnapshotStore.load(
                userID: "user-a", defaults: defaults)?.state.sets.first?.session_id,
            "canonical-session")
    }

    func testClearedDiscardAndSetCannotBeReplayedByOlderModel() async {
        let defaults = defaults()
        let ex = exercise()
        let active = session(status: "in_progress", updatedAt: 300)
        var terminal = WorkoutTerminalOutbox()
        terminal.enqueue(.init(
            id: "discard-a", action: .discard, date: fixedCivilDate,
            workoutID: "day-a", resolvedSessionID: active.id,
            deliveryState: .acknowledged, failedHTTPStatus: nil))
        WorkoutTerminalOutboxStore.save(
            terminal, userID: "user-a", defaults: defaults)
        var sets = SetOutbox()
        sets.enqueue(.init(
            body: .init(
                id: fixedUUID.uuidString,
                exercise_id: ex.exercise_id,
                template_exercise_id: ex.id,
                set_index: 1, weight: 135, reps: 5,
                is_warmup: false, logged_at: 2_000_000_000_000,
                duration_s: nil, is_timed: false),
            date: fixedCivilDate, workoutID: "day-a",
            resolvedSessionID: active.id,
            deliveryState: .queued, failedHTTPStatus: nil))
        SetOutboxStore.save(sets, userID: "user-a", defaults: defaults)
        let api = SetWriteAPIStub()
        api.createHandler = { _, _, _ in XCTFail("stale create"); return active }
        api.logHandler = { _, _, _ in
            XCTFail("stale set"); throw URLError(.badServerResponse)
        }
        api.stateHandler = { [self] _ in
            state(session: active, sets: [], exercise: ex)
        }
        let terminalAPI = SetTerminalAPIStub()
        terminalAPI.discardHandler = { _, _ in
            XCTFail("stale discard"); throw URLError(.badServerResponse)
        }
        let older = SyncModel(
            auth: retainedAuth(defaults: defaults), setWriteAPI: api,
            terminalAPI: terminalAPI, catalogAPI: SetCatalogAPIStub(),
            defaults: defaults, now: { self.fixedDate })

        // A replacement model acknowledged the discard, cleared its barrier
        // for explicit restart, and superseded the pre-discard set.
        WorkoutTerminalOutboxStore.clearAcknowledgedDiscard(
            date: fixedCivilDate, userID: "user-a", defaults: defaults)
        SetOutboxStore.remove(
            date: fixedCivilDate, userID: "user-a", defaults: defaults)

        await older.recoverWorkoutWrites()

        XCTAssertTrue(api.createCalls.isEmpty)
        XCTAssertTrue(api.logCalls.isEmpty)
        XCTAssertTrue(terminalAPI.discardCalls.isEmpty)
        XCTAssertTrue(older.setOutbox.isEmpty)
        XCTAssertTrue(older.terminalOutbox.isEmpty)
    }

    func testOlderModelCannotClearReplacementRunnerCheckpoint() {
        let defaults = defaults()
        let ex = exercise()
        var endedLiveActivities = 0
        var cancelledNotifications = 0
        let old = WorkoutRunnerCheckpoint(
            date: fixedCivilDate, sessionID: "session-a",
            selectedDayID: "day-a", currentSlotID: ex.id,
            skippedSlotIDs: [], workoutStartedAtMS: 100, finished: false)
        let replacement = WorkoutRunnerCheckpoint(
            date: fixedCivilDate, sessionID: "session-a",
            selectedDayID: "day-a", currentSlotID: ex.id,
            skippedSlotIDs: [ex.id], workoutStartedAtMS: 200, finished: true)
        WorkoutRunnerCheckpointStore.save(
            old, userID: "user-a", defaults: defaults)
        let older = SyncModel(
            auth: retainedAuth(defaults: defaults), defaults: defaults,
            now: { self.fixedDate },
            restActivityEnder: { endedLiveActivities += 1 },
            restNotificationCanceller: { cancelledNotifications += 1 })
        older.running = true
        older.restEndDate = fixedDate.addingTimeInterval(90)
        WorkoutRunnerCheckpointStore.save(
            replacement, userID: "user-a", defaults: defaults)

        older.replaceState(with: state(
            session: session(status: "completed", updatedAt: 300),
            sets: [], exercise: ex))

        XCTAssertEqual(
            WorkoutRunnerCheckpointStore.load(
                userID: "user-a", defaults: defaults),
            replacement)
        XCTAssertNil(older.restEndDate)
        XCTAssertEqual(endedLiveActivities, 0)
        XCTAssertEqual(cancelledNotifications, 0)
    }

    func testDelayedOldAcknowledgementCannotUpdateReplacementRestActivity() async {
        let defaults = defaults()
        let ex = exercise(targetSets: 2)
        let active = session(status: "in_progress", attempt: 0)
        let entered = SetAsyncLatch()
        let release = SetAsyncLatch()
        let api = SetWriteAPIStub()
        api.logHandler = { [self] sessionID, body, _ in
            await entered.open()
            await release.wait()
            return .init(
                set: setLog(body: body, sessionID: sessionID),
                deduped: false,
                session: active)
        }
        api.stateHandler = { _ in throw URLError(.notConnectedToInternet) }
        let sharedAuth = retainedAuth(defaults: defaults)
        var staleRestUpdates = 0
        let older = SyncModel(
            auth: sharedAuth, setWriteAPI: api, defaults: defaults,
            uuidFactory: { self.fixedUUID }, now: { self.fixedDate },
            restActivityUpdater: { _, _ in staleRestUpdates += 1 })
        prepare(older, exercise: ex, session: active, running: true)

        await older.logCurrentSet(expected: ex, expectedSetNumber: 1)
        await entered.wait()
        XCTAssertGreaterThan(staleRestUpdates, 0)

        let replacementCheckpoint = WorkoutRunnerCheckpoint(
            date: fixedCivilDate, sessionID: active.id,
            selectedDayID: "day-a", currentSlotID: ex.id,
            skippedSlotIDs: [], workoutStartedAtMS: 2_000_000_000_001,
            finished: false, sessionAttempt: 0)
        WorkoutRunnerCheckpointStore.save(
            replacementCheckpoint, userID: "user-a", defaults: defaults)
        let replacement = SyncModel(
            auth: sharedAuth, defaults: defaults, now: { self.fixedDate })
        replacement.restEndDate = fixedDate.addingTimeInterval(120)
        staleRestUpdates = 0

        await release.open()
        await older.drainSetOutbox()

        XCTAssertEqual(staleRestUpdates, 0)
        XCTAssertFalse(older.running)
        XCTAssertNil(older.restEndDate)
        XCTAssertNotNil(replacement.restEndDate)
        XCTAssertEqual(
            WorkoutRunnerCheckpointStore.load(
                userID: "user-a", defaults: defaults),
            replacementCheckpoint)
    }

    func testOldConflictCannotEndValueIdenticalReplacementRestAfterReauth() async {
        let defaults = defaults()
        let ex = exercise(targetSets: 2)
        let active = session(status: "in_progress", attempt: 0)
        let completed = session(
            status: "completed", updatedAt: 200, attempt: 0)
        let entered = SetAsyncLatch()
        let release = SetAsyncLatch()
        let api = SetWriteAPIStub()
        api.logHandler = { _, _, _ in
            await entered.open()
            await release.wait()
            let data = try JSONEncoder().encode(completed)
            let object = String(decoding: data, as: UTF8.self)
            throw APIError.http(
                409,
                "{\"error\":\"session_state_conflict\",\"current_session\":\(object)}")
        }
        let oldToken = jwt(subject: "user-a")
        let newToken = jwt(
            subject: "user-a",
            expiration: fixedDate.addingTimeInterval(5_000_000))
        let authAPI = SetAuthAPIStub()
        authAPI.authResult = .success(
            authResponse(jwt: newToken, userID: "user-a"))
        let sharedAuth = auth(
            defaults: defaults, api: authAPI, token: oldToken)
        var endedLiveActivities = 0
        var cancelledNotifications = 0
        let older = SyncModel(
            auth: sharedAuth, setWriteAPI: api, defaults: defaults,
            uuidFactory: { self.fixedUUID }, now: { self.fixedDate },
            restActivityEnder: { endedLiveActivities += 1 },
            restNotificationCanceller: { cancelledNotifications += 1 })
        prepare(older, exercise: ex, session: active, running: true)
        older.restEndDate = fixedDate.addingTimeInterval(90)
        let originalCheckpoint = try! XCTUnwrap(
            WorkoutRunnerCheckpointStore.load(
                userID: "user-a", defaults: defaults))

        let write = Task {
            await older.logSet(ex, weight: 135, reps: 5)
        }
        await entered.wait()
        sharedAuth.signOut()
        await sharedAuth.exchange(identityToken: "same-user", fullName: nil)
        let replacement = SyncModel(
            auth: sharedAuth, defaults: defaults, now: { self.fixedDate })
        replacement.replaceState(with: state(
            session: active, sets: [], exercise: ex))
        replacement.resumeWorkout()
        replacement.restEndDate = fixedDate.addingTimeInterval(120)
        XCTAssertEqual(
            WorkoutRunnerCheckpointStore.load(
                userID: "user-a", defaults: defaults),
            originalCheckpoint)

        await release.open()
        let acknowledged = await write.value
        XCTAssertFalse(acknowledged)

        XCTAssertEqual(
            WorkoutRunnerCheckpointStore.load(
                userID: "user-a", defaults: defaults),
            originalCheckpoint)
        XCTAssertFalse(older.running)
        XCTAssertNil(older.restEndDate)
        XCTAssertNotNil(replacement.restEndDate)
        // Sign-out retired the old account-visible artifacts exactly once;
        // the late conflict must not touch the replacement runner's pair.
        XCTAssertEqual(endedLiveActivities, 1)
        XCTAssertEqual(cancelledNotifications, 1)
    }

    func testOldAcknowledgementCannotStartRestAfterReauth() async {
        let defaults = defaults()
        let ex = exercise(targetSets: 2)
        let active = session(status: "in_progress", attempt: 0)
        let entered = SetAsyncLatch()
        let release = SetAsyncLatch()
        let api = SetWriteAPIStub()
        api.logHandler = { [self] sessionID, body, _ in
            await entered.open()
            await release.wait()
            return .init(
                set: setLog(body: body, sessionID: sessionID),
                deduped: false,
                session: active)
        }
        api.stateHandler = { _ in throw URLError(.notConnectedToInternet) }
        let oldToken = jwt(subject: "user-a")
        let newToken = jwt(
            subject: "user-a",
            expiration: fixedDate.addingTimeInterval(5_000_000))
        let authAPI = SetAuthAPIStub()
        authAPI.authResult = .success(
            authResponse(jwt: newToken, userID: "user-a"))
        let sharedAuth = auth(
            defaults: defaults, api: authAPI, token: oldToken)
        let older = SyncModel(
            auth: sharedAuth, setWriteAPI: api, defaults: defaults,
            uuidFactory: { self.fixedUUID }, now: { self.fixedDate })
        prepare(older, exercise: ex, session: active, running: true)
        let originalCheckpoint = try! XCTUnwrap(
            WorkoutRunnerCheckpointStore.load(
                userID: "user-a", defaults: defaults))

        let write = Task {
            await older.logSet(ex, weight: 135, reps: 5)
        }
        await entered.wait()
        sharedAuth.signOut()
        await sharedAuth.exchange(identityToken: "same-user", fullName: nil)
        let replacement = SyncModel(
            auth: sharedAuth, defaults: defaults, now: { self.fixedDate })
        replacement.replaceState(with: state(
            session: active, sets: [], exercise: ex))
        replacement.resumeWorkout()
        replacement.restEndDate = fixedDate.addingTimeInterval(120)

        await release.open()
        let acknowledged = await write.value

        XCTAssertTrue(acknowledged)
        XCTAssertFalse(older.running)
        XCTAssertNil(older.restEndDate)
        XCTAssertNotNil(replacement.restEndDate)
        XCTAssertEqual(
            WorkoutRunnerCheckpointStore.load(
                userID: "user-a", defaults: defaults),
            originalCheckpoint)
    }

    func testNewEpochCanClearCheckpointOwnedByRetiredEpoch() async {
        let defaults = defaults()
        let ex = exercise()
        let active = session(status: "in_progress", attempt: 0)
        let oldToken = jwt(subject: "user-a")
        let newToken = jwt(
            subject: "user-a",
            expiration: fixedDate.addingTimeInterval(5_000_000))
        let authAPI = SetAuthAPIStub()
        authAPI.authResult = .success(
            authResponse(jwt: newToken, userID: "user-a"))
        let sharedAuth = auth(
            defaults: defaults, api: authAPI, token: oldToken)
        let older = SyncModel(
            auth: sharedAuth, defaults: defaults, now: { self.fixedDate })
        prepare(older, exercise: ex, session: active, running: true)
        XCTAssertNotNil(WorkoutRunnerCheckpointStore.load(
            userID: "user-a", defaults: defaults))

        sharedAuth.signOut()
        await sharedAuth.exchange(identityToken: "same-user", fullName: nil)
        var endedLiveActivities = 0
        var cancelledNotifications = 0
        let replacement = SyncModel(
            auth: sharedAuth, defaults: defaults, now: { self.fixedDate },
            restActivityEnder: { endedLiveActivities += 1 },
            restNotificationCanceller: { cancelledNotifications += 1 })
        replacement.replaceState(with: state(
            session: session(
                status: "completed", updatedAt: 200, attempt: 0),
            sets: [], exercise: ex))

        XCTAssertNil(WorkoutRunnerCheckpointStore.load(
            userID: "user-a", defaults: defaults))
        XCTAssertEqual(endedLiveActivities, 1)
        XCTAssertEqual(cancelledNotifications, 1)
    }

    func testColdRelaunchPreservesUnresolvedRestartAndFencesRoutineMutations() async {
        let defaults = defaults()
        let ex = exercise()
        let discarded = session(
            status: "discarded", updatedAt: 100, attempt: 0)
        var terminal = WorkoutTerminalOutbox()
        terminal.enqueue(.init(
            id: "discard-a", action: .discard, date: fixedCivilDate,
            workoutID: "day-a", resolvedSessionID: discarded.id,
            deliveryState: .acknowledged, failedHTTPStatus: nil,
            expectedAttempt: 0))
        WorkoutTerminalOutboxStore.save(
            terminal, userID: "user-a", defaults: defaults)
        let sharedAuth = retainedAuth(defaults: defaults)
        let failingAPI = SetWriteAPIStub()
        failingAPI.createHandler = { _, _, _ in
            throw URLError(.notConnectedToInternet)
        }
        let first = SyncModel(
            auth: sharedAuth, setWriteAPI: failingAPI,
            defaults: defaults, uuidFactory: { self.fixedUUID },
            now: { self.fixedDate })
        first.replaceState(with: state(
            session: discarded, sets: [], exercise: ex))
        first.startWorkout()

        let acknowledged = await first.logSet(ex, weight: 135, reps: 5)
        XCTAssertFalse(acknowledged)
        XCTAssertNil(WorkoutRunnerCheckpointStore.load(
            userID: "user-a", defaults: defaults)?.sessionID)

        let liveAPI = SetWriteAPIStub()
        liveAPI.stateHandler = { [self] _ in
            state(session: discarded, sets: [], exercise: ex)
        }
        let routineAPI = SetRoutineEditingAPIStub()
        routineAPI.deleteDayHandler = { _, _, _ in
            XCTFail("A recovered workout day must not reach deletion")
            return APIClient.DeleteWorkoutResult(ok: true, version: 2)
        }
        routineAPI.calendarHandler = { _, _, _, _ in
            XCTFail("A recovered workout date must not be reassigned")
            return APIClient.CalendarWriteResult(ok: true, session: discarded)
        }
        let relaunched = SyncModel(
            auth: sharedAuth, setWriteAPI: liveAPI,
            catalogAPI: SetCatalogAPIStub(), routineEditingAPI: routineAPI,
            defaults: defaults,
            now: { self.fixedDate })
        await relaunched.load()

        XCTAssertEqual(relaunched.setOutbox.count, 1)
        XCTAssertTrue(relaunched.blocksNewWorkoutStart)
        XCTAssertNotNil(WorkoutRunnerCheckpointStore.load(
            userID: "user-a", defaults: defaults))

        await relaunched.deleteWorkoutDay(dayID: "day-a")
        XCTAssertEqual(routineAPI.deleteDayCalls, 0)
        XCTAssertEqual(
            relaunched.loadError,
            "Finish or discard the active workout before removing this workout day.")

        await relaunched.setCalendarOverride(
            date: fixedCivilDate, dayID: nil)
        XCTAssertEqual(routineAPI.calendarCalls, 0)
        XCTAssertEqual(
            relaunched.loadError,
            "Finish or discard the active workout before changing today's assignment.")
    }

    func testOldWorkerSetACKPromotesPlannedSessionInColdSnapshot() async {
        let defaults = defaults()
        let ex = exercise()
        let planned = session(status: "planned", updatedAt: 100, attempt: 0)
        let api = SetWriteAPIStub()
        api.logHandler = { [self] sessionID, body, _ in
            .init(
                set: setLog(body: body, sessionID: sessionID),
                deduped: false)
        }
        api.stateHandler = { _ in throw URLError(.notConnectedToInternet) }
        let sharedAuth = retainedAuth(defaults: defaults)
        let model = SyncModel(
            auth: sharedAuth, setWriteAPI: api, defaults: defaults,
            uuidFactory: { self.fixedUUID }, now: { self.fixedDate })
        model.replaceState(with: state(
            session: planned, sets: [], exercise: ex))
        model.startWorkout()

        let acknowledged = await model.logSet(ex, weight: 135, reps: 5)

        XCTAssertTrue(acknowledged)
        let snapshot = try! XCTUnwrap(StateSnapshotStore.load(
            userID: "user-a", defaults: defaults)?.state)
        XCTAssertEqual(snapshot.sessions.first?.status, "in_progress")
        XCTAssertEqual(snapshot.sessions.first?.attempt, 0)
        XCTAssertEqual(snapshot.sets.map(\.id), [fixedUUID.uuidString])

        let cold = SyncModel(
            auth: sharedAuth, defaults: defaults,
            now: { self.fixedDate })
        XCTAssertEqual(cold.todaySession?.status, "in_progress")
        XCTAssertEqual(cold.sets.map(\.id), [fixedUUID.uuidString])
        XCTAssertTrue(cold.isUsingCachedState)
    }

    func testMountedRunnerStaysFinishedWhileForegroundSettlesTimedOutFinalSet() async {
        let defaults = defaults()
        let ex = exercise(targetSets: 1)
        let active = session(
            status: "in_progress", updatedAt: 100, attempt: 0)
        let api = SetWriteAPIStub()
        var committed: SetLog?
        api.logHandler = { [self] sessionID, body, _ in
            if api.logCalls.count == 1 {
                throw URLError(.timedOut)
            }
            let row = setLog(body: body, sessionID: sessionID)
            committed = row
            return .init(
                set: row,
                deduped: true,
                session: session(
                    id: sessionID, status: "in_progress",
                    updatedAt: 200, attempt: 0))
        }
        api.stateHandler = { [self] _ in
            state(
                session: session(
                    status: "in_progress", updatedAt: 200, attempt: 0),
                sets: committed.map { [$0] } ?? [],
                exercise: ex)
        }
        let model = SyncModel(
            auth: retainedAuth(defaults: defaults), setWriteAPI: api,
            catalogAPI: SetCatalogAPIStub(), defaults: defaults,
            uuidFactory: { self.fixedUUID }, now: { self.fixedDate })
        model.replaceState(with: state(
            session: active, sets: [], exercise: ex))
        model.startWorkout()

        await model.logCurrentSet(
            expected: ex, expectedSetNumber: 1)
        XCTAssertTrue(model.running)
        XCTAssertTrue(model.finished)
        XCTAssertEqual(model.setOutbox.count, 1)

        await model.recoverWorkoutWrites()

        XCTAssertEqual(api.logCalls.count, 2)
        XCTAssertTrue(model.setOutbox.isEmpty)
        XCTAssertEqual(model.sets.map(\.id), [fixedUUID.uuidString])
        XCTAssertTrue(model.running)
        XCTAssertTrue(model.finished)
        XCTAssertEqual(
            WorkoutRunnerCheckpointStore.load(
                userID: "user-a", defaults: defaults)?.finished,
            true)
    }

    func testSuccessfulDeletePersistsTombstoneAndSessionBeforeColdOfflineLaunch() async {
        let defaults = defaults()
        let ex = exercise()
        let active = session(
            status: "in_progress", updatedAt: 100, attempt: 0)
        let body = SetRequestBody(
            id: fixedUUID.uuidString,
            exercise_id: ex.exercise_id,
            template_exercise_id: ex.id,
            set_index: 1,
            weight: 135,
            reps: 5,
            is_warmup: false,
            logged_at: 2_000_000_000_000,
            duration_s: nil,
            is_timed: false)
        let savedSet = setLog(body: body, sessionID: active.id)
        let api = SetWriteAPIStub()
        api.correctionHandler = { [self] _, _ in
            SetCorrectionResult(set: setLog(body: body, sessionID: active.id, updatedAt: 2_000_000_000_002, deletedAt: 200),
                                session: session(status: "planned", updatedAt: 200, attempt: 0))
        }
        let sharedAuth = retainedAuth(defaults: defaults)
        let model = SyncModel(
            auth: sharedAuth, setWriteAPI: api, defaults: defaults,
            now: { self.fixedDate })
        model.replaceState(with: state(
            session: active, sets: [savedSet], exercise: ex))

        await model.removeSet(savedSet)

        XCTAssertEqual(api.correctionCalls.map(\.setID), [savedSet.id])
        XCTAssertTrue(model.sets.isEmpty)
        XCTAssertEqual(StateSnapshotStore.load(
            userID: "user-a", defaults: defaults)?.state.sets.first?.deleted_at, 200)

        let cold = SyncModel(
            auth: sharedAuth, defaults: defaults,
            now: { self.fixedDate })
        XCTAssertNotNil(cold.plan)
        XCTAssertEqual(cold.todaySession?.status, "planned")
        XCTAssertTrue(cold.sets.isEmpty)
        XCTAssertTrue(cold.isUsingCachedState)
    }

    func testConflictAfterDeleteAdoptsNewAttemptWithoutResurrectingDeletedSet() async {
        let defaults = defaults()
        let ex = exercise()
        let active = session(
            status: "in_progress", updatedAt: 100, attempt: 0)
        let deletedBody = SetRequestBody(
            id: "22222222-2222-4222-8222-222222222222",
            exercise_id: ex.exercise_id,
            template_exercise_id: ex.id,
            set_index: 1,
            weight: 125,
            reps: 5,
            is_warmup: false,
            logged_at: 1_999_999_999_000,
            duration_s: nil,
            is_timed: false)
        let savedSet = setLog(body: deletedBody, sessionID: active.id)
        let api = SetWriteAPIStub()
        api.correctionHandler = { [self] _, _ in
            SetCorrectionResult(set: setLog(body: deletedBody, sessionID: active.id, updatedAt: 2_000_000_000_002, deletedAt: 150),
                                session: session(status: "planned", updatedAt: 150, attempt: 0))
        }
        api.logHandler = { [self] _, _, _ in
            let current = session(
                status: "in_progress", updatedAt: 200, attempt: 1)
            let data = try JSONEncoder().encode(current)
            let object = String(decoding: data, as: UTF8.self)
            throw APIError.http(
                409,
                "{\"error\":\"session_attempt_conflict\",\"current_session\":\(object)}")
        }
        let sharedAuth = retainedAuth(defaults: defaults)
        let model = SyncModel(
            auth: sharedAuth, setWriteAPI: api, defaults: defaults,
            uuidFactory: { self.fixedUUID }, now: { self.fixedDate })
        model.replaceState(with: state(
            session: active, sets: [savedSet], exercise: ex))
        model.startWorkout()

        await model.removeSet(savedSet)
        XCTAssertFalse(model.sets.contains { $0.id == savedSet.id })

        let acknowledged = await model.logSet(ex, weight: 135, reps: 5)

        XCTAssertFalse(acknowledged)
        XCTAssertEqual(api.logCalls.first?.body.expected_attempt, 0)
        XCTAssertTrue(model.setOutbox.isEmpty)
        XCTAssertEqual(model.todaySession?.status, "in_progress")
        XCTAssertEqual(model.todaySession?.attempt, 1)
        XCTAssertFalse(model.running)
        XCTAssertNil(WorkoutRunnerCheckpointStore.load(
            userID: "user-a", defaults: defaults))
        XCTAssertFalse(model.sets.contains { $0.id == savedSet.id })
    }

    func testExplicitRestartAttemptWinsOverCachedDiscardWithoutFollowUpPull() async {
        let defaults = defaults()
        let ex = exercise()
        let discarded = session(
            status: "discarded", updatedAt: 100, attempt: 0)
        var terminal = WorkoutTerminalOutbox()
        terminal.enqueue(.init(
            id: "discard-a", action: .discard, date: fixedCivilDate,
            workoutID: "day-a", resolvedSessionID: discarded.id,
            deliveryState: .acknowledged, failedHTTPStatus: nil))
        WorkoutTerminalOutboxStore.save(
            terminal, userID: "user-a", defaults: defaults)
        let revived = session(
            status: "planned", updatedAt: 200, attempt: 1)
        let api = SetWriteAPIStub()
        api.createHandler = { _, _, _ in revived }
        api.logHandler = { [self] sessionID, body, _ in
            .init(
                set: setLog(body: body, sessionID: sessionID),
                deduped: false,
                session: session(
                    id: sessionID, status: "in_progress",
                    updatedAt: 300, attempt: 1))
        }
        api.stateHandler = { _ in throw URLError(.notConnectedToInternet) }
        let sharedAuth = retainedAuth(defaults: defaults)
        let model = SyncModel(
            auth: sharedAuth, setWriteAPI: api, defaults: defaults,
            uuidFactory: { self.fixedUUID }, now: { self.fixedDate })
        model.replaceState(with: state(
            session: discarded, sets: [], exercise: ex))
        model.startWorkout()

        let acknowledged = await model.logSet(ex, weight: 135, reps: 5)

        XCTAssertTrue(acknowledged)
        XCTAssertEqual(api.createCalls.count, 1)
        XCTAssertEqual(api.createCalls.first?.expectedAttempt, 0)
        XCTAssertEqual(api.createCalls.first?.restartDiscardedAttempt, 0)
        XCTAssertEqual(api.logCalls.first?.body.expected_attempt, 1)
        let snapshot = try! XCTUnwrap(StateSnapshotStore.load(
            userID: "user-a", defaults: defaults)?.state)
        XCTAssertEqual(snapshot.sessions.first?.status, "in_progress")
        XCTAssertEqual(snapshot.sessions.first?.attempt, 1)
        XCTAssertEqual(snapshot.sets.map(\.id), [fixedUUID.uuidString])
        let cold = SyncModel(
            auth: sharedAuth, defaults: defaults,
            now: { self.fixedDate })
        XCTAssertEqual(cold.todaySession?.attempt, 1)
        XCTAssertEqual(cold.todaySession?.status, "in_progress")
    }

    func testNilBoundRunnerStopsWhenSessionCreateReportsNewerAttempt() async {
        let defaults = defaults()
        let ex = exercise()
        let api = SetWriteAPIStub()
        api.createHandler = { [self] _, _, _ in
            let current = session(
                status: "in_progress", updatedAt: 200, attempt: 1)
            let data = try JSONEncoder().encode(current)
            let object = String(decoding: data, as: UTF8.self)
            throw APIError.http(
                409,
                "{\"error\":\"session_attempt_conflict\",\"current_session\":\(object)}")
        }
        let model = SyncModel(
            auth: retainedAuth(defaults: defaults), setWriteAPI: api,
            defaults: defaults, uuidFactory: { self.fixedUUID },
            now: { self.fixedDate })
        prepare(model, exercise: ex, running: true)
        XCTAssertNil(WorkoutRunnerCheckpointStore.load(
            userID: "user-a", defaults: defaults)?.sessionID)

        let acknowledged = await model.logSet(ex, weight: 135, reps: 5)

        XCTAssertFalse(acknowledged)
        XCTAssertEqual(api.createCalls.first?.expectedAttempt, 0)
        XCTAssertNil(api.createCalls.first?.restartDiscardedAttempt)
        XCTAssertTrue(api.logCalls.isEmpty)
        XCTAssertTrue(model.setOutbox.isEmpty)
        XCTAssertFalse(model.running)
        XCTAssertNil(WorkoutRunnerCheckpointStore.load(
            userID: "user-a", defaults: defaults))
        XCTAssertEqual(model.todaySession?.status, "in_progress")
        XCTAssertEqual(model.todaySession?.attempt, 1)
    }

    func testLegacyAttemptZeroCreateKeepsCachedSetsWhenReconciliationFails() async {
        let defaults = defaults()
        let ex = exercise()
        let legacy = session(
            status: "in_progress", updatedAt: 100, attempt: nil)
        let oldBody = SetRequestBody(
            id: "22222222-2222-4222-8222-222222222222",
            exercise_id: ex.exercise_id,
            template_exercise_id: ex.id,
            set_index: 1,
            weight: 125,
            reps: 5,
            is_warmup: false,
            logged_at: 1_999_999_999_000,
            duration_s: nil,
            is_timed: false)
        let newBody = SetRequestBody(
            id: fixedUUID.uuidString,
            exercise_id: ex.exercise_id,
            template_exercise_id: ex.id,
            set_index: 2,
            weight: 135,
            reps: 5,
            is_warmup: false,
            logged_at: 2_000_000_000_000,
            duration_s: nil,
            is_timed: false)
        StateSnapshotStore.save(
            state(
                session: legacy,
                sets: [setLog(body: oldBody)],
                exercise: ex),
            userID: "user-a",
            defaults: defaults)
        var outbox = SetOutbox()
        outbox.enqueue(.init(
            body: newBody,
            date: fixedCivilDate,
            workoutID: "day-a",
            resolvedSessionID: nil,
            deliveryState: .queued,
            failedHTTPStatus: nil,
            expectedAttempt: 0))
        SetOutboxStore.save(outbox, userID: "user-a", defaults: defaults)
        let api = SetWriteAPIStub()
        api.createHandler = { [self] _, _, _ in
            session(status: "in_progress", updatedAt: 200, attempt: 0)
        }
        api.logHandler = { [self] sessionID, body, _ in
            .init(
                set: setLog(body: body, sessionID: sessionID),
                deduped: false,
                session: session(
                    id: sessionID, status: "in_progress",
                    updatedAt: 300, attempt: 0))
        }
        api.stateHandler = { _ in throw URLError(.notConnectedToInternet) }
        let model = SyncModel(
            auth: retainedAuth(defaults: defaults), setWriteAPI: api,
            defaults: defaults, now: { self.fixedDate })

        await model.drainSetOutbox()

        XCTAssertEqual(api.createCalls.first?.expectedAttempt, 0)
        XCTAssertNil(api.createCalls.first?.restartDiscardedAttempt)
        XCTAssertEqual(api.logCalls.first?.body.expected_attempt, 0)
        XCTAssertTrue(model.setOutbox.isEmpty)
        XCTAssertEqual(
            Set(model.sets.map(\.id)),
            Set([oldBody.id, newBody.id]))
        let snapshot = try! XCTUnwrap(StateSnapshotStore.load(
            userID: "user-a", defaults: defaults)?.state)
        XCTAssertEqual(snapshot.sessions.first?.attempt, 0)
        XCTAssertEqual(
            Set(snapshot.sets.map(\.id)),
            Set([oldBody.id, newBody.id]))
    }

    func testDelayedCreateResolutionCannotDowngradeEqualTimestampSetACK() async {
        let defaults = defaults()
        let ex = exercise()
        let discarded = session(
            status: "discarded", updatedAt: 100, attempt: 0)
        var terminal = WorkoutTerminalOutbox()
        terminal.enqueue(.init(
            id: "discard-a", action: .discard, date: fixedCivilDate,
            workoutID: "day-a", resolvedSessionID: discarded.id,
            deliveryState: .acknowledged, failedHTTPStatus: nil,
            expectedAttempt: 0))
        WorkoutTerminalOutboxStore.save(
            terminal, userID: "user-a", defaults: defaults)
        let entered = SetAsyncLatch()
        let release = SetAsyncLatch()
        let api = SetWriteAPIStub()
        api.createHandler = { [self] _, _, _ in
            await entered.open()
            await release.wait()
            return session(status: "planned", updatedAt: 200, attempt: 1)
        }
        api.logHandler = { [self] sessionID, body, _ in
            .init(
                set: setLog(body: body, sessionID: sessionID),
                deduped: false,
                session: session(
                    id: sessionID, status: "in_progress",
                    updatedAt: 200, attempt: 1))
        }
        api.stateHandler = { _ in throw URLError(.notConnectedToInternet) }
        let sharedAuth = retainedAuth(defaults: defaults)
        let older = SyncModel(
            auth: sharedAuth, setWriteAPI: api, defaults: defaults,
            uuidFactory: { self.fixedUUID }, now: { self.fixedDate })
        older.replaceState(with: state(
            session: discarded, sets: [], exercise: ex))
        older.startWorkout()

        let write = Task { await older.logSet(ex, weight: 135, reps: 5) }
        await entered.wait()
        let replacement = SyncModel(
            auth: sharedAuth, defaults: defaults,
            now: { self.fixedDate })
        replacement.replaceState(with: state(
            session: session(
                status: "in_progress", updatedAt: 200, attempt: 1),
            sets: [], exercise: ex))
        await release.open()

        let acknowledged = await write.value
        XCTAssertTrue(acknowledged)
        XCTAssertEqual(api.createCalls.first?.restartDiscardedAttempt, 0)
        XCTAssertEqual(api.logCalls.first?.body.expected_attempt, 1)
        let snapshot = try! XCTUnwrap(StateSnapshotStore.load(
            userID: "user-a", defaults: defaults)?.state)
        XCTAssertEqual(snapshot.sessions.first?.status, "in_progress")
        XCTAssertEqual(snapshot.sessions.first?.attempt, 1)
        let cold = SyncModel(
            auth: sharedAuth, defaults: defaults,
            now: { self.fixedDate })
        XCTAssertEqual(cold.todaySession?.status, "in_progress")
        XCTAssertEqual(cold.todaySession?.attempt, 1)
    }

    func testDelayedConflictCannotDowngradeEqualTimestampCurrentSession() async {
        let defaults = defaults()
        let ex = exercise()
        let current = session(
            status: "in_progress", updatedAt: 200, attempt: 1)
        StateSnapshotStore.save(
            state(session: current, sets: [], exercise: ex),
            userID: "user-a", defaults: defaults)
        let body = SetRequestBody(
            id: fixedUUID.uuidString,
            exercise_id: ex.exercise_id,
            template_exercise_id: ex.id,
            set_index: 1,
            weight: 135,
            reps: 5,
            is_warmup: false,
            logged_at: 2_000_000_000_000,
            duration_s: nil,
            is_timed: false)
        var outbox = SetOutbox()
        outbox.enqueue(.init(
            body: body, date: fixedCivilDate,
            workoutID: "day-a", resolvedSessionID: nil,
            deliveryState: .queued, failedHTTPStatus: nil,
            expectedAttempt: 0))
        SetOutboxStore.save(outbox, userID: "user-a", defaults: defaults)
        let api = SetWriteAPIStub()
        api.createHandler = { [self] _, _, _ in
            let stale = session(
                status: "planned", updatedAt: 200, attempt: 1)
            let data = try JSONEncoder().encode(stale)
            let object = String(decoding: data, as: UTF8.self)
            throw APIError.http(
                409,
                "{\"error\":\"session_attempt_conflict\",\"current_session\":\(object)}")
        }
        let model = SyncModel(
            auth: retainedAuth(defaults: defaults), setWriteAPI: api,
            defaults: defaults, now: { self.fixedDate })

        await model.drainSetOutbox()

        XCTAssertTrue(model.setOutbox.isEmpty)
        XCTAssertEqual(model.todaySession?.status, "in_progress")
        XCTAssertEqual(model.todaySession?.attempt, 1)
        let snapshot = try! XCTUnwrap(StateSnapshotStore.load(
            userID: "user-a", defaults: defaults)?.state)
        XCTAssertEqual(snapshot.sessions.first?.status, "in_progress")
        XCTAssertEqual(snapshot.sessions.first?.attempt, 1)
    }

    func testAttemptZeroResolutionCannotDemoteLegacyTerminalSnapshot() async {
        let defaults = defaults()
        let ex = exercise()
        let legacyCompleted = session(
            status: "completed", updatedAt: 200, attempt: nil)
        StateSnapshotStore.save(
            state(session: legacyCompleted, sets: [], exercise: ex),
            userID: "user-a", defaults: defaults)
        let body = SetRequestBody(
            id: fixedUUID.uuidString,
            exercise_id: ex.exercise_id,
            template_exercise_id: ex.id,
            set_index: 1,
            weight: 135,
            reps: 5,
            is_warmup: false,
            logged_at: 2_000_000_000_000,
            duration_s: nil,
            is_timed: false)
        var outbox = SetOutbox()
        outbox.enqueue(.init(
            body: body, date: fixedCivilDate,
            workoutID: "day-a", resolvedSessionID: nil,
            deliveryState: .queued, failedHTTPStatus: nil,
            expectedAttempt: 0))
        SetOutboxStore.save(outbox, userID: "user-a", defaults: defaults)
        let api = SetWriteAPIStub()
        api.createHandler = { [self] _, _, _ in
            let stalePlanned = session(
                status: "planned", updatedAt: 300, attempt: 0)
            let data = try JSONEncoder().encode(stalePlanned)
            let object = String(decoding: data, as: UTF8.self)
            throw APIError.http(
                409,
                "{\"error\":\"session_attempt_conflict\",\"current_session\":\(object)}")
        }
        let sharedAuth = retainedAuth(defaults: defaults)
        let model = SyncModel(
            auth: sharedAuth, setWriteAPI: api, defaults: defaults,
            now: { self.fixedDate })

        await model.drainSetOutbox()

        XCTAssertTrue(model.setOutbox.isEmpty)
        XCTAssertEqual(model.todaySession?.status, "completed")
        XCTAssertEqual(model.todaySession?.attempt, 0)
        let snapshot = try! XCTUnwrap(StateSnapshotStore.load(
            userID: "user-a", defaults: defaults)?.state)
        XCTAssertEqual(snapshot.sessions.first?.status, "completed")
        XCTAssertEqual(snapshot.sessions.first?.attempt, 0)
        let cold = SyncModel(
            auth: sharedAuth, defaults: defaults,
            now: { self.fixedDate })
        XCTAssertEqual(cold.todaySession?.status, "completed")
        XCTAssertEqual(cold.todaySession?.attempt, 0)
    }

    func testAuthoritativeConflictAdvancesPlannedSnapshotToCompletedSession() async {
        let defaults = defaults()
        let ex = exercise()
        let planned = session(
            status: "planned", updatedAt: 100, attempt: 1)
        StateSnapshotStore.save(
            state(session: planned, sets: [], exercise: ex),
            userID: "user-a", defaults: defaults)
        let body = SetRequestBody(
            id: fixedUUID.uuidString,
            exercise_id: ex.exercise_id,
            template_exercise_id: ex.id,
            set_index: 1,
            weight: 135,
            reps: 5,
            is_warmup: false,
            logged_at: 2_000_000_000_000,
            duration_s: nil,
            is_timed: false)
        var outbox = SetOutbox()
        outbox.enqueue(.init(
            body: body, date: fixedCivilDate,
            workoutID: "day-a", resolvedSessionID: nil,
            deliveryState: .queued, failedHTTPStatus: nil,
            expectedAttempt: 0))
        SetOutboxStore.save(outbox, userID: "user-a", defaults: defaults)
        let api = SetWriteAPIStub()
        api.createHandler = { [self] _, _, _ in
            let completed = session(
                status: "completed", updatedAt: 200, attempt: 1)
            let data = try JSONEncoder().encode(completed)
            let object = String(decoding: data, as: UTF8.self)
            throw APIError.http(
                409,
                "{\"error\":\"session_attempt_conflict\",\"current_session\":\(object)}")
        }
        let sharedAuth = retainedAuth(defaults: defaults)
        let model = SyncModel(
            auth: sharedAuth, setWriteAPI: api, defaults: defaults,
            now: { self.fixedDate })

        await model.drainSetOutbox()

        XCTAssertTrue(model.setOutbox.isEmpty)
        XCTAssertEqual(model.todaySession?.status, "completed")
        XCTAssertEqual(model.todaySession?.attempt, 1)
        let snapshot = try! XCTUnwrap(StateSnapshotStore.load(
            userID: "user-a", defaults: defaults)?.state)
        XCTAssertEqual(snapshot.sessions.first?.status, "completed")
        XCTAssertEqual(snapshot.sessions.first?.attempt, 1)
        let cold = SyncModel(
            auth: sharedAuth, defaults: defaults,
            now: { self.fixedDate })
        XCTAssertEqual(cold.todaySession?.status, "completed")
        XCTAssertEqual(cold.todaySession?.attempt, 1)
    }

    func testExactOldUUIDTombstoneSettlesWithoutRegressingNewAttempt() async {
        let defaults = defaults()
        let ex = exercise()
        let current = session(
            status: "in_progress", updatedAt: 300, attempt: 1)
        let oldBody = SetRequestBody(
            id: fixedUUID.uuidString,
            exercise_id: ex.exercise_id,
            template_exercise_id: ex.id,
            set_index: 1,
            weight: 125,
            reps: 5,
            is_warmup: false,
            logged_at: 1_999_999_999_000,
            duration_s: nil,
            is_timed: false)
        let currentBody = SetRequestBody(
            id: "22222222-2222-4222-8222-222222222222",
            exercise_id: ex.exercise_id,
            template_exercise_id: ex.id,
            set_index: 1,
            weight: 145,
            reps: 5,
            is_warmup: false,
            logged_at: 2_000_000_000_000,
            duration_s: nil,
            is_timed: false)
        StateSnapshotStore.save(
            state(
                session: current,
                sets: [setLog(body: currentBody)],
                exercise: ex),
            userID: "user-a", defaults: defaults)
        var outbox = SetOutbox()
        outbox.enqueue(.init(
            body: oldBody, date: fixedCivilDate,
            workoutID: "day-a", resolvedSessionID: current.id,
            deliveryState: .queued, failedHTTPStatus: nil,
            expectedAttempt: 0))
        SetOutboxStore.save(outbox, userID: "user-a", defaults: defaults)
        let api = SetWriteAPIStub()
        api.logHandler = { [self] sessionID, body, _ in
            let old = setLog(body: body, sessionID: sessionID)
            let tombstone = SetLog(
                id: old.id,
                session_id: old.session_id,
                exercise_id: old.exercise_id,
                template_exercise_id: old.template_exercise_id,
                set_index: old.set_index,
                weight: old.weight,
                reps: old.reps,
                rpe: old.rpe,
                is_warmup: old.is_warmup,
                logged_at: old.logged_at,
                duration_s: old.duration_s,
                is_timed: old.is_timed,
                deleted_at: 200)
            return .init(
                set: tombstone,
                deduped: true,
                session: current)
        }
        api.stateHandler = { _ in throw URLError(.notConnectedToInternet) }
        let model = SyncModel(
            auth: retainedAuth(defaults: defaults), setWriteAPI: api,
            defaults: defaults, now: { self.fixedDate })

        await model.drainSetOutbox()

        XCTAssertEqual(api.logCalls.first?.body.expected_attempt, 0)
        XCTAssertTrue(model.setOutbox.isEmpty)
        XCTAssertEqual(model.todaySession?.status, "in_progress")
        XCTAssertEqual(model.todaySession?.attempt, 1)
        XCTAssertEqual(model.sets.map(\.id), [currentBody.id])
        let snapshot = try! XCTUnwrap(StateSnapshotStore.load(
            userID: "user-a", defaults: defaults)?.state)
        XCTAssertEqual(snapshot.sessions.first?.attempt, 1)
        XCTAssertEqual(snapshot.sets.map(\.id), [currentBody.id])
    }

    func testMountedFinalSetTombstoneCannotBridgeRunnerToNewAttempt() async {
        let defaults = defaults()
        let ex = exercise(targetSets: 1)
        let old = session(
            status: "in_progress", updatedAt: 100, attempt: 0)
        let current = session(
            status: "in_progress", updatedAt: 300, attempt: 1)
        let entered = SetAsyncLatch()
        let release = SetAsyncLatch()
        let api = SetWriteAPIStub()
        api.logHandler = { [self] sessionID, body, _ in
            await entered.open()
            await release.wait()
            let accepted = setLog(body: body, sessionID: sessionID)
            let tombstone = SetLog(
                id: accepted.id,
                session_id: accepted.session_id,
                exercise_id: accepted.exercise_id,
                template_exercise_id: accepted.template_exercise_id,
                set_index: accepted.set_index,
                weight: accepted.weight,
                reps: accepted.reps,
                rpe: accepted.rpe,
                is_warmup: accepted.is_warmup,
                logged_at: accepted.logged_at,
                duration_s: accepted.duration_s,
                is_timed: accepted.is_timed,
                deleted_at: 200)
            return .init(set: tombstone, deduped: true, session: current)
        }
        api.stateHandler = { _ in throw URLError(.notConnectedToInternet) }
        let model = SyncModel(
            auth: retainedAuth(defaults: defaults), setWriteAPI: api,
            defaults: defaults, uuidFactory: { self.fixedUUID },
            now: { self.fixedDate })
        model.replaceState(with: state(
            session: old, sets: [], exercise: ex))
        model.startWorkout()

        await model.logCurrentSet(
            expected: ex, expectedSetNumber: 1)
        await entered.wait()
        XCTAssertTrue(model.running)
        XCTAssertTrue(model.finished)
        XCTAssertEqual(model.setOutbox.count, 1)

        await release.open()
        for _ in 0..<1_000 where !model.setOutbox.isEmpty {
            await Task.yield()
        }

        XCTAssertTrue(model.setOutbox.isEmpty)
        XCTAssertFalse(model.running)
        XCTAssertNil(WorkoutRunnerCheckpointStore.load(
            userID: "user-a", defaults: defaults))
        XCTAssertEqual(model.todaySession?.attempt, 1)
        XCTAssertTrue(model.sets.isEmpty)
        let snapshot = try! XCTUnwrap(StateSnapshotStore.load(
            userID: "user-a", defaults: defaults)?.state)
        XCTAssertEqual(snapshot.sessions.first?.attempt, 1)
        XCTAssertTrue(snapshot.sets.isEmpty)
    }

    func testDelayedFinishACKCannotOverwriteLaterDiscardInSameAttempt() async {
        let defaults = defaults()
        let ex = exercise()
        let active = session(
            status: "in_progress", updatedAt: 100, attempt: 0)
        let terminalAPI = SetTerminalAPIStub()
        let entered = SetAsyncLatch()
        let release = SetAsyncLatch()
        terminalAPI.completeHandler = { [self] _, _ in
            await entered.open()
            await release.wait()
            return session(
                status: "completed", updatedAt: 200, attempt: 0)
        }
        let model = SyncModel(
            auth: retainedAuth(defaults: defaults), terminalAPI: terminalAPI,
            defaults: defaults, now: { self.fixedDate })
        model.replaceState(with: state(
            session: active, sets: [], exercise: ex))
        model.startWorkout()
        model.finished = true

        let finish = Task { await model.finishWorkout() }
        await entered.wait()
        model.replaceState(with: state(
            session: session(
                status: "discarded", updatedAt: 200, attempt: 0),
            sets: [], exercise: ex))
        await release.open()
        await finish.value

        XCTAssertTrue(model.terminalOutbox.isEmpty)
        XCTAssertEqual(model.sessions.first?.status, "discarded")
        XCTAssertFalse(model.running)
        let snapshot = try! XCTUnwrap(StateSnapshotStore.load(
            userID: "user-a", defaults: defaults)?.state)
        XCTAssertEqual(snapshot.sessions.first?.status, "discarded")
        XCTAssertEqual(snapshot.sessions.first?.attempt, 0)
    }

    func testEqualTimestampFinishACKPreservesCompletedSessionDayRemap() async {
        let defaults = defaults()
        let ex = exercise()
        let active = session(
            status: "in_progress", updatedAt: 100, attempt: 0)
        let completed = session(
            status: "completed", updatedAt: 200, attempt: 0)
        let remapped = SessionRow(
            id: completed.id,
            date: completed.date,
            status: completed.status,
            workout_id: "day-remapped",
            updated_at: completed.updated_at,
            attempt: completed.attempt)
        let entered = SetAsyncLatch()
        let release = SetAsyncLatch()
        let terminalAPI = SetTerminalAPIStub()
        terminalAPI.completeHandler = { _, _ in
            await entered.open()
            await release.wait()
            return completed
        }
        let model = SyncModel(
            auth: retainedAuth(defaults: defaults), terminalAPI: terminalAPI,
            defaults: defaults, now: { self.fixedDate })
        model.replaceState(with: state(
            session: active, sets: [], exercise: ex))
        model.startWorkout()
        model.finished = true

        let finish = Task { await model.finishWorkout() }
        await entered.wait()
        model.replaceState(with: state(
            session: remapped, sets: [], exercise: ex))
        await release.open()
        await finish.value

        XCTAssertEqual(model.todaySession?.status, "completed")
        XCTAssertEqual(model.todaySession?.workout_id, "day-remapped")
        XCTAssertEqual(
            StateSnapshotStore.load(
                userID: "user-a", defaults: defaults)?.state.sessions.first?
                .workout_id,
            "day-remapped")
    }

    func testEqualTimestampCreateResolutionPreservesPlannedSessionDayRemap() async {
        let defaults = defaults()
        let ex = exercise()
        let created = session(
            status: "planned", updatedAt: 200, attempt: 0)
        let remapped = SessionRow(
            id: created.id,
            date: created.date,
            status: created.status,
            workout_id: "day-remapped",
            updated_at: created.updated_at,
            attempt: created.attempt)
        let entered = SetAsyncLatch()
        let release = SetAsyncLatch()
        let api = SetWriteAPIStub()
        api.createHandler = { _, _, _ in
            await entered.open()
            await release.wait()
            return created
        }
        api.logHandler = { _, _, _ in throw URLError(.timedOut) }
        let model = SyncModel(
            auth: retainedAuth(defaults: defaults), setWriteAPI: api,
            defaults: defaults, uuidFactory: { self.fixedUUID },
            now: { self.fixedDate })
        let base = state(session: created, sets: [], exercise: ex)
        model.replaceState(with: StateResponse(
            plan: base.plan,
            plan_version: base.plan_version,
            sessions: [],
            sets: [],
            external_events: [],
            external_activities: [],
            activities: [],
            server_time: base.server_time, planGroupsVersion: 1))
        model.startWorkout()

        let write = Task { await model.logSet(ex, weight: 135, reps: 5) }
        await entered.wait()
        let ticket = try! XCTUnwrap(StateSnapshotStore.reserveStateRequest(
            userID: "user-a", defaults: defaults))
        XCTAssertNotNil(StateSnapshotStore.commitStateResponse(
            StateResponse(
                plan: nil,
                plan_version: 1,
                sessions: [remapped],
                sets: [],
                external_events: [],
                external_activities: [],
                activities: [],
                server_time: base.server_time + 1_000),
            ticket: ticket,
            defaults: defaults))
        await release.open()

        let acknowledged = await write.value
        XCTAssertFalse(acknowledged)
        XCTAssertEqual(model.todaySession?.status, "planned")
        XCTAssertEqual(model.todaySession?.workout_id, "day-remapped")
        XCTAssertEqual(
            StateSnapshotStore.load(
                userID: "user-a", defaults: defaults)?.state.sessions.first?
                .workout_id,
            "day-remapped")
    }

    func testEqualTimestampDiscardACKPreservesDiscardedSessionDayRemap() async {
        let defaults = defaults()
        let ex = exercise()
        let active = session(
            status: "in_progress", updatedAt: 100, attempt: 0)
        let discarded = session(
            status: "discarded", updatedAt: 200, attempt: 0)
        let remapped = SessionRow(
            id: discarded.id,
            date: discarded.date,
            status: discarded.status,
            workout_id: "day-remapped",
            updated_at: discarded.updated_at,
            attempt: discarded.attempt)
        let entered = SetAsyncLatch()
        let release = SetAsyncLatch()
        let terminalAPI = SetTerminalAPIStub()
        terminalAPI.discardHandler = { _, _ in
            await entered.open()
            await release.wait()
            return discarded
        }
        let model = SyncModel(
            auth: retainedAuth(defaults: defaults), terminalAPI: terminalAPI,
            defaults: defaults, now: { self.fixedDate })
        model.replaceState(with: state(
            session: active, sets: [], exercise: ex))
        model.startWorkout()

        let discard = Task { await model.discardWorkout() }
        await entered.wait()
        model.replaceState(with: state(
            session: remapped, sets: [], exercise: ex))
        await release.open()
        await discard.value

        XCTAssertEqual(
            StateSnapshotStore.load(
                userID: "user-a", defaults: defaults)?.state.sessions.first?
                .workout_id,
            "day-remapped")
    }
}

extension SetOutboxTests {
    private func correctionFixture(_ ex: TemplateExercise, id: String = "set-correct", weight: Double = 185, sessionID: String = "session-a") -> SetLog {
        setLog(body: SetRequestBody(id: id, exercise_id: ex.exercise_id, template_exercise_id: ex.id,
            set_index: 1, weight: weight, reps: 5, is_warmup: ex.isWarmup,
            logged_at: 2_000_000_000_000, duration_s: ex.isTimed ? 30 : nil, is_timed: ex.isTimed), sessionID: sessionID)
    }

    private func corrected(_ original: SetLog, intent: PendingSetCorrection, session: SessionRow) -> SetCorrectionResult {
        SetCorrectionResult(set: SetLog(id: original.id, session_id: original.session_id,
            exercise_id: original.exercise_id, template_exercise_id: original.template_exercise_id,
            set_index: original.set_index, weight: intent.values?.weight ?? original.weight,
            reps: intent.values?.reps ?? original.reps, rpe: intent.values?.rpe,
            is_warmup: original.is_warmup, logged_at: original.logged_at,
            duration_s: intent.values?.durationSeconds, is_timed: original.is_timed,
            deleted_at: intent.isDelete ? 2_000_000_000_002 : nil, updated_at: 2_000_000_000_002), session: session)
    }

    func testRunnerPrescriptionWinsHistoryAndWarmupHasSeparateComparableContext() {
        let warmup = exercise(id: "warmup", warmup: true, targetWeight: 45)
        let working = exercise(targetWeight: 135)
        let last = session(id: "last", date: "2033-05-16", status: "completed")
        let old = correctionFixture(working, sessionID: last.id)
        XCTAssertTrue(RunnerInputPolicy.comparableSets(warmup, sets: [old], sessions: [last],
            currentSessionID: "session-a", dayExercises: [warmup, working]).isEmpty)
        XCTAssertEqual(RunnerInputPolicy.seed(warmup, previous: old, draft: nil).weight, 45)
        XCTAssertEqual(RunnerInputPolicy.seed(working, previous: old, draft: nil).weight, 135)
        let duplicate = exercise(id: "other")
        XCTAssertTrue(RunnerInputPolicy.comparableSets(duplicate, sets: [old], sessions: [last],
            currentSessionID: "session-a", dayExercises: [working, duplicate]).isEmpty)
        let hold = exercise(id: working.id, timed: true)
        XCTAssertTrue(RunnerInputPolicy.comparableSets(hold, sets: [old], sessions: [last],
            currentSessionID: "session-a", dayExercises: [hold]).isEmpty)
    }

    func testRunnerDraftSurvivesRecoveryButChangedPrescriptionWins() {
        let ex = exercise(targetWeight: 135)
        let draft = RunnerInputState(prescription: RunnerPrescription(ex), weight: 140, reps: 7, rpe: 8.5, durationSeconds: 45)
        XCTAssertEqual(RunnerInputPolicy.seed(ex, previous: nil, draft: draft), draft)
        let changed = exercise(targetWeight: 115)
        let next = RunnerInputPolicy.seed(changed, previous: nil, draft: draft)
        XCTAssertEqual(next.weight, 115)
        XCTAssertEqual(next.reps, 5)
        XCTAssertNil(next.rpe)
    }

    func testRPEAndIntentionalValuesPersistInSetEnvelopeAndCheckpoint() async throws {
        let defaults = defaults(), ex = exercise(targetWeight: 135)
        let api = SetWriteAPIStub()
        api.logHandler = { _, _, _ in throw URLError(.notConnectedToInternet) }
        let model = SyncModel(auth: retainedAuth(defaults: defaults), setWriteAPI: api,
                              defaults: defaults, now: { self.fixedDate })
        model.replaceState(with: state(session: session(attempt: 0), sets: [], exercise: ex))
        model.startWorkout()
        XCTAssertTrue(model.setRunnerValues(SetCorrectionValues(weight: 140, reps: 7, rpe: 8.5, durationSeconds: nil),
                                            expected: RunnerPrescription(ex)))
        XCTAssertEqual(WorkoutRunnerCheckpointStore.load(userID: "user-a", defaults: defaults)?.input?.weight, 140)
        await model.logCurrentSet(expected: ex, expectedSetNumber: 1)
        let intent = try XCTUnwrap(SetOutboxStore.load(userID: "user-a", defaults: defaults).pending.first)
        XCTAssertEqual(intent.body.prescription, .init(plan_id: "plan-a", version: 1, day_id: "day-a"))
        XCTAssertEqual(intent.body.rpe, 8.5)
        XCTAssertEqual(intent.body.scoped(to: 0).rpe, 8.5)
        let encoded = try JSONEncoder().encode(intent)
        XCTAssertEqual(try JSONDecoder().decode(PendingSetIntent.self, from: encoded).body, intent.body)
    }

    func testRejectedDeleteRetainsSetAndRestThenRetryUsesOriginalIdentity() async throws {
        let defaults = defaults(), ex = exercise()
        let active = session(updatedAt: 100, attempt: 0), original = correctionFixture(ex)
        let api = SetWriteAPIStub()
        api.correctionHandler = { _, _ in throw APIError.http(403, "rejected") }
        let model = SyncModel(auth: retainedAuth(defaults: defaults), setWriteAPI: api,
                              defaults: defaults, now: { self.fixedDate })
        model.replaceState(with: state(session: active, sets: [original], exercise: ex))
        model.startWorkout()
        let rest = fixedDate.addingTimeInterval(90)
        model.restEndDate = rest
        let index = model.exerciseIndex
        await model.removeSet(original)
        XCTAssertEqual(model.sets.map(\.id), [original.id])
        XCTAssertEqual(model.restEndDate, rest)
        XCTAssertEqual(model.exerciseIndex, index)
        let failed = try XCTUnwrap(model.setCorrections.first)
        XCTAssertEqual(failed.deliveryState, .failed)
        api.correctionHandler = { [self] intent, _ in
            corrected(original, intent: intent, session: session(status: "planned", updatedAt: 200, attempt: 0))
        }
        await model.retryCorrection(id: failed.id)
        XCTAssertEqual(api.correctionCalls.count, 2)
        XCTAssertEqual(api.correctionCalls.map(\.expectedUpdatedAt), [original.updated_at, original.updated_at])
        XCTAssertEqual(api.correctionCalls.map(\.setID), [original.id, original.id])
        XCTAssertTrue(model.sets.isEmpty)
        XCTAssertTrue(model.setCorrections.isEmpty)
        XCTAssertEqual(model.todaySession?.status, "planned")
        XCTAssertEqual(model.exerciseIndex, index)
        XCTAssertEqual(model.restEndDate, rest)
        XCTAssertTrue(api.logCalls.isEmpty)
    }

    func testOfflineFinalSetCorrectionRecoversFromDurableQueueWithoutDuplicateCreate() async throws {
        let defaults = defaults(), ex = exercise(targetSets: 1)
        let active = session(updatedAt: 100, attempt: 0), original = correctionFixture(ex)
        let api = SetWriteAPIStub()
        api.correctionHandler = { _, _ in throw URLError(.notConnectedToInternet) }
        let sharedAuth = retainedAuth(defaults: defaults)
        let model = SyncModel(auth: sharedAuth, setWriteAPI: api, defaults: defaults, now: { self.fixedDate })
        model.replaceState(with: state(session: active, sets: [original], exercise: ex))
        model.startWorkout()
        model.finished = true
        let values = SetCorrectionValues(weight: 135, reps: 4, rpe: 9, durationSeconds: nil)
        XCTAssertTrue(model.enqueueCorrection(set: original, values: values))
        await model.drainWorkoutWriteOutboxes()
        XCTAssertTrue(model.finished)
        XCTAssertEqual(model.sets.first?.weight, 185)
        let queued = try XCTUnwrap(model.setCorrections.first)
        api.correctionHandler = { [self] intent, _ in corrected(original, intent: intent, session: active) }
        // The next model owns the same durable operation and identity.
        let cold = SyncModel(auth: sharedAuth, setWriteAPI: api, defaults: defaults, now: { self.fixedDate })
        await cold.drainWorkoutWriteOutboxes()
        XCTAssertTrue(cold.setCorrections.isEmpty)
        XCTAssertEqual(cold.sets.first?.id, original.id)
        XCTAssertEqual(cold.sets.first?.weight, 135)
        XCTAssertEqual(cold.sets.first?.rpe, 9)
        XCTAssertEqual(api.correctionCalls.last?.id, queued.id)
        XCTAssertTrue(api.logCalls.isEmpty)
        XCTAssertEqual(StateSnapshotStore.load(userID: "user-a", defaults: defaults)?.state.sets.first?.weight, 135)
    }

    private func incompressiblePlan(_ ex: TemplateExercise) -> PlanTree {
        var generator: UInt64 = 0x123456789abcdef
        var noise = Data(count: 5 * 1_024 * 1_024)
        noise.withUnsafeMutableBytes { (bytes: UnsafeMutableRawBufferPointer) in
            for index in bytes.indices {
                generator ^= generator << 13
                generator ^= generator >> 7
                generator ^= generator << 17
                bytes[index] = UInt8(truncatingIfNeeded: generator)
            }
        }
        return PlanTree(id: "plan-a", name: "Plan A", version: 1,
            workouts: [day(with: [ex])], meta: noise.base64EncodedString())
    }

    func testCorrectionPackingFailurePersistsInvalidationBeforeRetiringIntent() async throws {
        let suite = "OversizedSnapshot.\(UUID().uuidString)"
        let defaults = LocalPersistence(suiteName: suite)!, ex = exercise()
        defer { defaults.removePersistentDomain(forName: suite) }
        let active = session(updatedAt: 100, attempt: 0), original = correctionFixture(ex)
        let api = SetWriteAPIStub()
        api.correctionHandler = { [self] intent, _ in corrected(original, intent: intent, session: active) }
        let sharedAuth = retainedAuth(defaults: defaults)
        let model = SyncModel(auth: sharedAuth, setWriteAPI: api, defaults: defaults, now: { self.fixedDate })
        model.replaceState(with: state(session: active, sets: [original], exercise: ex))
        // Exercise the real codec's size failure without asking LocalPersistence
        // to store an invalid value. The mounted model supplies the fallback.
        let hugePlan = incompressiblePlan(ex)
        XCTAssertNil(StateSnapshotStore.encodedEnvelope(try JSONEncoder().encode(hugePlan)))
        model.plan = hugePlan
        StateSnapshotStore.clear(userID: "user-a", defaults: defaults)
        let oldTicket = try XCTUnwrap(StateSnapshotStore.reserveFullStateRequest(userID: "user-a", defaults: defaults))
        XCTAssertTrue(model.enqueueCorrection(set: original,
            values: .init(weight: 135, reps: 4, rpe: 9, durationSeconds: nil)))
        await model.drainWorkoutWriteOutboxes()
        XCTAssertTrue(model.setCorrections.isEmpty)
        XCTAssertEqual(model.sets.first?.weight, 135)
        XCTAssertEqual(api.correctionCalls.count, 1)
        XCTAssertFalse(model.correctionRefreshNeeded)
        XCTAssertFalse(StateSnapshotStore.isCurrent(oldTicket, defaults: defaults))
        XCTAssertEqual(StateSnapshotStore.load(userID: "user-a", defaults: defaults)?.state.sets.first?.weight, 135)
        let marker = try XCTUnwrap(defaults.data(forKey: StateSnapshotStore.scopedKey(userID: "user-a")))
        XCTAssertLessThan(marker.count, 1_024)
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: marker) as? [String: Any])
        XCTAssertEqual(json["invalidated"] as? Bool, true)
        // A new defaults object bypasses the process-local live envelope,
        // modeling a cold read of only the durable marker.
        let coldDefaults = LocalPersistence(suiteName: suite)!
        let cold = SyncModel(auth: sharedAuth, setWriteAPI: api, defaults: coldDefaults, now: { self.fixedDate })
        XCTAssertTrue(cold.sets.isEmpty)
        XCTAssertTrue(cold.setCorrections.isEmpty)
        XCTAssertNil(StateSnapshotStore.mergeAcknowledgement(userID: "user-a",
            fallback: state(session: active, sets: [original], exercise: ex), defaults: coldDefaults) { $0 })
        let next = try XCTUnwrap(StateSnapshotStore.reserveStateRequest(userID: "user-a", defaults: coldDefaults))
        XCTAssertEqual(next.watermarks, .fullReload)
    }

    func testOversizedLiveStateRendersAndRefreshesWithoutPersistedBrowseRows() async throws {
        let suite = "OversizedSnapshot.\(UUID().uuidString)"
        let defaults = LocalPersistence(suiteName: suite)!, ex = exercise()
        defer { defaults.removePersistentDomain(forName: suite) }
        let active = session(updatedAt: 100, attempt: 0)
        let hugePlan = incompressiblePlan(ex)
        let api = SetWriteAPIStub(), catalog = SetCatalogAPIStub()
        api.stateHandler = { [self] _ in
            state(session: active,
                sets: [correctionFixture(ex, weight: api.stateCalls == 1 ? 135 : 95)],
                workouts: hugePlan.workouts, planMeta: hugePlan.meta)
        }
        let sharedAuth = retainedAuth(defaults: defaults)
        let model = SyncModel(auth: sharedAuth, setWriteAPI: api, catalogAPI: catalog,
            defaults: defaults, now: { self.fixedDate })
        let oldTicket = try XCTUnwrap(StateSnapshotStore.reserveStateRequest(userID: "user-a", defaults: defaults))
        await model.load()
        XCTAssertEqual(model.sets.first?.weight, 135)
        XCTAssertEqual(model.plan?.meta, hugePlan.meta)
        XCTAssertNil(model.loadError)
        XCTAssertFalse(model.isUsingCachedState)
        XCTAssertEqual(StateSnapshotStore.load(userID: "user-a", defaults: defaults)?.state.sets.first?.weight, 135)
        XCTAssertFalse(StateSnapshotStore.isCurrent(oldTicket, defaults: defaults))
        await model.loadAfterMutation()
        XCTAssertEqual(model.sets.first?.weight, 95)
        XCTAssertNil(model.loadError)
        XCTAssertEqual(catalog.jwtCalls.count, 2)
        XCTAssertEqual(api.stateWatermarkCalls, [.fullReload, .fullReload])
        // Bypass the live envelope to model a cold process reading its marker.
        let coldDefaults = LocalPersistence(suiteName: suite)!
        let cold = SyncModel(auth: sharedAuth, setWriteAPI: api, catalogAPI: catalog,
            defaults: coldDefaults, now: { self.fixedDate })
        XCTAssertTrue(cold.sets.isEmpty)
        await cold.load()
        XCTAssertEqual(cold.sets.first?.weight, 95)
        XCTAssertNil(cold.loadError)
        XCTAssertEqual(api.stateWatermarkCalls, [.fullReload, .fullReload, .fullReload])
        let stale = state(session: active, sets: [], exercise: ex)
        XCTAssertNil(StateSnapshotStore.commitStateResponse(stale, ticket: oldTicket, defaults: coldDefaults))
        // Explicit invalidation still clears live rows and fences delayed ACKs.
        XCTAssertTrue(StateSnapshotStore.invalidate(userID: "user-a", defaults: coldDefaults))
        XCTAssertNil(StateSnapshotStore.mergeAcknowledgement(userID: "user-a", fallback: stale,
            defaults: coldDefaults) { $0 })
    }

    func testOversizedLiveSnapshotAllowsCreateLogCorrectionFinishAndDiscard() async throws {
        let defaults = defaults(), ex = exercise(targetSets: 1)
        let hugePlan = incompressiblePlan(ex)
        let api = SetWriteAPIStub(), terminal = SetTerminalAPIStub()
        var serverSession = session(status: "in_progress", updatedAt: 100, attempt: 0)
        var serverSets: [SetLog] = []
        api.createHandler = { _, _, _ in serverSession }
        api.logHandler = { [self] _, body, _ in
            let row = setLog(body: body, sessionID: serverSession.id)
            serverSets = [row]
            return .init(set: row, deduped: false, session: serverSession)
        }
        api.correctionHandler = { [self] intent, _ in
            let result = corrected(try XCTUnwrap(serverSets.first), intent: intent, session: serverSession)
            serverSets = [result.set]
            return result
        }
        api.stateHandler = { [self] _ in
            state(session: serverSession, sets: serverSets, workouts: hugePlan.workouts, planMeta: hugePlan.meta)
        }
        terminal.completeHandler = { [self] _, _ in
            serverSession = session(status: "completed", updatedAt: 200, attempt: 0)
            return serverSession
        }
        terminal.discardHandler = { [self] _, _ in
            serverSession = session(status: "discarded", updatedAt: 300, attempt: 0)
            serverSets = []
            return serverSession
        }
        let model = SyncModel(auth: retainedAuth(defaults: defaults), setWriteAPI: api,
            terminalAPI: terminal, defaults: defaults, uuidFactory: { self.fixedUUID }, now: { self.fixedDate })
        model.replaceState(with: StateResponse(plan: hugePlan, plan_version: 1, sessions: [], sets: [],
            external_events: [], external_activities: [], activities: [], server_time: 2_000_000_000_000))
        model.startWorkout()
        let saved = await model.logSet(ex, weight: 135, reps: 5)
        XCTAssertTrue(saved, model.loadError ?? "Expected acknowledged set")
        XCTAssertEqual(api.createCalls.count, 1)
        XCTAssertEqual(api.logCalls.count, 1)
        XCTAssertTrue(model.setOutbox.isEmpty)
        XCTAssertTrue(model.enqueueCorrection(set: try XCTUnwrap(model.sets.first),
            values: .init(weight: 95, reps: 4, rpe: 8, durationSeconds: nil)))
        await model.drainWorkoutWriteOutboxes()
        XCTAssertTrue(model.setCorrections.isEmpty)
        XCTAssertEqual(model.sets.first?.weight, 95)
        await model.finishWorkout()
        XCTAssertEqual(terminal.completeCalls.count, 1)
        XCTAssertTrue(model.terminalOutbox.isEmpty)
        XCTAssertEqual(model.todaySession?.status, "completed")
        await model.discardWorkout()
        XCTAssertEqual(terminal.discardCalls.count, 1)
        XCTAssertEqual(model.currentTerminalIntent?.deliveryState, .acknowledged)
        XCTAssertFalse(model.running)
        XCTAssertTrue(model.sets.isEmpty)
        let marker = try XCTUnwrap(defaults.data(forKey: StateSnapshotStore.scopedKey(userID: "user-a")))
        XCTAssertLessThan(marker.count, 1_024)
        XCTAssertNil(StateSnapshotStore.load(userID: "user-a", defaults: defaults)?.watermarks)
    }

    func testCorrectionRetainsIntentWhenSnapshotAndInvalidationCannotAdvance() async throws {
        let defaults = defaults(), ex = exercise()
        let active = session(updatedAt: 100, attempt: 0), original = correctionFixture(ex)
        let api = SetWriteAPIStub()
        let key = StateSnapshotStore.scopedKey(userID: "user-a")
        api.correctionHandler = { [self] intent, _ in
            // The monotonic revision guard is a deterministic failure for
            // both the snapshot and its small invalidation fallback.
            let data = try XCTUnwrap(defaults.data(forKey: key))
            let json = try XCTUnwrap(StateSnapshotStore.decodedEnvelope(data))
            var envelope = try XCTUnwrap(JSONSerialization.jsonObject(with: json) as? [String: Any])
            envelope["revision"] = UInt64.max
            defaults.set(try JSONSerialization.data(withJSONObject: envelope), forKey: key)
            return corrected(original, intent: intent, session: active)
        }
        let model = SyncModel(auth: retainedAuth(defaults: defaults), setWriteAPI: api,
            defaults: defaults, now: { self.fixedDate }, automaticWorkoutWriteRetryEnabled: false)
        model.replaceState(with: state(session: active, sets: [original], exercise: ex))
        XCTAssertTrue(model.enqueueCorrection(set: original,
            values: .init(weight: 135, reps: 4, rpe: 9, durationSeconds: nil)))
        await model.drainWorkoutWriteOutboxes()
        XCTAssertEqual(model.sets.first?.weight, 135)
        XCTAssertTrue(model.correctionRefreshNeeded)
        XCTAssertEqual(model.setCorrections.count, 1)
        XCTAssertEqual(SetCorrectionOutboxStore.load(userID: "user-a", defaults: defaults).count, 1)
        XCTAssertEqual(model.setCorrections.first?.deliveryState, .queued)
    }

    func testDelayedCorrectionCannotAcceptSecondLocalEditOrMoveFinalReview() async throws {
        let defaults = defaults(), ex = exercise(targetSets: 1)
        let active = session(updatedAt: 100, attempt: 0), original = correctionFixture(ex)
        let api = SetWriteAPIStub(), entered = SetAsyncLatch(), release = SetAsyncLatch()
        api.correctionHandler = { [self] intent, _ in
            await entered.open(); await release.wait()
            return corrected(original, intent: intent, session: active)
        }
        let model = SyncModel(auth: retainedAuth(defaults: defaults), setWriteAPI: api, defaults: defaults, now: { self.fixedDate })
        model.replaceState(with: state(session: active, sets: [original], exercise: ex))
        model.startWorkout(); model.finished = true
        model.restEndDate = fixedDate.addingTimeInterval(90)
        let rest = model.restEndDate
        let values = SetCorrectionValues(weight: 135, reps: 4, rpe: 9, durationSeconds: nil)
        XCTAssertTrue(model.enqueueCorrection(set: original, values: values))
        await entered.wait()
        XCTAssertFalse(model.enqueueCorrection(set: original, values: nil))
        XCTAssertEqual(model.sets.first?.weight, 185)
        await release.open()
        await model.drainWorkoutWriteOutboxes()
        XCTAssertTrue(model.finished)
        XCTAssertEqual(model.restEndDate, rest)
        XCTAssertEqual(api.correctionCalls.count, 1)
        XCTAssertTrue(model.setCorrections.isEmpty)
    }

    func testCorrectionAcceptsAcknowledgedSlotDetachmentWithoutRetryingSavedEdit() async {
        let defaults = defaults(), ex = exercise()
        let active = session(updatedAt: 100, attempt: 0), original = correctionFixture(ex)
        let api = SetWriteAPIStub()
        api.correctionHandler = { [self] intent, _ in
            let accepted = corrected(original, intent: intent, session: active)
            let row = accepted.set
            return SetCorrectionResult(set: SetLog(id: row.id, session_id: row.session_id,
                exercise_id: row.exercise_id, template_exercise_id: nil, set_index: row.set_index,
                weight: row.weight, reps: row.reps, rpe: row.rpe, is_warmup: row.is_warmup,
                logged_at: row.logged_at, duration_s: row.duration_s, is_timed: row.is_timed,
                deleted_at: row.deleted_at, updated_at: row.updated_at), session: active)
        }
        let model = SyncModel(auth: retainedAuth(defaults: defaults), setWriteAPI: api,
                              defaults: defaults, now: { self.fixedDate })
        model.replaceState(with: state(session: active, sets: [original], exercise: ex))
        model.startWorkout()
        XCTAssertTrue(model.enqueueCorrection(set: original,
            values: .init(weight: 135, reps: 4, rpe: 9, durationSeconds: nil)))
        await model.drainWorkoutWriteOutboxes()
        XCTAssertTrue(model.setCorrections.isEmpty)
        XCTAssertEqual(model.sets.first?.weight, 135)
        XCTAssertNil(model.sets.first?.template_exercise_id)
        XCTAssertEqual(api.correctionCalls.count, 1)
        XCTAssertTrue(api.logCalls.isEmpty)
    }

    func testQueuedOriginalIsCreatedOnceBeforeItsCorrection() async throws {
        let defaults = defaults(), ex = exercise(targetSets: 1)
        let active = session(updatedAt: 100, attempt: 0)
        let api = SetWriteAPIStub()
        api.logHandler = { _, _, _ in throw URLError(.notConnectedToInternet) }
        let model = SyncModel(auth: retainedAuth(defaults: defaults), setWriteAPI: api,
                              defaults: defaults, now: { self.fixedDate })
        model.replaceState(with: state(session: active, sets: [], exercise: ex))
        model.startWorkout()
        await model.logCurrentSet(expected: ex, expectedSetNumber: 1)
        let pending = try XCTUnwrap(model.setOutbox.pending.first)
        XCTAssertTrue(model.enqueueCorrection(pending: pending, values: .init(weight: 95, reps: 4, rpe: 8, durationSeconds: nil)))
        var accepted: SetLog?
        api.logHandler = { [self] _, body, _ in
            let row = setLog(body: body)
            accepted = row
            return APIClient.SetLogResult(set: row, deduped: false, session: active)
        }
        api.stateHandler = { [self] _ in state(session: active, sets: accepted.map { [$0] } ?? [], exercise: ex) }
        api.correctionHandler = { [self] intent, _ in
            corrected(try XCTUnwrap(accepted), intent: intent, session: active)
        }
        await model.drainWorkoutWriteOutboxes()
        XCTAssertTrue(model.setOutbox.isEmpty)
        XCTAssertTrue(model.setCorrections.isEmpty)
        XCTAssertEqual(Set(api.logCalls.map { $0.body.id }), [pending.id])
        XCTAssertEqual(api.correctionCalls.first?.setID, pending.id)
        XCTAssertEqual(model.sets.first?.weight, 95)
        XCTAssertEqual(model.sets.first?.rpe, 8)
    }
}

extension SetOutboxTests {
    func testLockScreenRestControlIsBoundToOneTimerAndAccount() async throws {
        let defaults = defaults(), sharedAuth = retainedAuth(defaults: defaults)
        let model = SyncModel(auth: sharedAuth, defaults: defaults, now: { self.fixedDate })
        prepare(model, exercise: exercise(), session: session(attempt: 0), running: true)
        model.startRest(seconds: 90, name: "Squat")
        let first = try XCTUnwrap(model.restControlID), original = try XCTUnwrap(model.restEndDate)
        let extended = await model.controlTimer(id: first, action: "extend")
        XCTAssertTrue(extended)
        XCTAssertEqual(model.restEndDate, original.addingTimeInterval(15))
        model.startRest(seconds: 60, name: "Squat")
        let stale = await model.controlTimer(id: first, action: "stop")
        XCTAssertFalse(stale)
        let current = try XCTUnwrap(model.restControlID)
        sharedAuth.signOut()
        let crossedAccount = await model.controlTimer(id: current, action: "extend")
        XCTAssertFalse(crossedAccount)
    }

    func testEditedTimedDurationAndRPEReachTheOriginalSetFromLockScreenStop() async throws {
        let defaults = defaults(), ex = exercise(timed: true)
        let api = SetWriteAPIStub()
        api.logHandler = { _, _, _ in throw URLError(.notConnectedToInternet) }
        var clock = fixedDate
        let model = SyncModel(auth: retainedAuth(defaults: defaults), setWriteAPI: api, defaults: defaults, now: { clock })
        model.replaceState(with: state(session: session(attempt: 0), sets: [], exercise: ex))
        model.startWorkout()
        model.setHoldDuration(45); model.setRPE(8.5)
        model.startTimedSet(expected: ex, expectedSetNumber: 1)
        XCTAssertEqual(model.timedEndDate, fixedDate.addingTimeInterval(45))
        let token = try XCTUnwrap(model.timedControlID)
        clock = fixedDate.addingTimeInterval(20)
        let stopped = await model.controlTimer(id: token, action: "stop")
        XCTAssertTrue(stopped)
        let saved = try XCTUnwrap(SetOutboxStore.load(userID: "user-a", defaults: defaults).pending.first)
        XCTAssertEqual(saved.body.duration_s, 20)
        XCTAssertEqual(saved.body.rpe, 8.5)
        let repeated = await model.controlTimer(id: token, action: "stop")
        XCTAssertFalse(repeated)
        XCTAssertEqual(SetOutboxStore.load(userID: "user-a", defaults: defaults).count, 1)
    }
}

extension SetOutboxTests {
    private func completionFixture(sessionID: String = "session-a") throws -> WorkoutSummary {
        let url = try XCTUnwrap(Bundle(for: WorkoutSummaryTests.self).url(forResource: "WorkoutCompletion", withExtension: "json"))
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
        object["session_id"] = sessionID; object["date"] = fixedCivilDate
        return try JSONDecoder().decode(WorkoutSummary.self, from: JSONSerialization.data(withJSONObject: object))
    }

    func testAcknowledgedCompletionKeepsServerSummaryWhenRefreshIsUnavailable() async throws {
        let defaults = defaults(), ex = exercise(targetSets: 1), api = SetWriteAPIStub(), terminal = SetTerminalAPIStub()
        let active = session(updatedAt: 100, attempt: 0)
        var completed = session(status: "completed", updatedAt: 200, attempt: 0)
        completed.summary = try completionFixture()
        terminal.completeHandler = { _, _ in completed }
        let model = SyncModel(auth: retainedAuth(defaults: defaults), setWriteAPI: api, terminalAPI: terminal,
                              defaults: defaults, now: { self.fixedDate })
        model.replaceState(with: state(session: active, sets: [correctionFixture(ex)], exercise: ex))
        model.startWorkout(); model.finished = true
        await model.finishResolvedWorkout()
        XCTAssertEqual(model.todaySession?.status, "completed")
        XCTAssertTrue(model.terminalOutbox.intents.isEmpty)
        XCTAssertEqual(model.completionSummary(for: active.id)?.records.first?.value, 12)
        await model.loadCompletionSummary(sessionID: active.id)
        XCTAssertEqual(terminal.completeCalls.count, 1)
        XCTAssertEqual(model.completionSummary(for: active.id)?.working_sets, 4)
    }

    func testFailedSummaryFetchNeverRequeuesAcknowledgedCompletion() async {
        let defaults = defaults(), ex = exercise(targetSets: 1), api = SetWriteAPIStub(), terminal = SetTerminalAPIStub()
        let active = session(updatedAt: 100, attempt: 0)
        terminal.completeHandler = { [self] _, _ in session(status: "completed", updatedAt: 200, attempt: 0) }
        let model = SyncModel(auth: retainedAuth(defaults: defaults), setWriteAPI: api, terminalAPI: terminal,
                              defaults: defaults, now: { self.fixedDate })
        model.replaceState(with: state(session: active, sets: [correctionFixture(ex)], exercise: ex))
        model.startWorkout(); model.finished = true
        await model.finishResolvedWorkout()
        await model.loadCompletionSummary(sessionID: active.id)
        XCTAssertEqual(model.todaySession?.status, "completed")
        XCTAssertTrue(model.terminalOutbox.intents.isEmpty)
        XCTAssertNotNil(model.summaryErrors[active.id])
        XCTAssertEqual(terminal.completeCalls.count, 1)
    }

    func testDelayedSummaryCannotCrossSessionRestart() async throws {
        let defaults = defaults(), ex = exercise(), api = SetWriteAPIStub()
        let entered = SetAsyncLatch(), release = SetAsyncLatch()
        let oldSummary = try completionFixture()
        api.summaryHandler = { _, _ in await entered.open(); await release.wait(); return oldSummary }
        let model = SyncModel(auth: retainedAuth(defaults: defaults), setWriteAPI: api, defaults: defaults, now: { self.fixedDate })
        model.replaceState(with: state(session: session(status: "completed", attempt: 0), sets: [], exercise: ex))
        let task = Task { await model.loadCompletionSummary(sessionID: "session-a") }
        await entered.wait()
        model.replaceState(with: state(session: session(status: "planned", attempt: 1), sets: [], exercise: ex))
        await release.open(); await task.value
        XCTAssertNil(model.completionSummary(for: "session-a"))
    }
}

extension SetOutboxTests {
    func testGroupOfflineCircuitRotatesUUIDProgressAndUsesTransitionThenRoundRest() async {
        let defaults = defaults(), api = SetWriteAPIStub()
        let a = exercise(groupID: "group-a")
        let b = exercise(id: "slot-b", exerciseID: "exercise-b", groupID: "group-a")
        let c = exercise(id: "slot-c", exerciseID: "exercise-c", groupID: "group-a")
        let after = exercise(id: "slot-d", exerciseID: "exercise-d", targetSets: 1)
        api.logHandler = { _, _, _ in throw URLError(.notConnectedToInternet) }
        let model = SyncModel(auth: retainedAuth(defaults: defaults), setWriteAPI: api,
                              defaults: defaults, now: { self.fixedDate })
        model.replaceState(with: state(session: session(attempt: 0), sets: [], exercises: [a, b, c, after]))
        model.startWorkout()
        var sequence: [String] = [], indexes: [Int] = []
        for round in 1...3 {
            for member in [a, b, c] {
                XCTAssertEqual(model.currentExercise?.id, member.id)
                XCTAssertEqual(model.currentSetNumber, round)
                sequence.append(member.id)
                // Each physical action occurs on a later UI turn. The local
                // duplicate-tap guard intentionally lasts through this turn.
                for _ in 0..<50 {
                    if !model.isSetEntryBlocked(member) { break }
                    await Task.yield()
                }
                XCTAssertFalse(model.isSetEntryBlocked(member))
                await model.logCurrentSet(expected: member, expectedSetNumber: model.currentPhysicalSetNumber)
                indexes.append(model.setOutbox.pending.last!.body.set_index)
                XCTAssertEqual(model.restTotal, member.id == c.id ? 75 : 10)
                await model.drainSetOutbox()
            }
        }
        XCTAssertEqual(sequence, [a.id, b.id, c.id, a.id, b.id, c.id, a.id, b.id, c.id])
        XCTAssertEqual(indexes, [1, 1, 1, 2, 2, 2, 3, 3, 3])
        XCTAssertEqual(Set(model.setOutbox.pending.map(\.id)).count, 9)
        XCTAssertEqual(model.currentExercise?.id, after.id)
        XCTAssertEqual(model.restActivityCurrentStepName, after.exercise_name)
        XCTAssertFalse(model.finished)
    }

    func testGroupReversedStateAcknowledgementsKeepManualFocusAndRestDeadline() async {
        let defaults = defaults(), api = SetWriteAPIStub()
        let a = exercise(groupID: "group-a")
        let b = exercise(id: "slot-b", exerciseID: "exercise-b", groupID: "group-a")
        let active = session(attempt: 0)
        api.logHandler = { _, _, _ in throw URLError(.notConnectedToInternet) }
        let model = SyncModel(auth: retainedAuth(defaults: defaults), setWriteAPI: api,
                              defaults: defaults, now: { self.fixedDate })
        model.replaceState(with: state(session: active, sets: [], exercises: [a, b]))
        model.startWorkout()
        await model.logCurrentSet(expected: a, expectedSetNumber: 1)
        await model.drainSetOutbox()
        await model.logCurrentSet(expected: b, expectedSetNumber: 1)
        await model.drainSetOutbox()
        let intents = model.setOutbox.pending
        let acceptedA = setLog(body: intents[0].body), acceptedB = setLog(body: intents[1].body)
        let deadline = model.restEndDate
        model.jump(to: 1)
        model.replaceState(with: state(session: active, sets: [acceptedB], exercises: [a, b]))
        XCTAssertEqual(model.runnerSetsDone(a), 1)
        XCTAssertEqual(model.runnerSetsDone(b), 1)
        XCTAssertEqual(model.currentExercise?.id, b.id)
        XCTAssertEqual(model.currentSetNumber, 2)
        XCTAssertEqual(model.restEndDate, deadline)
        model.previous()
        model.next()
        model.replaceState(with: state(session: active, sets: [acceptedB, acceptedA], exercises: [a, b]))
        XCTAssertEqual(model.currentExercise?.id, b.id)
        XCTAssertTrue(model.setOutbox.isEmpty)
        XCTAssertEqual(model.restEndDate, deadline)
        model.replaceState(with: state(session: active, sets: [acceptedA, acceptedB], exercises: [a, b]))
        XCTAssertEqual(model.currentExercise?.id, b.id)
        XCTAssertEqual(model.runnerSetsDone(b), 1)
    }

    func testGroupAheadTimedMemberKeepsPhysicalIdentityAcrossUnchangedRefreshAndDuplicateExpiry() async {
        let defaults = defaults(), api = SetWriteAPIStub()
        let a = exercise(timed: true, groupID: "group-a")
        let b = exercise(id: "slot-b", exerciseID: "exercise-b", groupID: "group-a")
        let active = session(attempt: 0), prior = correctionFixture(a)
        api.logHandler = { _, _, _ in throw URLError(.notConnectedToInternet) }
        let model = SyncModel(auth: retainedAuth(defaults: defaults), setWriteAPI: api,
                              defaults: defaults, now: { self.fixedDate })
        model.replaceState(with: state(session: active, sets: [prior], exercises: [a, b]))
        model.startWorkout()
        XCTAssertEqual(model.currentExercise?.id, b.id)
        model.jump(to: 0)
        XCTAssertEqual(model.currentSetNumber, 1)
        XCTAssertEqual(model.currentPhysicalSetNumber, 2)
        model.startTimedSet(expected: a, expectedSetNumber: 2, at: fixedDate)
        let started = model.timedStartDate
        model.replaceState(with: state(session: active, sets: [prior], exercises: [a, b]))
        XCTAssertTrue(model.timedActive)
        XCTAssertEqual(model.currentExercise?.id, a.id)
        XCTAssertEqual(model.timedStartDate, started)
        await model.finishTimedSetIfDue(at: fixedDate.addingTimeInterval(30))
        await model.finishTimedSetIfDue(at: fixedDate.addingTimeInterval(30))
        await model.drainSetOutbox()
        XCTAssertEqual(model.setOutbox.count, 1)
        XCTAssertEqual(model.setOutbox.pending.first?.body.set_index, 2)
        XCTAssertEqual(model.currentExercise?.id, b.id)
        XCTAssertEqual(model.currentSetNumber, 1)
        model.jump(to: 0)
        model.startTimedSet(expected: a, expectedSetNumber: 2, at: fixedDate)
        XCTAssertFalse(model.timedActive)
        XCTAssertEqual(model.currentPhysicalSetNumber, 3)
    }

    func testGroupSkipUsesPendingCountsAndLastRemainingMemberGetsRoundRest() async {
        let defaults = defaults(), api = SetWriteAPIStub()
        let a = exercise(targetSets: 1, groupID: "group-a", transitionRest: 0)
        let b = exercise(id: "slot-b", exerciseID: "exercise-b", targetSets: 1,
                         groupID: "group-a", transitionRest: 0)
        let c = exercise(id: "slot-c", exerciseID: "exercise-c", targetSets: 1,
                         groupID: "group-a", transitionRest: 0)
        api.logHandler = { _, _, _ in throw URLError(.notConnectedToInternet) }
        let model = SyncModel(auth: retainedAuth(defaults: defaults), setWriteAPI: api,
                              defaults: defaults, now: { self.fixedDate })
        model.replaceState(with: state(session: session(attempt: 0), sets: [], exercises: [a, b, c]))
        model.startWorkout()
        await model.logCurrentSet(expected: a, expectedSetNumber: 1)
        await model.drainSetOutbox()
        XCTAssertNil(model.restEndDate)
        model.jump(to: 2)
        model.skip()
        XCTAssertEqual(model.currentExercise?.id, b.id)
        await model.logCurrentSet(expected: b, expectedSetNumber: 1)
        XCTAssertEqual(model.restTotal, 75)
        XCTAssertTrue(model.finished)
        XCTAssertEqual(model.setOutbox.count, 2)
        XCTAssertEqual(model.sets.count, 0)
    }

    func testGroupColdCheckpointRepairsPendingProgressButPreservesRecordedManualFocus() async throws {
        let defaults = defaults(), api = SetWriteAPIStub()
        let a = exercise(groupID: "group-a")
        let b = exercise(id: "slot-b", exerciseID: "exercise-b", groupID: "group-a")
        let active = session(attempt: 0), sharedAuth = retainedAuth(defaults: defaults)
        let prior = correctionFixture(a)
        let body = SetRequestBody(id: prior.id, exercise_id: a.exercise_id,
            template_exercise_id: a.id, set_index: 1, weight: 100, reps: 5,
            is_warmup: false, logged_at: prior.logged_at, duration_s: nil, is_timed: false)
        var outbox = SetOutbox()
        outbox.enqueue(.init(body: body, date: fixedCivilDate, workoutID: "day-a",
                             resolvedSessionID: active.id, deliveryState: .queued,
                             failedHTTPStatus: nil, expectedAttempt: 0))
        SetOutboxStore.save(outbox, userID: "user-a", defaults: defaults)
        WorkoutRunnerCheckpointStore.save(.init(date: fixedCivilDate, sessionID: active.id,
            selectedDayID: "day-a", currentSlotID: a.id, skippedSlotIDs: [],
            workoutStartedAtMS: prior.logged_at, finished: false, sessionAttempt: 0),
            userID: "user-a", defaults: defaults)
        api.logHandler = { _, _, _ in throw URLError(.notConnectedToInternet) }
        let cold = SyncModel(auth: sharedAuth, setWriteAPI: api, defaults: defaults, now: { self.fixedDate })
        cold.replaceState(with: state(session: active, sets: [], exercises: [a, b]))
        XCTAssertEqual(cold.resumableCheckpoint?.currentSlotID, b.id)
        cold.resumeWorkout()
        cold.jump(to: 0)
        let checkpoint = try XCTUnwrap(WorkoutRunnerCheckpointStore.load(userID: "user-a", defaults: defaults))
        XCTAssertNotNil(checkpoint.groupProgress)
        let next = SyncModel(auth: sharedAuth, setWriteAPI: api, defaults: defaults, now: { self.fixedDate })
        next.replaceState(with: state(session: active, sets: [], exercises: [a, b]))
        XCTAssertEqual(next.resumableCheckpoint?.currentSlotID, a.id)
        next.resumeWorkout()
        XCTAssertEqual(next.currentExercise?.id, a.id)
        XCTAssertEqual(next.currentSetNumber, 1)
        XCTAssertEqual(next.currentPhysicalSetNumber, 2)
    }

    func testGroupValueCorrectionPreservesFocusAndDeletionRepairsAtTimedBoundary() async {
        let defaults = defaults(), api = SetWriteAPIStub()
        let a = exercise(timed: true, groupID: "group-a")
        let b = exercise(id: "slot-b", exerciseID: "exercise-b", groupID: "group-a")
        let active = session(updatedAt: 100, attempt: 0)
        let priorA = correctionFixture(a, id: "prior-a"), priorB = correctionFixture(b, id: "prior-b")
        api.correctionHandler = { [self] intent, _ in
            corrected(intent.setID == priorA.id ? priorA : priorB, intent: intent, session: active)
        }
        api.logHandler = { _, _, _ in throw URLError(.notConnectedToInternet) }
        let model = SyncModel(auth: retainedAuth(defaults: defaults), setWriteAPI: api,
                              defaults: defaults, now: { self.fixedDate })
        model.replaceState(with: state(session: active, sets: [priorA, priorB], exercises: [a, b]))
        model.startWorkout()
        model.jump(to: 1)
        model.startRest(seconds: 51, name: b.exercise_name)
        let rest = model.restEndDate
        XCTAssertTrue(model.enqueueCorrection(set: priorB, values: .init(weight: 95, reps: 4, rpe: 8, durationSeconds: nil)))
        await model.drainWorkoutWriteOutboxes()
        XCTAssertEqual(model.currentExercise?.id, b.id)
        XCTAssertEqual(model.restEndDate, rest)
        model.jump(to: 0)
        model.startTimedSet(expected: a, expectedSetNumber: 2, at: fixedDate)
        XCTAssertTrue(model.enqueueCorrection(set: priorA, values: nil))
        await model.drainWorkoutWriteOutboxes()
        XCTAssertTrue(model.timedActive)
        XCTAssertEqual(model.currentExercise?.id, a.id)
        XCTAssertEqual(model.runnerSetsDone(a), 0)
        await model.finishTimedSetIfDue(at: fixedDate.addingTimeInterval(30))
        await model.finishTimedSetIfDue(at: fixedDate.addingTimeInterval(30))
        XCTAssertFalse(model.timedActive)
        XCTAssertEqual(model.setOutbox.count, 1)
        XCTAssertEqual(model.runnerSetsDone(a), 1)
        XCTAssertEqual(model.currentExercise?.id, a.id)
        XCTAssertEqual(model.currentSetNumber, 2)
    }

    func testGroupAcknowledgedFinalDeletionReopensJustCompletedGroupWithoutRestartingRest() async throws {
        let defaults = defaults(), api = SetWriteAPIStub()
        let a = exercise(targetSets: 1, groupID: "group-a")
        let b = exercise(id: "slot-b", exerciseID: "exercise-b", targetSets: 1, groupID: "group-a")
        let after = exercise(id: "slot-c", exerciseID: "exercise-c")
        let active = session(updatedAt: 100, attempt: 0)
        var accepted: [SetLog] = []
        api.logHandler = { [self] id, body, _ in
            let row = setLog(body: body, sessionID: id)
            accepted.append(row)
            return .init(set: row, deduped: false, session: active)
        }
        api.correctionHandler = { [self] intent, _ in
            corrected(try XCTUnwrap(accepted.first { $0.id == intent.setID }), intent: intent, session: active)
        }
        let model = SyncModel(auth: retainedAuth(defaults: defaults), setWriteAPI: api,
                              defaults: defaults, now: { self.fixedDate })
        model.replaceState(with: state(session: active, sets: [], exercises: [a, b, after]))
        model.startWorkout()
        await model.logCurrentSet(expected: a, expectedSetNumber: 1)
        await model.drainSetOutbox()
        await model.logCurrentSet(expected: b, expectedSetNumber: 1)
        await model.drainSetOutbox()
        XCTAssertEqual(model.currentExercise?.id, after.id)
        let rest = model.restEndDate
        XCTAssertTrue(model.enqueueCorrection(set: try XCTUnwrap(accepted.last), values: nil))
        await model.drainWorkoutWriteOutboxes()
        XCTAssertEqual(model.currentExercise?.id, b.id)
        XCTAssertEqual(model.restEndDate, rest)
        XCTAssertEqual(model.restActivityCurrentStepName, b.exercise_name)
        XCTAssertFalse(model.finished)
    }

    private func groupAcknowledgement(_ call: SetPlanEditingAPIStub.GroupCall) -> APIClient.ExerciseGroupAcknowledgement {
        .init(ok: true, plan_id: "plan-a", version: call.expectedVersion + 1,
              group_id: call.groupID, day_id: call.dayID, members: call.memberIDs,
              round_rest: call.roundRest, transition_rest: call.transitionRest,
              target_sets: call.targetSets, cleared: false)
    }

    func testGroupEditorPinsWholeGroupRequestAndAcknowledgesFailedRefresh() async {
        let defaults = defaults(), api = SetWriteAPIStub(), editor = SetPlanEditingAPIStub()
        let a = exercise(), b = exercise(id: "slot-b", exerciseID: "exercise-b")
        editor.groupHandler = { [self] call in groupAcknowledgement(call) }
        api.stateHandler = { _ in throw URLError(.notConnectedToInternet) }
        let model = SyncModel(auth: retainedAuth(defaults: defaults), setWriteAPI: api,
            planEditingAPI: editor, defaults: defaults, now: { self.fixedDate })
        model.replaceState(with: state(session: session(), sets: [], exercises: [a, b]))
        let saved = await model.saveExerciseGroup(dayID: "day-a", groupID: "stable-group", memberIDs: [b.id, a.id],
            expectedVersion: 1, roundRest: 80, transitionRest: 5, targetSets: 4, orderIndex: 0)
        XCTAssertTrue(saved)
        XCTAssertTrue(model.workoutEditorRefreshNeeded)
        XCTAssertNotNil(model.loadError)
        XCTAssertEqual(editor.groupCalls.count, 1)
        XCTAssertEqual(editor.groupCalls.first?.groupID, "stable-group")
        XCTAssertEqual(editor.groupCalls.first?.expectedVersion, 1)
        XCTAssertEqual(editor.groupCalls.first?.memberIDs, [b.id, a.id])
        XCTAssertEqual(editor.groupCalls.first?.orderIndex, 0)
        let repeated = await model.saveExerciseGroup(dayID: "day-a", groupID: "stable-group", memberIDs: [b.id, a.id],
            expectedVersion: 1, roundRest: 80, transitionRest: 5, targetSets: 4)
        XCTAssertFalse(repeated)
        XCTAssertEqual(editor.groupCalls.count, 1)
    }

    func testGroupClearAcknowledgementAdoptsNewTreeAndGroupedSlotPatchOmitsRounds() async {
        let defaults = defaults(), api = SetWriteAPIStub(), editor = SetPlanEditingAPIStub()
        let a = exercise(groupID: "group-a"), b = exercise(id: "slot-b", exerciseID: "exercise-b", groupID: "group-a")
        editor.updateHandler = { .init(id: a.id) }
        api.stateHandler = { [self] _ in state(session: session(), sets: [], exercises: [a, b]) }
        let model = SyncModel(auth: retainedAuth(defaults: defaults), setWriteAPI: api,
            planEditingAPI: editor, defaults: defaults, now: { self.fixedDate })
        model.replaceState(with: state(session: session(), sets: [], exercises: [a, b]))
        let updated = await model.updateSlot(dayID: "day-a", teID: a.id, isWarmup: false,
            targetSets: 9, targetReps: 6, targetRepsMax: nil, restSeconds: 90, targetDurationS: nil)
        XCTAssertTrue(updated)
        XCTAssertNil(editor.updatedFields["target_sets"])
        XCTAssertNil(editor.updatedFields["rest_seconds"])
        XCTAssertEqual(editor.updatedFields["target_reps"] as? Int, 6)
        editor.clearGroupHandler = { dayID, groupID, version, _ in
            XCTAssertEqual(dayID, "day-a")
            XCTAssertEqual(groupID, "group-a")
            XCTAssertEqual(version, 1)
            return .init(ok: true, plan_id: "plan-a", version: 2, group_id: groupID,
                         day_id: dayID, members: [], round_rest: nil, transition_rest: nil,
                         target_sets: nil, cleared: true)
        }
        let ungrouped = [exercise(), exercise(id: "slot-b", exerciseID: "exercise-b")]
        api.stateHandler = { [self] _ in
            state(session: session(), sets: [], workouts: [day(with: ungrouped)], planVersion: 2)
        }
        let cleared = await model.clearExerciseGroup(dayID: "day-a", groupID: "group-a", expectedVersion: 1)
        XCTAssertTrue(cleared)
        XCTAssertEqual(model.plan?.version, 2)
        XCTAssertNil(model.exercises.first?.group_id)
        XCTAssertEqual(editor.clearGroupCalls, 1)
    }

    func testGroupEditorStaleVersionRefreshesWithoutAcknowledgingAndLateACKIsAccountFenced() async {
        let defaults = defaults(), api = SetWriteAPIStub(), editor = SetPlanEditingAPIStub()
        let a = exercise(), b = exercise(id: "slot-b", exerciseID: "exercise-b")
        let sharedAuth = retainedAuth(defaults: defaults)
        editor.clearGroupHandler = { _, _, _, _ in throw APIError.http(409, #"{"conflict":true,"current_version":2}"#) }
        api.stateHandler = { [self] _ in
            state(session: session(), sets: [], workouts: [day(with: [a, b])], planVersion: 2)
        }
        let model = SyncModel(auth: sharedAuth, setWriteAPI: api,
            planEditingAPI: editor, defaults: defaults, now: { self.fixedDate })
        model.replaceState(with: state(session: session(), sets: [], exercises: [a, b]))
        let cleared = await model.clearExerciseGroup(dayID: "day-a", groupID: "group-a", expectedVersion: 1)
        XCTAssertFalse(cleared)
        XCTAssertEqual(model.plan?.version, 2)
        let entered = SetAsyncLatch(), release = SetAsyncLatch()
        editor.groupHandler = { [self] call in
            await entered.open()
            await release.wait()
            return groupAcknowledgement(call)
        }
        let write = Task { await model.saveExerciseGroup(dayID: "day-a", groupID: "group-a", memberIDs: [a.id, b.id],
            expectedVersion: 2, roundRest: 60, transitionRest: 0, targetSets: 3) }
        await entered.wait()
        let calls = api.stateCalls
        sharedAuth.signOut()
        await release.open()
        let saved = await write.value
        XCTAssertFalse(saved)
        XCTAssertEqual(api.stateCalls, calls)
    }
}

extension SetOutboxTests {
    func testGroupMemberDeletionAcknowledgementRequiresRefreshBeforeFurtherEditing() async {
        let defaults = defaults(), api = SetWriteAPIStub(), editor = SetPlanEditingAPIStub()
        let a = exercise(groupID: "group-a"), b = exercise(id: "slot-b", groupID: "group-a")
        editor.deleteHandler = {}
        api.stateHandler = { _ in throw URLError(.timedOut) }
        let model = SyncModel(auth: retainedAuth(defaults: defaults), setWriteAPI: api,
            planEditingAPI: editor, defaults: defaults, now: { self.fixedDate })
        model.replaceState(with: state(session: session(), sets: [], exercises: [a, b]))
        await model.deleteSlot(dayID: "day-a", teID: a.id)
        XCTAssertEqual(editor.deleteCalls, 1)
        XCTAssertTrue(model.workoutEditorRefreshNeeded)
        XCTAssertNotNil(model.loadError)
        // The server may have dissolved the remaining singleton group.
        await model.deleteSlot(dayID: "day-a", teID: b.id)
        XCTAssertEqual(editor.deleteCalls, 1)
    }

    func testAcknowledgedSlotReorderRequiresRefreshBeforeAnotherMove() async {
        let defaults = defaults(), api = SetWriteAPIStub(), editor = SetPlanEditingAPIStub()
        let a = exercise(), b = exercise(id: "slot-b")
        editor.updateHandler = { .init(id: a.id) }
        api.stateHandler = { _ in throw URLError(.timedOut) }
        let model = SyncModel(auth: retainedAuth(defaults: defaults), setWriteAPI: api,
            planEditingAPI: editor, defaults: defaults, now: { self.fixedDate })
        model.replaceState(with: state(session: session(), sets: [], exercises: [a, b]))
        await model.moveSlot(dayID: "day-a", teID: a.id, toIndex: 1)
        XCTAssertEqual(editor.updateCalls, 1)
        XCTAssertTrue(model.workoutEditorRefreshNeeded)
        XCTAssertNotNil(model.loadError)
        await model.moveSlot(dayID: "day-a", teID: a.id, toIndex: 0)
        XCTAssertEqual(editor.updateCalls, 1)
    }

    func testGroupDeletionDeferredDuringLaterHoldRepairsOnSkipAndManualFocusSupersedesRepair() async throws {
        for boundary in ["skip", "manual", "complete"] {
            let defaults = defaults(), api = SetWriteAPIStub()
            let a = exercise(targetSets: 1, groupID: "group-a")
            let b = exercise(id: "slot-b", exerciseID: "exercise-b", targetSets: 1, groupID: "group-a")
            let c = exercise(id: "slot-c", exerciseID: "exercise-c", timed: true, targetSets: 1)
            let d = exercise(id: "slot-d", exerciseID: "exercise-d", timed: true, targetSets: 2)
            let active = session(updatedAt: 100, attempt: 0)
            var accepted: [SetLog] = []
            api.logHandler = { [self] id, body, _ in
                let row = setLog(body: body, sessionID: id)
                accepted.append(row)
                return .init(set: row, deduped: false, session: active)
            }
            api.correctionHandler = { [self] intent, _ in
                corrected(try XCTUnwrap(accepted.first { $0.id == intent.setID }), intent: intent, session: active)
            }
            let model = SyncModel(auth: retainedAuth(defaults: defaults), setWriteAPI: api,
                                  defaults: defaults, now: { self.fixedDate })
            model.replaceState(with: state(session: active, sets: [], exercises: [a, b, c, d]))
            model.startWorkout()
            await model.logCurrentSet(expected: a, expectedSetNumber: 1)
            await model.drainSetOutbox()
            await model.logCurrentSet(expected: b, expectedSetNumber: 1)
            await model.drainSetOutbox()
            XCTAssertEqual(model.currentExercise?.id, c.id)
            model.startTimedSet(expected: c, expectedSetNumber: 1, at: fixedDate)
            XCTAssertTrue(model.enqueueCorrection(set: try XCTUnwrap(accepted.last), values: nil))
            await model.drainWorkoutWriteOutboxes()
            XCTAssertTrue(model.timedActive)
            if boundary == "manual" {
                model.jump(to: 3)
                model.startTimedSet(expected: d, expectedSetNumber: 1, at: fixedDate)
                await model.finishTimedSetIfDue(at: fixedDate.addingTimeInterval(30))
                // The explicit focus discarded the old repair; completing
                // D1 therefore stays on D2 instead of jumping back to B.
                XCTAssertEqual(model.currentExercise?.id, d.id)
                model.jump(to: 2)
                await model.drainSetOutbox()
                XCTAssertEqual(model.currentExercise?.id, c.id)
            } else if boundary == "skip" {
                model.skip()
                XCTAssertEqual(model.currentExercise?.id, b.id)
                XCTAssertTrue(model.isSkipped(c))
            } else {
                await model.finishTimedSetIfDue(at: fixedDate.addingTimeInterval(30))
                XCTAssertEqual(model.currentExercise?.id, b.id)
                XCTAssertEqual(model.runnerSetsDone(c), 1)
            }
            XCTAssertFalse(model.timedActive)
        }
    }
}

extension SetOutboxTests {
    func testGroupDeletionOfOldExecutionClassDoesNotChangeCurrentManualFocus() async {
        let defaults = defaults(), api = SetWriteAPIStub()
        let a = exercise(groupID: "group-a"), b = exercise(id: "slot-b", exerciseID: "exercise-b", groupID: "group-a")
        let oldWarmup = correctionFixture(exercise(warmup: true))
        let active = session(updatedAt: 100, attempt: 0)
        api.correctionHandler = { [self] intent, _ in corrected(oldWarmup, intent: intent, session: active) }
        let model = SyncModel(auth: retainedAuth(defaults: defaults), setWriteAPI: api,
                              defaults: defaults, now: { self.fixedDate })
        model.replaceState(with: state(session: active, sets: [oldWarmup], exercises: [a, b]))
        model.startWorkout()
        model.jump(to: 1)
        XCTAssertEqual(model.runnerSetsDone(a), 0)
        XCTAssertTrue(model.enqueueCorrection(set: oldWarmup, values: nil))
        await model.drainWorkoutWriteOutboxes()
        XCTAssertTrue(model.sets.isEmpty)
        XCTAssertEqual(model.currentExercise?.id, b.id)
        XCTAssertEqual(model.currentSetNumber, 1)
    }
}

extension SetOutboxTests {
    func testGroupDeletionLiveReadBeforeACKRepairsOnceAndDefersDuringLaterHold() async throws {
        for timedLater in [false, true] {
            let defaults = defaults(), api = SetWriteAPIStub()
            let a = exercise(targetSets: 1, groupID: "group-a")
            let b = exercise(id: "slot-b", exerciseID: "exercise-b", targetSets: 1, groupID: "group-a")
            let c = exercise(id: "slot-c", exerciseID: "exercise-c", timed: timedLater, targetSets: 2)
            let active = session(updatedAt: 100, attempt: 0)
            var accepted: [SetLog] = []
            api.logHandler = { [self] id, body, _ in
                let row = setLog(body: body, sessionID: id)
                accepted.append(row)
                return .init(set: row, deduped: false, session: active)
            }
            let entered = SetAsyncLatch(), release = SetAsyncLatch()
            var deleted: SetLog?
            api.correctionHandler = { [self] intent, _ in
                let result = corrected(try XCTUnwrap(accepted.first { $0.id == intent.setID }), intent: intent, session: active)
                deleted = result.set
                await entered.open()
                await release.wait()
                return result
            }
            let model = SyncModel(auth: retainedAuth(defaults: defaults), setWriteAPI: api,
                                  defaults: defaults, now: { self.fixedDate })
            model.replaceState(with: state(session: active, sets: [], exercises: [a, b, c]))
            model.startWorkout()
            await model.logCurrentSet(expected: a, expectedSetNumber: 1)
            await model.drainSetOutbox()
            await model.logCurrentSet(expected: b, expectedSetNumber: 1)
            await model.drainSetOutbox()
            if timedLater { model.startTimedSet(expected: c, expectedSetNumber: 1, at: fixedDate) }
            let rest = model.restEndDate
            XCTAssertTrue(model.enqueueCorrection(set: try XCTUnwrap(accepted.last), values: nil))
            let drain = Task { await model.drainWorkoutWriteOutboxes() }
            await entered.wait()
            model.replaceState(with: state(session: active,
                sets: [accepted[0], try XCTUnwrap(deleted)], exercises: [a, b, c]))
            XCTAssertEqual(model.currentExercise?.id, timedLater ? c.id : b.id)
            XCTAssertEqual(model.timedActive, timedLater)
            XCTAssertEqual(model.restEndDate, rest)
            if !timedLater { model.jump(to: 2) }
            await release.open()
            await drain.value
            XCTAssertTrue(model.setCorrections.isEmpty)
            XCTAssertEqual(model.currentExercise?.id, c.id)
            if timedLater {
                XCTAssertTrue(model.timedActive)
                await model.finishTimedSetIfDue(at: fixedDate.addingTimeInterval(30))
                XCTAssertEqual(model.currentExercise?.id, b.id)
                XCTAssertEqual(model.runnerSetsDone(c), 1)
            } else {
                // The read already handled deletion; its late ACK must keep
                // the manual focus selected after that authoritative read.
                XCTAssertEqual(model.restEndDate, rest)
            }
        }
    }

    func testGroupRetryOfPermanentFailurePreservesManualFocusInAnotherGroup() async throws {
        for retryAll in [false, true] {
            let defaults = defaults(), api = SetWriteAPIStub()
            let a = exercise(groupID: "group-a")
            let b = exercise(id: "slot-b", exerciseID: "exercise-b", groupID: "group-a")
            let c = exercise(id: "slot-c", exerciseID: "exercise-c", groupID: "group-b")
            let d = exercise(id: "slot-d", exerciseID: "exercise-d", groupID: "group-b")
            let active = session(attempt: 0)
            var rejecting = true
            api.logHandler = { [self] id, body, _ in
                if rejecting { throw APIError.http(400, #"{"error":"invalid_set"}"#) }
                return .init(set: setLog(body: body, sessionID: id), deduped: false, session: active)
            }
            let model = SyncModel(auth: retainedAuth(defaults: defaults), setWriteAPI: api,
                                  defaults: defaults, now: { self.fixedDate })
            model.replaceState(with: state(session: active, sets: [], exercises: [a, b, c, d]))
            model.startWorkout()
            await model.logCurrentSet(expected: a, expectedSetNumber: 1)
            await model.drainSetOutbox()
            let failed = try XCTUnwrap(model.setOutbox.pending.first)
            XCTAssertEqual(failed.deliveryState, .failed)
            XCTAssertEqual(model.runnerSetsDone(a), 0)
            model.jump(to: 3)
            let rest = model.restEndDate
            rejecting = false
            if retryAll { await model.retryFailedSetIntents() }
            else { await model.retrySetIntent(id: failed.id) }
            XCTAssertTrue(model.setOutbox.isEmpty)
            XCTAssertEqual(model.sets.first?.id, failed.id)
            XCTAssertEqual(model.runnerSetsDone(a), 1)
            XCTAssertEqual(model.currentExercise?.id, d.id)
            XCTAssertEqual(model.currentSetNumber, 1)
            XCTAssertEqual(model.restEndDate, rest)
            XCTAssertEqual(api.logCalls.map(\.body.id), [failed.id, failed.id])
        }
    }
}

extension SetOutboxTests {
    func testPendingGroupDeletionDoesNotTreatChangedExecutionClassAsDeletionEvidence() async throws {
        let defaults = defaults(), api = SetWriteAPIStub()
        let a = exercise(targetSets: 1, groupID: "group-a")
        let b = exercise(id: "slot-b", exerciseID: "exercise-b", targetSets: 1, groupID: "group-a")
        let c = exercise(id: "slot-c", exerciseID: "exercise-c", targetSets: 2)
        let changedA = exercise(targetSets: 1, warmup: true, groupID: "group-a")
        let changedB = exercise(id: b.id, exerciseID: b.exercise_id, targetSets: 1, warmup: true, groupID: "group-a")
        let active = session(updatedAt: 100, attempt: 0)
        var accepted: [SetLog] = []
        api.logHandler = { [self] id, body, _ in
            let row = setLog(body: body, sessionID: id)
            accepted.append(row)
            return .init(set: row, deduped: false, session: active)
        }
        let entered = SetAsyncLatch(), release = SetAsyncLatch()
        api.correctionHandler = { [self] intent, _ in
            let result = corrected(try XCTUnwrap(accepted.first { $0.id == intent.setID }), intent: intent, session: active)
            await entered.open()
            await release.wait()
            return result
        }
        let model = SyncModel(auth: retainedAuth(defaults: defaults), setWriteAPI: api,
                              defaults: defaults, now: { self.fixedDate })
        model.replaceState(with: state(session: active, sets: [], exercises: [a, b, c]))
        model.startWorkout()
        await model.logCurrentSet(expected: a, expectedSetNumber: 1)
        await model.drainSetOutbox()
        await model.logCurrentSet(expected: b, expectedSetNumber: 1)
        await model.drainSetOutbox()
        XCTAssertTrue(model.enqueueCorrection(set: try XCTUnwrap(accepted.last), values: nil))
        let drain = Task { await model.drainWorkoutWriteOutboxes() }
        await entered.wait()
        model.replaceState(with: state(session: active, sets: accepted,
            workouts: [day(with: [changedA, changedB, c])], planVersion: 2))
        XCTAssertEqual(model.sets.count, 2)
        XCTAssertEqual(model.runnerSetsDone(changedB), 0)
        XCTAssertEqual(model.currentExercise?.id, c.id)
        await release.open()
        await drain.value
        XCTAssertTrue(model.setCorrections.isEmpty)
        XCTAssertEqual(model.currentExercise?.id, c.id)
    }
}


extension SetOutboxTests {
    func testGroupEarlierMemberDeletionReopensCompletedGroupWithoutRestartingRest() async throws {
        try await verifyEarlierGroupMemberDeletion(boundary: "immediate")
    }

    func testGroupEarlierMemberDeletionDefersFollowingHoldAndHonorsManualFocus() async throws {
        try await verifyEarlierGroupMemberDeletion(boundary: "complete")
        try await verifyEarlierGroupMemberDeletion(boundary: "manual")
    }

    private func verifyEarlierGroupMemberDeletion(boundary: String) async throws {
        let defaults = defaults(), api = SetWriteAPIStub()
        let a = exercise(targetSets: 2, groupID: "group-a", transitionRest: 0)
        let b = exercise(id: "slot-b", exerciseID: "exercise-b", targetSets: 2, groupID: "group-a", transitionRest: 0)
        let c = exercise(id: "slot-c", exerciseID: "exercise-c", timed: true, targetSets: 2)
        let d = exercise(id: "slot-d", exerciseID: "exercise-d", timed: true, targetSets: 2)
        let active = session(updatedAt: 100, attempt: 0)
        var accepted: [SetLog] = []
        api.logHandler = { [self] id, body, _ in
            let row = setLog(body: body, sessionID: id)
            accepted.append(row)
            return .init(set: row, deduped: false, session: active)
        }
        api.correctionHandler = { [self] intent, _ in
            corrected(try XCTUnwrap(accepted.first { $0.id == intent.setID }), intent: intent, session: active)
        }
        let model = SyncModel(auth: retainedAuth(defaults: defaults), setWriteAPI: api,
                              defaults: defaults, now: { self.fixedDate })
        model.replaceState(with: state(session: active, sets: [], exercises: [a, b, c, d]))
        model.startWorkout()
        for member in [a, b, a, b] {
            for _ in 0..<50 {
                if !model.isSetEntryBlocked(member) { break }
                await Task.yield()
            }
            XCTAssertFalse(model.isSetEntryBlocked(member))
            await model.logCurrentSet(expected: member, expectedSetNumber: model.currentPhysicalSetNumber)
            await model.drainSetOutbox()
        }
        XCTAssertEqual(accepted.map(\.template_exercise_id), [a.id, b.id, a.id, b.id])
        XCTAssertEqual(model.currentExercise?.id, c.id)
        // Remove A's first-round set after B's second-round set completed the
        // group. Recovery belongs to the group, not only its final logged UUID.
        let earlier = try XCTUnwrap(accepted.first)
        if boundary != "immediate" && boundary != "replacement" {
            model.startTimedSet(expected: c, expectedSetNumber: 1, at: fixedDate)
        }
        let rest = model.restEndDate
        XCTAssertTrue(model.enqueueCorrection(set: earlier, values: nil))
        await model.drainWorkoutWriteOutboxes()
        XCTAssertEqual(model.runnerSetsDone(a), 1)
        XCTAssertEqual(model.runnerSetsDone(b), 2)
        XCTAssertEqual(model.restEndDate, rest)
        if boundary == "immediate" || boundary == "replacement" {
            XCTAssertEqual(model.currentExercise?.id, a.id)
            XCTAssertEqual(model.currentSetNumber, 2)
            XCTAssertFalse(model.finished)
            if boundary == "replacement" {
                for _ in 0..<50 {
                    if !model.isSetEntryBlocked(a) { break }
                    await Task.yield()
                }
                XCTAssertFalse(model.isSetEntryBlocked(a))
                model.skipRest()
                XCTAssertNil(model.restEndDate)
                await model.logCurrentSet(expected: a, expectedSetNumber: model.currentPhysicalSetNumber)
                XCTAssertEqual(model.runnerSetsDone(a), 2)
                XCTAssertEqual(model.currentExercise?.id, c.id)
                XCTAssertEqual(model.restTotal, 75)
                XCTAssertNotNil(model.restEndDate)
                let replacementRest = model.restEndDate
                await model.drainSetOutbox()
                XCTAssertEqual(accepted.count, 5)
                XCTAssertEqual(model.restEndDate, replacementRest)
            }
        } else {
            XCTAssertEqual(model.currentExercise?.id, c.id)
            XCTAssertTrue(model.timedActive)
            if boundary == "manual" {
                model.jump(to: 3)
                model.startTimedSet(expected: d, expectedSetNumber: 1, at: fixedDate)
            }
            await model.finishTimedSetIfDue(at: fixedDate.addingTimeInterval(30))
            XCTAssertFalse(model.timedActive)
            XCTAssertEqual(model.currentExercise?.id, boundary == "manual" ? d.id : a.id)
            XCTAssertEqual(model.currentSetNumber, 2)
            await model.drainSetOutbox()
        }
    }
}


extension SetOutboxTests {
    func testGroupDelayedDeletionPreservesManualNavigationBeforeACK() async throws {
        for navigation in ["jump", "next"] {
            for liveReadBeforeACK in [false, true] {
                let defaults = defaults(), api = SetWriteAPIStub()
                let a = exercise(targetSets: 1, groupID: "group-a")
                let b = exercise(id: "slot-b", exerciseID: "exercise-b", targetSets: 1, groupID: "group-a")
                let c = exercise(id: "slot-c", exerciseID: "exercise-c", targetSets: 2)
                let d = exercise(id: "slot-d", exerciseID: "exercise-d", targetSets: 2)
                let active = session(updatedAt: 100, attempt: 0)
                var accepted: [SetLog] = []
                api.logHandler = { [self] id, body, _ in
                    let row = setLog(body: body, sessionID: id)
                    accepted.append(row)
                    return .init(set: row, deduped: false, session: active)
                }
                let entered = SetAsyncLatch(), release = SetAsyncLatch()
                var deleted: SetLog?
                api.correctionHandler = { [self] intent, _ in
                    let result = corrected(try XCTUnwrap(accepted.first { $0.id == intent.setID }),
                                           intent: intent, session: active)
                    deleted = result.set
                    await entered.open()
                    await release.wait()
                    return result
                }
                let model = SyncModel(auth: retainedAuth(defaults: defaults), setWriteAPI: api,
                                      defaults: defaults, now: { self.fixedDate })
                model.replaceState(with: state(session: active, sets: [], exercises: [a, b, c, d]))
                model.startWorkout()
                await model.logCurrentSet(expected: a, expectedSetNumber: 1)
                await model.drainSetOutbox()
                await model.logCurrentSet(expected: b, expectedSetNumber: 1)
                await model.drainSetOutbox()
                XCTAssertEqual(model.currentExercise?.id, c.id)
                let rest = model.restEndDate
                XCTAssertTrue(model.enqueueCorrection(set: try XCTUnwrap(accepted.first), values: nil))
                let drain = Task { await model.drainWorkoutWriteOutboxes() }
                await entered.wait()
                // Navigation happens before either authoritative deletion
                // observation, so the completed group no longer owns focus.
                if navigation == "jump" { model.jump(to: 3) } else { model.next() }
                XCTAssertEqual(model.currentExercise?.id, d.id)
                if liveReadBeforeACK {
                    model.replaceState(with: state(session: active,
                        sets: [try XCTUnwrap(deleted), accepted[1]], exercises: [a, b, c, d]))
                    XCTAssertEqual(model.currentExercise?.id, d.id)
                }
                await release.open()
                await drain.value
                XCTAssertTrue(model.setCorrections.isEmpty)
                XCTAssertEqual(model.runnerSetsDone(a), 0)
                XCTAssertEqual(model.currentExercise?.id, d.id)
                XCTAssertEqual(model.currentSetNumber, 1)
                XCTAssertEqual(model.restEndDate, rest)
            }
        }
    }
}

extension SetOutboxTests {
    func testGroupDeletionAfterUnrelatedSelectionRepairsWithEitherAcknowledgementOrder() async throws {
        for otherGroup in [false, true] {
            for liveReadFirst in [false, true] {
                try await verifyDeletionAfterUnrelatedSelection(otherGroup: otherGroup,
                    liveReadFirst: liveReadFirst, holdBoundary: nil)
            }
        }
    }

    func testGroupDeletionAfterUnrelatedTimedSelectionWaitsForHoldBoundary() async throws {
        for liveReadFirst in [false, true] {
            for boundary in ["complete", "skip", "manual"] {
                try await verifyDeletionAfterUnrelatedSelection(otherGroup: false,
                    liveReadFirst: liveReadFirst, holdBoundary: boundary)
            }
        }
    }

    private func verifyDeletionAfterUnrelatedSelection(otherGroup: Bool, liveReadFirst: Bool,
                                                       holdBoundary: String?) async throws {
        let defaults = defaults(), api = SetWriteAPIStub()
        let a = exercise(targetSets: 1, groupID: "group-a")
        let b = exercise(id: "slot-b", exerciseID: "exercise-b", targetSets: 1, groupID: "group-a")
        let c = exercise(id: "slot-c", exerciseID: "exercise-c", timed: holdBoundary != nil,
                         targetSets: 2, groupID: otherGroup ? "group-b" : nil)
        let d = exercise(id: "slot-d", exerciseID: "exercise-d", targetSets: 2,
                         groupID: otherGroup ? "group-b" : nil)
        let slots = [a, b, c, d], active = session(updatedAt: 100, attempt: 0)
        var accepted: [SetLog] = []
        api.logHandler = { [self] id, body, _ in
            let row = setLog(body: body, sessionID: id)
            accepted.append(row)
            return .init(set: row, deduped: false, session: active)
        }
        let entered = SetAsyncLatch(), release = SetAsyncLatch()
        var deletion: SetCorrectionResult?
        api.correctionHandler = { [self] intent, _ in
            let result = corrected(try XCTUnwrap(accepted.first { $0.id == intent.setID }), intent: intent, session: active)
            deletion = result
            await entered.open()
            await release.wait()
            return result
        }
        let model = SyncModel(auth: retainedAuth(defaults: defaults), setWriteAPI: api,
                              defaults: defaults, now: { self.fixedDate })
        model.replaceState(with: state(session: active, sets: [], exercises: slots))
        model.startWorkout()
        await model.logCurrentSet(expected: a, expectedSetNumber: 1)
        await model.drainSetOutbox()
        await model.logCurrentSet(expected: b, expectedSetNumber: 1)
        await model.drainSetOutbox()
        XCTAssertEqual(model.currentExercise?.id, c.id)
        model.jump(to: 2)
        if holdBoundary != nil { model.startTimedSet(expected: c, expectedSetNumber: 1, at: fixedDate) }
        XCTAssertTrue(model.enqueueCorrection(set: try XCTUnwrap(accepted.first), values: nil))
        XCTAssertEqual(model.setCorrections.first?.runnerFocusRevision,
                       WorkoutRunnerCheckpointStore.load(userID: "user-a", defaults: defaults)?.focus?.revision)
        let drain = Task { await model.drainWorkoutWriteOutboxes() }
        await entered.wait()
        let rest = model.restEndDate
        if liveReadFirst {
            model.replaceState(with: state(session: active,
                sets: [try XCTUnwrap(deletion).set, accepted[1]], exercises: slots))
            XCTAssertEqual(model.currentExercise?.id, holdBoundary == nil ? a.id : c.id)
        }
        await release.open()
        await drain.value
        XCTAssertTrue(model.setCorrections.isEmpty)
        XCTAssertEqual(model.runnerSetsDone(a), 0)
        XCTAssertEqual(model.currentExercise?.id, holdBoundary == nil ? a.id : c.id)
        XCTAssertEqual(model.restEndDate, rest)
        model.replaceState(with: state(session: active, sets: [accepted[1]], exercises: slots))
        XCTAssertEqual(model.currentExercise?.id, holdBoundary == nil ? a.id : c.id)
        if let holdBoundary {
            XCTAssertTrue(model.timedActive)
            switch holdBoundary {
            case "complete":
                await model.finishTimedSetIfDue(at: fixedDate.addingTimeInterval(30))
                XCTAssertEqual(model.runnerSetsDone(c), 1)
                XCTAssertEqual(model.currentExercise?.id, a.id)
            case "skip":
                model.skip()
                XCTAssertEqual(model.currentExercise?.id, a.id)
            default:
                model.jump(to: 3)
                await model.finishTimedSetIfDue(at: fixedDate.addingTimeInterval(30))
                XCTAssertEqual(model.runnerSetsDone(c), 0)
                XCTAssertEqual(model.currentExercise?.id, d.id)
                model.replaceState(with: state(session: active, sets: [accepted[1]], exercises: slots))
                XCTAssertEqual(model.currentExercise?.id, d.id)
            }
            XCTAssertFalse(model.timedActive)
        }
        await model.drainSetOutbox()
    }

    func testGroupColdDeletionFromUnrelatedSelectionUsesRevisionAndCheckpointDay() async throws {
        for olderDeletion in [false, true] {
            for otherGroup in [false, true] {
                for liveReadFirst in [false, true] {
                    try await verifyColdDeletionFromUnrelatedSelection(olderDeletion: olderDeletion,
                        otherGroup: otherGroup, liveReadFirst: liveReadFirst)
                }
            }
        }
    }

    private func verifyColdDeletionFromUnrelatedSelection(olderDeletion: Bool, otherGroup: Bool,
                                                          liveReadFirst: Bool) async throws {
        let defaults = defaults(), api = SetWriteAPIStub()
        let a = exercise(targetSets: 1, groupID: "group-a")
        let b = exercise(id: "slot-b", exerciseID: "exercise-b", targetSets: 1, groupID: "group-a")
        let c = exercise(id: "slot-c", exerciseID: "exercise-c", targetSets: 2,
                         groupID: otherGroup ? "group-b" : nil)
        let d = exercise(id: "slot-d", exerciseID: "exercise-d", targetSets: 2,
                         groupID: otherGroup ? "group-b" : nil)
        // A checkpoint's explicit workout override may differ from the session
        // pin and the day initially selected while the cached state loads.
        let overrideDay = Workout(id: "day-override", name: "Override", day_label: "O",
            order_index: 1, exercises: [a, b, c, d])
        let pinned = exercise(id: "pinned", exerciseID: "pinned-exercise")
        let days = [day(with: [pinned]), overrideDay]
        let active = session(updatedAt: 100, attempt: 0)
        let originalA = correctionFixture(a, id: "original-a"), originalB = correctionFixture(b, id: "original-b")
        StateSnapshotStore.save(state(session: active, sets: [originalA, originalB], workouts: days),
                                userID: "user-a", defaults: defaults)
        let progress: GroupRunnerProgress? = otherGroup ? .init(id: "group-b", members: [
            .init(id: c.id, target: 2, completedIDs: [], skipped: false),
            .init(id: d.id, target: 2, completedIDs: [], skipped: false),
        ]) : nil
        WorkoutRunnerCheckpointStore.save(.init(date: fixedCivilDate, sessionID: active.id,
            selectedDayID: overrideDay.id, currentSlotID: c.id, skippedSlotIDs: [],
            workoutStartedAtMS: originalA.logged_at, finished: false, sessionAttempt: 0,
            groupProgress: progress, focus: .init(revision: 1, isExplicit: true)),
            userID: "user-a", defaults: defaults)
        let intent = PendingSetCorrection(id: "correction-a", setID: originalA.id, date: fixedCivilDate,
            slotID: a.id, exerciseID: a.exercise_id, sessionID: active.id, expectedAttempt: 0,
            expectedUpdatedAt: originalA.updated_at, values: nil, runnerFocusRevision: olderDeletion ? 0 : 1)
        SetCorrectionOutboxStore.enqueue(intent, userID: "user-a", defaults: defaults)
        let deletion = corrected(originalA, intent: intent, session: active)
        let entered = SetAsyncLatch(), release = SetAsyncLatch()
        api.correctionHandler = { _, _ in
            if liveReadFirst { await entered.open(); await release.wait() }
            return deletion
        }
        let model = SyncModel(auth: retainedAuth(defaults: defaults), setWriteAPI: api,
                              defaults: defaults, now: { self.fixedDate })
        let drain = Task { await model.drainWorkoutWriteOutboxes() }
        if liveReadFirst {
            await entered.wait()
            model.replaceState(with: state(session: active, sets: [deletion.set, originalB], workouts: days))
            XCTAssertEqual(model.resumableCheckpoint?.currentSlotID, olderDeletion ? c.id : a.id)
            await release.open()
        }
        await drain.value
        XCTAssertTrue(model.setCorrections.isEmpty)
        let saved = try XCTUnwrap(WorkoutRunnerCheckpointStore.load(userID: "user-a", defaults: defaults))
        XCTAssertEqual(saved.currentSlotID, olderDeletion ? c.id : a.id)
        XCTAssertEqual(saved.selectedDayID, overrideDay.id)
        XCTAssertEqual(saved.focus?.isExplicit, olderDeletion)
        if !liveReadFirst { XCTAssertNil(model.resumableCheckpoint) }
        model.replaceState(with: state(session: active, sets: [originalB], workouts: days))
        XCTAssertEqual(model.resumableCheckpoint?.currentSlotID, olderDeletion ? c.id : a.id)
        model.resumeWorkout()
        XCTAssertEqual(model.currentExercise?.id, olderDeletion ? c.id : a.id)
        XCTAssertEqual(model.selectedDayID, overrideDay.id)
    }

    func testGroupNewerSameGroupFocusSurvivesDelayedDeletionAndUnchangedRefresh() async throws {
        for navigation in ["previous", "jump"] {
            for liveReadFirst in [false, true] {
                try await verifyGroupDeletionFocusOrder(navigation: navigation,
                    liveReadFirst: liveReadFirst, deletionAfterSelection: false)
            }
        }
    }

    func testGroupDeletionInitiatedAfterSameGroupSelectionStillRepairs() async throws {
        for liveReadFirst in [false, true] {
            try await verifyGroupDeletionFocusOrder(navigation: "jump",
                liveReadFirst: liveReadFirst, deletionAfterSelection: true)
        }
    }

    func testGroupNewerFocusSurvivesFinishedWorkoutReopeningBeforeDeletionACK() async throws {
        for liveReadFirst in [false, true] {
            try await verifyGroupDeletionFocusOrder(navigation: "jump", liveReadFirst: liveReadFirst,
                deletionAfterSelection: false, includesFollowingSlot: false)
        }
    }

    private func verifyGroupDeletionFocusOrder(navigation: String, liveReadFirst: Bool,
                                               deletionAfterSelection: Bool,
                                               includesFollowingSlot: Bool = true) async throws {
        let defaults = defaults(), api = SetWriteAPIStub()
        let a = exercise(targetSets: 1, groupID: "group-a")
        let b = exercise(id: "slot-b", exerciseID: "exercise-b", targetSets: 1, groupID: "group-a")
        let c = exercise(id: "slot-c", exerciseID: "exercise-c", targetSets: 2)
        let slots = includesFollowingSlot ? [a, b, c] : [a, b]
        let active = session(updatedAt: 100, attempt: 0)
        var accepted: [SetLog] = []
        api.logHandler = { [self] id, body, _ in
            let row = setLog(body: body, sessionID: id)
            accepted.append(row)
            return .init(set: row, deduped: false, session: active)
        }
        let entered = SetAsyncLatch(), release = SetAsyncLatch()
        var deleted: SetLog?
        api.correctionHandler = { [self] intent, _ in
            let result = corrected(try XCTUnwrap(accepted.first { $0.id == intent.setID }), intent: intent, session: active)
            deleted = result.set
            await entered.open()
            await release.wait()
            return result
        }
        let model = SyncModel(auth: retainedAuth(defaults: defaults), setWriteAPI: api,
                              defaults: defaults, now: { self.fixedDate })
        model.replaceState(with: state(session: active, sets: [], exercises: slots))
        model.startWorkout()
        await model.logCurrentSet(expected: a, expectedSetNumber: 1)
        await model.drainSetOutbox()
        await model.logCurrentSet(expected: b, expectedSetNumber: 1)
        await model.drainSetOutbox()
        XCTAssertEqual(model.currentExercise?.id, includesFollowingSlot ? c.id : b.id)
        XCTAssertEqual(model.finished, !includesFollowingSlot)
        if deletionAfterSelection { model.jump(to: 1) }
        XCTAssertTrue(model.enqueueCorrection(set: try XCTUnwrap(accepted.first), values: nil))
        let capturedRevision = try XCTUnwrap(model.setCorrections.first?.runnerFocusRevision)
        let drain = Task { await model.drainWorkoutWriteOutboxes() }
        await entered.wait()
        if !deletionAfterSelection {
            if navigation == "previous" { model.previous() } else { model.jump(to: 1) }
        }
        let checkpoint = try XCTUnwrap(WorkoutRunnerCheckpointStore.load(userID: "user-a", defaults: defaults))
        XCTAssertEqual(checkpoint.focus?.isExplicit, true)
        if deletionAfterSelection { XCTAssertEqual(checkpoint.focus?.revision, capturedRevision) }
        else { XCTAssertGreaterThan(try XCTUnwrap(checkpoint.focus?.revision), capturedRevision) }
        let rest = model.restEndDate
        if liveReadFirst {
            model.replaceState(with: state(session: active,
                sets: [try XCTUnwrap(deleted), accepted[1]], exercises: slots))
            XCTAssertEqual(model.currentExercise?.id, deletionAfterSelection ? a.id : b.id)
            XCTAssertFalse(model.finished)
            XCTAssertEqual(WorkoutRunnerCheckpointStore.load(userID: "user-a", defaults: defaults)?.focus?.isExplicit,
                           !deletionAfterSelection)
        }
        await release.open()
        await drain.value
        XCTAssertTrue(model.setCorrections.isEmpty)
        XCTAssertEqual(model.currentExercise?.id, deletionAfterSelection ? a.id : b.id)
        XCTAssertEqual(model.restEndDate, rest)
        model.replaceState(with: state(session: active, sets: [accepted[1]], exercises: slots))
        XCTAssertEqual(model.currentExercise?.id, deletionAfterSelection ? a.id : b.id)
        XCTAssertEqual(WorkoutRunnerCheckpointStore.load(userID: "user-a", defaults: defaults)?.focus?.isExplicit,
                       !deletionAfterSelection)
        if !deletionAfterSelection {
            // Skip ends manual focus and resumes the derived group sequence.
            model.skip()
            XCTAssertEqual(model.currentExercise?.id, a.id)
            XCTAssertEqual(WorkoutRunnerCheckpointStore.load(userID: "user-a", defaults: defaults)?.focus?.isExplicit, false)
        }
    }

    func testGroupPendingDeletionPreservesNewerTimedFocusUntilPhysicalCommit() async throws {
        let defaults = defaults(), api = SetWriteAPIStub()
        let a = exercise(targetSets: 2, groupID: "group-a", transitionRest: 0)
        let b = exercise(id: "slot-b", exerciseID: "exercise-b", timed: true, targetSets: 2,
                         groupID: "group-a", transitionRest: 0)
        let active = session(updatedAt: 100, attempt: 0), original = correctionFixture(a)
        let entered = SetAsyncLatch(), release = SetAsyncLatch()
        api.correctionHandler = { [self] intent, _ in
            await entered.open()
            await release.wait()
            return corrected(original, intent: intent, session: active)
        }
        api.logHandler = { [self] id, body, _ in .init(set: setLog(body: body, sessionID: id), deduped: false, session: active) }
        let model = SyncModel(auth: retainedAuth(defaults: defaults), setWriteAPI: api,
                              defaults: defaults, now: { self.fixedDate })
        model.replaceState(with: state(session: active, sets: [original], exercises: [a, b]))
        model.startWorkout()
        XCTAssertTrue(model.enqueueCorrection(set: original, values: nil))
        let drain = Task { await model.drainWorkoutWriteOutboxes() }
        await entered.wait()
        model.jump(to: 1)
        model.startTimedSet(expected: b, expectedSetNumber: 1, at: fixedDate)
        await release.open()
        await drain.value
        XCTAssertEqual(model.currentExercise?.id, b.id)
        XCTAssertTrue(model.timedActive)
        model.replaceState(with: state(session: active, sets: [], exercises: [a, b]))
        XCTAssertTrue(model.timedActive)
        await model.finishTimedSetIfDue(at: fixedDate.addingTimeInterval(30))
        XCTAssertEqual(model.currentExercise?.id, a.id)
        XCTAssertEqual(model.runnerSetsDone(b), 1)
        XCTAssertNil(model.restEndDate)
        XCTAssertEqual(WorkoutRunnerCheckpointStore.load(userID: "user-a", defaults: defaults)?.focus?.isExplicit, false)
        await model.drainSetOutbox()
    }

    func testGroupColdPendingDeletionHonorsPersistedSelectionRevisionInBothObservationOrders() async throws {
        for olderDeletion in [false, true] {
            for liveReadFirst in [false, true] {
                try await verifyColdGroupDeletionFocusOrder(olderDeletion: olderDeletion,
                    liveReadFirst: liveReadFirst, includesFollowingSlot: true)
            }
        }
    }

    func testGroupColdNewerFocusSurvivesFinishedWorkoutReopeningBeforeDeletionACK() async throws {
        for liveReadFirst in [false, true] {
            try await verifyColdGroupDeletionFocusOrder(olderDeletion: true,
                liveReadFirst: liveReadFirst, includesFollowingSlot: false)
        }
    }

    private func verifyColdGroupDeletionFocusOrder(olderDeletion: Bool, liveReadFirst: Bool,
                                                   includesFollowingSlot: Bool) async throws {
        let defaults = defaults(), api = SetWriteAPIStub()
        let a = exercise(targetSets: 1, groupID: "group-a")
        let b = exercise(id: "slot-b", exerciseID: "exercise-b", targetSets: 1, groupID: "group-a")
        let c = exercise(id: "slot-c", exerciseID: "exercise-c", targetSets: 2)
        let slots = includesFollowingSlot ? [a, b, c] : [a, b]
        let active = session(updatedAt: 100, attempt: 0)
        let originalA = correctionFixture(a, id: "original-a"), originalB = correctionFixture(b, id: "original-b")
        let baseline = state(session: active, sets: [originalA, originalB], exercises: slots)
        StateSnapshotStore.save(baseline, userID: "user-a", defaults: defaults)
        let progress = GroupRunnerProgress(id: "group-a", members: [
            .init(id: a.id, target: 1, completedIDs: [originalA.id], skipped: false),
            .init(id: b.id, target: 1, completedIDs: [originalB.id], skipped: false),
        ])
        WorkoutRunnerCheckpointStore.save(.init(date: fixedCivilDate, sessionID: active.id,
            selectedDayID: "day-a", currentSlotID: b.id, skippedSlotIDs: [],
            workoutStartedAtMS: originalA.logged_at, finished: !includesFollowingSlot, sessionAttempt: 0,
            groupProgress: progress, focus: .init(revision: 1, isExplicit: true)),
            userID: "user-a", defaults: defaults)
        let intent = PendingSetCorrection(id: "correction-a", setID: originalA.id, date: fixedCivilDate,
            slotID: a.id, exerciseID: a.exercise_id, sessionID: active.id, expectedAttempt: 0,
            expectedUpdatedAt: originalA.updated_at, values: nil, runnerFocusRevision: olderDeletion ? 0 : 1)
        SetCorrectionOutboxStore.enqueue(intent, userID: "user-a", defaults: defaults)
        let deleted = corrected(originalA, intent: intent, session: active)
        let entered = SetAsyncLatch(), release = SetAsyncLatch()
        api.correctionHandler = { _, _ in
            if liveReadFirst { await entered.open(); await release.wait() }
            return deleted
        }
        let model = SyncModel(auth: retainedAuth(defaults: defaults), setWriteAPI: api,
                              defaults: defaults, now: { self.fixedDate })
        let drain = Task { await model.drainWorkoutWriteOutboxes() }
        if liveReadFirst {
            await entered.wait()
            model.replaceState(with: state(session: active, sets: [deleted.set, originalB], exercises: slots))
            XCTAssertEqual(model.resumableCheckpoint?.currentSlotID, olderDeletion ? b.id : a.id)
            XCTAssertEqual(model.resumableCheckpoint?.finished, false)
            XCTAssertEqual(model.resumableCheckpoint?.focus?.isExplicit, olderDeletion)
            await release.open()
        }
        await drain.value
        XCTAssertTrue(model.setCorrections.isEmpty)
        model.replaceState(with: state(session: active, sets: [originalB], exercises: slots))
        XCTAssertEqual(model.resumableCheckpoint?.currentSlotID, olderDeletion ? b.id : a.id)
        XCTAssertEqual(model.resumableCheckpoint?.focus?.isExplicit, olderDeletion)
        model.resumeWorkout()
        XCTAssertEqual(model.currentExercise?.id, olderDeletion ? b.id : a.id)
        XCTAssertEqual(model.currentSetNumber, 1)
    }

    func testGroupManualAheadMembersUseTransitionUntilTheCompletedRoundFloorAdvances() async {
        for transition in [0, 7] {
            let defaults = defaults(), api = SetWriteAPIStub()
            let a = exercise(targetSets: 2, groupID: "group-a", transitionRest: transition)
            let b = exercise(id: "slot-b", exerciseID: "exercise-b", targetSets: 2,
                             groupID: "group-a", transitionRest: transition)
            let c = exercise(id: "slot-c", exerciseID: "exercise-c")
            api.logHandler = { _, _, _ in throw URLError(.notConnectedToInternet) }
            let model = SyncModel(auth: retainedAuth(defaults: defaults), setWriteAPI: api,
                                  defaults: defaults, now: { self.fixedDate })
            model.replaceState(with: state(session: session(attempt: 0), sets: [], exercises: [a, b, c]))
            model.startWorkout()
            for member in [b, b, a, a] {
                if member.id == b.id { model.jump(to: 1) }
                else if model.runnerSetsDone(a) == 0 { model.jump(to: 0) }
                for _ in 0..<50 {
                    if !model.isSetEntryBlocked(member) { break }
                    await Task.yield()
                }
                XCTAssertFalse(model.isSetEntryBlocked(member))
                await model.logCurrentSet(expected: member, expectedSetNumber: model.currentPhysicalSetNumber)
                XCTAssertEqual(WorkoutRunnerCheckpointStore.load(userID: "user-a", defaults: defaults)?.focus?.isExplicit, false)
                if member.id == b.id {
                    XCTAssertEqual(model.currentSetNumber, 1)
                    if transition == 0 { XCTAssertNil(model.restEndDate) }
                    else { XCTAssertEqual(model.restTotal, transition) }
                } else {
                    // A0/B2 -> A1/B2 and A1/B2 -> A2/B2 each finish a
                    // previously incomplete round, despite A's first position.
                    XCTAssertEqual(model.restTotal, 75)
                    XCTAssertNotNil(model.restEndDate)
                }
                await model.drainSetOutbox()
            }
            XCTAssertEqual(model.currentExercise?.id, c.id)
            XCTAssertEqual(model.setOutbox.count, 4)
        }
    }

    func testGroupReplacementSetCompletesRoundWithZeroTransitionRest() async throws {
        try await verifyEarlierGroupMemberDeletion(boundary: "replacement")
    }
}

extension SetOutboxTests {
    func testGroupAutomaticSelectionChangeEndsEarlierManualFocusOwnership() async throws {
        let defaults = defaults(), api = SetWriteAPIStub()
        let a = exercise(groupID: "group-a"), b = exercise(id: "slot-b", exerciseID: "exercise-b", groupID: "group-a")
        let changedA = exercise(targetSets: 4, groupID: "group-a")
        let changedB = exercise(id: b.id, exerciseID: b.exercise_id, targetSets: 4, groupID: "group-a")
        let active = session(updatedAt: 100, attempt: 0)
        let a1 = correctionFixture(a, id: "a1"), a2 = correctionFixture(a, id: "a2"), b1 = correctionFixture(b, id: "b1")
        let entered = SetAsyncLatch(), release = SetAsyncLatch()
        api.correctionHandler = { [self] intent, _ in
            await entered.open()
            await release.wait()
            return corrected(a1, intent: intent, session: active)
        }
        let model = SyncModel(auth: retainedAuth(defaults: defaults), setWriteAPI: api,
                              defaults: defaults, now: { self.fixedDate })
        model.replaceState(with: state(session: active, sets: [a1, a2, b1], exercises: [a, b]))
        model.startWorkout()
        XCTAssertTrue(model.enqueueCorrection(set: a1, values: nil))
        let drain = Task { await model.drainWorkoutWriteOutboxes() }
        await entered.wait()
        model.jump(to: 0)
        model.replaceState(with: state(session: active, sets: [a1, a2, b1],
            workouts: [day(with: [changedA, changedB])], planVersion: 2))
        XCTAssertEqual(model.currentExercise?.id, b.id)
        XCTAssertEqual(WorkoutRunnerCheckpointStore.load(userID: "user-a", defaults: defaults)?.focus?.isExplicit, false)
        await release.open()
        await drain.value
        XCTAssertEqual(model.currentExercise?.id, a.id)
        XCTAssertEqual(model.currentSetNumber, 2)
    }

    func testGroupColdEligibleDeletionEndsFocusEvenWhenTheCursorStaysOnSameMember() async throws {
        let defaults = defaults(), api = SetWriteAPIStub()
        let a = exercise(groupID: "group-a"), b = exercise(id: "slot-b", exerciseID: "exercise-b", groupID: "group-a")
        let active = session(updatedAt: 100, attempt: 0)
        let a1 = correctionFixture(a, id: "a1"), a2 = correctionFixture(a, id: "a2"), b1 = correctionFixture(b, id: "b1")
        StateSnapshotStore.save(state(session: active, sets: [a1, a2, b1], exercises: [a, b]),
                                userID: "user-a", defaults: defaults)
        WorkoutRunnerCheckpointStore.save(.init(date: fixedCivilDate, sessionID: active.id,
            selectedDayID: "day-a", currentSlotID: a.id, skippedSlotIDs: [],
            workoutStartedAtMS: a1.logged_at, finished: false, sessionAttempt: 0,
            groupProgress: .init(id: "group-a", members: [
                .init(id: a.id, target: 3, completedIDs: [a1.id, a2.id], skipped: false),
                .init(id: b.id, target: 3, completedIDs: [b1.id], skipped: false),
            ]), focus: .init(revision: 1, isExplicit: true)), userID: "user-a", defaults: defaults)
        let older = PendingSetCorrection(id: "delete-b", setID: b1.id, date: fixedCivilDate,
            slotID: b.id, exerciseID: b.exercise_id, sessionID: active.id, expectedAttempt: 0,
            expectedUpdatedAt: b1.updated_at, values: nil, runnerFocusRevision: 0,
            deliveryState: .failed, failedHTTPStatus: 409)
        let newer = PendingSetCorrection(id: "delete-a", setID: a1.id, date: fixedCivilDate,
            slotID: a.id, exerciseID: a.exercise_id, sessionID: active.id, expectedAttempt: 0,
            expectedUpdatedAt: a1.updated_at, values: nil, runnerFocusRevision: 1)
        SetCorrectionOutboxStore.enqueue(older, userID: "user-a", defaults: defaults)
        SetCorrectionOutboxStore.enqueue(newer, userID: "user-a", defaults: defaults)
        api.correctionHandler = { [self] intent, _ in
            corrected(intent.setID == a1.id ? a1 : b1, intent: intent, session: active)
        }
        let model = SyncModel(auth: retainedAuth(defaults: defaults), setWriteAPI: api,
                              defaults: defaults, now: { self.fixedDate })
        await model.drainWorkoutWriteOutboxes()
        XCTAssertEqual(model.setCorrections.map(\.id), [older.id])
        XCTAssertEqual(WorkoutRunnerCheckpointStore.load(userID: "user-a", defaults: defaults)?.focus?.isExplicit, false)
        model.replaceState(with: state(session: active, sets: [a2, b1], exercises: [a, b]))
        XCTAssertEqual(model.resumableCheckpoint?.currentSlotID, a.id)
        await model.retryCorrection(id: older.id)
        model.replaceState(with: state(session: active, sets: [a2], exercises: [a, b]))
        XCTAssertEqual(model.resumableCheckpoint?.currentSlotID, b.id)
    }

    func testCorrectionFocusRevisionIsLocalDurableMetadataAndLegacyIntentDecodes() throws {
        let defaults = defaults()
        let intent = PendingSetCorrection(id: "delete-a", setID: "set-a", date: fixedCivilDate,
            slotID: "slot-a", exerciseID: "exercise-a", sessionID: "session-a", expectedAttempt: 0,
            expectedUpdatedAt: 100, values: nil, runnerFocusRevision: 7)
        SetCorrectionOutboxStore.enqueue(intent, userID: "user-a", defaults: defaults)
        XCTAssertEqual(SetCorrectionOutboxStore.load(userID: "user-a", defaults: defaults).first?.runnerFocusRevision, 7)
        XCTAssertNil(intent.requestBody?["runnerFocusRevision"])
        var json = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(intent)) as? [String: Any])
        json.removeValue(forKey: "runnerFocusRevision")
        let legacy = try JSONDecoder().decode(PendingSetCorrection.self, from: JSONSerialization.data(withJSONObject: json))
        XCTAssertNil(legacy.runnerFocusRevision)
        var attemptedRebind = intent
        attemptedRebind.runnerFocusRevision = 9
        SetCorrectionOutboxStore.replace(attemptedRebind, userID: "user-a", defaults: defaults)
        XCTAssertEqual(SetCorrectionOutboxStore.load(userID: "user-a", defaults: defaults).first?.runnerFocusRevision, 7)
    }
}

extension SetOutboxTests {
    func testDeferredGroupDeletionRecoversAfterProcessDeathDuringFollowingHold() async throws {
        for liveReadFirst in [false, true] {
            for otherGroup in [false, true] {
                try await verifyDeferredGroupDeletionRestart(liveReadFirst: liveReadFirst,
                    otherGroup: otherGroup, change: nil)
            }
        }
    }

    func testDeferredGroupDeletionNavigationCancellationSurvivesProcessDeath() async throws {
        for liveReadFirst in [false, true] {
            try await verifyDeferredGroupDeletionRestart(liveReadFirst: liveReadFirst,
                otherGroup: false, change: "navigation")
        }
    }

    func testDeferredGroupDeletionRejectsObsoleteCheckpointAndGroupIdentity() async throws {
        for change in ["attempt", "date", "account", "group", "class"] {
            try await verifyDeferredGroupDeletionRestart(liveReadFirst: false,
                otherGroup: false, change: change)
        }
    }

    func testDeferredGroupDeletionRecoveryUsesCurrentRoundTargets() async throws {
        try await verifyDeferredGroupDeletionRestart(liveReadFirst: false,
            otherGroup: false, change: "rounds")
    }

    func testDeferredGroupDeletionRecoveryUsesCurrentMemberOrder() async throws {
        try await verifyDeferredGroupDeletionRestart(liveReadFirst: false,
            otherGroup: false, change: "order")
    }

    private func verifyDeferredGroupDeletionRestart(liveReadFirst: Bool, otherGroup: Bool,
                                                     change: String?) async throws {
        let suite = "DeferredGroupRepair.\(UUID().uuidString)"
        let defaults = LocalPersistence(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let a = exercise(targetSets: 1, groupID: "group-a")
        let b = exercise(id: "slot-b", exerciseID: "exercise-b", targetSets: 1, groupID: "group-a")
        let c = exercise(id: "slot-c", exerciseID: "exercise-c", timed: true, targetSets: 2,
                         groupID: otherGroup ? "group-b" : nil)
        let d = exercise(id: "slot-d", exerciseID: "exercise-d", targetSets: 2,
                         groupID: otherGroup ? "group-b" : nil)
        let overrideDay = Workout(id: "day-override", name: "Override", day_label: "O",
            order_index: 1, exercises: [a, b, c, d])
        let pinned = day(with: [exercise(id: "pinned", exerciseID: "pinned-exercise")])
        let days = [pinned, overrideDay]
        let active = session(updatedAt: 100, attempt: 0)
        let originalA = correctionFixture(a, id: "original-a"), originalB = correctionFixture(b, id: "original-b")
        let api = SetWriteAPIStub(), entered = SetAsyncLatch(), release = SetAsyncLatch()
        var deletion: SetCorrectionResult?
        api.correctionHandler = { [self] intent, _ in
            let result = corrected(originalA, intent: intent, session: active)
            deletion = result
            await entered.open()
            await release.wait()
            return result
        }
        let sharedAuth = retainedAuth(defaults: defaults)
        let model = SyncModel(auth: sharedAuth, setWriteAPI: api, defaults: defaults, now: { self.fixedDate })
        model.replaceState(with: state(session: active, sets: [originalA, originalB], workouts: days))
        model.selectedDayID = overrideDay.id
        model.startWorkout()
        model.jump(to: 2)
        model.startTimedSet(expected: c, expectedSetNumber: 1, at: fixedDate)
        XCTAssertTrue(model.enqueueCorrection(set: originalA, values: nil))
        let repair = try XCTUnwrap(model.setCorrections.first?.runnerGroupRepair)
        XCTAssertEqual(repair.dayID, overrideDay.id)
        XCTAssertEqual(repair.groupID, "group-a")
        let drain = Task { await model.drainWorkoutWriteOutboxes() }
        await entered.wait()
        if liveReadFirst {
            model.replaceState(with: state(session: active,
                sets: [try XCTUnwrap(deletion).set, originalB], workouts: days))
        }
        await release.open()
        await drain.value
        XCTAssertTrue(model.setCorrections.isEmpty)
        XCTAssertTrue(model.timedActive)
        XCTAssertEqual(model.currentExercise?.id, c.id)
        let durable = try XCTUnwrap(WorkoutRunnerCheckpointStore.load(userID: "user-a", defaults: defaults))
        XCTAssertEqual(durable.currentSlotID, c.id)
        XCTAssertEqual(durable.deferredGroupRepair, repair)
        if change == "navigation" {
            model.jump(to: 3)
            XCTAssertNil(WorkoutRunnerCheckpointStore.load(userID: "user-a", defaults: defaults)?.deferredGroupRepair)
        }
        let coldDefaults = LocalPersistence(suiteName: suite)!
        if change == "account" {
            let otherAuth = auth(userID: "user-b", defaults: coldDefaults)
            let other = SyncModel(auth: otherAuth, defaults: coldDefaults, now: { self.fixedDate })
            XCTAssertTrue(other.setCorrections.isEmpty)
            XCTAssertNil(other.resumableCheckpoint)
            XCTAssertNil(WorkoutRunnerCheckpointStore.load(userID: "user-b", defaults: coldDefaults))
            return
        }
        let coldDate = change == "date" ? fixedDate.addingTimeInterval(86_400) : fixedDate
        let cold = SyncModel(auth: sharedAuth, setWriteAPI: SetWriteAPIStub(), defaults: coldDefaults, now: { coldDate })
        XCTAssertFalse(cold.timedActive)
        XCTAssertNil(cold.resumableCheckpoint)
        var liveDays = days
        if change.map({ ["group", "class", "rounds"].contains($0) }) == true {
            let changedA = exercise(targetSets: change == "rounds" ? 2 : 1,
                warmup: change == "class", groupID: change == "group" ? nil : "group-a")
            let changedB = exercise(id: b.id, exerciseID: b.exercise_id,
                targetSets: change == "rounds" ? 2 : 1, warmup: change == "class",
                groupID: change == "group" ? nil : "group-a")
            liveDays = [pinned, Workout(id: overrideDay.id, name: "Override", day_label: "O",
                order_index: 1, exercises: [changedA, changedB, c, d])]
        }
        if change == "order" {
            liveDays = [pinned, Workout(id: overrideDay.id, name: "Override", day_label: "O",
                order_index: 1, exercises: [b, a, c, d])]
        }
        let liveSession = change == "attempt" ? session(updatedAt: 200, attempt: 1) : active
        cold.replaceState(with: state(session: liveSession, sets: [originalB], workouts: liveDays))
        if change == "attempt" || change == "date" {
            XCTAssertNil(cold.resumableCheckpoint)
            XCTAssertNil(WorkoutRunnerCheckpointStore.load(userID: "user-a", defaults: coldDefaults))
            return
        }
        let expectedSlot = change == "navigation" ? d.id
            : (change == nil || change == "rounds" || change == "order" ? a.id : c.id)
        XCTAssertEqual(cold.resumableCheckpoint?.currentSlotID, expectedSlot)
        XCTAssertNil(cold.resumableCheckpoint?.deferredGroupRepair)
        XCTAssertNil(WorkoutRunnerCheckpointStore.load(userID: "user-a", defaults: coldDefaults)?.deferredGroupRepair)
        cold.resumeWorkout()
        XCTAssertEqual(cold.currentExercise?.id, expectedSlot)
        XCTAssertFalse(cold.timedActive)
        XCTAssertEqual(cold.runnerSetsDone(c), 0)
        cold.replaceState(with: state(session: liveSession, sets: [originalB], workouts: liveDays))
        XCTAssertEqual(cold.currentExercise?.id, expectedSlot)
    }

    func testGroupDeletionReceiptRecoversCrashAfterTombstoneSnapshotBeforeCheckpoint() async throws {
        for legacyBackfill in [false, true] {
            let defaults = defaults()
            let a = exercise(targetSets: 1, groupID: "group-a")
            let b = exercise(id: "slot-b", exerciseID: "exercise-b", targetSets: 1, groupID: "group-a")
            let c = exercise(id: "slot-c", exerciseID: "exercise-c", timed: true)
            let slots = [a, b, c], active = session(updatedAt: 100, attempt: 0)
            let originalA = correctionFixture(a, id: "original-a"), originalB = correctionFixture(b, id: "original-b")
            let checkpoint = WorkoutRunnerCheckpoint(date: fixedCivilDate, sessionID: active.id,
                selectedDayID: "day-a", currentSlotID: c.id, skippedSlotIDs: [],
                workoutStartedAtMS: originalA.logged_at, finished: false, sessionAttempt: 0)
            WorkoutRunnerCheckpointStore.save(checkpoint, userID: "user-a", defaults: defaults)
            let repair = try XCTUnwrap(RunnerGroupRepair(groupID: "group-a", day: day(with: slots)))
            var intent = PendingSetCorrection(id: "delete-a", setID: originalA.id, date: fixedCivilDate,
                slotID: a.id, exerciseID: a.exercise_id, sessionID: active.id, expectedAttempt: 0,
                expectedUpdatedAt: originalA.updated_at, values: nil, runnerFocusRevision: 0,
                runnerGroupRepair: legacyBackfill ? nil : repair)
            SetCorrectionOutboxStore.enqueue(intent, userID: "user-a", defaults: defaults)
            let deletion = corrected(originalA, intent: intent, session: active)
            if legacyBackfill {
                StateSnapshotStore.save(state(session: active, sets: [originalA, originalB], exercises: slots),
                                        userID: "user-a", defaults: defaults)
                let backfill = SyncModel(auth: retainedAuth(defaults: defaults), defaults: defaults, now: { self.fixedDate })
                backfill.replaceState(with: state(session: active, sets: [deletion.set, originalB], exercises: slots))
                intent = try XCTUnwrap(SetCorrectionOutboxStore.load(userID: "user-a", defaults: defaults).first)
                XCTAssertEqual(intent.runnerGroupRepair, repair)
                // Model the earlier crash point: the tombstone snapshot is
                // durable, but the old C checkpoint has not yet been replaced.
                WorkoutRunnerCheckpointStore.save(checkpoint, userID: "user-a", defaults: defaults)
            } else {
                StateSnapshotStore.save(state(session: active, sets: [deletion.set, originalB], exercises: slots),
                                        userID: "user-a", defaults: defaults)
            }
            let api = SetWriteAPIStub()
            api.correctionHandler = { _, _ in deletion }
            let cold = SyncModel(auth: retainedAuth(defaults: defaults), setWriteAPI: api,
                                 defaults: defaults, now: { self.fixedDate })
            XCTAssertNil(cold.resumableCheckpoint)
            await cold.drainWorkoutWriteOutboxes()
            XCTAssertTrue(cold.setCorrections.isEmpty)
            XCTAssertEqual(WorkoutRunnerCheckpointStore.load(userID: "user-a", defaults: defaults)?.currentSlotID, a.id)
            XCTAssertNil(cold.resumableCheckpoint)
            cold.replaceState(with: state(session: active, sets: [originalB], exercises: slots))
            XCTAssertEqual(cold.resumableCheckpoint?.currentSlotID, a.id)
        }
    }
}

extension SetOutboxTests {
    func testOldGroupDeletionACKLeavesDurableRecoveryForReplacementOwner() async throws {
        try await verifyOldGroupDeletionACKHandoff(terminalTeardown: false)
    }

    func testOldGroupDeletionACKRetiresAfterTerminalCheckpointTeardown() async throws {
        try await verifyOldGroupDeletionACKHandoff(terminalTeardown: true)
    }

    private func verifyOldGroupDeletionACKHandoff(terminalTeardown: Bool) async throws {
        let defaults = defaults(), api = SetWriteAPIStub(), authAPI = SetAuthAPIStub()
        let a = exercise(targetSets: 1, groupID: "group-a")
        let b = exercise(id: "slot-b", exerciseID: "exercise-b", targetSets: 1, groupID: "group-a")
        let c = exercise(id: "slot-c", exerciseID: "exercise-c", timed: true)
        let slots = [a, b, c], active = session(updatedAt: 100, attempt: 0)
        let originalA = correctionFixture(a, id: "original-a"), originalB = correctionFixture(b, id: "original-b")
        let newToken = jwt(subject: "user-a", expiration: fixedDate.addingTimeInterval(5_000_000))
        authAPI.authResult = .success(authResponse(jwt: newToken, userID: "user-a"))
        let sharedAuth = auth(defaults: defaults, api: authAPI)
        let entered = SetAsyncLatch(), release = SetAsyncLatch()
        api.correctionHandler = { [self] intent, _ in
            await entered.open()
            await release.wait()
            return corrected(originalA, intent: intent, session: active)
        }
        let older = SyncModel(auth: sharedAuth, setWriteAPI: api, defaults: defaults, now: { self.fixedDate })
        older.replaceState(with: state(session: active, sets: [originalA, originalB], exercises: slots))
        older.startWorkout()
        older.jump(to: 2)
        older.startTimedSet(expected: c, expectedSetNumber: 1, at: fixedDate)
        XCTAssertTrue(older.enqueueCorrection(set: originalA, values: nil))
        let oldDrain = Task { await older.drainWorkoutWriteOutboxes() }
        await entered.wait()
        sharedAuth.signOut()
        await sharedAuth.exchange(identityToken: "same-user", fullName: nil)
        let replacementAPI = SetWriteAPIStub()
        replacementAPI.correctionHandler = { [self] intent, _ in corrected(originalA, intent: intent, session: active) }
        let replacement = SyncModel(auth: sharedAuth, setWriteAPI: replacementAPI,
                                    defaults: defaults, now: { self.fixedDate })
        replacement.replaceState(with: state(session: active, sets: [originalA, originalB], exercises: slots))
        replacement.resumeWorkout()
        XCTAssertTrue(replacement.running)
        XCTAssertEqual(replacement.currentExercise?.id, c.id)
        if terminalTeardown {
            replacement.replaceState(with: state(session: session(status: "completed", updatedAt: 200, attempt: 0),
                sets: [originalA, originalB], exercises: slots))
            XCTAssertFalse(replacement.running)
            XCTAssertNil(WorkoutRunnerCheckpointStore.load(userID: "user-a", defaults: defaults))
        }
        let checkpoint = WorkoutRunnerCheckpointStore.load(userID: "user-a", defaults: defaults)
        await release.open()
        await oldDrain.value
        XCTAssertEqual(WorkoutRunnerCheckpointStore.load(userID: "user-a", defaults: defaults), checkpoint)
        if terminalTeardown {
            XCTAssertTrue(SetCorrectionOutboxStore.load(userID: "user-a", defaults: defaults).isEmpty)
            return
        }
        XCTAssertEqual(SetCorrectionOutboxStore.load(userID: "user-a", defaults: defaults).count, 1)
        await older.drainWorkoutWriteOutboxes()
        XCTAssertEqual(api.correctionCalls.count, 1)
        await replacement.drainWorkoutWriteOutboxes()
        XCTAssertTrue(replacement.setCorrections.isEmpty)
        XCTAssertEqual(replacement.currentExercise?.id, a.id)
        XCTAssertNil(WorkoutRunnerCheckpointStore.load(userID: "user-a", defaults: defaults)?.deferredGroupRepair)
    }

    func testGroupCorrectionRecoveryEvidenceIsImmutableLocalMetadata() throws {
        let defaults = defaults()
        let a = exercise(groupID: "group-a"), b = exercise(id: "slot-b", exerciseID: "exercise-b", groupID: "group-a")
        let repair = try XCTUnwrap(RunnerGroupRepair(groupID: "group-a", day: day(with: [a, b])))
        let intent = PendingSetCorrection(id: "delete-a", setID: "set-a", date: fixedCivilDate,
            slotID: a.id, exerciseID: a.exercise_id, sessionID: "session-a", expectedAttempt: 0,
            expectedUpdatedAt: 100, values: nil, runnerFocusRevision: 7, runnerGroupRepair: repair)
        SetCorrectionOutboxStore.enqueue(intent, userID: "user-a", defaults: defaults)
        XCTAssertEqual(SetCorrectionOutboxStore.load(userID: "user-a", defaults: defaults).first?.runnerGroupRepair, repair)
        XCTAssertNil(intent.requestBody?["runnerGroupRepair"])
        var attemptedRebind = intent
        let changedA = exercise(warmup: true, groupID: "group-a")
        attemptedRebind.runnerGroupRepair = RunnerGroupRepair(groupID: "group-a", day: day(with: [changedA, b]))
        SetCorrectionOutboxStore.replace(attemptedRebind, userID: "user-a", defaults: defaults)
        XCTAssertEqual(SetCorrectionOutboxStore.load(userID: "user-a", defaults: defaults).first?.runnerGroupRepair, repair)
        var json = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(intent)) as? [String: Any])
        json.removeValue(forKey: "runnerGroupRepair")
        let legacy = try JSONDecoder().decode(PendingSetCorrection.self, from: JSONSerialization.data(withJSONObject: json))
        XCTAssertNil(legacy.runnerGroupRepair)
    }
}

extension SetOutboxTests {
    func testPreparedGroupDeletionWaitsForLivePlanAfterCacheInvalidation() async throws {
        let defaults = defaults()
        let a = exercise(targetSets: 1, groupID: "group-a")
        let b = exercise(id: "slot-b", exerciseID: "exercise-b", targetSets: 1, groupID: "group-a")
        let c = exercise(id: "slot-c", exerciseID: "exercise-c", timed: true)
        let slots = [a, b, c], active = session(updatedAt: 100, attempt: 0)
        let originalA = correctionFixture(a, id: "original-a"), originalB = correctionFixture(b, id: "original-b")
        let checkpoint = WorkoutRunnerCheckpoint(date: fixedCivilDate, sessionID: active.id,
            selectedDayID: "day-a", currentSlotID: c.id, skippedSlotIDs: [],
            workoutStartedAtMS: originalA.logged_at, finished: false, sessionAttempt: 0)
        WorkoutRunnerCheckpointStore.save(checkpoint, userID: "user-a", defaults: defaults)
        let intent = PendingSetCorrection(id: "delete-a", setID: originalA.id, date: fixedCivilDate,
            slotID: a.id, exerciseID: a.exercise_id, sessionID: active.id, expectedAttempt: 0,
            expectedUpdatedAt: originalA.updated_at, values: nil, runnerFocusRevision: 0,
            runnerGroupRepair: RunnerGroupRepair(groupID: "group-a", day: day(with: slots)))
        SetCorrectionOutboxStore.enqueue(intent, userID: "user-a", defaults: defaults)
        XCTAssertTrue(StateSnapshotStore.invalidate(userID: "user-a", defaults: defaults))
        let deletion = corrected(originalA, intent: intent, session: active), api = SetWriteAPIStub()
        api.correctionHandler = { _, _ in deletion }
        let cold = SyncModel(auth: retainedAuth(defaults: defaults), setWriteAPI: api,
                             defaults: defaults, now: { self.fixedDate })
        XCTAssertNil(cold.plan)
        await cold.drainWorkoutWriteOutboxes()
        XCTAssertEqual(cold.setCorrections.count, 1)
        XCTAssertEqual(WorkoutRunnerCheckpointStore.load(userID: "user-a", defaults: defaults), checkpoint)
        XCTAssertNil(cold.resumableCheckpoint)
        cold.replaceState(with: state(session: active, sets: [deletion.set, originalB], exercises: slots))
        XCTAssertEqual(cold.resumableCheckpoint?.currentSlotID, a.id)
        await cold.drainWorkoutWriteOutboxes()
        XCTAssertTrue(cold.setCorrections.isEmpty)
        XCTAssertEqual(WorkoutRunnerCheckpointStore.load(userID: "user-a", defaults: defaults)?.currentSlotID, a.id)
    }
}

extension SetOutboxTests {
    func testPreparedGroupDeletionRetiresObsoleteDurableScopeWithoutCachedPlan() async throws {
        for changedScope in ["date", "session", "attempt"] {
            let defaults = defaults()
            let a = exercise(targetSets: 1, groupID: "group-a")
            let b = exercise(id: "slot-b", exerciseID: "exercise-b", targetSets: 1, groupID: "group-a")
            let active = session(updatedAt: 100, attempt: 0), original = correctionFixture(a)
            let checkpoint = WorkoutRunnerCheckpoint(
                date: changedScope == "date" ? "2033-05-19" : fixedCivilDate,
                sessionID: changedScope == "session" ? "new-session" : active.id,
                selectedDayID: "day-a", currentSlotID: "slot-c", skippedSlotIDs: [],
                workoutStartedAtMS: original.logged_at, finished: false,
                sessionAttempt: changedScope == "attempt" ? 1 : 0)
            WorkoutRunnerCheckpointStore.save(checkpoint, userID: "user-a", defaults: defaults)
            let intent = PendingSetCorrection(id: "old-delete", setID: original.id, date: fixedCivilDate,
                slotID: a.id, exerciseID: a.exercise_id, sessionID: active.id, expectedAttempt: 0,
                expectedUpdatedAt: original.updated_at, values: nil, runnerFocusRevision: 0,
                runnerGroupRepair: RunnerGroupRepair(groupID: "group-a", day: day(with: [a, b])))
            SetCorrectionOutboxStore.enqueue(intent, userID: "user-a", defaults: defaults)
            XCTAssertTrue(StateSnapshotStore.invalidate(userID: "user-a", defaults: defaults))
            let api = SetWriteAPIStub()
            api.correctionHandler = { [self] received, _ in corrected(original, intent: received, session: active) }
            let cold = SyncModel(auth: retainedAuth(defaults: defaults), setWriteAPI: api,
                                 defaults: defaults, now: { self.fixedDate })
            XCTAssertNil(cold.plan)
            await cold.drainWorkoutWriteOutboxes()
            XCTAssertTrue(cold.setCorrections.isEmpty, changedScope)
            XCTAssertEqual(WorkoutRunnerCheckpointStore.load(userID: "user-a", defaults: defaults), checkpoint)
            XCTAssertNil(cold.resumableCheckpoint)
            XCTAssertEqual(api.correctionCalls.count, 1)
        }
    }
}

extension SetOutboxTests {
    func testStaleColdDeletionACKCannotAbsorbNewerAutomaticCheckpointFocus() async throws {
        let defaults = defaults(), oldAPI = SetWriteAPIStub()
        let a = exercise(targetSets: 1, groupID: "group-a")
        let b = exercise(id: "slot-b", exerciseID: "exercise-b", targetSets: 1, groupID: "group-a")
        let c = exercise(id: "slot-c", exerciseID: "exercise-c", targetSets: 1)
        let d = exercise(id: "slot-d", exerciseID: "exercise-d", targetSets: 1)
        let slots = [a, b, c, d], active = session(updatedAt: 100, attempt: 0)
        let originalA = correctionFixture(a, id: "original-a"), originalB = correctionFixture(b, id: "original-b")
        let completedC = correctionFixture(c, id: "completed-c")
        StateSnapshotStore.save(state(session: active, sets: [originalA, originalB], exercises: slots),
                                userID: "user-a", defaults: defaults)
        WorkoutRunnerCheckpointStore.save(.init(date: fixedCivilDate, sessionID: active.id,
            selectedDayID: "day-a", currentSlotID: c.id, skippedSlotIDs: [],
            workoutStartedAtMS: originalA.logged_at, finished: false, sessionAttempt: 0,
            focus: .init(revision: 2, isExplicit: true)), userID: "user-a", defaults: defaults)
        let intent = PendingSetCorrection(id: "delete-a", setID: originalA.id, date: fixedCivilDate,
            slotID: a.id, exerciseID: a.exercise_id, sessionID: active.id, expectedAttempt: 0,
            expectedUpdatedAt: originalA.updated_at, values: nil, runnerFocusRevision: 1,
            runnerGroupRepair: RunnerGroupRepair(groupID: "group-a", day: day(with: slots)))
        SetCorrectionOutboxStore.enqueue(intent, userID: "user-a", defaults: defaults)
        let deletion = corrected(originalA, intent: intent, session: active)
        let entered = SetAsyncLatch(), release = SetAsyncLatch()
        oldAPI.correctionHandler = { _, _ in
            await entered.open()
            await release.wait()
            return deletion
        }
        let sharedAuth = retainedAuth(defaults: defaults)
        let older = SyncModel(auth: sharedAuth, setWriteAPI: oldAPI, defaults: defaults, now: { self.fixedDate })
        let oldDrain = Task { await older.drainWorkoutWriteOutboxes() }
        await entered.wait()
        let newAPI = SetWriteAPIStub()
        newAPI.correctionHandler = { _, _ in deletion }
        let newer = SyncModel(auth: sharedAuth, setWriteAPI: newAPI, defaults: defaults, now: { self.fixedDate })
        newer.replaceState(with: state(session: active, sets: [originalA, originalB, completedC], exercises: slots))
        let checkpoint = try XCTUnwrap(newer.resumableCheckpoint)
        XCTAssertEqual(checkpoint.currentSlotID, d.id)
        XCTAssertEqual(checkpoint.focus?.isExplicit, false)
        XCTAssertNil(checkpoint.groupProgress)
        await release.open()
        await oldDrain.value
        XCTAssertEqual(WorkoutRunnerCheckpointStore.load(userID: "user-a", defaults: defaults), checkpoint)
        XCTAssertEqual(SetCorrectionOutboxStore.load(userID: "user-a", defaults: defaults).count, 1)
        await newer.drainWorkoutWriteOutboxes()
        XCTAssertTrue(newer.setCorrections.isEmpty)
        XCTAssertEqual(newer.resumableCheckpoint?.currentSlotID, a.id)
    }
}

@MainActor
extension SetOutboxTests {
    func testFeedbackEditsSurviveFinalSetReviewCheckpointRelaunchAndRetry() async throws {
        let defaults = defaults()
        let ex = exercise(targetSets: 1)
        let s = session(attempt: 2)
        let api = SetWriteAPIStub()
        configureSuccess(api, exercise: ex, session: s)
        let terminal = SetTerminalAPIStub()
        terminal.feedbackHandler = { _ in throw URLError(.notConnectedToInternet) }
        let model = SyncModel(auth: retainedAuth(defaults: defaults), setWriteAPI: api,
            terminalAPI: terminal, defaults: defaults, now: { self.fixedDate })
        model.replaceState(with: state(session: s, sets: [], exercise: ex))
        prepare(model, exercise: ex, session: s, running: true)
        let target = try XCTUnwrap(model.terminalActionTarget)
        let first = WorkoutFeedback(notes: "Speech draft", perceivedFatigue: 7, expected: .init(notes: nil, perceivedFatigue: nil))
        let edited = WorkoutFeedback(notes: "Typed correction before finishing", perceivedFatigue: 6, expected: .init(notes: nil, perceivedFatigue: nil))
        XCTAssertTrue(model.saveWorkoutFeedback(first, expected: target, previous: nil))
        XCTAssertTrue(model.saveWorkoutFeedback(edited, expected: target, previous: first))
        XCTAssertFalse(model.saveWorkoutFeedback(first, expected: target, previous: first))
        // Actual final-set delivery updates runner focus/checkpoint.
        _ = await model.logSet(ex, weight: 135, reps: 5)
        model.skipRest()
        XCTAssertTrue(model.running)
        XCTAssertTrue(model.finished)
        XCTAssertEqual(WorkoutRunnerCheckpointStore.load(userID: "user-a", defaults: defaults)?.feedback, edited)
        await model.finishWorkout()
        XCTAssertEqual(terminal.feedbackCalls.last!, edited)
        XCTAssertEqual(WorkoutTerminalOutboxStore.load(userID: "user-a", defaults: defaults).intents.first?.feedback, edited)
        // A submitted finish is immutable while its acknowledgement is pending.
        XCTAssertFalse(model.saveWorkoutFeedback(first, expected: target, previous: edited))
        let recoveryAPI = SetWriteAPIStub()
        recoveryAPI.stateHandler = { _ in throw URLError(.notConnectedToInternet) }
        let recoveryTerminal = SetTerminalAPIStub()
        recoveryTerminal.feedbackHandler = { [self] feedback in
            var complete = session(status: "completed", updatedAt: 2_000_000_000_010, attempt: 2)
            complete.notes = feedback?.notes
            complete.perceived_fatigue = feedback?.perceivedFatigue
            return complete
        }
        let recovered = SyncModel(auth: retainedAuth(defaults: defaults), setWriteAPI: recoveryAPI,
            terminalAPI: recoveryTerminal, defaults: defaults, now: { self.fixedDate })
        await recovered.drainWorkoutWriteOutboxes()
        XCTAssertEqual(recoveryTerminal.feedbackCalls.last!, edited)
        XCTAssertTrue(WorkoutTerminalOutboxStore.load(userID: "user-a", defaults: defaults).isEmpty)
        let saved = StateSnapshotStore.load(userID: "user-a", defaults: defaults)?.state.sessions.first
        XCTAssertEqual(saved?.notes, edited.notes)
        XCTAssertEqual(saved?.perceived_fatigue, 6)
    }

    func testDelayedFinishAcknowledgementCannotEraseNewerRecoveredFeedback() async throws {
        let defaults = defaults()
        let ex = exercise()
        let s = session(attempt: 2)
        let terminal = SetTerminalAPIStub()
        var acknowledgement: CheckedContinuation<SessionRow, Never>?
        terminal.feedbackHandler = { _ in await withCheckedContinuation { acknowledgement = $0 } }
        let model = SyncModel(auth: retainedAuth(defaults: defaults), terminalAPI: terminal,
            defaults: defaults, now: { self.fixedDate })
        prepare(model, exercise: ex, session: s, running: true)
        let first = WorkoutFeedback(notes: "First finish", perceivedFatigue: 5)
        XCTAssertTrue(model.saveWorkoutFeedback(first, expected: try XCTUnwrap(model.terminalActionTarget), previous: nil))
        let send = Task { await model.finishWorkout() }
        while acknowledgement == nil { await Task.yield() }
        let old = try XCTUnwrap(WorkoutTerminalOutboxStore.load(userID: "user-a", defaults: defaults).intents.first)
        // A recovered model owns a newer explicit choice, with another id.
        WorkoutTerminalOutboxStore.remove(id: old.id, userID: "user-a", defaults: defaults)
        let newer = WorkoutFeedback(notes: "Newer approved correction", perceivedFatigue: 7)
        let replacement = WorkoutTerminalIntent(id: "newer-choice", action: .finish, date: s.date,
            workoutID: s.workout_id, resolvedSessionID: s.id, deliveryState: .queued,
            failedHTTPStatus: nil, expectedAttempt: 2, feedback: newer)
        WorkoutTerminalOutboxStore.enqueue(replacement, userID: "user-a", defaults: defaults)
        var response = session(status: "completed", updatedAt: 2_000_000_000_010, attempt: 2)
        response.notes = first.notes; response.perceived_fatigue = 5
        acknowledgement?.resume(returning: response)
        await send.value
        XCTAssertEqual(WorkoutTerminalOutboxStore.load(userID: "user-a", defaults: defaults).intents.first, replacement)
    }
}

@MainActor
extension SetOutboxTests {
    func testSkippingInheritedFeedbackLeavesNewerServerWordsUntouched() async throws {
        let defaults = defaults(), terminal = SetTerminalAPIStub()
        let ex = exercise()
        var old = session(attempt: 2)
        old.notes = "Already saved"; old.perceived_fatigue = 3
        terminal.feedbackHandler = { [self] feedback in
            XCTAssertNil(feedback, "Skip must omit feedback even when the read model has existing words")
            var newer = session(status: "completed", updatedAt: 2_000_000_000_010, attempt: 2)
            newer.notes = "Newer server words"; newer.perceived_fatigue = 6
            return newer
        }
        let model = SyncModel(auth: retainedAuth(defaults: defaults), terminalAPI: terminal,
            defaults: defaults, now: { self.fixedDate })
        model.replaceState(with: state(session: old, sets: [], exercise: ex))
        prepare(model, exercise: ex, session: old, running: true)
        XCTAssertEqual(model.currentWorkoutFeedback?.notes, "Already saved")
        await model.finishWorkout()
        XCTAssertEqual(terminal.feedbackCalls.count, 1)
        XCTAssertEqual(model.todaySession?.notes, "Newer server words")
        XCTAssertEqual(model.todaySession?.perceived_fatigue, 6)
        XCTAssertTrue(WorkoutTerminalOutboxStore.load(userID: "user-a", defaults: defaults).isEmpty)
    }

    func testAliasedFeedbackConflictSurvivesRelaunchAndRequiresExplicitChoice() async throws {
        for useMine in [false, true] {
            let defaults = defaults(), terminal = SetTerminalAPIStub(), ex = exercise()
            let old = session(id: "old-alias", attempt: 2)
            var server = session(id: "canonical-session", updatedAt: 2_000_000_000_010, attempt: 2)
            server.notes = "Saved elsewhere"; server.perceived_fatigue = 8
            let serverJSON = try JSONSerialization.jsonObject(with: JSONEncoder().encode(server))
            let body = String(data: try JSONSerialization.data(withJSONObject: [
                "error": "session_feedback_conflict", "current_session": serverJSON]), encoding: .utf8)!
            terminal.feedbackHandler = { _ in throw APIError.http(409, body) }
            let auth = retainedAuth(defaults: defaults)
            let model = SyncModel(auth: auth, terminalAPI: terminal, defaults: defaults, now: { self.fixedDate })
            model.replaceState(with: state(session: old, sets: [], exercise: ex))
            prepare(model, exercise: ex, session: old, running: true)
            XCTAssertTrue(model.saveWorkoutFeedback(.init(notes: "My approved words", perceivedFatigue: 4),
                expected: try XCTUnwrap(model.terminalActionTarget), previous: nil))
            await model.finishWorkout()
            let conflict = try XCTUnwrap(WorkoutTerminalOutboxStore.load(userID: "user-a", defaults: defaults).intents.first)
            XCTAssertEqual(conflict.deliveryState, .failed)
            XCTAssertEqual(conflict.resolvedSessionID, "canonical-session")
            XCTAssertEqual(conflict.feedbackConflict, .init(notes: server.notes, perceivedFatigue: 8))
            XCTAssertEqual(conflict.feedback?.notes, "My approved words")
            await model.retryTerminalIntent(id: conflict.id)
            XCTAssertEqual(terminal.feedbackCalls.count, 1, "Generic Retry cannot bypass the explicit choice")

            let recovery = SetTerminalAPIStub()
            recovery.feedbackHandler = { [self] feedback in
                if useMine {
                    XCTAssertEqual(feedback?.expected, conflict.feedbackConflict)
                    XCTAssertEqual(feedback?.notes, "My approved words")
                } else { XCTAssertNil(feedback) }
                var response = session(id: server.id, status: "completed", updatedAt: 2_000_000_000_020, attempt: 2)
                response.notes = server.notes; response.perceived_fatigue = server.perceived_fatigue
                if let feedback { response.notes = feedback.notes; response.perceived_fatigue = feedback.perceivedFatigue }
                return response
            }
            let recovered = SyncModel(auth: auth, terminalAPI: recovery, defaults: defaults, now: { self.fixedDate })
            await recovered.drainWorkoutWriteOutboxes()
            XCTAssertTrue(recovery.feedbackCalls.isEmpty)
            await recovered.resolveWorkoutFeedbackConflict(id: conflict.id,
                expected: .init(notes: "An older displayed version", perceivedFatigue: 1), useMine: useMine)
            XCTAssertTrue(recovery.feedbackCalls.isEmpty, "A stale review cannot authorize replacing unseen feedback")
            await recovered.resolveWorkoutFeedbackConflict(id: conflict.id, expected: try XCTUnwrap(conflict.feedbackConflict), useMine: useMine)
            XCTAssertEqual(recovery.feedbackCalls.count, 1)
            XCTAssertTrue(WorkoutTerminalOutboxStore.load(userID: "user-a", defaults: defaults).isEmpty)
            XCTAssertEqual(recovered.todaySession?.notes, useMine ? "My approved words" : "Saved elsewhere")
        }
    }

    func testSavingBeforeFirstSetRefreshesFinishTargetAndPersistsFeedback() async throws {
        let defaults = defaults(), terminal = SetTerminalAPIStub(), api = SetWriteAPIStub(), ex = exercise()
        let created = session(status: "planned", attempt: 0)
        api.createHandler = { _, _, _ in created }
        terminal.feedbackHandler = { [self] feedback in
            var complete = session(status: "completed", updatedAt: 2_000_000_000_010, attempt: 0)
            complete.notes = feedback?.notes
            return complete
        }
        let model = SyncModel(auth: retainedAuth(defaults: defaults), setWriteAPI: api,
            terminalAPI: terminal, defaults: defaults, now: { self.fixedDate })
        prepare(model, exercise: ex, running: true)
        let opened = try XCTUnwrap(model.terminalActionTarget)
        XCTAssertTrue(model.saveWorkoutFeedback(.init(notes: "Ended early", perceivedFatigue: nil),
            expected: opened, previous: nil))
        await model.finishWorkout(expected: try XCTUnwrap(model.terminalActionTarget))
        XCTAssertEqual(terminal.feedbackCalls.count, 1)
        XCTAssertEqual(model.todaySession?.notes, "Ended early")
        XCTAssertFalse(model.running)
    }
}

@MainActor
extension SetOutboxTests {
    func testApprovedFeedbackWithoutSetsSurvivesRelaunchAndRemoteTerminalStillWins() async throws {
        for status in ["absent", "planned", "skipped", "discarded", "completed"] {
            let suite = "FeedbackBeforeFirstSet.\(UUID().uuidString)"
            let defaults = LocalPersistence(suiteName: suite)!, ex = exercise(targetSets: 1)
            defer { defaults.removePersistentDomain(forName: suite) }
            let auth = retainedAuth(defaults: defaults)
            let model = SyncModel(auth: auth, defaults: defaults, now: { self.fixedDate })
            prepare(model, exercise: ex, running: true)
            model.skip()
            XCTAssertTrue(model.saveWorkoutFeedback(.init(notes: "Stopped before any set", perceivedFatigue: 8),
                expected: try XCTUnwrap(model.terminalActionTarget), previous: nil))
            // Process-local runner ownership does not survive process death.
            let coldDefaults = LocalPersistence(suiteName: suite)!
            let cold = SyncModel(auth: retainedAuth(defaults: coldDefaults), defaults: coldDefaults, now: { self.fixedDate })
            let server = session(status: status, attempt: 0)
            let live = StateResponse(plan: model.plan, plan_version: 1,
                sessions: status == "absent" ? [] : [server], sets: [], external_events: [],
                external_activities: [], activities: [], server_time: 2_000_000_000_000, planGroupsVersion: 1)
            cold.replaceState(with: live)
            if ["absent", "planned"].contains(status) {
                XCTAssertEqual(cold.resumableCheckpoint?.feedback?.notes, "Stopped before any set", status)
                XCTAssertEqual(cold.todayResolvedDay?.id, "day-a", status)
                cold.resumeWorkout()
                XCTAssertTrue(cold.running, status)
                XCTAssertEqual(cold.currentWorkoutFeedback?.notes, "Stopped before any set", status)
                XCTAssertEqual(WorkoutRunnerCheckpointStore.load(userID: "user-a", defaults: defaults)?.feedback?.notes,
                    "Stopped before any set", status)
            } else {
                XCTAssertFalse(cold.hasResumableWorkout, status)
                XCTAssertNil(WorkoutRunnerCheckpointStore.load(userID: "user-a", defaults: defaults), status)
            }
        }
    }

    func testStaleViewCannotFinishOverNewerLocallyApprovedFeedback() async throws {
        let defaults = defaults(), auth = retainedAuth(defaults: defaults), ex = exercise(), s = session(attempt: 2)
        let terminal = SetTerminalAPIStub()
        terminal.feedbackHandler = { _ in XCTFail("Stale view must not send"); throw URLError(.badServerResponse) }
        let old = SyncModel(auth: auth, terminalAPI: terminal, defaults: defaults, now: { self.fixedDate })
        old.replaceState(with: state(session: s, sets: [], exercise: ex))
        prepare(old, exercise: ex, session: s, running: true)
        XCTAssertTrue(old.saveWorkoutFeedback(.init(notes: "First words", perceivedFatigue: 4),
            expected: try XCTUnwrap(old.terminalActionTarget), previous: nil))
        let oldTarget = try XCTUnwrap(old.terminalActionTarget)
        let newer = SyncModel(auth: auth, defaults: defaults, now: { self.fixedDate })
        newer.replaceState(with: state(session: s, sets: [], exercise: ex))
        newer.resumeWorkout()
        XCTAssertTrue(newer.running)
        XCTAssertTrue(newer.saveWorkoutFeedback(.init(notes: "Newer local words", perceivedFatigue: 5),
            expected: try XCTUnwrap(newer.terminalActionTarget), previous: newer.currentWorkoutFeedback))
        let checkpoint = WorkoutRunnerCheckpointStore.load(userID: "user-a", defaults: defaults)
        await old.finishWorkout(expected: oldTarget)
        XCTAssertTrue(terminal.feedbackCalls.isEmpty)
        XCTAssertTrue(WorkoutTerminalOutboxStore.load(userID: "user-a", defaults: defaults).isEmpty)
        XCTAssertEqual(WorkoutRunnerCheckpointStore.load(userID: "user-a", defaults: defaults), checkpoint)
        XCTAssertEqual(checkpoint?.feedback?.notes, "Newer local words")
    }

    func testOpenFeedbackEditorSurvivesFirstSessionAcknowledgement() async throws {
        let defaults = defaults(), api = SetWriteAPIStub(), ex = exercise(targetSets: 1)
        let entered = SetAsyncLatch(), release = SetAsyncLatch(), created = session(attempt: 0)
        configureSuccess(api, exercise: ex, session: created)
        api.createHandler = { _, _, _ in
            await entered.open(); await release.wait(); return created
        }
        let model = SyncModel(auth: retainedAuth(defaults: defaults), setWriteAPI: api,
            defaults: defaults, now: { self.fixedDate })
        prepare(model, exercise: ex, running: true)
        let write = Task { await model.logSet(ex, weight: 135, reps: 5) }
        await entered.wait()
        let opened = try XCTUnwrap(model.terminalActionTarget)
        XCTAssertNil(opened.sessionID)
        await release.open(); _ = await write.value
        XCTAssertEqual(model.todaySession?.id, created.id)
        XCTAssertTrue(model.saveWorkoutFeedback(.init(notes: "Edited while the set was syncing", perceivedFatigue: 6),
            expected: opened, previous: nil))
        XCTAssertEqual(WorkoutRunnerCheckpointStore.load(userID: "user-a", defaults: defaults)?.feedback?.notes,
            "Edited while the set was syncing")
    }
}

@MainActor
extension SetOutboxTests {
    func testSkippingFeedbackAfterFirstSessionAcknowledgementStillFinishes() async throws {
        let defaults = defaults(), api = SetWriteAPIStub(), terminal = SetTerminalAPIStub(), ex = exercise(targetSets: 1)
        let entered = SetAsyncLatch(), release = SetAsyncLatch(), created = session(attempt: 0)
        configureSuccess(api, exercise: ex, session: created)
        api.createHandler = { _, _, _ in
            await entered.open(); await release.wait(); return created
        }
        terminal.feedbackHandler = { [self] feedback in
            XCTAssertNil(feedback)
            return session(status: "completed", updatedAt: 2_000_000_000_010, attempt: 0)
        }
        let model = SyncModel(auth: retainedAuth(defaults: defaults), setWriteAPI: api,
            terminalAPI: terminal, defaults: defaults, now: { self.fixedDate })
        prepare(model, exercise: ex, running: true)
        let write = Task { await model.logSet(ex, weight: 135, reps: 5) }
        await entered.wait()
        let opened = try XCTUnwrap(model.terminalActionTarget)
        XCTAssertNil(opened.sessionID)
        await release.open(); _ = await write.value
        // End-workout sheet Skip deliberately submits no draft, using the
        // target captured before its pending first set received a session ID.
        await model.finishWorkout(expected: opened)
        XCTAssertEqual(terminal.feedbackCalls.count, 1)
        XCTAssertEqual(model.todaySession?.status, "completed")
        XCTAssertFalse(model.running)
    }
}


extension SetOutboxTests {
    func testMemberActivationRequiresLiveEmptyStateAndRecoversAfterReadFailure() async {
        for error in [URLError(.notConnectedToInternet) as Error, APIError.http(500, "synthetic")] {
            let defaults = defaults()
            let api = SetWriteAPIStub()
            api.stateHandler = { _ in throw error }
            let auth = retainedAuth(defaults: defaults)
            let model = SyncModel(auth: auth, setWriteAPI: api, defaults: defaults)
            XCTAssertFalse(model.hasVerifiedPlanState)
            XCTAssertFalse(model.canCreateRoutine)
            await model.load()
            XCTAssertFalse(model.canCreateRoutine)
            XCTAssertNotNil(model.loadError)
            let empty = StateResponse(plan: nil, plan_version: 0, sessions: [], sets: [],
                external_events: [], external_activities: [], activities: [], server_time: 10)
            api.stateHandler = { _ in empty }
            await model.load()
            XCTAssertTrue(model.hasVerifiedPlanState)
            XCTAssertTrue(model.canCreateRoutine)
            // A later failed refresh must not keep offering empty-account setup.
            api.stateHandler = { _ in throw error }
            await model.load()
            XCTAssertFalse(model.canCreateRoutine)
        }
    }

    func testMemberActivationCachedEmptyIsNotProofOfAnEmptyAccount() async {
        let defaults = defaults()
        let empty = StateResponse(plan: nil, plan_version: 0, sessions: [], sets: [],
            external_events: [], external_activities: [], activities: [], server_time: 10)
        StateSnapshotStore.save(empty, userID: "user-a", defaults: defaults)
        let auth = retainedAuth(defaults: defaults)
        let api = SetWriteAPIStub()
        api.stateHandler = { _ in throw URLError(.notConnectedToInternet) }
        let model = SyncModel(auth: auth, setWriteAPI: api, defaults: defaults)
        XCTAssertTrue(model.isUsingCachedState)
        XCTAssertFalse(model.canCreateRoutine)
        await model.load()
        XCTAssertFalse(model.hasVerifiedPlanState)
        XCTAssertFalse(model.canCreateRoutine)
        // Recovery finds a plan created on another client, preserving its identity.
        let existing = state(session: session(), sets: [], exercise: exercise())
        api.stateHandler = { _ in existing }
        await model.load()
        XCTAssertEqual(model.plan?.id, existing.plan?.id)
        XCTAssertFalse(model.canCreateRoutine)
        auth.signOut()
        XCTAssertFalse(model.canCreateRoutine)
    }
}

extension SetOutboxTests {
    func testSupersetLoadsCarryIntoLaterRoundsWhileOffline() async {
        let defaults = defaults(), api = SetWriteAPIStub()
        api.logHandler = { _, _, _ in throw URLError(.notConnectedToInternet) }
        let first = exercise(targetSets: 2, targetWeight: 100, groupID: "pair", transitionRest: 0)
        let second = exercise(id: "slot-b", exerciseID: "exercise-b", targetSets: 2,
                              targetWeight: 45, groupID: "pair", transitionRest: 0)
        let model = SyncModel(auth: retainedAuth(defaults: defaults), setWriteAPI: api,
                              defaults: defaults, now: { self.fixedDate })
        model.replaceState(with: state(session: session(), sets: [], exercises: [first, second]))
        model.startWorkout()
        model.setWeight(112.5)
        await model.logCurrentSet(expected: first, expectedSetNumber: 1)
        XCTAssertEqual(model.currentExercise?.id, second.id)
        XCTAssertEqual(model.weight, 45)
        model.setWeight(52.5)
        await model.logCurrentSet(expected: second, expectedSetNumber: 1)
        XCTAssertEqual(model.currentExercise?.id, first.id)
        XCTAssertEqual(model.currentSetNumber, 2)
        XCTAssertEqual(model.weight, 112.5)
        await model.drainSetOutbox()
        // Let the same-turn duplicate-tap guard release before another physical set.
        for _ in 0..<100 {
            if !model.isSetEntryBlocked(first) { break }
            await Task.yield()
        }
        XCTAssertFalse(model.isSetEntryBlocked(first))
        await model.logCurrentSet(expected: first, expectedSetNumber: 2)
        XCTAssertEqual(model.currentExercise?.id, second.id)
        XCTAssertEqual(model.weight, 52.5)
        let pending = SetOutboxStore.load(userID: "user-a", defaults: defaults).pending
        XCTAssertEqual(pending.filter { $0.slotID == first.id }.map { $0.body.weight }, [112.5, 112.5])
        XCTAssertEqual(model.exercises.first?.target_weight, 100)
    }

    func testPerExerciseLoadDraftsSurviveNavigationAndColdResume() {
        let defaults = defaults(), auth = retainedAuth(defaults: defaults)
        let first = exercise(targetWeight: 100)
        let second = exercise(id: "slot-b", exerciseID: "exercise-b", targetWeight: 45)
        let active = session()
        do {
            let model = SyncModel(auth: auth, defaults: defaults, now: { self.fixedDate })
            model.replaceState(with: state(session: active, sets: [], exercises: [first, second]))
            model.startWorkout()
            model.setWeight(112.5)
            model.next()
            model.setWeight(52.5)
            model.previous()
            XCTAssertEqual(model.weight, 112.5)
            model.next()
            XCTAssertEqual(model.weight, 52.5)
        }
        let cold = SyncModel(auth: auth, defaults: defaults, now: { self.fixedDate })
        cold.replaceState(with: state(session: active, sets: [], exercises: [first, second]))
        XCTAssertTrue(cold.hasResumableWorkout)
        cold.resumeWorkout()
        XCTAssertEqual(cold.weight, 52.5)
        cold.previous()
        XCTAssertEqual(cold.weight, 112.5)
    }

    func testChangedPrescriptionInvalidatesOnlyItsOwnExerciseDraft() {
        let defaults = defaults()
        let first = exercise(targetWeight: 100)
        let second = exercise(id: "slot-b", exerciseID: "exercise-b", targetWeight: 45)
        let model = SyncModel(auth: retainedAuth(defaults: defaults), defaults: defaults, now: { self.fixedDate })
        model.replaceState(with: state(session: session(), sets: [], exercises: [first, second]))
        model.startWorkout()
        model.setWeight(112.5)
        model.next()
        model.setWeight(52.5)
        let changed = exercise(targetWeight: 80)
        model.replaceState(with: state(session: session(), sets: [], exercises: [changed, second]))
        model.previous()
        XCTAssertEqual(model.weight, 80)
        model.next()
        XCTAssertEqual(model.weight, 52.5)
    }

    func testNewWorkoutAttemptDoesNotInheritPriorLoadDrafts() throws {
        let defaults = defaults(), auth = retainedAuth(defaults: defaults)
        let ex = exercise(targetWeight: 100)
        do {
            let model = SyncModel(auth: auth, defaults: defaults, now: { self.fixedDate })
            model.replaceState(with: state(session: session(updatedAt: 100, attempt: 0), sets: [], exercise: ex))
            model.startWorkout()
            model.setWeight(112.5)
        }
        // Carry durable state across a process boundary without carrying the
        // old model's process-local ownership of the runner's shared artifacts.
        let coldDefaults = self.defaults()
        let checkpoint = try XCTUnwrap(WorkoutRunnerCheckpointStore.load(userID: "user-a", defaults: defaults))
        WorkoutRunnerCheckpointStore.save(checkpoint, userID: "user-a", defaults: coldDefaults)
        let next = SyncModel(auth: retainedAuth(defaults: coldDefaults), defaults: coldDefaults, now: { self.fixedDate })
        next.replaceState(with: state(session: session(status: "planned", updatedAt: 200, attempt: 1), sets: [], exercise: ex))
        XCTAssertFalse(next.hasResumableWorkout)
        next.startWorkout()
        XCTAssertTrue(next.running, next.loadError ?? "New workout did not start")
        XCTAssertEqual(next.weight, 100)
    }
}
