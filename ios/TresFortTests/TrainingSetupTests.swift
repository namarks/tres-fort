import XCTest
@testable import TresFort

@MainActor
final class TrainingSetupTests: XCTestCase {
    private final class TokenStore: AppTokenStore {
        func load() -> String? { nil }
        func save(_ token: String) {}
        func clear() {}
    }
    private final class API: TrainingSetupAPI {
        var state = TrainingProfileState(profile: nil, version: 0, updated_at: nil)
        var loadOverride: (() async throws -> TrainingProfileState)?
        var saveOverride: (() async throws -> TrainingProfileState)?
        var acceptOverride: (() async throws -> StarterWorkoutReceipt)?
        var saves = 0
        var acceptances: [(String, Int)] = []
        func trainingProfile(jwt: String) async throws -> TrainingProfileState {
            if let loadOverride { return try await loadOverride() }; return state
        }
        func saveTrainingProfile(_ profile: TrainingProfile, version: Int, jwt: String) async throws -> TrainingProfileState {
            saves += 1
            if let saveOverride { return try await saveOverride() }
            state = .init(profile: profile, version: version + 1, updated_at: 10)
            return state
        }
        func starterWorkouts(jwt: String) async throws -> StarterWorkoutOptions {
            .init(profile_version: state.version, can_accept: true, workouts: [Self.starter])
        }
        static var starter: StarterWorkout {
            .init(id: "bodyweight-v1", name: "Start moving", explanation: "A repeatable routine", exercises: [])
        }
        func acceptStarter(_ id: String, profileVersion: Int, jwt: String) async throws -> StarterWorkoutReceipt {
            acceptances.append((id, profileVersion))
            if let acceptOverride { return try await acceptOverride() }
            return .init(acknowledged: true, plan_id: "plan", workout_id: "workout", version: 2)
        }
    }
    private func auth(_ defaults: LocalPersistence, user: String = "member-a") throws -> AuthModel {
        let auth = AuthModel(tokenStore: TokenStore(), defaults: defaults)
        auth.userID = user
        let payload = try JSONSerialization.data(withJSONObject: ["sub": user, "exp": 4_000_000_000])
        auth.jwt = "header." + payload.base64EncodedString().replacingOccurrences(of: "=", with: "") + ".signature"
        return auth
    }
    private func persistence() throws -> LocalPersistence {
        let suite = "TrainingSetupTests.\(UUID().uuidString)"
        let value = try XCTUnwrap(LocalPersistence(suiteName: suite))
        addTeardownBlock { value.removePersistentDomain(forName: suite) }
        return value
    }

    func testMultisportDraftSurvivesRelaunchAndSaveReachesCoachContract() async throws {
        let local = try persistence(), auth = try auth(local), api = API()
        let model = TrainingSetupModel(auth: auth, api: api, defaults: local)
        await model.load()
        model.profile.activities = ["weightlifting", "running", "swimming"]
        model.profile.activity_context = "Two runs and a weekend swim"
        let restored = TrainingSetupModel(auth: auth, api: api, defaults: local)
        await restored.load()
        XCTAssertEqual(restored.profile, model.profile)
        let saved = await restored.save(showStarters: true)
        XCTAssertTrue(saved)
        XCTAssertEqual(api.state.profile?.activity_context, "Two runs and a weekend swim")
        XCTAssertEqual(restored.options?.profile_version, 1)
    }

    func testColdReadFailureCannotBecomeAnEmptyAccountOrOverwriteSavedProfile() async throws {
        let local = try persistence(), auth = try auth(local), api = API()
        api.loadOverride = { throw URLError(.notConnectedToInternet) }
        let model = TrainingSetupModel(auth: auth, api: api, defaults: local)
        await model.load()
        XCTAssertFalse(model.ready)
        let saved = await model.save(showStarters: true)
        XCTAssertFalse(saved); XCTAssertEqual(api.saves, 0)
    }

    func testLateSaveAfterAccountChangeDoesNotPublishOrPersistIntoAnotherAccount() async throws {
        let local = try persistence(), auth = try auth(local), api = API()
        let model = TrainingSetupModel(auth: auth, api: api, defaults: local)
        await model.load()
        var reply: CheckedContinuation<TrainingProfileState, Error>?
        api.saveOverride = { try await withCheckedThrowingContinuation { reply = $0 } }
        let task = Task { await model.save(showStarters: true) }
        for _ in 0..<100 where reply == nil { await Task.yield() }
        let continuation = try XCTUnwrap(reply)
        auth.userID = "member-b"
        continuation.resume(returning: .init(profile: .init(), version: 1, updated_at: 10))
        let saved = await task.value
        XCTAssertFalse(saved); XCTAssertNil(model.options)
        XCTAssertNil(local.data(forKey: AccountLocalState.trainingProfileDraftKey(userID: "member-b")))
    }

    func testConflictingSavedProfileRequiresExplicitReload() async throws {
        let local = try persistence(), auth = try auth(local), api = API()
        let model = TrainingSetupModel(auth: auth, api: api, defaults: local)
        await model.load(); model.profile.activities = ["running"]
        var remote = TrainingProfile(); remote.activities = ["swimming"]
        api.state = .init(profile: remote, version: 1, updated_at: 1)
        let restored = TrainingSetupModel(auth: auth, api: api, defaults: local)
        await restored.load()
        XCTAssertTrue(restored.hasConflict)
        XCTAssertEqual(restored.profile.activities, ["running"])
        await restored.load(discardDraft: true)
        XCTAssertFalse(restored.hasConflict)
        XCTAssertEqual(restored.profile.activities, ["swimming"])
    }

    func testLostAcceptanceReplyResumesTheSameRequestAndProfileRemainsEditableAfterward() async throws {
        let local = try persistence(), auth = try auth(local), api = API()
        let model = TrainingSetupModel(auth: auth, api: api, defaults: local)
        await model.load()
        let saved = await model.save(showStarters: true)
        XCTAssertTrue(saved)
        api.acceptOverride = { throw URLError(.networkConnectionLost) }
        await model.accept(API.starter)
        XCTAssertTrue(model.hasUncertainAcceptance)
        api.acceptOverride = nil
        let restored = TrainingSetupModel(auth: auth, api: api, defaults: local)
        await restored.load()
        XCTAssertEqual(api.acceptances.map(\.0), ["bodyweight-v1", "bodyweight-v1"])
        XCTAssertEqual(api.acceptances.map(\.1), [1, 1])
        XCTAssertNotNil(restored.receipt)
        XCTAssertEqual(auth.activityPersistenceGeneration, 1)
        let editor = TrainingSetupModel(auth: auth, api: api, defaults: local)
        await editor.load()
        XCTAssertNil(editor.receipt)
        XCTAssertFalse(editor.hasUncertainAcceptance)
        editor.profile.activities = ["cycling"]
        let edited = await editor.save(showStarters: false)
        XCTAssertTrue(edited)
    }

    func testStarterAcknowledgementRefreshesAccountEvenAfterSheetDismissal() async throws {
        let local = try persistence(), auth = try auth(local), api = API()
        let model = TrainingSetupModel(auth: auth, api: api, defaults: local)
        await model.load()
        _ = await model.save(showStarters: true)
        var reply: CheckedContinuation<StarterWorkoutReceipt, Error>?
        api.acceptOverride = { try await withCheckedThrowingContinuation { reply = $0 } }
        let task = Task { await model.accept(API.starter) }
        for _ in 0..<100 where reply == nil { await Task.yield() }
        let continuation = try XCTUnwrap(reply)
        model.cancel()
        continuation.resume(returning: .init(acknowledged: true, plan_id: "plan", workout_id: "workout", version: 2))
        await task.value
        XCTAssertEqual(auth.activityPersistenceGeneration, 1)
        XCTAssertNil(model.receipt)
    }

    func testProtectedDraftFailurePreventsUnrecoverableStarterWrite() async throws {
        let harness = LocalPersistenceTestHarness()
        addTeardownBlock { harness.cleanup() }
        let local = harness.open(), auth = try auth(local), api = API()
        let model = TrainingSetupModel(auth: auth, api: api, defaults: local)
        await model.load()
        let saved = await model.save(showStarters: true)
        XCTAssertTrue(saved)
        harness.faults.failWrites = true
        await model.accept(API.starter)
        XCTAssertTrue(api.acceptances.isEmpty)
        XCTAssertNotNil(model.error)
    }

    func testDefinitiveStarterConflictRetiresIntentAndAllowsProfileEditing() async throws {
        let local = try persistence(), auth = try auth(local), api = API()
        let model = TrainingSetupModel(auth: auth, api: api, defaults: local)
        await model.load()
        _ = await model.save(showStarters: true)
        api.acceptOverride = { throw APIError.http(409, "training_changed") }
        await model.accept(API.starter)
        XCTAssertTrue(model.hasConflict)
        XCTAssertFalse(model.hasUncertainAcceptance)
        let reopened = TrainingSetupModel(auth: auth, api: api, defaults: local)
        await reopened.load()
        XCTAssertFalse(reopened.hasUncertainAcceptance)
        reopened.profile.activity_context = "A revised weekly routine"
        let saved = await reopened.save(showStarters: false)
        XCTAssertTrue(saved)
        XCTAssertEqual(api.acceptances.count, 1)
    }
}
