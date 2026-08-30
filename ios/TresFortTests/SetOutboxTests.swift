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
        let jwt: String
    }
    struct LogCall: Equatable {
        let sessionID: String
        let body: SetRequestBody
        let jwt: String
    }

    var createHandler: ((String, String?, String) async throws -> SessionRow)?
    var logHandler: ((String, SetRequestBody, String) async throws -> APIClient.SetLogResult)?
    var stateHandler: ((String) async throws -> StateResponse)?
    private(set) var createCalls: [CreateCall] = []
    private(set) var logCalls: [LogCall] = []
    private(set) var stateCalls = 0

    func createSession(
        date: String,
        dayTemplateID: String?,
        jwt: String
    ) async throws -> SessionRow {
        createCalls.append(.init(
            date: date, dayTemplateID: dayTemplateID, jwt: jwt))
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

    func getState(jwt: String) async throws -> StateResponse {
        stateCalls += 1
        guard let stateHandler else { throw URLError(.badServerResponse) }
        return try await stateHandler(jwt)
    }
}

@MainActor
private final class SetTerminalAPIStub: WorkoutTerminalAPI {
    var completeHandler: ((String, String) async throws -> SessionRow)?
    var discardHandler: ((String, String) async throws -> SessionRow)?
    private(set) var completeCalls: [(sessionID: String, jwt: String)] = []
    private(set) var discardCalls: [(sessionID: String, jwt: String)] = []

    func completeSession(sessionId: String, jwt: String) async throws -> SessionRow {
        completeCalls.append((sessionId, jwt))
        guard let completeHandler else { throw URLError(.badServerResponse) }
        return try await completeHandler(sessionId, jwt)
    }

    func discardSession(sessionId: String, jwt: String) async throws -> SessionRow {
        discardCalls.append((sessionId, jwt))
        guard let discardHandler else { throw URLError(.badServerResponse) }
        return try await discardHandler(sessionId, jwt)
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
        date: String? = nil
    ) -> SessionRow {
        SessionRow(
            id: id, date: date ?? fixedCivilDate, status: "in_progress",
            day_template_id: "day-a")
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
        let setObjects: [[String: Any]] = sets.map { row in
            [
                "id": row.id,
                "session_id": row.session_id,
                "exercise_id": row.exercise_id,
                "template_exercise_id": row.template_exercise_id ?? NSNull(),
                "set_index": row.set_index,
                "weight": row.weight,
                "reps": row.reps,
                "rpe": row.rpe ?? NSNull(),
                "is_warmup": row.is_warmup,
                "logged_at": row.logged_at,
                "duration_s": row.duration_s ?? NSNull(),
                "is_timed": row.is_timed ?? NSNull(),
                "deleted_at": row.deleted_at ?? NSNull(),
            ]
        }
        let ex: [String: Any] = [
            "id": exercise.id,
            "exercise_id": exercise.exercise_id,
            "exercise_name": exercise.exercise_name,
            "exercise_unit": exercise.exercise_unit,
            "order_index": exercise.order_index,
            "target_sets": exercise.target_sets,
            "target_reps": exercise.target_reps,
            "target_reps_max": NSNull(),
            "target_rpe": NSNull(),
            "rest_seconds": exercise.rest_seconds,
            "target_weight": exercise.target_weight ?? NSNull(),
            "cues": NSNull(),
            "exercise_modality": exercise.exercise_modality,
            "exercise_laterality": exercise.exercise_laterality ?? NSNull(),
            "exercise_load_mode": exercise.exercise_load_mode ?? NSNull(),
            "exercise_demo_slug": NSNull(),
            "target_duration_s": exercise.target_duration_s ?? NSNull(),
            "is_warmup": exercise.is_warmup ?? 0,
        ]
        let sessionObject: [String: Any] = [
            "id": session.id,
            "date": session.date,
            "status": session.status,
            "day_template_id": session.day_template_id ?? NSNull(),
        ]
        let object: [String: Any] = [
            "plan": [
                "id": "plan-a", "name": "Plan A", "version": 1,
                "meta": NSNull(),
                "days": [[
                    "id": "day-a", "name": "Day A", "day_label": "A",
                    "order_index": 0, "exercises": [ex],
                ]],
            ],
            "plan_version": 1,
            "sessions": [sessionObject],
            "sets": setObjects,
            "external_events": [],
            "external_activities": [],
            "activities": [],
            "server_time": 2_000_000_000_000,
        ]
        let data = try! JSONSerialization.data(withJSONObject: object)
        return try! JSONDecoder().decode(StateResponse.self, from: data)
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
            XCTAssertEqual(
                SetOutboxStore.load(userID: "user-a", defaults: defaults)
                    .pending.first?.body,
                body)
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
        XCTAssertEqual(api.logCalls.first?.body, body)
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
        XCTAssertEqual(api.logCalls.first?.body, body)
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

        XCTAssertEqual(api.logCalls.map(\.body), [body, body])
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

    func testFinishAndDiscardStayGuardedWhileCurrentDateHasPendingIntent() async {
        let defaults = defaults()
        let ex = exercise()
        let s = session()
        let api = SetWriteAPIStub()
        api.logHandler = { _, _, _ in throw URLError(.notConnectedToInternet) }
        let model = SyncModel(
            auth: retainedAuth(defaults: defaults), setWriteAPI: api,
            defaults: defaults, now: { self.fixedDate })
        prepare(model, exercise: ex, session: s, running: true)
        _ = await model.logSet(ex, weight: 135, reps: 5)

        await model.finishWorkout()
        XCTAssertTrue(model.running)
        XCTAssertEqual(model.todaySession?.id, s.id)
        XCTAssertTrue(model.loadError?.contains("queued sets") == true)

        await model.discardWorkout()
        XCTAssertTrue(model.running)
        XCTAssertEqual(model.todaySession?.id, s.id)
        XCTAssertTrue(model.loadError?.contains("queued sets") == true)
    }

    func testDiscardInFlightExcludesSetAndConcurrentFinish() async {
        let defaults = defaults()
        let ex = exercise(timed: true)
        let s = session()
        let auth = auth(defaults: defaults)
        let setAPI = SetWriteAPIStub()
        let terminalAPI = SetTerminalAPIStub()
        let discardEntered = SetAsyncLatch()
        let releaseDiscard = SetAsyncLatch()
        terminalAPI.discardHandler = { _, _ in
            await discardEntered.open()
            await releaseDiscard.wait()
            return s
        }
        terminalAPI.completeHandler = { _, _ in s }
        let model = SyncModel(
            auth: auth,
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
        await model.finishWorkout()

        XCTAssertFalse(acknowledged)
        XCTAssertFalse(model.timedActive)
        XCTAssertTrue(model.setOutbox.isEmpty)
        XCTAssertTrue(
            SetOutboxStore.load(userID: "user-a", defaults: defaults).isEmpty)
        XCTAssertTrue(setAPI.logCalls.isEmpty)
        XCTAssertTrue(terminalAPI.completeCalls.isEmpty)
        XCTAssertEqual(terminalAPI.discardCalls.count, 1)

        auth.signOut()
        await releaseDiscard.open()
        await discard.value
        XCTAssertFalse(model.isTerminalMutationInFlight)
    }
}
