import Foundation
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
    ) async throws -> AccountDeletionResponse { try deletionResult.get() }

    func downloadAccountExport(jwt: String) async throws -> AccountExportFile {
        throw URLError(.badServerResponse)
    }
}

@MainActor
private final class SetWriteAPIStub: SetWriteAPI {
    struct CreateCall: Equatable {
        let date: String
        let dayTemplateID: String?
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
    var stateHandler: ((String) async throws -> StateResponse)?
    private(set) var createCalls: [CreateCall] = []
    private(set) var logCalls: [LogCall] = []
    private(set) var reopenCalls: [(
        sessionID: String,
        dayTemplateID: String?,
        expectedAttempt: Int?,
        jwt: String
    )] = []
    private(set) var deleteCalls: [(setID: String, jwt: String)] = []
    private(set) var stateCalls = 0

    func createSession(
        date: String,
        dayTemplateID: String?,
        jwt: String
    ) async throws -> SessionRow {
        createCalls.append(.init(
            date: date, dayTemplateID: dayTemplateID,
            expectedAttempt: nil, restartDiscardedAttempt: nil, jwt: jwt))
        guard let createHandler else { throw URLError(.badServerResponse) }
        return try await createHandler(date, dayTemplateID, jwt)
    }

    func createSession(
        date: String,
        dayTemplateID: String?,
        expectedAttempt: Int?,
        restartDiscardedAttempt: Int?,
        jwt: String
    ) async throws -> SessionRow {
        createCalls.append(.init(
            date: date, dayTemplateID: dayTemplateID,
            expectedAttempt: expectedAttempt,
            restartDiscardedAttempt: restartDiscardedAttempt,
            jwt: jwt))
        guard let createHandler else { throw URLError(.badServerResponse) }
        return try await createHandler(date, dayTemplateID, jwt)
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
        dayTemplateID: String?,
        expectedAttempt: Int?,
        jwt: String
    ) async throws -> SessionRow {
        reopenCalls.append((sessionId, dayTemplateID, expectedAttempt, jwt))
        guard let reopenHandler else { throw URLError(.badServerResponse) }
        return try await reopenHandler(
            sessionId, dayTemplateID, expectedAttempt, jwt)
    }

    func getState(jwt: String) async throws -> StateResponse {
        stateCalls += 1
        guard let stateHandler else { throw URLError(.badServerResponse) }
        return try await stateHandler(jwt)
    }

    func deleteSet(setId: String, jwt: String) async throws {
        deleteCalls.append((setId, jwt))
        guard let deleteHandler else { throw URLError(.badServerResponse) }
        try await deleteHandler(setId, jwt)
    }
}

@MainActor
private final class SetTerminalAPIStub: WorkoutTerminalAPI {
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

    func getExercises(jwt: String) async throws -> [ExerciseCatalog] {
        try result.get()
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

    private func defaults() -> UserDefaults {
        let name = "SetOutboxTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        defaults.removePersistentDomain(forName: name)
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

    private func auth(
        userID: String = "user-a",
        defaults: UserDefaults,
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

    private func retainedAuth(defaults: UserDefaults) -> AuthModel {
        let model = auth(defaults: defaults)
        retainedAuthModels.append(model)
        return model
    }

    private func exercise(
        id: String = "slot-a",
        exerciseID: String = "exercise-a",
        timed: Bool = false,
        targetSets: Int = 3
    ) -> TemplateExercise {
        TemplateExercise(
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
            target_weight: 100,
            cues: nil,
            exercise_modality: timed ? "timed" : "barbell",
            exercise_laterality: "bilateral",
            exercise_load_mode: "total",
            exercise_demo_slug: nil,
            target_duration_s: timed ? 30 : nil,
            is_warmup: 0)
    }

    private func day(with exercises: [TemplateExercise]) -> DayTemplate {
        DayTemplate(
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
            days: [day(with: [exercise])], meta: nil)
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
            day_template_id: "day-a", updated_at: updatedAt,
            attempt: attempt)
    }

    private func setLog(
        body: SetRequestBody,
        sessionID: String = "session-a"
    ) -> SetLog {
        SetLog(
            id: body.id,
            session_id: sessionID,
            exercise_id: body.exercise_id,
            template_exercise_id: body.template_exercise_id,
            set_index: body.set_index,
            weight: body.weight,
            reps: body.reps,
            rpe: nil,
            is_warmup: body.is_warmup ? 1 : 0,
            logged_at: body.logged_at,
            duration_s: body.duration_s,
            is_timed: body.is_timed ? 1 : 0,
            deleted_at: nil)
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
            days: [day(with: exercises)])
    }

    private func state(
        session: SessionRow,
        sets: [SetLog],
        days: [DayTemplate],
        serverTime: Int = 2_000_000_000_000,
        planName: String = "Plan A"
    ) -> StateResponse {
        StateResponse(
            plan: PlanTree(
                id: "plan-a", name: planName, version: 1,
                days: days, meta: nil),
            plan_version: 1,
            sessions: [session],
            sets: sets,
            external_events: [],
            external_activities: [],
            activities: [],
            server_time: serverTime)
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
            dayTemplateID: "day-a",
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
        model.startTimedSet()

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
            dayTemplateID: "day-a",
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

    func testStaleDayTemplateFallsBackBeforeRetryingSet() async {
        let defaults = defaults()
        let ex = exercise()
        let s = SessionRow(
            id: "session-a", date: fixedCivilDate, status: "in_progress",
            day_template_id: nil)
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
            dayTemplateID: "removed-day-id",
            resolvedSessionID: nil,
            deliveryState: .queued,
            failedHTTPStatus: nil))
        SetOutboxStore.save(outbox, userID: "user-a", defaults: defaults)
        let api = SetWriteAPIStub()
        api.createHandler = { _, dayTemplateID, _ in
            if dayTemplateID != nil { throw APIError.http(422, "unknown_day") }
            let stored = SetOutboxStore.load(
                userID: "user-a", defaults: defaults)
            XCTAssertNil(stored.pending.first?.dayTemplateID)
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

        XCTAssertEqual(api.createCalls.map(\.dayTemplateID), [
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
            dayTemplateID: "day-a",
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
        let model = SyncModel(
            auth: retainedAuth(defaults: defaults), setWriteAPI: api,
            defaults: defaults, now: { self.fixedDate })
        prepare(model, exercise: ex, session: s)

        let firstAttempt = await model.logSet(ex, weight: 135, reps: 5)
        XCTAssertFalse(firstAttempt)
        XCTAssertEqual(model.setOutbox.pending.first?.deliveryState, .failed)
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
            dayTemplateID: "day-a",
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
                dayTemplateID: "day-a",
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
            days: [day(with: [exA, exB])], meta: nil)

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
            dayTemplateID: "day-a",
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

    func testRateLimitRemainsQueuedRatherThanPermanentlyFailed() async {
        let defaults = defaults()
        let ex = exercise()
        let s = session()
        let api = SetWriteAPIStub()
        api.logHandler = { _, _, _ in throw APIError.http(429, "rate_limited") }
        let model = SyncModel(
            auth: retainedAuth(defaults: defaults), setWriteAPI: api,
            defaults: defaults, now: { self.fixedDate })
        prepare(model, exercise: ex, session: s)

        let acknowledged = await model.logSet(ex, weight: 135, reps: 5)

        XCTAssertFalse(acknowledged)
        XCTAssertEqual(model.setOutbox.pending.first?.deliveryState, .queued)
        XCTAssertNil(model.setOutbox.pending.first?.failedHTTPStatus)
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
        await model.drainWorkoutWriteOutboxes()

        XCTAssertEqual(terminalAPI.completeCalls.map(\.jwt), [oldToken, newToken])
        XCTAssertTrue(model.terminalOutbox.isEmpty)
        XCTAssertFalse(model.running)
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
            dayTemplateID: "day-a",
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
            dayTemplateID: "day-a",
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
        model.startTimedSet()

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
            dayTemplateID: "day-a",
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
            dayTemplateID: "day-a",
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

    func testSkippedOverrideReopensBeforeRunnerAndFirstSet() async {
        let defaults = defaults()
        let original = exercise()
        let override = exercise(id: "slot-b", exerciseID: "exercise-b")
        let overrideDay = DayTemplate(
            id: "day-b", name: "Day B", day_label: "B",
            order_index: 1, exercises: [override])
        let skipped = session(
            status: "skipped", updatedAt: 100, attempt: 0)
        let entered = SetAsyncLatch()
        let release = SetAsyncLatch()
        let api = SetWriteAPIStub()
        api.reopenHandler = { sessionID, dayTemplateID, expectedAttempt, _ in
            XCTAssertEqual(sessionID, skipped.id)
            XCTAssertEqual(dayTemplateID, overrideDay.id)
            XCTAssertEqual(expectedAttempt, 0)
            await entered.open()
            await release.wait()
            return SessionRow(
                id: skipped.id,
                date: skipped.date,
                status: "planned",
                day_template_id: overrideDay.id,
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
                    day_template_id: overrideDay.id,
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
            days: [day(with: [original]), overrideDay]))

        model.startOverride(dayID: overrideDay.id)
        await entered.wait()

        XCTAssertTrue(model.isReopeningSkippedWorkout)
        XCTAssertFalse(model.running)
        XCTAssertTrue(api.createCalls.isEmpty)
        await release.open()
        while model.isReopeningSkippedWorkout { await Task.yield() }

        XCTAssertTrue(model.running)
        XCTAssertEqual(model.selectedDayID, overrideDay.id)
        XCTAssertEqual(model.currentExercise?.id, override.id)
        XCTAssertEqual(model.todaySession?.day_template_id, overrideDay.id)
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
            dayTemplateID: "day-a",
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
            dayTemplateID: "day-a",
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
            dayTemplateID: "day-a",
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
        let selectedDay = DayTemplate(
            id: "day-a", name: "Selected Day", day_label: "A",
            order_index: 0, exercises: [first])
        let scheduledDay = DayTemplate(
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
            status: "in_progress", day_template_id: nil)
        let model = SyncModel(
            auth: retainedAuth(defaults: defaults),
            defaults: defaults,
            now: { self.fixedDate })
        model.plan = PlanTree(
            id: "plan-a", name: "Plan A", version: 1,
            days: [selectedDay, scheduledDay], meta: meta)
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
            days: [day(with: [exercise()])],
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

    func testNewestLoadOwnsStateAndSpinnerWhenResponsesInvert() async {
        let defaults = defaults()
        let ex = exercise()
        let api = SetWriteAPIStub()
        let firstEntered = SetAsyncLatch()
        let releaseFirst = SetAsyncLatch()
        let secondEntered = SetAsyncLatch()
        let releaseSecond = SetAsyncLatch()
        api.stateHandler = { [self] _ in
            if api.stateCalls == 1 {
                await firstEntered.open()
                await releaseFirst.wait()
                return state(
                    session: session(status: "planned"), sets: [], exercise: ex)
            }
            await secondEntered.open()
            await releaseSecond.wait()
            return state(
                session: session(status: "completed"), sets: [], exercise: ex)
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
        await secondEntered.wait()

        await releaseFirst.open()
        await first.value
        XCTAssertTrue(model.isLoading, "an older completion cannot hide the newer load")
        XCTAssertNil(model.todaySession, "the superseded response must not apply")

        await releaseSecond.open()
        await second.value
        XCTAssertFalse(model.isLoading)
        XCTAssertEqual(model.todaySession?.status, "completed")
        XCTAssertEqual(
            StateSnapshotStore.load(
                userID: "user-a", defaults: defaults)?.state.sessions.first?.status,
            "completed")
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
            dayTemplateID: "day-a",
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
            dayTemplateID: "day-a",
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
        let overrideDay = DayTemplate(
            id: "day-a", name: "Override", day_label: "A",
            order_index: 0, exercises: [overrideSlot])
        let pinnedDay = DayTemplate(
            id: "day-b", name: "Pinned", day_label: "B",
            order_index: 1, exercises: [])
        let liveSession = SessionRow(
            id: "session-a", date: fixedCivilDate,
            status: "in_progress", day_template_id: pinnedDay.id)
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
            days: [overrideDay, pinnedDay]))

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
            dayTemplateID: "day-a",
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
            days: [day(with: [first, second])], meta: nil)
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
                sets: [], days: [day(with: [ex])],
                serverTime: 9_000, planName: "Stale Plan")
        }
        secondAPI.stateHandler = { [self] _ in
            await secondEntered.open()
            await releaseSecond.wait()
            return state(
                session: session(status: "completed", updatedAt: 400),
                sets: [], days: [day(with: [ex])],
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
                days: [day(with: [ex])], meta: nil),
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
            dayTemplateID: "day-a", resolvedSessionID: active.id,
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
            date: fixedCivilDate, dayTemplateID: "day-a",
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
            now: { self.fixedDate })
        WorkoutRunnerCheckpointStore.save(
            replacement, userID: "user-a", defaults: defaults)

        older.replaceState(with: state(
            session: session(status: "completed", updatedAt: 300),
            sets: [], exercise: ex))

        XCTAssertEqual(
            WorkoutRunnerCheckpointStore.load(
                userID: "user-a", defaults: defaults),
            replacement)
    }

    func testColdRelaunchPreservesUnresolvedRestartAfterCreateFailure() async {
        let defaults = defaults()
        let ex = exercise()
        let discarded = session(
            status: "discarded", updatedAt: 100, attempt: 0)
        var terminal = WorkoutTerminalOutbox()
        terminal.enqueue(.init(
            id: "discard-a", action: .discard, date: fixedCivilDate,
            dayTemplateID: "day-a", resolvedSessionID: discarded.id,
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
        let relaunched = SyncModel(
            auth: sharedAuth, setWriteAPI: liveAPI,
            catalogAPI: SetCatalogAPIStub(), defaults: defaults,
            now: { self.fixedDate })
        await relaunched.load()

        XCTAssertEqual(relaunched.setOutbox.count, 1)
        XCTAssertTrue(relaunched.blocksNewWorkoutStart)
        XCTAssertNotNil(WorkoutRunnerCheckpointStore.load(
            userID: "user-a", defaults: defaults))
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

    func testMountedRunnerFinishesAfterForegroundSettlesTimedOutFinalSet() async {
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

        await model.logCurrentSet()
        XCTAssertTrue(model.running)
        XCTAssertFalse(model.finished)
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

    func testSuccessfulDeleteInvalidatesSnapshotBeforeColdOfflineLaunch() async {
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
        api.deleteHandler = { _, _ in }
        let sharedAuth = retainedAuth(defaults: defaults)
        let model = SyncModel(
            auth: sharedAuth, setWriteAPI: api, defaults: defaults,
            now: { self.fixedDate })
        model.replaceState(with: state(
            session: active, sets: [savedSet], exercise: ex))

        await model.removeSet(savedSet)

        XCTAssertEqual(api.deleteCalls.map(\.setID), [savedSet.id])
        XCTAssertTrue(model.sets.isEmpty)
        XCTAssertNil(StateSnapshotStore.load(
            userID: "user-a", defaults: defaults))

        let cold = SyncModel(
            auth: sharedAuth, defaults: defaults,
            now: { self.fixedDate })
        XCTAssertNil(cold.plan)
        XCTAssertTrue(cold.sets.isEmpty)
        XCTAssertFalse(cold.isUsingCachedState)
    }

    func testConflictAfterDeleteAdoptsNewAttemptWithoutRecreatingInvalidatedSnapshot() async {
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
        api.deleteHandler = { _, _ in }
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
        XCTAssertNil(StateSnapshotStore.load(
            userID: "user-a", defaults: defaults))

        let acknowledged = await model.logSet(ex, weight: 135, reps: 5)

        XCTAssertFalse(acknowledged)
        XCTAssertEqual(api.logCalls.first?.body.expected_attempt, 0)
        XCTAssertTrue(model.setOutbox.isEmpty)
        XCTAssertEqual(model.todaySession?.status, "in_progress")
        XCTAssertEqual(model.todaySession?.attempt, 1)
        XCTAssertFalse(model.running)
        XCTAssertNil(WorkoutRunnerCheckpointStore.load(
            userID: "user-a", defaults: defaults))
        XCTAssertNil(StateSnapshotStore.load(
            userID: "user-a", defaults: defaults))
    }

    func testExplicitRestartAttemptWinsOverCachedDiscardWithoutFollowUpPull() async {
        let defaults = defaults()
        let ex = exercise()
        let discarded = session(
            status: "discarded", updatedAt: 100, attempt: 0)
        var terminal = WorkoutTerminalOutbox()
        terminal.enqueue(.init(
            id: "discard-a", action: .discard, date: fixedCivilDate,
            dayTemplateID: "day-a", resolvedSessionID: discarded.id,
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
            dayTemplateID: "day-a",
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
            dayTemplateID: "day-a", resolvedSessionID: discarded.id,
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
            dayTemplateID: "day-a", resolvedSessionID: nil,
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
            dayTemplateID: "day-a", resolvedSessionID: nil,
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
            dayTemplateID: "day-a", resolvedSessionID: nil,
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
            dayTemplateID: "day-a", resolvedSessionID: current.id,
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
}
