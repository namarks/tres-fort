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

private final class AuthAPIStub: AuthAPI {
    var authResult: Result<AuthResponse, Error> = .failure(URLError(.badServerResponse))
    var renewalResult: Result<SessionRenewalResponse, Error> =
        .failure(URLError(.badServerResponse))
    var deletionResult: Result<AccountDeletionResponse, Error> =
        .failure(URLError(.badServerResponse))
    var renewalHandler: ((String) async throws -> SessionRenewalResponse)?
    var deletionHandler: ((String, String) async throws -> AccountDeletionResponse)?
    private(set) var renewalCalls = 0
    private(set) var deletionCalls = 0
    private(set) var deletionKeys: [String] = []

    func authApple(identityToken: String, fullName: String?) async throws -> AuthResponse {
        try authResult.get()
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

    func testAcknowledgedDeletionClearsOnlyCurrentAccountLocalState() async {
        let defaults = defaults()
        defaults.set("user-a", forKey: AuthModel.userIDKey)
        defaults.set(true, forKey: AuthModel.onboardedKey)
        let accountToken = sessionToken(for: "user-a")
        let tokens = MemoryTokenStore(accountToken)
        let api = AuthAPIStub()
        api.deletionResult = .success(AccountDeletionResponse(
            ok: true,
            owner_tombstoned: false))

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

    func testDeletionRetryReusesIdempotencyKeyAfterLostResponse() async {
        let defaults = defaults()
        defaults.set("user-a", forKey: AuthModel.userIDKey)
        let tokens = MemoryTokenStore(sessionToken(for: "user-a"))
        let api = AuthAPIStub()
        api.deletionHandler = { _, _ in
            if api.deletionCalls == 1 {
                throw URLError(.networkConnectionLost)
            }
            return AccountDeletionResponse(ok: true, owner_tombstoned: false)
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
            return AccountDeletionResponse(ok: true, owner_tombstoned: false)
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
    }
}
