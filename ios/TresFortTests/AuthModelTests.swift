import Foundation
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
    private func defaults() -> UserDefaults {
        let name = "AuthModelTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        defaults.removePersistentDomain(forName: name)
        return defaults
    }

    private func jwt(expiration: Date, subject: String = "user-a") -> String {
        func base64URL(_ data: Data) -> String {
            data.base64EncodedString()
                .replacingOccurrences(of: "+", with: "-")
                .replacingOccurrences(of: "/", with: "_")
                .replacingOccurrences(of: "=", with: "")
        }
        let header = try! JSONSerialization.data(withJSONObject: ["alg": "HS256"])
        let payload = try! JSONSerialization.data(withJSONObject: [
            "exp": Int(expiration.timeIntervalSince1970),
            "sub": subject
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
            dayTemplateID: "day-a",
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
        XCTAssertFalse(defaults.dictionaryRepresentation().values.contains {
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
        XCTAssertEqual(
            defaults.data(forKey: GroupModel.intervalsConnectionKey(userID: "user-a")),
            try! JSONEncoder().encode(intervalsA))
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
}
