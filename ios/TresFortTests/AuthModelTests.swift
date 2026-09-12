import Foundation
import HealthKit
import XCTest
@testable import TresFort

private final class MemoryTokenStore: AppTokenStore {
    var token: String?

    init(_ token: String? = nil) { self.token = token }
    func save(_ token: String) { self.token = token }
    func load() -> String? { token }
    func clear() { token = nil }
}

private struct AppleAuthCall: Equatable {
    let identityToken: String
    let authorizationCode: String?
    let fullName: String?
}

private final class AuthAPIStub: AuthAPI {
    var authResult: Result<AuthResponse, Error> = .failure(URLError(.badServerResponse))
    var renewalResult: Result<SessionRenewalResponse, Error> =
        .failure(URLError(.badServerResponse))
    var deletionResult: Result<AccountDeletionResponse, Error> =
        .failure(URLError(.badServerResponse))
    var exportResult: Result<AccountExportFile, Error> =
        .failure(URLError(.badServerResponse))
    var authHandler: (() async throws -> AuthResponse)?
    var renewalHandler: ((String) async throws -> SessionRenewalResponse)?
    var deletionHandler: ((String, String) async throws -> AccountDeletionResponse)?
    var exportHandler: ((String) async throws -> AccountExportFile)?
    private(set) var renewalCalls = 0
    private(set) var appleAuthCalls: [AppleAuthCall] = []
    private(set) var deletionCalls = 0
    private(set) var deletionKeys: [String] = []
    private(set) var exportCalls = 0

    func authApple(
        identityToken: String,
        authorizationCode: String?,
        fullName: String?
    ) async throws -> AuthResponse {
        appleAuthCalls.append(AppleAuthCall(
            identityToken: identityToken,
            authorizationCode: authorizationCode,
            fullName: fullName))
        if let authHandler { return try await authHandler() }
        return try authResult.get()
    }

    func authReview(username: String, password: String) async throws -> AuthResponse {
        if let authHandler { return try await authHandler() }
        return try authResult.get()
    }

    func renewAppSession(jwt: String) async throws -> SessionRenewalResponse {
        renewalCalls += 1
        if let renewalHandler { return try await renewalHandler(jwt) }
        return try renewalResult.get()
    }

    func deleteAccount(
        jwt: String,
        idempotencyKey: String
    ) async throws -> AccountDeletionResponse {
        deletionCalls += 1
        deletionKeys.append(idempotencyKey)
        if let deletionHandler {
            return try await deletionHandler(jwt, idempotencyKey)
        }
        return try deletionResult.get()
    }

    func downloadAccountExport(jwt: String) async throws -> AccountExportFile {
        exportCalls += 1
        if let exportHandler { return try await exportHandler(jwt) }
        return try exportResult.get()
    }
}

private final class AppleCredentialCheckerStub: AppleCredentialStateChecking {
    var result: AppAppleCredentialState = .authorized
    var handler: ((String) async -> AppAppleCredentialState)?
    private(set) var checkedUserIDs: [String] = []

    func state(for appleUserID: String) async -> AppAppleCredentialState {
        checkedUserIDs.append(appleUserID)
        if let handler { return await handler(appleUserID) }
        return result
    }
}

private actor AsyncLatch {
    private var isOpen = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func wait() async {
        if isOpen { return }
        await withCheckedContinuation { continuation in
            waiters.append(continuation)
        }
    }

    func open() {
        guard !isOpen else { return }
        isOpen = true
        let continuations = waiters
        waiters.removeAll()
        continuations.forEach { $0.resume() }
    }
}

@MainActor
final class AuthModelTests: XCTestCase {
    private func defaults() -> LocalPersistence {
        let name = "AuthModelTests.\(UUID().uuidString)"
        let defaults = LocalPersistence(suiteName: name)!
        defaults.removePersistentDomain(forName: name)
        addTeardownBlock { [preferences = defaults.preferences, directory = defaults.trainingStore.directory] in
            preferences.removePersistentDomain(forName: name)
            try? FileManager.default.removeItem(at: directory)
        }
        return defaults
    }

    private func jwt(expiration: Date, subject: String = "user-a", review: Bool = false) -> String {
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
            "app_review": review
        ])
        return "\(base64URL(header)).\(base64URL(payload)).signature"
    }

    private func sessionToken(for userID: String) -> String {
        jwt(expiration: Date.distantFuture, subject: userID)
    }

    private func pendingSetIntent(
        id: String = UUID().uuidString,
        slotID: String = "slot-a"
    ) -> PendingSetIntent {
        PendingSetIntent(
            body: SetRequestBody(
                id: id,
                exercise_id: "exercise-a",
                template_exercise_id: slotID,
                set_index: 1,
                weight: 100,
                reps: 5,
                is_warmup: false,
                logged_at: 2_000_000_000_000,
                duration_s: nil,
                is_timed: false),
            date: "2026-08-29",
            workoutID: "day-a",
            resolvedSessionID: "session-a",
            deliveryState: .queued,
            failedHTTPStatus: nil)
    }

    func testLaunchRejectsBearerBoundToDifferentPersistedAccount() {
        let defaults = defaults()
        defaults.set("user-a", forKey: AuthModel.userIDKey)
        let tokens = MemoryTokenStore(sessionToken(for: "user-b"))

        let model = AuthModel(
            api: AuthAPIStub(), tokenStore: tokens, defaults: defaults)

        XCTAssertNil(model.jwt)
        XCTAssertNil(tokens.token)
        XCTAssertEqual(model.userID, "user-a")
        XCTAssertEqual(model.phase, .signedOut)
        XCTAssertNotNil(model.reauthenticationReason)
    }

    func testUninstalledTabViewDoesNotSupersedeMountedModelsStateRequest() throws {
        let defaults = defaults()
        let auth = AuthModel(api: AuthAPIStub(),
            tokenStore: MemoryTokenStore(sessionToken(for: "user-a")), defaults: defaults)
        let ticket = try XCTUnwrap(StateSnapshotStore.reserveStateRequest(
            userID: "user-a", defaults: defaults))
        XCTAssertTrue(StateSnapshotStore.isCurrent(ticket, defaults: defaults))

        // SwiftUI can construct and discard view descriptions without mounting
        // their state. That must not create a competing SyncModel or advance
        // the account snapshot while the installed model's pull is in flight.
        _ = MainTabView(auth: auth, defaults: defaults)

        XCTAssertNil(defaults.string(forKey: StateSyncAccountStore.activeAccountKey))
        XCTAssertTrue(StateSnapshotStore.isCurrent(ticket, defaults: defaults))
    }

    func testLaunchMigratesBearerSubjectIntoMissingAccountPointer() {
        let defaults = defaults()
        let token = sessionToken(for: "user-a")

        let model = AuthModel(
            api: AuthAPIStub(), tokenStore: MemoryTokenStore(token), defaults: defaults)

        XCTAssertEqual(model.jwt, token)
        XCTAssertEqual(model.userID, "user-a")
        XCTAssertEqual(defaults.string(forKey: AuthModel.userIDKey), "user-a")
        XCTAssertEqual(model.phase, .signedIn)
    }

    func testExchangeRejectsBearerForDifferentResponseUser() async {
        let defaults = defaults()
        let tokens = MemoryTokenStore()
        let api = AuthAPIStub()
        api.authResult = .success(response(
            jwt: sessionToken(for: "user-b"),
            userID: "user-a"))
        let model = AuthModel(api: api, tokenStore: tokens, defaults: defaults)

        await model.exchange(identityToken: "apple-a", fullName: nil)

        XCTAssertNil(model.jwt)
        XCTAssertNil(tokens.token)
        XCTAssertNil(model.userID)
        XCTAssertEqual(model.phase, .error("session identity mismatch"))
    }

    func testExchangeForwardsAppleAuthorizationCodeWithoutPersistingIt() async {
        let defaults = defaults()
        let tokens = MemoryTokenStore()
        let api = AuthAPIStub()
        api.authResult = .success(response(
            jwt: sessionToken(for: "user-a"),
            userID: "user-a"))
        let model = AuthModel(api: api, tokenStore: tokens, defaults: defaults)

        await model.exchange(
            identityToken: "apple-identity-token",
            fullName: "Test User",
            appleUserID: "apple-user-a",
            authorizationCode: "single-use-authorization-code")

        XCTAssertEqual(api.appleAuthCalls, [AppleAuthCall(
            identityToken: "apple-identity-token",
            authorizationCode: "single-use-authorization-code",
            fullName: "Test User")])
        XCTAssertEqual(model.phase, .signedIn)
        XCTAssertFalse(defaults.preferences.dictionaryRepresentation().values.contains {
            ($0 as? String) == "single-use-authorization-code"
        })
    }

    func testNativeAppleCredentialWithoutAuthorizationCodeShowsError() {
        let api = AuthAPIStub()
        let model = AuthModel(
            api: api,
            tokenStore: MemoryTokenStore(),
            defaults: defaults())

        model.handleAppleCredential(
            identityToken: "apple-identity-token",
            authorizationCode: nil,
            fullName: nil,
            appleUserID: "apple-user-a")

        XCTAssertEqual(
            model.phase,
            .error(
                "Apple did not provide the authorization code required to sign in. Please try again."))
        XCTAssertTrue(api.appleAuthCalls.isEmpty)
    }

    private func response(jwt: String, userID: String) -> AuthResponse {
        AuthResponse(
            jwt: jwt,
            user: UserDTO(
                id: userID,
                display_name: "Test",
                email: "test@example.com"))
    }

    func testNearExpirySessionRenewsAndKeepsSameAccount() async {
        let now = Date(timeIntervalSince1970: 2_000_000_000)
        let old = jwt(expiration: now.addingTimeInterval(60))
        let fresh = jwt(expiration: now.addingTimeInterval(60 * 24 * 60 * 60))
        let tokenStore = MemoryTokenStore(old)
        let defaults = defaults()
        defaults.set("user-a", forKey: AuthModel.userIDKey)
        let api = AuthAPIStub()
        api.renewalResult = .success(SessionRenewalResponse(jwt: fresh))
        let model = AuthModel(
            api: api, tokenStore: tokenStore, defaults: defaults, now: { now })

        await model.renewSessionIfNeeded()

        XCTAssertEqual(api.renewalCalls, 1)
        XCTAssertEqual(model.jwt, fresh)
        XCTAssertEqual(tokenStore.token, fresh)
        XCTAssertEqual(model.userID, "user-a")
        XCTAssertEqual(model.phase, .signedIn)
    }

    func testFreshSessionSkipsRenewal() async {
        let now = Date(timeIntervalSince1970: 2_000_000_000)
        let fresh = jwt(expiration: now.addingTimeInterval(8 * 24 * 60 * 60))
        let tokenStore = MemoryTokenStore(fresh)
        let api = AuthAPIStub()
        let model = AuthModel(
            api: api, tokenStore: tokenStore, defaults: defaults(), now: { now })

        await model.renewSessionIfNeeded()

        XCTAssertEqual(api.renewalCalls, 0)
        XCTAssertEqual(model.jwt, fresh)
    }

    func testOfflineRenewalFailurePreservesTokenAndSignedInState() async {
        let now = Date(timeIntervalSince1970: 2_000_000_000)
        let old = jwt(expiration: now.addingTimeInterval(60))
        let tokenStore = MemoryTokenStore(old)
        let api = AuthAPIStub()
        api.renewalResult = .failure(URLError(.notConnectedToInternet))
        let model = AuthModel(
            api: api, tokenStore: tokenStore, defaults: defaults(), now: { now })

        await model.renewSessionIfNeeded()

        XCTAssertEqual(model.jwt, old)
        XCTAssertEqual(tokenStore.token, old)
        XCTAssertEqual(model.phase, .signedIn)
    }

    func testStaleRenewalResponseCannotOverwriteSwitchedAccount() async {
        let now = Date(timeIntervalSince1970: 2_000_000_000)
        let tokenA = jwt(expiration: now.addingTimeInterval(60))
        let renewedA = jwt(expiration: now.addingTimeInterval(60 * 24 * 60 * 60))
        let tokenStore = MemoryTokenStore(tokenA)
        let defaults = defaults()
        defaults.set("user-a", forKey: AuthModel.userIDKey)
        let api = AuthAPIStub()
        let started = AsyncLatch()
        let release = AsyncLatch()
        api.renewalHandler = { _ in
            await started.open()
            await release.wait()
            return SessionRenewalResponse(jwt: renewedA)
        }
        let model = AuthModel(
            api: api, tokenStore: tokenStore, defaults: defaults, now: { now })

        let renewal = Task { await model.renewSessionIfNeeded(force: true) }
        await started.wait()
        let tokenB = sessionToken(for: "user-b")
        api.authResult = .success(response(jwt: tokenB, userID: "user-b"))
        await model.exchange(identityToken: "apple-b", fullName: nil)
        await release.open()
        await renewal.value

        XCTAssertEqual(model.jwt, tokenB)
        XCTAssertEqual(tokenStore.token, tokenB)
        XCTAssertEqual(model.userID, "user-b")
        XCTAssertEqual(model.phase, .signedIn)
    }

    func testUnauthorizedRenewalRequiresReauthWithoutDroppingAccountPointer() async {
        let now = Date(timeIntervalSince1970: 2_000_000_000)
        let old = jwt(expiration: now.addingTimeInterval(-1))
        let tokenStore = MemoryTokenStore(old)
        let defaults = defaults()
        defaults.set("user-a", forKey: AuthModel.userIDKey)
        let api = AuthAPIStub()
        api.renewalResult = .failure(APIError.http(401, "invalid_token"))
        let model = AuthModel(
            api: api, tokenStore: tokenStore, defaults: defaults, now: { now })

        await model.renewSessionIfNeeded()

        XCTAssertNil(model.jwt)
        XCTAssertNil(tokenStore.token)
        XCTAssertEqual(model.userID, "user-a")
        XCTAssertEqual(defaults.string(forKey: AuthModel.userIDKey), "user-a")
        XCTAssertEqual(model.phase, .signedOut)
    }

    func testMismatchedRenewalCannotReplaceCurrentAccountSession() async {
        let now = Date(timeIntervalSince1970: 2_000_000_000)
        let tokenA = jwt(
            expiration: now.addingTimeInterval(60),
            subject: "user-a")
        let tokenStore = MemoryTokenStore(tokenA)
        let defaults = defaults()
        defaults.set("user-a", forKey: AuthModel.userIDKey)
        let api = AuthAPIStub()
        api.renewalResult = .success(SessionRenewalResponse(
            jwt: jwt(
                expiration: now.addingTimeInterval(60 * 24 * 60 * 60),
                subject: "user-b")))
        let model = AuthModel(
            api: api, tokenStore: tokenStore, defaults: defaults, now: { now })

        await model.renewSessionIfNeeded(force: true)

        XCTAssertNil(model.jwt)
        XCTAssertNil(tokenStore.token)
        XCTAssertEqual(model.userID, "user-a")
        XCTAssertEqual(defaults.string(forKey: AuthModel.userIDKey), "user-a")
        XCTAssertEqual(model.phase, .signedOut)
        XCTAssertNotNil(model.reauthenticationReason)
    }

    func testRevokedAppleCredentialRequiresRecoverableSameUserSignIn() async {
        let defaults = defaults()
        defaults.set("user-a", forKey: AuthModel.userIDKey)
        defaults.set(
            "apple-user-a",
            forKey: AccountLocalState.appleCredentialUserKey(userID: "user-a"))
        var outbox = ActivityOutbox()
        outbox.enqueue(PendingActivity(
            id: UUID().uuidString,
            date: "2026-08-29",
            type: "walk",
            title: nil,
            duration_minutes: nil,
            notes: nil,
            logged_at: 2_000_000_000_000))
        ActivityOutboxStore.save(outbox, userID: "user-a", defaults: defaults)
        let accountToken = sessionToken(for: "user-a")
        let tokens = MemoryTokenStore(accountToken)
        let checker = AppleCredentialCheckerStub()
        checker.result = .revoked
        let model = AuthModel(
            api: AuthAPIStub(),
            tokenStore: tokens,
            appleCredentialChecker: checker,
            defaults: defaults)

        await model.checkAppleCredentialState()

        XCTAssertEqual(checker.checkedUserIDs, ["apple-user-a"])
        XCTAssertNil(model.jwt)
        XCTAssertNil(tokens.token)
        XCTAssertEqual(model.userID, "user-a")
        XCTAssertEqual(model.appleCredentialUserID, "apple-user-a")
        XCTAssertEqual(model.phase, .signedOut)
        XCTAssertNotNil(model.reauthenticationReason)
        XCTAssertEqual(
            ActivityOutboxStore.load(userID: "user-a", defaults: defaults).count,
            1)
    }

    func testReauthenticationAndOrdinarySignOutRetainAccountSetQueue() {
        let defaults = defaults()
        defaults.set("user-a", forKey: AuthModel.userIDKey)
        var setOutbox = SetOutbox()
        setOutbox.enqueue(pendingSetIntent())
        SetOutboxStore.save(setOutbox, userID: "user-a", defaults: defaults)
        let model = AuthModel(
            api: AuthAPIStub(),
            tokenStore: MemoryTokenStore(sessionToken(for: "user-a")),
            defaults: defaults)

        model.requireReauthentication()
        XCTAssertEqual(
            SetOutboxStore.load(userID: "user-a", defaults: defaults).count,
            1)
        model.signOut()

        XCTAssertNil(model.userID)
        XCTAssertEqual(
            SetOutboxStore.load(userID: "user-a", defaults: defaults).count,
            1)
    }

    func testUnavailableAppleCredentialCheckPreservesUsableSession() async {
        let defaults = defaults()
        defaults.set("user-a", forKey: AuthModel.userIDKey)
        defaults.set(
            "apple-user-a",
            forKey: AccountLocalState.appleCredentialUserKey(userID: "user-a"))
        let accountToken = sessionToken(for: "user-a")
        let tokens = MemoryTokenStore(accountToken)
        let checker = AppleCredentialCheckerStub()
        checker.result = .unavailable
        let model = AuthModel(
            api: AuthAPIStub(),
            tokenStore: tokens,
            appleCredentialChecker: checker,
            defaults: defaults)

        await model.checkAppleCredentialState()

        XCTAssertEqual(model.jwt, accountToken)
        XCTAssertEqual(model.phase, .signedIn)
        XCTAssertNil(model.reauthenticationReason)
    }

    #if DEBUG && targetEnvironment(simulator)
    func testDebugSimulatorPreservesServerAuthenticatedSessionAcrossCredentialChecks() async {
        let defaults = defaults()
        let tokens = MemoryTokenStore()
        let api = AuthAPIStub()
        let token = sessionToken(for: "user-a")
        api.authResult = .success(response(jwt: token, userID: "user-a"))
        // Use the production checker, so this exercises the simulator boundary
        // that previously signed the user straight back out after exchange.
        let model = AuthModel(api: api, tokenStore: tokens, defaults: defaults)

        await model.exchange(
            identityToken: "apple-identity-token",
            fullName: nil,
            appleUserID: "apple-user-a",
            authorizationCode: "single-use-authorization-code")
        await model.checkAppleCredentialState()
        await model.checkAppleCredentialState()

        XCTAssertEqual(api.appleAuthCalls.count, 1)
        XCTAssertEqual(model.jwt, token)
        XCTAssertEqual(tokens.token, token)
        XCTAssertEqual(model.phase, .signedIn)
        XCTAssertNil(model.reauthenticationReason)
    }

    func testDebugSimulatorStillRejectsFailedServerAuthentication() async {
        let tokens = MemoryTokenStore()
        let api = AuthAPIStub()
        api.authResult = .failure(APIError.http(401, "invalid_apple_token"))
        let model = AuthModel(api: api, tokenStore: tokens, defaults: defaults())

        await model.exchange(
            identityToken: "invalid-apple-identity-token",
            fullName: nil,
            appleUserID: "apple-user-a",
            authorizationCode: "single-use-authorization-code")
        await model.checkAppleCredentialState()

        XCTAssertEqual(api.appleAuthCalls.count, 1)
        XCTAssertNil(model.jwt)
        XCTAssertNil(tokens.token)
        guard case .error = model.phase else {
            return XCTFail("Server rejection must keep the simulator signed out")
        }
    }
    #endif

    func testTransferredAppleCredentialPreservesUsableSession() async {
        let defaults = defaults()
        defaults.set("user-a", forKey: AuthModel.userIDKey)
        defaults.set(
            "apple-user-a",
            forKey: AccountLocalState.appleCredentialUserKey(userID: "user-a"))
        let accountToken = sessionToken(for: "user-a")
        let tokens = MemoryTokenStore(accountToken)
        let checker = AppleCredentialCheckerStub()
        checker.result = .transferred
        let model = AuthModel(
            api: AuthAPIStub(),
            tokenStore: tokens,
            appleCredentialChecker: checker,
            defaults: defaults)

        await model.checkAppleCredentialState()

        XCTAssertEqual(model.jwt, accountToken)
        XCTAssertEqual(tokens.token, accountToken)
        XCTAssertEqual(model.userID, "user-a")
        XCTAssertEqual(model.phase, .signedIn)
        XCTAssertNil(model.reauthenticationReason)
    }

    func testStaleAppleCredentialCallbackCannotSignOutSwitchedAccount() async {
        let defaults = defaults()
        defaults.set("user-a", forKey: AuthModel.userIDKey)
        defaults.set(
            "apple-user-a",
            forKey: AccountLocalState.appleCredentialUserKey(userID: "user-a"))
        let tokenA = sessionToken(for: "user-a")
        let tokenStore = MemoryTokenStore(tokenA)
        let checker = AppleCredentialCheckerStub()
        let started = AsyncLatch()
        let release = AsyncLatch()
        checker.handler = { _ in
            await started.open()
            await release.wait()
            return .revoked
        }
        let api = AuthAPIStub()
        let model = AuthModel(
            api: api,
            tokenStore: tokenStore,
            appleCredentialChecker: checker,
            defaults: defaults)

        let check = Task { await model.checkAppleCredentialState() }
        await started.wait()
        let tokenB = sessionToken(for: "user-b")
        api.authResult = .success(response(jwt: tokenB, userID: "user-b"))
        await model.exchange(
            identityToken: "apple-b",
            fullName: nil,
            appleUserID: "apple-user-b")
        await release.open()
        await check.value

        XCTAssertEqual(model.jwt, tokenB)
        XCTAssertEqual(tokenStore.token, tokenB)
        XCTAssertEqual(model.userID, "user-b")
        XCTAssertEqual(model.appleCredentialUserID, "apple-user-b")
        XCTAssertNil(model.reauthenticationReason)
        XCTAssertEqual(model.phase, .signedIn)
    }

    func testSameUserRecoveryAndAccountSwitchKeepOutboxesSeparated() async {
        let defaults = defaults()
        defaults.set("user-a", forKey: AuthModel.userIDKey)
        let pending = PendingActivity(
            id: UUID().uuidString,
            date: "2026-08-29",
            type: "walk",
            title: "Offline walk",
            duration_minutes: 20,
            notes: nil,
            logged_at: 2_000_000_000_000)
        var outbox = ActivityOutbox()
        outbox.enqueue(pending)
        ActivityOutboxStore.save(outbox, userID: "user-a", defaults: defaults)

        let api = AuthAPIStub()
        let tokenStore = MemoryTokenStore()
        let model = AuthModel(api: api, tokenStore: tokenStore, defaults: defaults)

        let sameUserToken = sessionToken(for: "user-a")
        api.authResult = .success(response(jwt: sameUserToken, userID: "user-a"))
        await model.exchange(
            identityToken: "apple-a",
            fullName: nil,
            appleUserID: "apple-user-a")
        XCTAssertEqual(model.appleCredentialUserID, "apple-user-a")
        XCTAssertEqual(
            defaults.string(forKey: AccountLocalState.appleCredentialUserKey(
                userID: "user-a")),
            "apple-user-a")
        XCTAssertEqual(
            ActivityOutboxStore.load(userID: "user-a", defaults: defaults).count, 1)

        let otherUserToken = sessionToken(for: "user-b")
        api.authResult = .success(response(jwt: otherUserToken, userID: "user-b"))
        await model.exchange(
            identityToken: "apple-b",
            fullName: nil,
            appleUserID: "apple-user-b")
        XCTAssertEqual(model.userID, "user-b")
        XCTAssertEqual(model.appleCredentialUserID, "apple-user-b")
        XCTAssertTrue(
            ActivityOutboxStore.load(userID: "user-b", defaults: defaults).isEmpty)
        XCTAssertEqual(
            ActivityOutboxStore.load(userID: "user-a", defaults: defaults).count, 1)
    }

    func testLegacyStateBindsToPersistedAccountBeforeRejectedBearerAndNewSignIn() async {
        let defaults = defaults()
        defaults.set("user-a", forKey: AuthModel.userIDKey)

        var legacyOutbox = ActivityOutbox()
        legacyOutbox.enqueue(PendingActivity(
            id: UUID().uuidString,
            date: "2026-08-29",
            type: "walk",
            title: "Account A walk",
            duration_minutes: 20,
            notes: nil,
            logged_at: 2_000_000_000_000))
        defaults.set(
            try! JSONEncoder().encode(legacyOutbox),
            forKey: ActivityOutboxStore.legacyKey)
        let intervalsA = IntervalsConnection(
            athlete_id: "athlete-a", connected_at: 2_000_000_000_000)
        defaults.set(
            try! JSONEncoder().encode(intervalsA),
            forKey: GroupModel.legacyIntervalsConnectionKey)
        defaults.set(true, forKey: HealthKitSyncModel.legacyEnabledKey)
        let anchorA = Data([1, 2, 3])
        defaults.set(anchorA, forKey: HealthKitSyncModel.legacyAnchorKey)

        // The saved bearer belongs to B and is rejected against A's durable
        // pointer. Legacy data must already be scoped to A before that check.
        let tokens = MemoryTokenStore(sessionToken(for: "user-b"))
        let api = AuthAPIStub()
        let model = AuthModel(api: api, tokenStore: tokens, defaults: defaults)

        XCTAssertNil(model.jwt)
        XCTAssertNil(tokens.token)
        XCTAssertEqual(model.userID, "user-a")
        XCTAssertEqual(
            ActivityOutboxStore.load(userID: "user-a", defaults: defaults).count, 1)
        let migratedIntervals = try! JSONDecoder().decode(
            IntervalsConnection.self,
            from: try! XCTUnwrap(defaults.data(
                forKey: GroupModel.intervalsConnectionKey(userID: "user-a"))))
        XCTAssertEqual(migratedIntervals, intervalsA)
        XCTAssertTrue(defaults.bool(
            forKey: HealthKitSyncModel.enabledKey(userID: "user-a")))
        XCTAssertEqual(
            defaults.data(forKey: HealthKitSyncModel.anchorKey(userID: "user-a")),
            anchorA)
        XCTAssertNil(defaults.data(forKey: ActivityOutboxStore.legacyKey))
        XCTAssertNil(defaults.data(forKey: GroupModel.legacyIntervalsConnectionKey))
        XCTAssertNil(defaults.object(forKey: HealthKitSyncModel.legacyEnabledKey))
        XCTAssertNil(defaults.data(forKey: HealthKitSyncModel.legacyAnchorKey))

        let tokenB = sessionToken(for: "user-b")
        api.authResult = .success(response(jwt: tokenB, userID: "user-b"))
        await model.exchange(
            identityToken: "apple-b",
            fullName: nil,
            appleUserID: "apple-user-b")

        let groupB = GroupModel(auth: model, defaults: defaults)
        let healthB = HealthKitSyncModel(auth: model, defaults: defaults)
        XCTAssertEqual(model.userID, "user-b")
        XCTAssertTrue(groupB.outbox.isEmpty)
        XCTAssertNil(groupB.intervalsConnection)
        XCTAssertFalse(healthB.enabled)
        XCTAssertNil(defaults.data(
            forKey: HealthKitSyncModel.anchorKey(userID: "user-b")))
        XCTAssertEqual(
            ActivityOutboxStore.load(userID: "user-a", defaults: defaults).count, 1)
    }

    func testLegacyOutboxMigratesOnceIntoCurrentAccountNamespace() {
        let defaults = defaults()
        let pending = PendingActivity(
            id: UUID().uuidString,
            date: "2026-08-29",
            type: "walk",
            title: nil,
            duration_minutes: nil,
            notes: nil,
            logged_at: 2_000_000_000_000)
        var outbox = ActivityOutbox()
        outbox.enqueue(pending)
        let data = try! JSONEncoder().encode(outbox)
        defaults.set(data, forKey: ActivityOutboxStore.legacyKey)

        XCTAssertEqual(
            ActivityOutboxStore.load(userID: "user-a", defaults: defaults).count, 1)
        XCTAssertNil(defaults.data(forKey: ActivityOutboxStore.legacyKey))
        XCTAssertTrue(
            ActivityOutboxStore.load(userID: "user-b", defaults: defaults).isEmpty)
    }

    func testHealthKitIntentAndAnchorMigrateIntoOnlyTheCurrentAccount() {
        let defaults = defaults()
        defaults.set("user-a", forKey: AuthModel.userIDKey)
        defaults.set(true, forKey: HealthKitSyncModel.legacyEnabledKey)
        let anchorBytes = Data([1, 2, 3])
        defaults.set(anchorBytes, forKey: HealthKitSyncModel.legacyAnchorKey)
        let authA = AuthModel(
            api: AuthAPIStub(), tokenStore: MemoryTokenStore(), defaults: defaults)

        let healthA = HealthKitSyncModel(auth: authA, defaults: defaults)

        XCTAssertTrue(healthA.enabled)
        XCTAssertEqual(
            defaults.data(forKey: HealthKitSyncModel.anchorKey(userID: "user-a")),
            anchorBytes)
        XCTAssertNil(defaults.object(forKey: HealthKitSyncModel.legacyEnabledKey))
        XCTAssertNil(defaults.data(forKey: HealthKitSyncModel.legacyAnchorKey))

        defaults.set("user-b", forKey: AuthModel.userIDKey)
        let authB = AuthModel(
            api: AuthAPIStub(), tokenStore: MemoryTokenStore(), defaults: defaults)
        let healthB = HealthKitSyncModel(auth: authB, defaults: defaults)
        XCTAssertFalse(healthB.enabled)
        XCTAssertNil(
            defaults.data(forKey: HealthKitSyncModel.anchorKey(userID: "user-b")))
    }

    func testDisconnectClearsInvalidHealthAnchorWithoutErasingTraining() throws {
        let h = LocalPersistenceTestHarness()
        addTeardownBlock { h.cleanup() }
        let local = h.open()
        let auth = AuthModel(api: AuthAPIStub(), tokenStore: MemoryTokenStore(), defaults: local)
        auth.userID = "user-a"
        auth.jwt = sessionToken(for: "user-a")
        let key = HealthKitSyncModel.anchorKey(userID: "user-a")
        let otherKey = HealthKitSyncModel.anchorKey(userID: "user-b")
        let queueKey = SetOutboxStore.scopedKey(userID: "user-a")
        let original = Data("undecodable Health anchor".utf8)
        XCTAssertTrue(local.set(original, forKey: key))
        XCTAssertTrue(local.set(Data([2]), forKey: otherKey))
        XCTAssertTrue(local.set(Data([3]), forKey: queueKey))
        XCTAssertTrue(local.set(true, forKey: HealthKitSyncModel.enabledKey(userID: "user-a")))
        let health = HealthKitSyncModel(auth: auth, defaults: local)
        XCTAssertNil(health.loadAnchor())
        XCTAssertNil(auth.featureJWT)
        XCTAssertFalse(local.retry(userID: "user-a"))

        health.disconnect()

        XCTAssertFalse(health.enabled)
        XCTAssertNil(try h.store.data(forKey: key))
        XCTAssertFalse(local.hasFailure(userID: "user-a"))
        XCTAssertEqual(auth.featureJWT, auth.jwt)
        XCTAssertEqual(h.open().data(forKey: otherKey), Data([2]))
        XCTAssertEqual(h.open().data(forKey: queueKey), Data([3]))
    }

    func testFailedHealthDisconnectKeepsResetReachableAcrossRelaunch() throws {
        let h = LocalPersistenceTestHarness()
        addTeardownBlock { h.cleanup() }
        let local = h.open()
        let auth = AuthModel(api: AuthAPIStub(), tokenStore: MemoryTokenStore(), defaults: local)
        auth.userID = "user-a"
        auth.jwt = sessionToken(for: "user-a")
        let key = HealthKitSyncModel.anchorKey(userID: "user-a")
        let original = Data("undecodable Health anchor".utf8)
        XCTAssertTrue(local.set(original, forKey: key))
        XCTAssertTrue(local.set(true, forKey: HealthKitSyncModel.enabledKey(userID: "user-a")))
        let health = HealthKitSyncModel(auth: auth, defaults: local)
        XCTAssertNil(health.loadAnchor())
        h.faults.failWrites = true

        health.disconnect()

        XCTAssertFalse(health.enabled)
        XCTAssertTrue(health.anchorResetPending)
        XCTAssertNotNil(health.lastError)
        XCTAssertEqual(try h.store.data(forKey: key), original)
        h.faults.failWrites = false
        // A generic write retry must not lose the explicit reset's retry action.
        XCTAssertTrue(local.retry(userID: "user-a"))
        let cold = h.open()
        let replacement = HealthKitSyncModel(auth: auth, defaults: cold)
        XCTAssertFalse(replacement.enabled)
        XCTAssertTrue(replacement.anchorResetPending)
        replacement.disconnect()
        XCTAssertFalse(replacement.anchorResetPending)
        XCTAssertNil(replacement.lastError)
        XCTAssertNil(try h.store.data(forKey: key))
        XCTAssertFalse(h.open().bool(forKey: AccountLocalState.healthResetPendingKey(userID: "user-a")))
    }

    func testDisconnectedHealthSyncCannotRestoreItsAnchorAfterReconnect() throws {
        let h = LocalPersistenceTestHarness()
        addTeardownBlock { h.cleanup() }
        let local = h.open()
        let auth = AuthModel(api: AuthAPIStub(), tokenStore: MemoryTokenStore(), defaults: local)
        auth.userID = "user-a"
        auth.jwt = sessionToken(for: "user-a")
        XCTAssertTrue(local.set(true, forKey: HealthKitSyncModel.enabledKey(userID: "user-a")))
        let old = HealthKitSyncModel(auth: auth, defaults: local)
        let generation = old.syncGeneration
        let anchor = HKQueryAnchor(fromValue: 1)
        XCTAssertTrue(old.saveAnchor(anchor, generation: generation))

        old.disconnect()

        XCTAssertEqual(local.recoveryGeneration, 0, "Ordinary disconnect must keep the current screen mounted")
        XCTAssertFalse(old.saveAnchor(anchor, generation: generation))
        // A fresh model represents the next successful, explicit connection.
        let replacement = HealthKitSyncModel(auth: auth, defaults: local)
        replacement.enabled = true
        XCTAssertFalse(old.saveAnchor(anchor, generation: generation))
        XCTAssertNil(replacement.loadAnchor())
        XCTAssertTrue(replacement.saveAnchor(anchor, generation: replacement.syncGeneration))
        XCTAssertNotNil(replacement.loadAnchor())
    }

    func testAccountExportUsesCurrentFeatureBearer() async {
        let defaults = defaults()
        defaults.set("user-a", forKey: AuthModel.userIDKey)
        let token = sessionToken(for: "user-a")
        let api = AuthAPIStub()
        let expected = AccountExportFile(
            data: Data("{\"schema_version\":1}".utf8),
            filename: "tres-fort-account-export-2026-08-29.json")
        api.exportResult = .success(expected)
        let model = AuthModel(
            api: api,
            tokenStore: MemoryTokenStore(token),
            defaults: defaults)

        do {
            let file = try await model.downloadAccountExport()
            XCTAssertEqual(file, expected)
        } catch {
            XCTFail("account export failed: \(error)")
        }
        XCTAssertEqual(api.exportCalls, 1)
    }

    func testInFlightExportSurvivesSameAccountSessionRenewal() async {
        let defaults = defaults()
        defaults.set("user-a", forKey: AuthModel.userIDKey)
        let oldToken = sessionToken(for: "user-a")
        let renewedToken = jwt(
            expiration: Date.distantFuture.addingTimeInterval(-1),
            subject: "user-a")
        let tokens = MemoryTokenStore(oldToken)
        let api = AuthAPIStub()
        let started = AsyncLatch()
        let release = AsyncLatch()
        let expected = AccountExportFile(
            data: Data("{\"schema_version\":1}".utf8),
            filename: "user-a.json")
        api.exportHandler = { _ in
            await started.open()
            await release.wait()
            return expected
        }
        api.renewalResult = .success(SessionRenewalResponse(jwt: renewedToken))
        let model = AuthModel(api: api, tokenStore: tokens, defaults: defaults)

        let export = Task { try await model.downloadAccountExport() }
        await started.wait()
        await model.renewSessionIfNeeded(force: true)
        await release.open()

        do {
            let file = try await export.value
            XCTAssertEqual(file, expected)
        } catch {
            XCTFail("same-account renewal discarded export: \(error)")
        }
        XCTAssertEqual(model.userID, "user-a")
        XCTAssertEqual(model.jwt, renewedToken)
        XCTAssertEqual(tokens.token, renewedToken)
    }

    func testPendingDeletionCannotExportAccountData() async {
        let defaults = defaults()
        defaults.set("user-a", forKey: AuthModel.userIDKey)
        defaults.set(
            UUID().uuidString,
            forKey: AccountLocalState.accountDeletionKey(userID: "user-a"))
        let api = AuthAPIStub()
        let model = AuthModel(
            api: api,
            tokenStore: MemoryTokenStore(sessionToken(for: "user-a")),
            defaults: defaults)

        do {
            _ = try await model.downloadAccountExport()
            XCTFail("pending deletion unexpectedly exported account data")
        } catch let APIError.http(code, _) {
            XCTAssertEqual(code, 401)
        } catch {
            XCTFail("unexpected error: \(error)")
        }
        XCTAssertEqual(api.exportCalls, 0)
    }

    func testInFlightExportIsDiscardedAfterAccountSwitch() async {
        let defaults = defaults()
        defaults.set("user-a", forKey: AuthModel.userIDKey)
        let tokenA = sessionToken(for: "user-a")
        let api = AuthAPIStub()
        let started = AsyncLatch()
        let release = AsyncLatch()
        api.exportHandler = { _ in
            await started.open()
            await release.wait()
            return AccountExportFile(
                data: Data("{\"account\":\"user-a\"}".utf8),
                filename: "user-a.json")
        }
        let model = AuthModel(
            api: api,
            tokenStore: MemoryTokenStore(tokenA),
            defaults: defaults)

        let export = Task { try await model.downloadAccountExport() }
        await started.wait()
        let tokenB = sessionToken(for: "user-b")
        api.authResult = .success(response(jwt: tokenB, userID: "user-b"))
        await model.exchange(identityToken: "apple-b", fullName: nil)
        await release.open()

        do {
            _ = try await export.value
            XCTFail("stale account export unexpectedly reached the new account")
        } catch let APIError.decoding(message) {
            XCTAssertTrue(message.contains("account changed"))
        } catch {
            XCTFail("unexpected error: \(error)")
        }
        XCTAssertEqual(model.userID, "user-b")
        XCTAssertEqual(model.jwt, tokenB)
        XCTAssertEqual(api.exportCalls, 1)
    }

    func testActivitySaveFailureDoesNotPostAndRetryIsDurableBeforeNetwork() async {
        let h = LocalPersistenceTestHarness()
        addTeardownBlock { h.cleanup() }
        let defaults = h.open()
        defaults.set("user-a", forKey: AuthModel.userIDKey)
        let auth = AuthModel(api: AuthAPIStub(), tokenStore: MemoryTokenStore(sessionToken(for: "user-a")), defaults: defaults)
        let pending = PendingActivity(id: "activity-a", date: "2026-09-10", type: "walk",
                                      title: nil, duration_minutes: 10, notes: nil, logged_at: 2_000_000_000_000)
        var postCount = 0
        let group = GroupModel(auth: auth, defaults: defaults, activityLogger: { activity, _ in
            postCount += 1
            XCTAssertEqual(ActivityOutboxStore.load(userID: "user-a", defaults: defaults).pending.map(\.id), [activity.id])
            throw URLError(.notConnectedToInternet)
        })
        group.selectedGroupID = "group-a"
        h.faults.failWrites = true
        await group.logActivity(pending)
        XCTAssertEqual(postCount, 0)
        XCTAssertTrue(group.feed["group-a"]?.isEmpty ?? true)
        XCTAssertNotNil(group.lastError)
        h.faults.failWrites = false
        XCTAssertTrue(defaults.retry(userID: "user-a"))
        await group.logActivity(pending)
        XCTAssertEqual(postCount, 1)
        XCTAssertEqual(ActivityOutboxStore.load(userID: "user-a", defaults: h.open()).pending.map(\.id), [pending.id])
        XCTAssertEqual(group.feed["group-a"]?.count, 1)
    }

    func testDeletionCleanupFailurePreservesReceiptAndRetriesAfterColdLaunch() async throws {
        let h = LocalPersistenceTestHarness()
        addTeardownBlock { h.cleanup() }
        let defaults = h.open()
        defaults.set("user-a", forKey: AuthModel.userIDKey)
        let tokens = MemoryTokenStore(sessionToken(for: "user-a"))
        let api = AuthAPIStub()
        api.deletionResult = .success(.init(ok: true, owner_tombstoned: false, apple_revocation: .revoked))
        let keyA = SetOutboxStore.scopedKey(userID: "user-a")
        let keyB = SetOutboxStore.scopedKey(userID: "user-b")
        XCTAssertTrue(defaults.set(Data("account A training".utf8), forKey: keyA))
        XCTAssertTrue(defaults.set(Data("account B training".utf8), forKey: keyB))
        let auth = AuthModel(api: api, tokenStore: tokens, defaults: defaults)
        h.faults.failedFiles = [h.store.fileURL(forKey: keyA).lastPathComponent]
        do { try await auth.deleteAccount(); XCTFail("Local cleanup must not be claimed complete") }
        catch { XCTAssertTrue(error.localizedDescription.contains("saved data")) }
        let receipt = try XCTUnwrap(defaults.string(forKey: AccountLocalState.accountDeletionKey(userID: "user-a")))
        XCTAssertTrue(auth.accountDeletionPending)
        XCTAssertEqual(auth.userID, "user-a")
        XCTAssertEqual(auth.jwt, tokens.token)
        XCTAssertNotNil(tokens.token)
        XCTAssertNil(auth.featureJWT)
        XCTAssertEqual(try h.store.data(forKey: keyA), Data("account A training".utf8))

        let cold = AuthModel(api: api, tokenStore: tokens, defaults: h.open())
        XCTAssertTrue(cold.accountDeletionPending)
        h.faults.failedFiles = []
        try await cold.deleteAccount()
        XCTAssertEqual(api.deletionKeys, [receipt, receipt])
        XCTAssertNil(tokens.token)
        XCTAssertNil(cold.userID)
        XCTAssertNil(try h.store.data(forKey: keyA))
        XCTAssertEqual(try h.store.data(forKey: keyB), Data("account B training".utf8))
    }

    func testAcknowledgedDeletionClearsOnlyCurrentAccountLocalState() async {
        let defaults = defaults()
        defaults.set("user-a", forKey: AuthModel.userIDKey)
        defaults.set(true, forKey: AuthModel.onboardedKey)
        let accountToken = sessionToken(for: "user-a")
        let tokens = MemoryTokenStore(accountToken)
        let api = AuthAPIStub()
        api.deletionResult = .success(AccountDeletionResponse(
            ok: true,
            owner_tombstoned: false,
            apple_revocation: .revoked))

        var outboxA = ActivityOutbox()
        outboxA.enqueue(PendingActivity(
            id: UUID().uuidString,
            date: "2026-08-29",
            type: "walk",
            title: nil,
            duration_minutes: nil,
            notes: nil,
            logged_at: 2_000_000_000_000))
        var outboxB = ActivityOutbox()
        outboxB.enqueue(PendingActivity(
            id: UUID().uuidString,
            date: "2026-08-29",
            type: "run",
            title: nil,
            duration_minutes: nil,
            notes: nil,
            logged_at: 2_000_000_000_001))
        ActivityOutboxStore.save(outboxA, userID: "user-a", defaults: defaults)
        ActivityOutboxStore.save(outboxB, userID: "user-b", defaults: defaults)
        var setOutboxA = SetOutbox()
        setOutboxA.enqueue(pendingSetIntent(slotID: "slot-a"))
        var setOutboxB = SetOutbox()
        setOutboxB.enqueue(pendingSetIntent(slotID: "slot-b"))
        SetOutboxStore.save(setOutboxA, userID: "user-a", defaults: defaults)
        SetOutboxStore.save(setOutboxB, userID: "user-b", defaults: defaults)
        var terminalOutboxA = WorkoutTerminalOutbox()
        terminalOutboxA.enqueue(.init(
            id: UUID().uuidString,
            action: .finish,
            date: "2026-08-29",
            workoutID: "day-a",
            resolvedSessionID: "session-a",
            deliveryState: .queued,
            failedHTTPStatus: nil))
        var terminalOutboxB = WorkoutTerminalOutbox()
        terminalOutboxB.enqueue(.init(
            id: UUID().uuidString,
            action: .discard,
            date: "2026-08-29",
            workoutID: "day-b",
            resolvedSessionID: "session-b",
            deliveryState: .queued,
            failedHTTPStatus: nil))
        WorkoutTerminalOutboxStore.save(
            terminalOutboxA, userID: "user-a", defaults: defaults)
        WorkoutTerminalOutboxStore.save(
            terminalOutboxB, userID: "user-b", defaults: defaults)
        defaults.set(Data([1]), forKey: GroupModel.intervalsConnectionKey(userID: "user-a"))
        defaults.set(Data([2]), forKey: GroupModel.intervalsConnectionKey(userID: "user-b"))
        defaults.set(true, forKey: HealthKitSyncModel.enabledKey(userID: "user-a"))
        defaults.set(Data([3]), forKey: HealthKitSyncModel.anchorKey(userID: "user-a"))
        defaults.set(true, forKey: HealthKitSyncModel.enabledKey(userID: "user-b"))

        let model = AuthModel(api: api, tokenStore: tokens, defaults: defaults)
        do {
            try await model.deleteAccount()
        } catch {
            XCTFail("acknowledged deletion failed: \(error)")
        }

        XCTAssertEqual(api.deletionCalls, 1)
        XCTAssertNil(model.jwt)
        XCTAssertNil(model.userID)
        XCTAssertEqual(model.phase, .signedOut)
        XCTAssertFalse(model.onboardingComplete)
        XCTAssertNil(tokens.token)
        XCTAssertNil(defaults.string(forKey: AuthModel.userIDKey))
        XCTAssertNil(defaults.object(forKey: AuthModel.onboardedKey))
        XCTAssertTrue(
            ActivityOutboxStore.load(userID: "user-a", defaults: defaults).isEmpty)
        XCTAssertEqual(
            ActivityOutboxStore.load(userID: "user-b", defaults: defaults).count, 1)
        XCTAssertTrue(
            SetOutboxStore.load(userID: "user-a", defaults: defaults).isEmpty)
        XCTAssertEqual(
            SetOutboxStore.load(userID: "user-b", defaults: defaults).count, 1)
        XCTAssertTrue(
            WorkoutTerminalOutboxStore.load(
                userID: "user-a", defaults: defaults).isEmpty)
        XCTAssertEqual(
            WorkoutTerminalOutboxStore.load(
                userID: "user-b", defaults: defaults).count, 1)
        XCTAssertNil(defaults.data(
            forKey: GroupModel.intervalsConnectionKey(userID: "user-a")))
        XCTAssertEqual(
            defaults.data(forKey: GroupModel.intervalsConnectionKey(userID: "user-b")),
            Data([2]))
        XCTAssertNil(defaults.object(
            forKey: HealthKitSyncModel.enabledKey(userID: "user-a")))
        XCTAssertNil(defaults.data(
            forKey: HealthKitSyncModel.anchorKey(userID: "user-a")))
        XCTAssertTrue(defaults.bool(
            forKey: HealthKitSyncModel.enabledKey(userID: "user-b")))
        XCTAssertNil(defaults.string(
            forKey: AccountLocalState.accountDeletionKey(userID: "user-a")))
        XCTAssertFalse(model.postDeletionAppleRevocationRequired)
    }

    func testManualAppleRevocationHandoffIsOneShotAndDismissalDoesNotAffectAuth() async {
        let defaults = defaults()
        defaults.set("user-a", forKey: AuthModel.userIDKey)
        let tokens = MemoryTokenStore(sessionToken(for: "user-a"))
        let api = AuthAPIStub()
        api.deletionResult = .success(AccountDeletionResponse(
            ok: true,
            owner_tombstoned: false,
            apple_revocation: .manualRequired))
        let model = AuthModel(api: api, tokenStore: tokens, defaults: defaults)

        do {
            try await model.deleteAccount()
        } catch {
            XCTFail("acknowledged deletion failed: \(error)")
        }

        XCTAssertTrue(model.postDeletionAppleRevocationRequired)
        XCTAssertTrue(defaults.bool(
            forKey: AuthModel.postDeletionAppleRevocationKey))
        XCTAssertEqual(model.phase, .signedOut)
        XCTAssertNil(model.jwt)
        XCTAssertNil(model.userID)

        let relaunched = AuthModel(
            api: AuthAPIStub(),
            tokenStore: MemoryTokenStore(),
            defaults: defaults)
        XCTAssertTrue(relaunched.postDeletionAppleRevocationRequired)

        relaunched.dismissPostDeletionAppleRevocationHandoff()

        XCTAssertFalse(relaunched.postDeletionAppleRevocationRequired)
        XCTAssertNil(defaults.object(
            forKey: AuthModel.postDeletionAppleRevocationKey))
        XCTAssertEqual(relaunched.phase, .signedOut)
        XCTAssertNil(relaunched.jwt)
        XCTAssertNil(relaunched.userID)
    }

    func testLegacyDeletionResponseWithoutRevocationOutcomeUsesManualHandoff() async throws {
        let revoked = try JSONDecoder().decode(
            AccountDeletionResponse.self,
            from: Data(
                #"{"ok":true,"owner_tombstoned":false,"apple_revocation":"revoked"}"#.utf8))
        let manual = try JSONDecoder().decode(
            AccountDeletionResponse.self,
            from: Data(
                #"{"ok":true,"owner_tombstoned":false,"apple_revocation":"manual_required"}"#.utf8))
        let decoded = try JSONDecoder().decode(
            AccountDeletionResponse.self,
            from: Data(#"{"ok":true,"owner_tombstoned":false}"#.utf8))
        XCTAssertEqual(revoked.apple_revocation, .revoked)
        XCTAssertEqual(manual.apple_revocation, .manualRequired)
        XCTAssertNil(decoded.apple_revocation)

        let defaults = defaults()
        defaults.set("user-a", forKey: AuthModel.userIDKey)
        let api = AuthAPIStub()
        api.deletionResult = .success(decoded)
        let model = AuthModel(
            api: api,
            tokenStore: MemoryTokenStore(sessionToken(for: "user-a")),
            defaults: defaults)

        try await model.deleteAccount()

        XCTAssertTrue(model.postDeletionAppleRevocationRequired)
        XCTAssertEqual(model.phase, .signedOut)
    }

    func testFailedDeletionPreservesSessionAndQueuedStateForRetry() async {
        let defaults = defaults()
        defaults.set("user-a", forKey: AuthModel.userIDKey)
        defaults.set(true, forKey: AuthModel.onboardedKey)
        let accountToken = sessionToken(for: "user-a")
        let tokens = MemoryTokenStore(accountToken)
        let api = AuthAPIStub()
        api.deletionResult = .failure(URLError(.notConnectedToInternet))
        var outbox = ActivityOutbox()
        outbox.enqueue(PendingActivity(
            id: UUID().uuidString,
            date: "2026-08-29",
            type: "walk",
            title: nil,
            duration_minutes: nil,
            notes: nil,
            logged_at: 2_000_000_000_000))
        ActivityOutboxStore.save(outbox, userID: "user-a", defaults: defaults)
        let model = AuthModel(api: api, tokenStore: tokens, defaults: defaults)

        do {
            try await model.deleteAccount()
            XCTFail("failed deletion unexpectedly succeeded")
        } catch {
            // Expected: no acknowledgement means no local destructive cleanup.
        }

        XCTAssertEqual(api.deletionCalls, 1)
        XCTAssertEqual(model.jwt, accountToken)
        XCTAssertEqual(model.userID, "user-a")
        XCTAssertEqual(model.phase, .signedIn)
        XCTAssertTrue(model.onboardingComplete)
        XCTAssertEqual(tokens.token, accountToken)
        XCTAssertEqual(
            ActivityOutboxStore.load(userID: "user-a", defaults: defaults).count, 1)
        XCTAssertNotNil(defaults.string(
            forKey: AccountLocalState.accountDeletionKey(userID: "user-a")))
    }

    func testLaunchRestoresPendingDeletionAndProtectsRetryBearer() {
        let defaults = defaults()
        defaults.set("user-a", forKey: AuthModel.userIDKey)
        defaults.set(
            "persisted-delete-key",
            forKey: AccountLocalState.accountDeletionKey(userID: "user-a"))
        let accountToken = sessionToken(for: "user-a")
        let tokens = MemoryTokenStore(accountToken)

        let model = AuthModel(
            api: AuthAPIStub(), tokenStore: tokens, defaults: defaults)

        XCTAssertTrue(model.accountDeletionPending)
        model.requireReauthentication()
        XCTAssertEqual(model.jwt, accountToken)
        XCTAssertEqual(tokens.token, accountToken)
        XCTAssertEqual(model.phase, .signedIn)
    }

    func testDeletionRetryReusesIdempotencyKeyAfterLostResponse() async {
        let defaults = defaults()
        defaults.set("user-a", forKey: AuthModel.userIDKey)
        let tokens = MemoryTokenStore(sessionToken(for: "user-a"))
        let api = AuthAPIStub()
        api.deletionHandler = { _, _ in
            if api.deletionCalls == 1 {
                throw URLError(.networkConnectionLost)
            }
            return AccountDeletionResponse(
                ok: true,
                owner_tombstoned: false,
                apple_revocation: .revoked)
        }
        let model = AuthModel(api: api, tokenStore: tokens, defaults: defaults)

        do {
            try await model.deleteAccount()
            XCTFail("lost first response unexpectedly succeeded")
        } catch {
            // The durable local key remains for an exact retry.
        }
        let persisted = defaults.string(
            forKey: AccountLocalState.accountDeletionKey(userID: "user-a"))
        XCTAssertNotNil(persisted)
        XCTAssertTrue(model.accountDeletionPending)

        // A background request can observe the already-committed deletion and
        // receive 401 before this lost DELETE response is retried. Preserve the
        // only bearer capable of replaying the key-bound receipt.
        let pendingToken = model.jwt
        model.requireReauthentication()
        XCTAssertEqual(model.jwt, pendingToken)
        XCTAssertEqual(tokens.token, pendingToken)
        XCTAssertEqual(model.phase, .signedIn)
        model.signOut()
        XCTAssertEqual(model.jwt, pendingToken)
        XCTAssertEqual(model.userID, "user-a")

        do {
            try await model.deleteAccount()
        } catch {
            XCTFail("retry failed: \(error)")
        }

        XCTAssertEqual(api.deletionCalls, 2)
        XCTAssertEqual(api.deletionKeys.count, 2)
        XCTAssertEqual(api.deletionKeys[0], api.deletionKeys[1])
        XCTAssertEqual(api.deletionKeys[0], persisted)
        XCTAssertNil(model.jwt)
        XCTAssertNil(model.userID)
        XCTAssertNil(defaults.string(
            forKey: AccountLocalState.accountDeletionKey(userID: "user-a")))
        XCTAssertFalse(model.accountDeletionPending)
    }

    func testUnauthorizedDeletionAbandonsUnrecognizedRetryKeyAndRequiresReauth() async {
        let defaults = defaults()
        defaults.set("user-a", forKey: AuthModel.userIDKey)
        let tokens = MemoryTokenStore(sessionToken(for: "user-a"))
        let api = AuthAPIStub()
        api.deletionResult = .failure(APIError.http(401, "invalid_token"))
        let model = AuthModel(api: api, tokenStore: tokens, defaults: defaults)

        do {
            try await model.deleteAccount()
            XCTFail("unauthorized deletion unexpectedly succeeded")
        } catch {
            // Expected: the server did not recognize this bearer/key pair.
        }

        XCTAssertFalse(model.accountDeletionPending)
        XCTAssertNil(defaults.string(
            forKey: AccountLocalState.accountDeletionKey(userID: "user-a")))
        XCTAssertNil(model.jwt)
        XCTAssertNil(tokens.token)
        XCTAssertEqual(model.userID, "user-a")
        XCTAssertEqual(model.phase, .signedOut)
    }

    func testDeletionFreshAuthenticationRequirementExplainsNextStep() async {
        let defaults = defaults()
        defaults.set("user-a", forKey: AuthModel.userIDKey)
        let tokens = MemoryTokenStore(sessionToken(for: "user-a"))
        let api = AuthAPIStub()
        api.deletionResult = .failure(APIError.http(
            401, "{\"error\":\"reauthentication_required\"}"))
        let model = AuthModel(api: api, tokenStore: tokens, defaults: defaults)

        do {
            try await model.deleteAccount()
            XCTFail("stale session unexpectedly passed the deletion freshness gate")
        } catch let APIError.http(code, _) {
            XCTAssertEqual(code, 401)
        } catch {
            XCTFail("unexpected error: \(error)")
        }

        XCTAssertFalse(model.accountDeletionPending)
        XCTAssertNil(model.jwt)
        XCTAssertNil(tokens.token)
        XCTAssertEqual(model.userID, "user-a")
        XCTAssertEqual(model.phase, .signedOut)
        XCTAssertEqual(
            model.reauthenticationReason,
            "Sign in with Apple again to confirm account deletion.")
    }

    func testUnknownDeletionReceiptCompletesLocalDeletionForCurrentAccount() async {
        let defaults = defaults()
        defaults.set("user-a", forKey: AuthModel.userIDKey)
        defaults.set(true, forKey: AuthModel.onboardedKey)
        defaults.set(
            "receipt-from-this-device",
            forKey: AccountLocalState.accountDeletionKey(userID: "user-a"))
        defaults.set(
            "apple-user-a",
            forKey: AccountLocalState.appleCredentialUserKey(userID: "user-a"))
        var outbox = ActivityOutbox()
        outbox.enqueue(PendingActivity(
            id: UUID().uuidString,
            date: "2026-08-29",
            type: "walk",
            title: nil,
            duration_minutes: nil,
            notes: nil,
            logged_at: 2_000_000_000_000))
        ActivityOutboxStore.save(outbox, userID: "user-a", defaults: defaults)
        defaults.set(Data([1]), forKey: GroupModel.intervalsConnectionKey(userID: "user-a"))
        defaults.set(true, forKey: HealthKitSyncModel.enabledKey(userID: "user-a"))
        defaults.set(Data([2]), forKey: HealthKitSyncModel.anchorKey(userID: "user-a"))
        let tokens = MemoryTokenStore(sessionToken(for: "user-a"))
        let api = AuthAPIStub()
        api.deletionResult = .failure(APIError.http(
            404, #"{"error":"account_not_found"}"#))
        let model = AuthModel(api: api, tokenStore: tokens, defaults: defaults)

        XCTAssertTrue(model.accountDeletionPending)
        do {
            try await model.deleteAccount()
        } catch {
            XCTFail("already-deleted account did not complete local cleanup: \(error)")
        }

        XCTAssertFalse(model.accountDeletionPending)
        XCTAssertNil(defaults.string(
            forKey: AccountLocalState.accountDeletionKey(userID: "user-a")))
        XCTAssertNil(model.jwt)
        XCTAssertNil(tokens.token)
        XCTAssertNil(model.userID)
        XCTAssertEqual(model.phase, .signedOut)
        XCTAssertFalse(model.onboardingComplete)
        XCTAssertNil(defaults.string(forKey: AuthModel.userIDKey))
        XCTAssertNil(defaults.object(forKey: AuthModel.onboardedKey))
        XCTAssertTrue(
            ActivityOutboxStore.load(userID: "user-a", defaults: defaults).isEmpty)
        XCTAssertNil(defaults.data(
            forKey: GroupModel.intervalsConnectionKey(userID: "user-a")))
        XCTAssertNil(defaults.object(
            forKey: HealthKitSyncModel.enabledKey(userID: "user-a")))
        XCTAssertNil(defaults.data(
            forKey: HealthKitSyncModel.anchorKey(userID: "user-a")))
        XCTAssertNil(defaults.string(
            forKey: AccountLocalState.appleCredentialUserKey(userID: "user-a")))
        XCTAssertTrue(model.postDeletionAppleRevocationRequired)
    }

    func testGenericDeletion404PreservesLocalStateAndRetryCredential() async {
        let defaults = defaults()
        defaults.set("user-a", forKey: AuthModel.userIDKey)
        var outbox = ActivityOutbox()
        outbox.enqueue(PendingActivity(
            id: UUID().uuidString,
            date: "2026-08-29",
            type: "walk",
            title: nil,
            duration_minutes: nil,
            notes: nil,
            logged_at: 2_000_000_000_000))
        ActivityOutboxStore.save(outbox, userID: "user-a", defaults: defaults)
        let token = sessionToken(for: "user-a")
        let tokens = MemoryTokenStore(token)
        let api = AuthAPIStub()
        api.deletionResult = .failure(APIError.http(
            404, #"{"error":"not_found"}"#))
        let model = AuthModel(api: api, tokenStore: tokens, defaults: defaults)

        do {
            try await model.deleteAccount()
            XCTFail("generic 404 unexpectedly authorized local deletion")
        } catch let APIError.http(code, _) {
            XCTAssertEqual(code, 404)
        } catch {
            XCTFail("unexpected error: \(error)")
        }

        XCTAssertTrue(model.accountDeletionPending)
        XCTAssertEqual(model.jwt, token)
        XCTAssertEqual(tokens.token, token)
        XCTAssertEqual(model.userID, "user-a")
        XCTAssertNotNil(defaults.string(
            forKey: AccountLocalState.accountDeletionKey(userID: "user-a")))
        XCTAssertEqual(
            ActivityOutboxStore.load(userID: "user-a", defaults: defaults).count,
            1)
        XCTAssertFalse(model.postDeletionAppleRevocationRequired)
    }

    func testUnknownDeletionReceiptAfterAccountSwitchClearsOnlyInitiator() async {
        let defaults = defaults()
        defaults.set("user-a", forKey: AuthModel.userIDKey)
        let tokens = MemoryTokenStore(sessionToken(for: "user-a"))
        var outboxA = ActivityOutbox()
        outboxA.enqueue(PendingActivity(
            id: UUID().uuidString,
            date: "2026-08-29",
            type: "walk",
            title: nil,
            duration_minutes: nil,
            notes: nil,
            logged_at: 2_000_000_000_000))
        var outboxB = ActivityOutbox()
        outboxB.enqueue(PendingActivity(
            id: UUID().uuidString,
            date: "2026-08-29",
            type: "run",
            title: nil,
            duration_minutes: nil,
            notes: nil,
            logged_at: 2_000_000_000_001))
        ActivityOutboxStore.save(outboxA, userID: "user-a", defaults: defaults)
        ActivityOutboxStore.save(outboxB, userID: "user-b", defaults: defaults)
        defaults.set(true, forKey: HealthKitSyncModel.enabledKey(userID: "user-a"))
        defaults.set(true, forKey: HealthKitSyncModel.enabledKey(userID: "user-b"))

        let api = AuthAPIStub()
        let started = AsyncLatch()
        let release = AsyncLatch()
        api.deletionHandler = { _, _ in
            await started.open()
            await release.wait()
            throw APIError.http(404, #"{"error":"account_not_found"}"#)
        }
        let model = AuthModel(api: api, tokenStore: tokens, defaults: defaults)

        let deletion = Task { try await model.deleteAccount() }
        await started.wait()
        let tokenB = sessionToken(for: "user-b")
        api.authResult = .success(response(jwt: tokenB, userID: "user-b"))
        await model.exchange(
            identityToken: "apple-b",
            fullName: nil,
            appleUserID: "apple-user-b")
        await release.open()
        do {
            try await deletion.value
        } catch {
            XCTFail("already-deleted account did not complete local cleanup: \(error)")
        }

        XCTAssertTrue(
            ActivityOutboxStore.load(userID: "user-a", defaults: defaults).isEmpty)
        XCTAssertEqual(
            ActivityOutboxStore.load(userID: "user-b", defaults: defaults).count, 1)
        XCTAssertNil(defaults.object(
            forKey: HealthKitSyncModel.enabledKey(userID: "user-a")))
        XCTAssertTrue(defaults.bool(
            forKey: HealthKitSyncModel.enabledKey(userID: "user-b")))
        XCTAssertEqual(model.jwt, tokenB)
        XCTAssertEqual(tokens.token, tokenB)
        XCTAssertEqual(model.userID, "user-b")
        XCTAssertEqual(defaults.string(forKey: AuthModel.userIDKey), "user-b")
        XCTAssertEqual(model.phase, .signedIn)
        XCTAssertTrue(model.postDeletionAppleRevocationRequired)
    }

    func testDeletionCompletionIgnoresReplacementAccountsNavigationFailure() async throws {
        let h = LocalPersistenceTestHarness()
        addTeardownBlock { h.cleanup() }
        let local = h.open(), api = AuthAPIStub()
        local.set("user-a", forKey: AuthModel.userIDKey)
        local.set("apple-a", forKey: AccountLocalState.appleCredentialUserKey(userID: "user-a"))
        let tokens = MemoryTokenStore(sessionToken(for: "user-a"))
        let started = AsyncLatch(), release = AsyncLatch()
        api.deletionHandler = { _, _ in
            await started.open(); await release.wait()
            return .init(ok: true, owner_tombstoned: false, apple_revocation: .revoked)
        }
        let model = AuthModel(api: api, tokenStore: tokens, defaults: local)
        let deletion = Task { try await model.deleteAccount() }
        await started.wait()
        let tokenB = sessionToken(for: "user-b")
        api.authResult = .success(response(jwt: tokenB, userID: "user-b"))
        await model.exchange(identityToken: "apple-b", fullName: nil, appleUserID: "apple-b")
        XCTAssertTrue(model.requestEntry(.coach))
        let savedB = try h.store.data(forKey: AuthModel.pendingEntryKey)
        h.faults.failedFiles = [h.store.fileURL(forKey: AuthModel.pendingEntryKey).lastPathComponent]
        XCTAssertFalse(model.requestEntry(.workouts))
        XCTAssertTrue(local.hasFailure(forKey: AuthModel.pendingEntryKey))
        await release.open()
        try await deletion.value
        XCTAssertNil(local.string(forKey: AccountLocalState.accountDeletionKey(userID: "user-a")))
        XCTAssertNil(local.string(forKey: AccountLocalState.appleCredentialUserKey(userID: "user-a")))
        XCTAssertNil(local.object(forKey: AccountLocalState.onboardedKey(userID: "user-a")))
        XCTAssertEqual(model.userID, "user-b")
        XCTAssertEqual(tokens.token, tokenB)
        XCTAssertEqual(try h.store.data(forKey: AuthModel.pendingEntryKey), savedB)
        XCTAssertTrue(local.hasFailure(forKey: AuthModel.pendingEntryKey))
    }

    func testDeletionCompletionAfterAccountSwitchOnlyClearsInitiatingAccount() async {
        let defaults = defaults()
        defaults.set("user-a", forKey: AuthModel.userIDKey)
        let tokens = MemoryTokenStore(sessionToken(for: "user-a"))
        var outboxA = ActivityOutbox()
        outboxA.enqueue(PendingActivity(
            id: UUID().uuidString,
            date: "2026-08-29",
            type: "walk",
            title: nil,
            duration_minutes: nil,
            notes: nil,
            logged_at: 2_000_000_000_000))
        var outboxB = ActivityOutbox()
        outboxB.enqueue(PendingActivity(
            id: UUID().uuidString,
            date: "2026-08-29",
            type: "run",
            title: nil,
            duration_minutes: nil,
            notes: nil,
            logged_at: 2_000_000_000_001))
        ActivityOutboxStore.save(outboxA, userID: "user-a", defaults: defaults)
        ActivityOutboxStore.save(outboxB, userID: "user-b", defaults: defaults)
        let api = AuthAPIStub()
        let started = AsyncLatch()
        let release = AsyncLatch()
        api.deletionHandler = { _, _ in
            await started.open()
            await release.wait()
            return AccountDeletionResponse(
                ok: true,
                owner_tombstoned: false,
                apple_revocation: .manualRequired)
        }
        let model = AuthModel(api: api, tokenStore: tokens, defaults: defaults)

        let deletion = Task { try await model.deleteAccount() }
        await started.wait()
        let tokenB = sessionToken(for: "user-b")
        api.authResult = .success(response(jwt: tokenB, userID: "user-b"))
        await model.exchange(identityToken: "apple-b", fullName: nil)
        await release.open()
        do {
            try await deletion.value
        } catch {
            XCTFail("acknowledged deletion failed: \(error)")
        }

        XCTAssertTrue(
            ActivityOutboxStore.load(userID: "user-a", defaults: defaults).isEmpty)
        XCTAssertEqual(
            ActivityOutboxStore.load(userID: "user-b", defaults: defaults).count, 1)
        XCTAssertNil(defaults.string(
            forKey: AccountLocalState.accountDeletionKey(userID: "user-a")))
        XCTAssertEqual(model.jwt, tokenB)
        XCTAssertEqual(tokens.token, tokenB)
        XCTAssertEqual(model.userID, "user-b")
        XCTAssertEqual(defaults.string(forKey: AuthModel.userIDKey), "user-b")
        XCTAssertEqual(model.phase, .signedIn)
        XCTAssertTrue(model.postDeletionAppleRevocationRequired)
    }

    func testInFlightActivityCannotRecreateOutboxAfterDeletion() async {
        let defaults = defaults()
        defaults.set("user-a", forKey: AuthModel.userIDKey)
        let tokens = MemoryTokenStore(sessionToken(for: "user-a"))
        let api = AuthAPIStub()
        let deletionStarted = AsyncLatch()
        let deletionRelease = AsyncLatch()
        api.deletionHandler = { _, _ in
            await deletionStarted.open()
            await deletionRelease.wait()
            return AccountDeletionResponse(
                ok: true,
                owner_tombstoned: false,
                apple_revocation: .revoked)
        }
        let activityStarted = AsyncLatch()
        let activityRelease = AsyncLatch()
        let auth = AuthModel(
            api: api, tokenStore: tokens, defaults: defaults)
        let group = GroupModel(
            auth: auth,
            defaults: defaults,
            activityLogger: { _, _ in
                await activityStarted.open()
                await activityRelease.wait()
                throw APIError.http(500, "deleted_principal")
            })
        let pending = PendingActivity(
            id: UUID().uuidString,
            date: "2026-08-29",
            type: "walk",
            title: nil,
            duration_minutes: nil,
            notes: nil,
            logged_at: 2_000_000_000_000)

        let logging = Task { await group.logActivity(pending) }
        await activityStarted.wait()
        let deletion = Task { try await auth.deleteAccount() }
        await deletionStarted.wait()
        XCTAssertTrue(auth.accountDeletionPending)
        XCTAssertNil(auth.featureJWT)
        await deletionRelease.open()
        do {
            try await deletion.value
        } catch {
            XCTFail("acknowledged deletion failed: \(error)")
        }
        await activityRelease.open()
        await logging.value

        XCTAssertTrue(
            ActivityOutboxStore.load(
                userID: "user-a", defaults: defaults).isEmpty)
    }

    func testInFlightActivityFailureQueuesAfterSameAccountSessionRenewal() async {
        let now = Date(timeIntervalSince1970: 2_000_000_000)
        let defaults = defaults()
        defaults.set("user-a", forKey: AuthModel.userIDKey)
        let oldToken = jwt(
            expiration: now.addingTimeInterval(60), subject: "user-a")
        let renewedToken = jwt(
            expiration: now.addingTimeInterval(60 * 24 * 60 * 60),
            subject: "user-a")
        let api = AuthAPIStub()
        api.renewalResult = .success(SessionRenewalResponse(jwt: renewedToken))
        let activityStarted = AsyncLatch()
        let activityRelease = AsyncLatch()
        let auth = AuthModel(
            api: api,
            tokenStore: MemoryTokenStore(oldToken),
            defaults: defaults,
            now: { now })
        let group = GroupModel(
            auth: auth,
            defaults: defaults,
            activityLogger: { _, token in
                XCTAssertEqual(token, oldToken)
                await activityStarted.open()
                await activityRelease.wait()
                throw APIError.http(500, "temporary_failure")
            })
        let pending = PendingActivity(
            id: UUID().uuidString,
            date: "2026-08-29",
            type: "walk",
            title: nil,
            duration_minutes: nil,
            notes: nil,
            logged_at: 2_000_000_000_000)

        let logging = Task { await group.logActivity(pending) }
        await activityStarted.wait()
        await auth.renewSessionIfNeeded(force: true)
        XCTAssertEqual(auth.featureJWT, renewedToken)
        await activityRelease.open()
        await logging.value

        XCTAssertEqual(group.outbox.count, 1)
        XCTAssertEqual(group.outbox.pending.first?.id, pending.id)
        XCTAssertEqual(
            ActivityOutboxStore.load(userID: "user-a", defaults: defaults)
                .pending.first?.id,
            pending.id)
        XCTAssertEqual(auth.featureJWT, renewedToken)
        XCTAssertEqual(auth.phase, .signedIn)
    }

    func testGroupLoadAcceptsResponseAfterSameAccountSessionRenewal() async {
        let now = Date(timeIntervalSince1970: 2_000_000_000)
        let defaults = defaults()
        defaults.set("user-a", forKey: AuthModel.userIDKey)
        let oldToken = jwt(
            expiration: now.addingTimeInterval(60), subject: "user-a")
        let renewedToken = jwt(
            expiration: now.addingTimeInterval(60 * 24 * 60 * 60),
            subject: "user-a")
        let api = AuthAPIStub()
        api.renewalResult = .success(SessionRenewalResponse(jwt: renewedToken))
        let auth = AuthModel(
            api: api,
            tokenStore: MemoryTokenStore(oldToken),
            defaults: defaults,
            now: { now })
        let loadStarted = AsyncLatch()
        let loadRelease = AsyncLatch()
        let group = GroupModel(
            auth: auth,
            defaults: defaults,
            groupLister: { token in
                XCTAssertEqual(token, oldToken)
                await loadStarted.open()
                await loadRelease.wait()
                return []
            },
            profileLoader: { token in
                XCTAssertEqual(token, renewedToken)
                return MeProfile(
                    display_name: nil,
                    email: nil,
                    intervals: .init(
                        connected: false,
                        athlete_id: nil,
                        needs_reauth: nil),
                    claude: .init(
                        is_owner: false,
                        connected: false,
                        last_active: nil),
                    health: nil)
            })

        let loading = Task { await group.load() }
        await loadStarted.wait()
        await auth.renewSessionIfNeeded(force: true)
        XCTAssertEqual(auth.featureJWT, renewedToken)
        await loadRelease.open()
        await loading.value

        XCTAssertEqual(group.phase, .none)
        XCTAssertNil(group.lastError)
        XCTAssertEqual(auth.featureJWT, renewedToken)
        XCTAssertEqual(auth.phase, .signedIn)
    }

    func testGroupLoadRetriesOldBearer401AfterSameAccountRenewal() async {
        let now = Date(timeIntervalSince1970: 2_000_000_000)
        let defaults = defaults()
        defaults.set("user-a", forKey: AuthModel.userIDKey)
        let oldToken = jwt(
            expiration: now.addingTimeInterval(60), subject: "user-a")
        let renewedToken = jwt(
            expiration: now.addingTimeInterval(60 * 24 * 60 * 60),
            subject: "user-a")
        let api = AuthAPIStub()
        api.renewalResult = .success(SessionRenewalResponse(jwt: renewedToken))
        let auth = AuthModel(
            api: api,
            tokenStore: MemoryTokenStore(oldToken),
            defaults: defaults,
            now: { now })
        let loadStarted = AsyncLatch()
        let loadRelease = AsyncLatch()
        var listCalls = 0
        let group = GroupModel(
            auth: auth,
            defaults: defaults,
            groupLister: { token in
                listCalls += 1
                if token == oldToken {
                    await loadStarted.open()
                    await loadRelease.wait()
                    throw APIError.http(401, "invalid_token")
                }
                XCTAssertEqual(token, renewedToken)
                return []
            },
            profileLoader: { token in
                XCTAssertEqual(token, renewedToken)
                return MeProfile(
                    display_name: nil,
                    email: nil,
                    intervals: .init(
                        connected: false,
                        athlete_id: nil,
                        needs_reauth: nil),
                    claude: .init(
                        is_owner: false,
                        connected: false,
                        last_active: nil),
                    health: nil)
            })

        let loading = Task { await group.load() }
        await loadStarted.wait()
        await auth.renewSessionIfNeeded(force: true)
        await loadRelease.open()
        await loading.value

        XCTAssertEqual(listCalls, 2)
        XCTAssertEqual(group.phase, .none)
        XCTAssertNil(group.lastError)
        XCTAssertEqual(auth.featureJWT, renewedToken)
        XCTAssertEqual(auth.phase, .signedIn)
    }

    func testActivityOutboxSuccessFinalizesAfterSameAccountSessionRenewal() async {
        let now = Date(timeIntervalSince1970: 2_000_000_000)
        let defaults = defaults()
        defaults.set("user-a", forKey: AuthModel.userIDKey)
        let oldToken = jwt(
            expiration: now.addingTimeInterval(60), subject: "user-a")
        let renewedToken = jwt(
            expiration: now.addingTimeInterval(60 * 24 * 60 * 60),
            subject: "user-a")
        let api = AuthAPIStub()
        api.renewalResult = .success(SessionRenewalResponse(jwt: renewedToken))
        let auth = AuthModel(
            api: api,
            tokenStore: MemoryTokenStore(oldToken),
            defaults: defaults,
            now: { now })
        let pending = PendingActivity(
            id: UUID().uuidString,
            date: "2026-08-31",
            type: "walk",
            title: nil,
            duration_minutes: 30,
            notes: nil,
            logged_at: 2_000_000_000_000)
        var seeded = ActivityOutbox()
        seeded.enqueue(pending)
        ActivityOutboxStore.save(
            seeded, userID: "user-a", defaults: defaults)
        let sendStarted = AsyncLatch()
        let sendRelease = AsyncLatch()
        let group = GroupModel(
            auth: auth,
            defaults: defaults,
            activityLogger: { entry, token in
                XCTAssertEqual(entry.id, pending.id)
                XCTAssertEqual(token, oldToken)
                await sendStarted.open()
                await sendRelease.wait()
                return ActivityRow(
                    id: entry.id,
                    user_id: "user-a",
                    date: entry.date,
                    type: entry.type,
                    title: entry.title,
                    duration_minutes: entry.duration_minutes,
                    notes: entry.notes,
                    logged_at: entry.logged_at,
                    source: "manual",
                    deleted_at: nil)
            })
        var persistedCallbacks = 0
        group.onActivityPersisted = { persistedCallbacks += 1 }

        let draining = Task { await group.drainOutbox() }
        await sendStarted.wait()
        await auth.renewSessionIfNeeded(force: true)
        await sendRelease.open()
        await draining.value

        XCTAssertTrue(group.outbox.isEmpty)
        XCTAssertTrue(ActivityOutboxStore.load(
            userID: "user-a", defaults: defaults).isEmpty)
        XCTAssertEqual(persistedCallbacks, 1)
        XCTAssertEqual(auth.featureJWT, renewedToken)
        XCTAssertEqual(auth.phase, .signedIn)
    }

    func testActivityOutboxOldBearer401PreservesRenewedSessionAndQueue() async {
        let now = Date(timeIntervalSince1970: 2_000_000_000)
        let defaults = defaults()
        defaults.set("user-a", forKey: AuthModel.userIDKey)
        let oldToken = jwt(
            expiration: now.addingTimeInterval(60), subject: "user-a")
        let renewedToken = jwt(
            expiration: now.addingTimeInterval(60 * 24 * 60 * 60),
            subject: "user-a")
        let api = AuthAPIStub()
        api.renewalResult = .success(SessionRenewalResponse(jwt: renewedToken))
        let auth = AuthModel(
            api: api,
            tokenStore: MemoryTokenStore(oldToken),
            defaults: defaults,
            now: { now })
        let pending = PendingActivity(
            id: UUID().uuidString,
            date: "2026-08-31",
            type: "walk",
            title: nil,
            duration_minutes: 30,
            notes: nil,
            logged_at: 2_000_000_000_000)
        var seeded = ActivityOutbox()
        seeded.enqueue(pending)
        ActivityOutboxStore.save(
            seeded, userID: "user-a", defaults: defaults)
        let sendStarted = AsyncLatch()
        let sendRelease = AsyncLatch()
        let group = GroupModel(
            auth: auth,
            defaults: defaults,
            activityLogger: { _, token in
                XCTAssertEqual(token, oldToken)
                await sendStarted.open()
                await sendRelease.wait()
                throw APIError.http(401, "invalid_token")
            })

        let draining = Task { await group.drainOutbox() }
        await sendStarted.wait()
        await auth.renewSessionIfNeeded(force: true)
        await sendRelease.open()
        await draining.value

        XCTAssertEqual(group.outbox.count, 1)
        XCTAssertEqual(ActivityOutboxStore.load(
            userID: "user-a", defaults: defaults).count, 1)
        XCTAssertEqual(auth.featureJWT, renewedToken)
        XCTAssertEqual(auth.phase, .signedIn)
    }

    func testOldActivityDrainCannotOverwriteNewSameUserReauthQueue() async {
        let defaults = defaults()
        defaults.set("user-a", forKey: AuthModel.userIDKey)
        let oldToken = sessionToken(for: "user-a")
        let newToken = jwt(
            expiration: Date(timeIntervalSince1970: 2_100_000_000),
            subject: "user-a")
        let api = AuthAPIStub()
        let auth = AuthModel(
            api: api,
            tokenStore: MemoryTokenStore(oldToken),
            defaults: defaults)
        let oldPending = PendingActivity(
            id: UUID().uuidString,
            date: "2026-08-31",
            type: "walk",
            title: nil,
            duration_minutes: 30,
            notes: nil,
            logged_at: 2_000_000_000_000)
        let newPending = PendingActivity(
            id: UUID().uuidString,
            date: "2026-08-31",
            type: "run",
            title: nil,
            duration_minutes: 20,
            notes: nil,
            logged_at: 2_000_000_000_001)
        var seeded = ActivityOutbox()
        seeded.enqueue(oldPending)
        ActivityOutboxStore.save(
            seeded, userID: "user-a", defaults: defaults)
        let oldSendStarted = AsyncLatch()
        let oldSendRelease = AsyncLatch()
        let oldGroup = GroupModel(
            auth: auth,
            defaults: defaults,
            activityLogger: { entry, token in
                XCTAssertEqual(entry.id, oldPending.id)
                XCTAssertEqual(token, oldToken)
                await oldSendStarted.open()
                await oldSendRelease.wait()
                return ActivityRow(
                    id: entry.id,
                    user_id: "user-a",
                    date: entry.date,
                    type: entry.type,
                    title: entry.title,
                    duration_minutes: entry.duration_minutes,
                    notes: entry.notes,
                    logged_at: entry.logged_at,
                    source: "manual",
                    deleted_at: nil)
            })

        let oldDrain = Task { await oldGroup.drainOutbox() }
        await oldSendStarted.wait()

        auth.signOut()
        api.authResult = .success(response(jwt: newToken, userID: "user-a"))
        await auth.exchange(identityToken: "apple-a", fullName: nil)
        XCTAssertEqual(auth.featureJWT, newToken)
        let newGroup = GroupModel(
            auth: auth,
            defaults: defaults,
            activityLogger: { entry, token in
                XCTAssertEqual(entry.id, newPending.id)
                XCTAssertEqual(token, newToken)
                throw URLError(.notConnectedToInternet)
            })
        await newGroup.logActivity(newPending)
        XCTAssertEqual(Set(newGroup.outbox.pending.map(\.id)),
                       Set([oldPending.id, newPending.id]))

        await oldSendRelease.open()
        await oldDrain.value

        let durable = ActivityOutboxStore.load(
            userID: "user-a", defaults: defaults)
        XCTAssertEqual(durable.pending.map(\.id), [newPending.id])
        XCTAssertEqual(oldGroup.outbox.pending.map(\.id), [newPending.id])
        XCTAssertEqual(newGroup.outbox.pending.map(\.id),
                       [oldPending.id, newPending.id])
        XCTAssertEqual(auth.featureJWT, newToken)
        XCTAssertEqual(auth.phase, .signedIn)
    }
}


extension AuthModelTests {
    func testUnreadableEntrySurvivesLaunchSignOutAndRetryUntilExplicitDeletion() async throws {
        for invalidEnvelope in [false, true] {
            let h = LocalPersistenceTestHarness()
            addTeardownBlock { h.cleanup() }
            let local = h.open(), key = AuthModel.pendingEntryKey
            local.set("user-a", forKey: AuthModel.userIDKey)
            let corrupt = Data("unreadable saved navigation".utf8)
            XCTAssertTrue(local.set(corrupt, forKey: key))
            if invalidEnvelope { try corrupt.write(to: h.store.fileURL(forKey: key)) }
            let originalFile = try Data(contentsOf: h.store.fileURL(forKey: key))
            let tokens = MemoryTokenStore(sessionToken(for: "user-a"))
            let api = AuthAPIStub()
            api.deletionResult = .success(.init(ok: true, owner_tombstoned: false, apple_revocation: .revoked))
            let auth = AuthModel(api: api, tokenStore: tokens, defaults: local)
            XCTAssertTrue(local.hasFailure(userID: "user-a"))
            XCTAssertNil(auth.featureJWT)
            XCTAssertFalse(auth.requestEntry(.coach))
            auth.signOut()
            XCTAssertEqual(auth.userID, "user-a")
            XCTAssertFalse(local.retry(userID: "user-a"))
            XCTAssertEqual(try Data(contentsOf: h.store.fileURL(forKey: key)), originalFile)
            try await auth.deleteAccount()
            XCTAssertNil(try h.store.data(forKey: key))
            XCTAssertNil(tokens.token)
            XCTAssertNil(auth.userID)
        }
    }

    func testFailedEntryRequestDoesNotAcceptUnsavedNavigation() throws {
        let h = LocalPersistenceTestHarness()
        addTeardownBlock { h.cleanup() }
        let local = h.open(), tokens = MemoryTokenStore(sessionToken(for: "user-a"))
        let auth = AuthModel(api: AuthAPIStub(), tokenStore: tokens, defaults: local)
        XCTAssertTrue(auth.requestEntry(.invite("ABC234")))
        let original = auth.pendingEntryIntents
        let bytes = try h.store.data(forKey: AuthModel.pendingEntryKey)
        h.faults.failWrites = true
        XCTAssertFalse(auth.requestEntry(.coach))
        XCTAssertEqual(auth.pendingEntryIntents, original)
        XCTAssertNotNil(auth.entryPersistenceError)
        XCTAssertNil(auth.nextEntryIntent)
        XCTAssertEqual(try h.store.data(forKey: AuthModel.pendingEntryKey), bytes)
        let cold = AuthModel(api: AuthAPIStub(), tokenStore: tokens, defaults: h.open())
        XCTAssertEqual(cold.pendingEntryIntents, original)
        h.faults.failWrites = false
        XCTAssertTrue(local.retry(userID: "user-a"))
        auth.recoverEntryIntents()
        XCTAssertTrue(auth.requestEntry(.coach))
        XCTAssertNil(auth.entryPersistenceError)
        let restored = AuthModel(api: AuthAPIStub(), tokenStore: tokens, defaults: h.open())
        XCTAssertEqual(restored.pendingEntryIntents.map(\.destination), [.invite("ABC234"), .coach])
    }

    func testFailedEntryDismissalKeepsDurableDestinationForRetry() throws {
        let h = LocalPersistenceTestHarness()
        addTeardownBlock { h.cleanup() }
        let local = h.open(), tokens = MemoryTokenStore(sessionToken(for: "user-a"))
        let auth = AuthModel(api: AuthAPIStub(), tokenStore: tokens, defaults: local)
        XCTAssertTrue(auth.requestEntry(.coach))
        let intent = try XCTUnwrap(auth.nextEntryIntent)
        h.faults.failWrites = true
        XCTAssertFalse(auth.finishEntry(intent, epoch: auth.featureSessionEpoch))
        XCTAssertEqual(auth.pendingEntryIntents, [intent])
        let cold = AuthModel(api: AuthAPIStub(), tokenStore: tokens, defaults: h.open())
        XCTAssertEqual(cold.nextEntryIntent, intent)
        h.faults.failWrites = false
        XCTAssertTrue(local.retry(userID: "user-a"))
        auth.recoverEntryIntents()
        XCTAssertTrue(auth.finishEntry(intent, epoch: auth.featureSessionEpoch))
        XCTAssertNil(try h.store.data(forKey: AuthModel.pendingEntryKey))
    }

    func testFailedEntryBindRecoversWithoutTransferringToAnotherAccount() async throws {
        let h = LocalPersistenceTestHarness()
        addTeardownBlock { h.cleanup() }
        let local = h.open(), api = AuthAPIStub(), tokens = MemoryTokenStore()
        let originalToken = sessionToken(for: "user-a")
        let auth = AuthModel(api: api, tokenStore: tokens, defaults: local)
        XCTAssertTrue(auth.requestEntry(.invite("ABC234")))
        let original = try h.store.data(forKey: AuthModel.pendingEntryKey)
        h.faults.failWrites = true
        api.authResult = .success(AuthResponse(jwt: originalToken,
            user: UserDTO(id: "user-a", display_name: nil, email: nil)))
        await auth.exchange(identityToken: "synthetic", fullName: nil)
        XCTAssertEqual(auth.userID, "user-a")
        XCTAssertNil(auth.featureJWT)
        XCTAssertTrue(auth.pendingEntryIntents.isEmpty)
        XCTAssertEqual(try h.store.data(forKey: AuthModel.pendingEntryKey), original)
        api.authResult = .success(AuthResponse(jwt: sessionToken(for: "user-b"),
            user: UserDTO(id: "user-b", display_name: nil, email: nil)))
        await auth.exchange(identityToken: "synthetic", fullName: nil)
        XCTAssertEqual(auth.userID, "user-a")
        XCTAssertEqual(tokens.token, originalToken)
        auth.signOut()
        XCTAssertEqual(auth.userID, "user-a")
        h.faults.failWrites = false
        XCTAssertTrue(local.retry(userID: "user-a"))
        auth.recoverEntryIntents()
        XCTAssertEqual(auth.pendingEntryIntents.map(\.accountID), ["user-a"])
        let cold = AuthModel(api: api, tokenStore: tokens, defaults: h.open())
        XCTAssertEqual(cold.pendingEntryIntents, auth.pendingEntryIntents)
    }

    func testEntryRecoveryReloadsNavigationAfterFailedLegacyRead() throws {
        let h = LocalPersistenceTestHarness()
        addTeardownBlock { h.cleanup() }
        let intent = MemberEntryIntent(id: UUID(), destination: .invite("ABC234"), accountID: "user-a")
        h.preferences.set(try JSONEncoder().encode([intent]), forKey: AuthModel.pendingEntryKey)
        h.faults.failWrites = true
        let local = h.open()
        let auth = AuthModel(api: AuthAPIStub(), tokenStore: MemoryTokenStore(sessionToken(for: "user-a")), defaults: local)
        XCTAssertTrue(auth.pendingEntryIntents.isEmpty)
        XCTAssertNil(auth.featureJWT)
        h.faults.failWrites = false
        XCTAssertTrue(local.retry(userID: "user-a"))
        auth.recoverEntryIntents()
        XCTAssertEqual(auth.nextEntryIntent, intent)
    }

    func testOnboardingDoesNotAdvanceWhenDestinationCannotBeSaved() {
        let h = LocalPersistenceTestHarness()
        addTeardownBlock { h.cleanup() }
        let local = h.open()
        let auth = AuthModel(api: AuthAPIStub(), tokenStore: MemoryTokenStore(sessionToken(for: "user-a")), defaults: local)
        auth.onboardingComplete = false
        let flow = OnboardingFlow(auth: auth)
        flow.advance(from: flow.checkpoint)
        flow.advance(from: flow.checkpoint)
        flow.advance(from: flow.checkpoint)
        h.faults.failWrites = true
        flow.finish(from: flow.checkpoint, destination: .workouts)
        XCTAssertFalse(auth.onboardingComplete)
        XCTAssertEqual(flow.step, .coach)
        XCTAssertTrue(auth.pendingEntryIntents.isEmpty)
        h.faults.failWrites = false
        XCTAssertTrue(local.retry(userID: "user-a"))
        auth.recoverEntryIntents()
        flow.finish(from: flow.checkpoint, destination: .workouts)
        XCTAssertTrue(auth.onboardingComplete)
        XCTAssertEqual(auth.nextEntryIntent?.destination, .workouts)
    }

    func testMemberEntrySurvivesFailedSignInRelaunchAndOnboarding() async {
        let defaults = defaults()
        let api = AuthAPIStub()
        let auth = AuthModel(api: api, tokenStore: MemoryTokenStore(), defaults: defaults)
        let url = Config.apiBaseURL.appendingPathComponent("join/ABC234")
        auth.handleDeepLink(url)
        auth.handleDeepLink(url)
        auth.requestEntry(.coach)
        await auth.exchange(identityToken: "synthetic", fullName: nil)
        XCTAssertEqual(auth.pendingEntryIntents.count, 2)
        XCTAssertNil(auth.userID)
        let restored = AuthModel(api: api, tokenStore: MemoryTokenStore(), defaults: defaults)
        api.authResult = .success(AuthResponse(jwt: sessionToken(for: "user-a"),
            user: UserDTO(id: "user-a", display_name: nil, email: nil)))
        await restored.exchange(identityToken: "synthetic", fullName: nil)
        XCTAssertFalse(restored.onboardingComplete)
        XCTAssertNil(restored.nextEntryIntent)
        XCTAssertEqual(restored.pendingEntryIntents.map(\.accountID), ["user-a", "user-a"])
        let flow = OnboardingFlow(auth: restored)
        flow.advance(from: flow.checkpoint)
        XCTAssertEqual(flow.step, .intervals)
        flow.advance(from: flow.checkpoint)
        flow.finish(from: flow.checkpoint)
        XCTAssertEqual(restored.nextEntryIntent?.destination, .invite("ABC234"))
        let invite = restored.nextEntryIntent!
        restored.finishEntry(invite, epoch: restored.featureSessionEpoch)
        XCTAssertEqual(restored.nextEntryIntent?.destination, .coach)
        // Dismissal of a retired sheet cannot remove the next destination.
        restored.finishEntry(invite, epoch: restored.featureSessionEpoch)
        XCTAssertEqual(restored.nextEntryIntent?.destination, .coach)
    }

    func testOnboardingLateSuccessAfterSkipCannotAdvanceAnotherStep() {
        let auth = AuthModel(api: AuthAPIStub(), tokenStore: MemoryTokenStore(sessionToken(for: "user-a")), defaults: defaults())
        auth.onboardingComplete = false
        let flow = OnboardingFlow(auth: auth)
        flow.advance(from: flow.checkpoint)
        let groupRequest = flow.checkpoint
        flow.advance(from: groupRequest) // Skip while joining.
        flow.advance(from: groupRequest) // Delayed join success.
        XCTAssertEqual(flow.step, .intervals)
        let intervalsRequest = flow.checkpoint
        flow.advance(from: intervalsRequest) // Skip while connecting.
        flow.advance(from: intervalsRequest) // Delayed OAuth/manual success.
        XCTAssertEqual(flow.step, .coach)
        XCTAssertFalse(auth.onboardingComplete)
        XCTAssertTrue(auth.pendingEntryIntents.isEmpty)
        flow.finish(from: flow.checkpoint, destination: .workouts)
        XCTAssertEqual(auth.nextEntryIntent?.destination, .workouts)
    }

    func testOldOnboardingAndEntryCallbacksCannotCrossSameUserReauthentication() async {
        let defaults = defaults()
        let api = AuthAPIStub()
        api.authResult = .success(AuthResponse(jwt: sessionToken(for: "user-a"),
            user: UserDTO(id: "user-a", display_name: nil, email: nil)))
        let auth = AuthModel(api: api, tokenStore: MemoryTokenStore(), defaults: defaults)
        await auth.exchange(identityToken: "synthetic", fullName: nil)
        let flow = OnboardingFlow(auth: auth)
        flow.advance(from: flow.checkpoint)
        flow.advance(from: flow.checkpoint)
        flow.advance(from: flow.checkpoint)
        let oldStep = flow.checkpoint
        auth.requestEntry(.coach)
        let intent = auth.pendingEntryIntents[0], epoch = auth.featureSessionEpoch
        auth.requireReauthentication()
        await auth.exchange(identityToken: "synthetic", fullName: nil)
        flow.finish(from: oldStep, destination: .workouts)
        auth.finishEntry(intent, epoch: epoch)
        XCTAssertFalse(auth.onboardingComplete)
        XCTAssertEqual(auth.pendingEntryIntents.map(\.destination), [.coach])
    }

    func testAccountChangeCannotInheritOnboardingOrBoundIntent() async {
        let defaults = defaults()
        defaults.set("user-a", forKey: AuthModel.userIDKey)
        defaults.set(true, forKey: AuthModel.onboardedKey)
        let api = AuthAPIStub()
        let auth = AuthModel(api: api, tokenStore: MemoryTokenStore(sessionToken(for: "user-a")), defaults: defaults)
        XCTAssertTrue(auth.onboardingComplete)
        auth.requestEntry(.coach)
        auth.requireReauthentication()
        api.authResult = .success(AuthResponse(jwt: sessionToken(for: "user-b"),
            user: UserDTO(id: "user-b", display_name: nil, email: nil)))
        await auth.exchange(identityToken: "synthetic", fullName: nil)
        XCTAssertFalse(auth.onboardingComplete)
        XCTAssertTrue(auth.pendingEntryIntents.isEmpty)
        XCTAssertTrue(defaults.bool(forKey: AccountLocalState.onboardedKey(userID: "user-a")))
        auth.requestEntry(.workouts)
        auth.signOut()
        XCTAssertTrue(auth.pendingEntryIntents.isEmpty)
        XCTAssertNil(defaults.data(forKey: AuthModel.pendingEntryKey))
    }

    func testDelayedSignInDoesNotRestoreAccountOrIntentAfterSignOut() async {
        let started = AsyncLatch(), release = AsyncLatch()
        let api = AuthAPIStub()
        let response = AuthResponse(jwt: sessionToken(for: "user-a"), user: UserDTO(id: "user-a", display_name: nil, email: nil))
        api.authHandler = { await started.open(); await release.wait(); return response }
        let auth = AuthModel(api: api, tokenStore: MemoryTokenStore(), defaults: defaults())
        auth.requestEntry(.coach)
        let task = Task { await auth.exchange(identityToken: "synthetic", fullName: nil) }
        await started.wait()
        auth.signOut()
        await release.open()
        await task.value
        XCTAssertEqual(auth.phase, .signedOut)
        XCTAssertNil(auth.jwt)
        XCTAssertNil(auth.userID)
        XCTAssertTrue(auth.pendingEntryIntents.isEmpty)
    }
}


extension AuthModelTests {
    func testInterruptedOnboardingRelaunchRetainsUnfinishedAccountSetup() async {
        let defaults = defaults(), api = AuthAPIStub(), tokens = MemoryTokenStore()
        api.authResult = .success(AuthResponse(jwt: sessionToken(for: "user-a"),
            user: UserDTO(id: "user-a", display_name: nil, email: nil)))
        let auth = AuthModel(api: api, tokenStore: tokens, defaults: defaults)
        auth.requestEntry(.coach)
        await auth.exchange(identityToken: "synthetic", fullName: nil)
        let restored = AuthModel(api: api, tokenStore: tokens, defaults: defaults)
        XCTAssertEqual(restored.phase, .signedIn)
        XCTAssertFalse(restored.onboardingComplete)
        XCTAssertNil(restored.nextEntryIntent)
        XCTAssertEqual(restored.pendingEntryIntents.map(\.destination), [.coach])
        restored.completeOnboarding()
        let finished = AuthModel(api: api, tokenStore: tokens, defaults: defaults)
        XCTAssertTrue(finished.onboardingComplete)
        XCTAssertEqual(finished.nextEntryIntent?.destination, .coach)
    }
}

extension AuthModelTests {
    private func intervalsProfile(connected: Bool = true, pending: Bool = false, generation: Int = 1, lastSyncedAt: Int = 1) -> MeProfile {
        MeProfile(display_name: nil, email: nil,
            intervals: .init(connected: connected, athlete_id: connected ? "athlete-a" : nil,
                needs_reauth: false, credential_generation: generation, sync_pending: pending,
                last_synced_at: pending ? nil : lastSyncedAt),
            claude: .init(is_owner: false, connected: false, last_active: nil), health: nil)
    }

    func testIntervalsAcknowledgementSurvivesOutageAndRetriesWithoutCredentials() async throws {
        let defaults = defaults()
        let auth = AuthModel(api: AuthAPIStub(), tokenStore: MemoryTokenStore(sessionToken(for: "user-a")), defaults: defaults)
        var writes = 0, imports = 0, refreshes = 0
        let pending = intervalsProfile(pending: true), complete = intervalsProfile().intervals
        let group = GroupModel(auth: auth, defaults: defaults,
            profileLoader: { _ in pending },
            intervalsConnector: { _, athlete, _ in
                writes += 1; XCTAssertEqual(athlete, "0")
                return .init(connected: true, credential_generation: 1)
            }, intervalsImporter: { generation, _ in
                imports += 1; XCTAssertEqual(generation, 1)
                return .init(status: .synced, connection: complete)
            }, intervalsPollDelays: [0])
        group.onActivityPersisted = { refreshes += 1 }
        try await group.setIntervalsCredentials(apiKey: "synthetic-key", athleteID: "")
        XCTAssertEqual(group.intervalsStatus?.connected, true)
        XCTAssertEqual(group.intervalsImportStatus, .retry)
        XCTAssertEqual(refreshes, 0)
        await group.retryIntervalsSync()
        XCTAssertEqual(writes, 1); XCTAssertEqual(imports, 1); XCTAssertEqual(refreshes, 1)
        XCTAssertEqual(group.intervalsStatus?.sync_pending, false)
        XCTAssertFalse(group.intervalsBusy)
    }

    func testIntervalsCurrentServerDisconnectOverridesPersistedMirror() async throws {
        let defaults = defaults()
        defaults.set(try JSONEncoder().encode(IntervalsConnection(athlete_id: "old-athlete", connected_at: 1)),
            forKey: GroupModel.intervalsConnectionKey(userID: "user-a"))
        let auth = AuthModel(api: AuthAPIStub(), tokenStore: MemoryTokenStore(sessionToken(for: "user-a")), defaults: defaults)
        let profile = intervalsProfile(connected: false)
        let group = GroupModel(auth: auth, defaults: defaults, profileLoader: { _ in profile })
        XCTAssertNil(group.intervalsStatus) // Cold launch cannot certify saved credentials.
        await group.refreshMe()
        XCTAssertEqual(group.intervalsStatus?.connected, false)
        XCTAssertNil(group.intervalsConnection)
        XCTAssertNil(defaults.data(forKey: GroupModel.intervalsConnectionKey(userID: "user-a")))
    }

    func testIntervalsLateImportCannotUndoDisconnectOrNotifyCalendar() async throws {
        let defaults = defaults()
        let auth = AuthModel(api: AuthAPIStub(), tokenStore: MemoryTokenStore(sessionToken(for: "user-a")), defaults: defaults)
        let started = AsyncLatch(), release = AsyncLatch(), profile = intervalsProfile()
        var refreshes = 0
        let group = GroupModel(auth: auth, defaults: defaults, profileLoader: { _ in profile },
            intervalsConnector: { key, _, _ in XCTAssertNil(key); return .init(connected: false, credential_generation: 2) },
            intervalsImporter: { _, _ in
                await started.open(); await release.wait()
                return .init(status: .synced, connection: profile.intervals)
            })
        group.onActivityPersisted = { refreshes += 1 }
        await group.refreshMe()
        let syncing = Task { await group.retryIntervalsSync() }
        await started.wait()
        try await group.disconnectIntervals()
        await release.open(); await syncing.value
        XCTAssertEqual(group.intervalsStatus?.connected, false)
        XCTAssertEqual(group.intervalsStatus?.credential_generation, 2)
        XCTAssertEqual(refreshes, 0)
    }

    func testIntervalsProfileStartedBeforeDisconnectCannotRestoreConnection() async throws {
        let defaults = defaults()
        let auth = AuthModel(api: AuthAPIStub(), tokenStore: MemoryTokenStore(sessionToken(for: "user-a")), defaults: defaults)
        let started = AsyncLatch(), release = AsyncLatch(), profile = intervalsProfile()
        let group = GroupModel(auth: auth, defaults: defaults, profileLoader: { _ in
            await started.open(); await release.wait(); return profile
        }, intervalsConnector: { _, _, _ in .init(connected: false, credential_generation: 2) })
        let reading = Task { await group.refreshMe() }
        await started.wait(); try await group.disconnectIntervals()
        await release.open(); await reading.value
        XCTAssertEqual(group.intervalsStatus?.connected, false)
        XCTAssertEqual(group.intervalsStatus?.credential_generation, 2)
    }

    func testIntervalsReceiptSurvivesSameAccountRenewalButCannotCrossAccount() async throws {
        for switchAccount in [false, true] {
            let defaults = defaults(), api = AuthAPIStub()
            let auth = AuthModel(api: api, tokenStore: MemoryTokenStore(sessionToken(for: "user-a")), defaults: defaults)
            let started = AsyncLatch(), release = AsyncLatch(), profile = intervalsProfile()
            var refreshes = 0
            let group = GroupModel(auth: auth, defaults: defaults, profileLoader: { _ in profile }, intervalsConnector: { _, _, _ in
                await started.open(); await release.wait()
                return .init(connected: true, credential_generation: 1)
            })
            group.onActivityPersisted = { refreshes += 1 }
            let saving = Task { try await group.setIntervalsCredentials(apiKey: "synthetic", athleteID: "athlete-a") }
            await started.wait()
            let nextUser = switchAccount ? "user-b" : "user-a"
            api.authResult = .success(response(jwt: jwt(expiration: Date.distantFuture.addingTimeInterval(-3600), subject: nextUser), userID: nextUser))
            await auth.exchange(identityToken: "synthetic", fullName: nil)
            await release.open(); try await saving.value
            XCTAssertEqual(refreshes, switchAccount ? 0 : 1)
            XCTAssertEqual(group.intervalsStatus?.connected, switchAccount ? nil : true)
        }
    }

    func testIntervalsOAuthAcceptedCallbackDoesNotBecomeFailureWhenProfileUnavailable() async throws {
        let defaults = defaults()
        let auth = AuthModel(api: AuthAPIStub(), tokenStore: MemoryTokenStore(sessionToken(for: "user-a")), defaults: defaults)
        var authorizations = 0, reads = 0
        let group = GroupModel(auth: auth, defaults: defaults, profileLoader: { _ in
            reads += 1; throw URLError(.notConnectedToInternet)
        }, intervalsAuthorizer: { _ in authorizations += 1; return .init(connected: true) })
        let connected = try await group.connectIntervalsViaOAuth()
        XCTAssertTrue(connected)
        XCTAssertTrue(group.intervalsStatusUnavailable)
        await group.retryIntervalsSync() // Recover by reading status, never by resending authorization.
        XCTAssertEqual(authorizations, 1); XCTAssertEqual(reads, 2)
    }

    func testIntervalsOAuthCancellationKeepsCurrentStatusAndLateCallbackCannotUndoDisconnect() async throws {
        let defaults = defaults()
        let auth = AuthModel(api: AuthAPIStub(), tokenStore: MemoryTokenStore(sessionToken(for: "user-a")), defaults: defaults)
        let profile = intervalsProfile()
        var cancelled = true
        let started = AsyncLatch(), release = AsyncLatch()
        let group = GroupModel(auth: auth, defaults: defaults, profileLoader: { _ in profile },
            intervalsConnector: { _, _, _ in .init(connected: false, credential_generation: 2) },
            intervalsAuthorizer: { _ in
                if cancelled { return .init(connected: false) }
                await started.open(); await release.wait()
                return .init(connected: true)
            })
        await group.refreshMe()
        let result = try await group.connectIntervalsViaOAuth()
        XCTAssertFalse(result); XCTAssertEqual(group.intervalsStatus?.connected, true)
        cancelled = false
        let connecting = Task { try await group.connectIntervalsViaOAuth() }
        await started.wait(); try await group.disconnectIntervals(); await release.open()
        let late = try await connecting.value
        XCTAssertFalse(late); XCTAssertEqual(group.intervalsStatus?.connected, false)
    }

    func testIntervalsOAuthParserSeparatesAcceptedImportFailureFromAuthorizationFailure() throws {
        let result = try IntervalsOAuthResult.parse(URL(string: "tresfort://intervals-connected?ok=1&sync=retry")!)
        XCTAssertTrue(result.connected); XCTAssertNil(result.credentialGeneration)
        XCTAssertThrowsError(try IntervalsOAuthResult.parse(URL(string: "tresfort://intervals-connected?error=bad_state")!))
        XCTAssertThrowsError(try IntervalsOAuthResult.parse(URL(string: "https://untrusted.example?ok=1")!))
        XCTAssertNil(try IntervalsOAuthResult.parse(URL(string: "tresfort://intervals-connected?ok=1")!).credentialGeneration)
    }
}


extension AuthModelTests {
    func testIntervalsAcknowledgementObservesBackgroundImportWithoutRepeatingProviderRequest() async throws {
        let defaults = defaults()
        let auth = AuthModel(api: AuthAPIStub(), tokenStore: MemoryTokenStore(sessionToken(for: "user-a")), defaults: defaults)
        let pending = intervalsProfile(pending: true), complete = intervalsProfile()
        var reads = 0, writes = 0, notifications = 0
        let group = GroupModel(auth: auth, defaults: defaults,
            profileLoader: { _ in reads += 1; return reads == 1 ? pending : complete },
            intervalsConnector: { _, _, _ in writes += 1; return .init(connected: true, credential_generation: 1) },
            intervalsImporter: { _, _ in XCTFail("Initial observation must not start a competing import"); return .init(status: .retry, connection: nil) },
            intervalsPollDelays: [0, 0])
        group.onActivityPersisted = { notifications += 1 }
        try await group.setIntervalsCredentials(apiKey: "synthetic", athleteID: "athlete-a")
        XCTAssertEqual(writes, 1); XCTAssertEqual(reads, 2); XCTAssertEqual(notifications, 1)
        XCTAssertEqual(group.intervalsImportStatus, .synced)
        XCTAssertFalse(group.intervalsBusy)
    }

    func testIntervalsBackgroundImportOutageRemainsRetryableAfterAcknowledgement() async throws {
        let defaults = defaults()
        let auth = AuthModel(api: AuthAPIStub(), tokenStore: MemoryTokenStore(sessionToken(for: "user-a")), defaults: defaults)
        let pending = intervalsProfile(pending: true), complete = intervalsProfile()
        var writes = 0, imports = 0
        let group = GroupModel(auth: auth, defaults: defaults, profileLoader: { _ in pending },
            intervalsConnector: { _, _, _ in writes += 1; return .init(connected: true, credential_generation: 1) },
            intervalsImporter: { generation, _ in
                imports += 1; XCTAssertEqual(generation, 1)
                return .init(status: .synced, connection: complete.intervals)
            }, intervalsPollDelays: [0, 0])
        try await group.setIntervalsCredentials(apiKey: "synthetic", athleteID: "athlete-a")
        XCTAssertEqual(group.intervalsImportStatus, .retry)
        XCTAssertEqual(group.intervalsStatus?.connected, true)
        XCTAssertFalse(group.intervalsBusy)
        await group.retryIntervalsSync()
        XCTAssertEqual(writes, 1); XCTAssertEqual(imports, 1)
        XCTAssertEqual(group.intervalsStatus?.sync_pending, false)
        let callback = try IntervalsOAuthResult.parse(URL(string: "tresfort://intervals-connected?ok=1&generation=7")!)
        XCTAssertEqual(callback.credentialGeneration, 7)
    }
}


extension AuthModelTests {
    func testIntervalsIdenticalReconnectWaitsForANewerSyncBeyondTheAcknowledgedWatermark() async throws {
        let defaults = defaults()
        let auth = AuthModel(api: AuthAPIStub(), tokenStore: MemoryTokenStore(sessionToken(for: "user-a")), defaults: defaults)
        let old = intervalsProfile(), fresh = intervalsProfile(lastSyncedAt: 2)
        var reads = 0, notifications = 0
        let group = GroupModel(auth: auth, defaults: defaults,
            profileLoader: { _ in reads += 1; return reads == 1 ? old : fresh },
            intervalsConnector: { _, _, _ in .init(connected: true, credential_generation: 1, activity_sync_after: 1) },
            intervalsPollDelays: [0, 0])
        group.onActivityPersisted = { notifications += 1 }
        try await group.setIntervalsCredentials(apiKey: "unchanged-synthetic", athleteID: "athlete-a")
        XCTAssertEqual(reads, 2); XCTAssertEqual(notifications, 1)
        XCTAssertEqual(group.intervalsStatus?.last_synced_at, 2)
        let callback = try IntervalsOAuthResult.parse(URL(string: "tresfort://intervals-connected?ok=1&generation=7&sync_after=42")!)
        XCTAssertEqual(callback.activitySyncAfter, 42)
    }
    func testReviewSignInSkipsPersonalIntentsAppleAndLegacyData() async throws {
        let local = defaults(), api = AuthAPIStub(), tokens = MemoryTokenStore()
        let checker = AppleCredentialCheckerStub()
        local.set(true, forKey: AccountLocalState.legacyHealthEnabledKey)
        let token = jwt(expiration: .distantFuture, subject: "review-user", review: true)
        api.authResult = .success(AuthResponse(jwt: token, user: UserDTO(id: "review-user", display_name: "App Review", email: nil)))
        let auth = AuthModel(api: api, tokenStore: tokens, appleCredentialChecker: checker, defaults: local)
        auth.requestEntry(.coach)
        await auth.signInForReview(username: "app-review", password: "synthetic-password")
        XCTAssertEqual(auth.phase, .signedIn)
        XCTAssertTrue(auth.isReviewAccount)
        XCTAssertTrue(auth.onboardingComplete)
        XCTAssertTrue(auth.pendingEntryIntents.isEmpty)
        XCTAssertNil(auth.appleCredentialUserID)
        await auth.checkAppleCredentialState()
        XCTAssertTrue(checker.checkedUserIDs.isEmpty)
        AccountLocalState.bindLegacyState(userID: "review-user", defaults: local)
        XCTAssertFalse(local.bool(forKey: AccountLocalState.healthEnabledKey(userID: "review-user")))
        XCTAssertTrue(local.bool(forKey: AccountLocalState.legacyHealthEnabledKey))
        let restored = AuthModel(api: api, tokenStore: tokens, defaults: local)
        XCTAssertTrue(restored.isReviewAccount)
        XCTAssertTrue(local.bool(forKey: AccountLocalState.legacyHealthEnabledKey))
        api.deletionResult = .success(AccountDeletionResponse(ok: true, owner_tombstoned: false, apple_revocation: .manualRequired))
        try await auth.deleteAccount()
        XCTAssertEqual(auth.phase, .signedOut)
        XCTAssertFalse(auth.postDeletionAppleRevocationRequired)
        XCTAssertTrue(local.bool(forKey: AccountLocalState.legacyHealthEnabledKey))
        XCTAssertFalse(local.bool(forKey: AccountLocalState.reviewAccountKey(userID: "review-user")))
    }

    func testReviewDeletionCleanupRetryPreservesPersonalLegacyData() {
        let local = defaults()
        let marker = AccountLocalState.reviewAccountKey(userID: "review-user")
        let receipt = AccountLocalState.accountDeletionKey(userID: "review-user")
        local.set(true, forKey: marker)
        local.set(true, forKey: AccountLocalState.legacyHealthEnabledKey)
        local.recordInvalidData(Data([1]), forKey: receipt)

        XCTAssertFalse(AccountLocalState.clear(userID: "review-user", defaults: local))
        XCTAssertTrue(local.bool(forKey: marker))
        XCTAssertTrue(local.bool(forKey: AccountLocalState.legacyHealthEnabledKey))
        XCTAssertTrue(local.eraseAfterAccountDeletion(forKey: receipt))
        XCTAssertTrue(AccountLocalState.clear(userID: "review-user", defaults: local))
        XCTAssertFalse(local.bool(forKey: marker))
        XCTAssertTrue(local.bool(forKey: AccountLocalState.legacyHealthEnabledKey))
    }

    func testReviewSignInRejectsPersonalTokenAndHidesCredentialErrorBody() async {
        let api = AuthAPIStub(), tokens = MemoryTokenStore()
        let auth = AuthModel(api: api, tokenStore: tokens, defaults: defaults())
        api.authResult = .success(AuthResponse(jwt: sessionToken(for: "personal-user"), user: UserDTO(id: "personal-user", display_name: nil, email: nil)))
        await auth.signInForReview(username: "app-review", password: "synthetic-password")
        XCTAssertEqual(auth.phase, .error("session identity mismatch"))
        XCTAssertNil(auth.jwt)
        api.authResult = .failure(APIError.http(401, "must-never-display-submitted-password"))
        await auth.signInForReview(username: "app-review", password: "synthetic-password")
        XCTAssertEqual(auth.phase, .error("The reviewer username or password is incorrect."))
        XCTAssertNil(tokens.token)
    }

}
