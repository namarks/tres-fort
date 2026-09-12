import AuthenticationServices
import Foundation
import SwiftUI

@MainActor
final class AuthModel: ObservableObject {
    private struct ServerErrorEnvelope: Decodable {
        let error: String
    }

    enum Phase: Equatable {
        case signedOut
        case working(String)
        case signedIn
        case error(String)
    }

    @Published var phase: Phase = .signedOut
    @Published var jwt: String?
    var isReviewAccount: Bool { jwt.flatMap(Self.claims)?["app_review"] as? Bool == true }
    @Published private(set) var isRenewing = false
    @Published private(set) var appleCredentialUserID: String?
    @Published private(set) var reauthenticationReason: String?
    /// One-shot post-deletion handoff shown from RootView. Only this
    /// non-sensitive boolean is persisted so terminating the app cannot lose
    /// required Apple cleanup directions; no authorization code or provider
    /// credential is stored, and dismissal does not mutate authentication.
    @Published private(set) var postDeletionAppleRevocationRequired = false
    /// A durable DELETE /api/me attempt has not yet been acknowledged. While
    /// this is true the current bearer is the only credential that can replay
    /// the key-bound deletion receipt after a lost response, so background
    /// 401s and explicit sign-out must not discard it.
    @Published private(set) var accountDeletionPending = false
    /// Pause ordinary requests while deletion or protected local storage needs
    /// recovery. Keep the bearer available to AuthModel for deletion retries.
    var featureJWT: String? {
        accountDeletionPending || defaults.hasFailure(userID: userID) ? nil : jwt
    }
    /// Process-local identity for one continuously active feature session.
    /// It changes across sign-out, reauthentication teardown, deletion, and a
    /// subsequent sign-in, but not ordinary same-account bearer renewal. Feature
    /// models capture it so an old task cannot become current again after a
    /// sign-out/same-user-sign-in ABA.
    private(set) var featureSessionEpoch: UInt64 = 0
    /// Cross-model, account-scoped signal that server-side activity data
    /// changed. It survives a same-user sign-out/sign-in boundary so a new
    /// SyncModel can refresh when an older Group/Health task finishes late.
    @Published private(set) var activityPersistenceGeneration: UInt64 = 0
    /// Server user id, captured from /auth/apple's `user.id` and persisted
    /// in LocalPersistence so GroupModel can survive an app relaunch with the
    /// keychain JWT alone. Used as the fallback for `is_me` comparisons
    /// against /api/groups members (the M2 list endpoint doesn't stamp
    /// `is_me` — only /feed and /stats do).
    @Published var userID: String?

    func noteActivityPersisted(for accountID: String?) {
        noteAccountStatePersisted(for: accountID)
    }

    /// Cross-model refresh signal for any successful same-account server
    /// mutation completed by a feature model from an older session epoch.
    /// The publisher retains its original activity-oriented name for source
    /// compatibility with the existing subscribers.
    func noteAccountStatePersisted(for accountID: String?) {
        guard let accountID, userID == accountID, featureJWT != nil else {
            return
        }
        activityPersistenceGeneration &+= 1
    }

    /// Drives whether RootView shows the first-run `OnboardingView` or the
    /// main app. `false` ⇒ a brand-new sign-in that hasn't been guided
    /// through setup yet. Persisted so it survives relaunch and never
    /// re-fires once completed. See the grandfathering logic in `init`.
    @Published var onboardingComplete = false

    @Published private(set) var pendingEntryIntents: [MemberEntryIntent] = []
    @Published private(set) var entryPersistenceError: String?
    static let pendingEntryKey = "com.nmarkspdx.liftcoach.pending-entry.v1"
    private var signInRequestID = UUID()

    var pendingInviteCode: String? {
        pendingEntryIntents.compactMap {
            if case let .invite(code) = $0.destination { return code }
            return nil
        }.first
    }

    var nextEntryIntent: MemberEntryIntent? {
        guard featureJWT != nil, onboardingComplete else { return nil }
        return pendingEntryIntents.first { $0.accountID == userID }
    }

    func isCurrentFeatureSession(accountID: String?, epoch: UInt64) -> Bool {
        accountID != nil && userID == accountID && featureJWT != nil && featureSessionEpoch == epoch
    }

    @discardableResult
    func requestEntry(_ destination: MemberEntryIntent.Destination) -> Bool {
        guard let current = readEntryIntents() else { return entrySaveFailed() }
        // Repeated Universal Link delivery does not duplicate a sheet.
        guard !current.contains(where: {
            $0.destination == destination && $0.accountID == userID
        }) else { return true }
        let replacement = current + [MemberEntryIntent(id: UUID(), destination: destination, accountID: userID)]
        guard persistEntryIntents(replacement) else { return false }
        pendingEntryIntents = replacement
        entryPersistenceError = nil
        return true
    }

    @discardableResult
    func finishEntry(_ intent: MemberEntryIntent, epoch: UInt64) -> Bool {
        guard isCurrentFeatureSession(accountID: intent.accountID, epoch: epoch) else { return false }
        guard let current = readEntryIntents() else { return entrySaveFailed() }
        let replacement = current.filter { $0.id != intent.id }
        guard persistEntryIntents(replacement) else { return false }
        pendingEntryIntents = replacement
        entryPersistenceError = nil
        return true
    }

    private func readEntryIntents() -> [MemberEntryIntent]? {
        let data = defaults.data(forKey: Self.pendingEntryKey)
        guard !defaults.hasFailure(forKey: Self.pendingEntryKey) else { return nil }
        guard let data else { return [] }
        guard let intents = try? JSONDecoder().decode([MemberEntryIntent].self, from: data) else {
            defaults.recordInvalidData(data, forKey: Self.pendingEntryKey)
            return nil
        }
        return intents
    }

    private func persistEntryIntents(_ intents: [MemberEntryIntent]) -> Bool {
        let saved: Bool
        if intents.isEmpty { saved = defaults.removeObject(forKey: Self.pendingEntryKey) }
        else if let data = try? JSONEncoder().encode(intents) {
            saved = defaults.set(data, forKey: Self.pendingEntryKey)
        } else {
            defaults.recordWriteFailure(forKey: Self.pendingEntryKey)
            saved = false
        }
        return saved ? true : entrySaveFailed()
    }

    @discardableResult
    private func entrySaveFailed() -> Bool {
        entryPersistenceError = "Your navigation change could not be saved. Retry saved data, then open the link or choose the destination again."
        return false
    }

    func dismissEntryPersistenceError() { entryPersistenceError = nil }

    /// AuthModel survives the feature-view remount after storage recovery.
    /// Reload its navigation state too, including an interrupted account bind.
    func recoverEntryIntents() {
        if let accountID = userID, jwt != nil { bindEntryIntents(to: accountID) }
        else if let current = readEntryIntents() {
            pendingEntryIntents = current.filter { $0.accountID == nil || $0.accountID == userID }
        }
    }

    private func bindEntryIntents(to accountID: String) {
        guard let current = readEntryIntents() else { entrySaveFailed(); return }
        let replacement = current.filter {
            $0.accountID == nil || $0.accountID == accountID
        }.map { intent in
            var bound = intent
            bound.accountID = accountID
            return bound
        }
        guard replacement == current || persistEntryIntents(replacement) else {
            // Do not expose the previous account's destinations while the
            // durable bind is waiting for storage recovery.
            pendingEntryIntents = []
            return
        }
        pendingEntryIntents = replacement
    }

    private let api: any AuthAPI
    private let tokenStore: any AppTokenStore
    private let appleCredentialChecker: any AppleCredentialStateChecking
    private let defaults: LocalPersistence
    private let now: () -> Date
    /// Weak-owner callbacks registered by mounted feature models. AuthModel
    /// invokes them immediately before an account boundary makes their epoch
    /// stale, so process-shared UI such as Live Activities cannot outlive the
    /// signed-in account. A `false` result prunes a deallocated observer.
    private var featureSessionBoundaryObservers: [UUID: () -> Bool] = [:]
    static let userIDKey = "com.nmarkspdx.liftcoach.user-id.v1"
    static let onboardedKey = "com.nmarkspdx.liftcoach.onboarded.v1"
    static let postDeletionAppleRevocationKey =
        "com.nmarkspdx.liftcoach.post-deletion-apple-revocation.v1"
    static let renewalWindow: TimeInterval = 7 * 24 * 60 * 60

    @discardableResult
    func observeFeatureSessionBoundary(
        _ observer: @escaping () -> Bool
    ) -> UUID {
        let id = UUID()
        featureSessionBoundaryObservers[id] = observer
        return id
    }

    private func notifyFeatureSessionBoundary() {
        featureSessionBoundaryObservers =
            featureSessionBoundaryObservers.filter { $0.value() }
    }

    private static func serverErrorCode(in body: String) -> String? {
        guard let data = body.data(using: .utf8) else { return nil }
        return try? JSONDecoder().decode(
            ServerErrorEnvelope.self,
            from: data
        ).error
    }

    init(
        api: any AuthAPI = APIClient(),
        tokenStore: any AppTokenStore = KeychainTokenStore(),
        appleCredentialChecker: any AppleCredentialStateChecking =
            AppleCredentialStateChecker(),
        defaults: LocalPersistence = .standard,
        now: @escaping () -> Date = Date.init
    ) {
        self.api = api
        self.tokenStore = tokenStore
        self.appleCredentialChecker = appleCredentialChecker
        self.defaults = defaults
        self.now = now
        postDeletionAppleRevocationRequired = defaults.bool(
            forKey: Self.postDeletionAppleRevocationKey)
        let token = tokenStore.load()
        let persistedUserID = defaults.string(forKey: Self.userIDKey)
        if let token, Self.claims(of: token)?["app_review"] as? Bool == true,
           let reviewID = Self.subject(of: token) {
            guard defaults.set(true, forKey: AccountLocalState.reviewAccountKey(userID: reviewID)) else {
                phase = .error("Saved data needs recovery before reviewer sign-in.")
                return
            }
        }
        userID = persistedUserID
        if let current = readEntryIntents() {
            pendingEntryIntents = current.filter { $0.accountID == nil || $0.accountID == userID }
        }
        if let persistedUserID {
            // Bind process-global values to their preexisting owner before a
            // mismatched or malformed bearer can be rejected and replaced by
            // a different Apple account.
            AccountLocalState.bindLegacyState(
                userID: persistedUserID, defaults: defaults)
        }
        if let token, let tokenUserID = Self.subject(of: token) {
            if let persistedUserID, persistedUserID != tokenUserID {
                // A crash between the separate Keychain and LocalPersistence
                // writes can leave account A's local namespace beside account
                // B's bearer. Never enter the signed-in surface with that
                // mixed pair; preserve A's pointer for explicit recovery.
                tokenStore.clear()
                reauthenticationReason =
                    "Your saved session could not be matched to this account. Sign in again to reconnect it."
            } else {
                if persistedUserID == nil {
                    // Upgrade older installs that have a valid app JWT but
                    // predate the persisted account namespace.
                    defaults.set(tokenUserID, forKey: Self.userIDKey)
                    userID = tokenUserID
                    AccountLocalState.bindLegacyState(
                        userID: tokenUserID, defaults: defaults)
                }
                jwt = token
                phase = .signedIn
            }
        } else if token != nil {
            // Server app JWTs always carry `sub`. A malformed or legacy
            // credential cannot safely be paired with account-scoped state.
            tokenStore.clear()
            reauthenticationReason =
                "Your saved session needs to be renewed. Sign in again to reconnect this account."
        }
        // Migrate the prior install flag only to its known account. A newly
        // signed-in independent member must not inherit another member's setup.
        if let accountID = userID {
            let key = AccountLocalState.onboardedKey(userID: accountID)
            if defaults.object(forKey: key) == nil {
                defaults.set(defaults.object(forKey: Self.onboardedKey) as? Bool ?? (jwt != nil), forKey: key)
            }
            onboardingComplete = defaults.bool(forKey: key)
            defaults.removeObject(forKey: Self.onboardedKey)
        } else {
            onboardingComplete = false
            defaults.removeObject(forKey: Self.onboardedKey)
        }
        if let accountID = userID, jwt != nil { bindEntryIntents(to: accountID) }
        if let accountID = userID {
            appleCredentialUserID = defaults.string(
                forKey: AccountLocalState.appleCredentialUserKey(
                    userID: accountID))
            accountDeletionPending = defaults.string(
                forKey: AccountLocalState.accountDeletionKey(
                    userID: accountID)) != nil
        }
    }

    /// Mark first-run setup done (finished or skipped through). Persists so
    /// `OnboardingView` never shows again on this device.
    func completeOnboarding() {
        guard let accountID = userID, featureJWT != nil else { return }
        defaults.set(true, forKey: AccountLocalState.onboardedKey(userID: accountID))
        onboardingComplete = true
    }

    func handleAppleResult(_ result: Result<ASAuthorization, Error>) {
        switch result {
        case let .failure(error):
            phase = .error(error.localizedDescription)
        case let .success(auth):
            guard let cred = auth.credential as? ASAuthorizationAppleIDCredential else {
                phase = .error("No Apple identity token")
                return
            }
            let name = cred.fullName.flatMap { comps -> String? in
                let s = PersonNameComponentsFormatter().string(from: comps)
                return s.isEmpty ? nil : s
            }
            handleAppleCredential(
                identityToken: cred.identityToken.flatMap {
                    String(data: $0, encoding: .utf8)
                },
                authorizationCode: cred.authorizationCode.flatMap {
                    String(data: $0, encoding: .utf8)
                },
                fullName: name,
                appleUserID: cred.user)
        }
    }

    /// The native Sign in with Apple UI must supply both values. Keeping this
    /// validation in a small internal seam makes the user-visible failure
    /// deterministic without constructing AuthenticationServices objects in
    /// unit tests.
    func handleAppleCredential(
        identityToken: String?,
        authorizationCode: String?,
        fullName: String?,
        appleUserID: String
    ) {
        guard let identityToken, !identityToken.isEmpty else {
            phase = .error("No Apple identity token")
            return
        }
        guard let authorizationCode, !authorizationCode.isEmpty else {
            phase = .error(
                "Apple did not provide the authorization code required to sign in. Please try again.")
            return
        }
        Task {
            await exchange(
                identityToken: identityToken,
                fullName: fullName,
                appleUserID: appleUserID,
                authorizationCode: authorizationCode)
        }
    }

    func exchange(
        identityToken: String,
        fullName: String?,
        appleUserID: String? = nil,
        authorizationCode: String? = nil
    ) async {
        let requestID = UUID()
        signInRequestID = requestID
        let epoch = featureSessionEpoch
        phase = .working("Signing in…")
        do {
            let res = try await api.authApple(
                identityToken: identityToken,
                authorizationCode: authorizationCode,
                fullName: fullName)
            guard signInRequestID == requestID, featureSessionEpoch == epoch else { return }
            guard Self.subject(of: res.jwt) == res.user.id else {
                // This is an authentication-integrity failure, not malformed
                // response JSON. Keep the user-facing state specific instead
                // of routing it through APIError.decoding's "Decode failed"
                // prefix.
                phase = .error("session identity mismatch")
                return
            }
            finishSignIn(res, appleUserID: appleUserID)
        } catch {
            guard signInRequestID == requestID, featureSessionEpoch == epoch else { return }
            phase = .error(error.localizedDescription)
        }
    }

    func signInForReview(username: String, password: String) async {
        let requestID = UUID()
        signInRequestID = requestID
        let epoch = featureSessionEpoch
        guard !accountDeletionPending else { return }
        phase = .working("Signing in…")
        do {
            let res = try await api.authReview(username: username, password: password)
            guard signInRequestID == requestID, featureSessionEpoch == epoch else { return }
            guard Self.subject(of: res.jwt) == res.user.id,
                  Self.claims(of: res.jwt)?["app_review"] as? Bool == true else {
                phase = .error("session identity mismatch")
                return
            }
            // Never carry a personal invitation, coach intent, or unscoped
            // legacy training into the shared sample account.
            guard persistEntryIntents([]) else {
                phase = .error("Saved navigation needs recovery before changing accounts.")
                return
            }
            pendingEntryIntents = []
            finishSignIn(res, appleUserID: nil, review: true)
        } catch let APIError.http(code, _) {
            guard signInRequestID == requestID, featureSessionEpoch == epoch else { return }
            phase = .error(code == 401 ? "The reviewer username or password is incorrect."
                : "Reviewer sign-in is unavailable. Please try again later or contact support.")
        } catch {
            guard signInRequestID == requestID, featureSessionEpoch == epoch else { return }
            phase = .error("Could not connect. Check your connection and try again.")
        }
    }

    private func finishSignIn(_ res: AuthResponse, appleUserID: String?, review: Bool = false) {
        // A failed bind may leave previously unbound links on disk. Do
        // not let a different account claim them after reauthentication.
        if let previousAccount = userID, previousAccount != res.user.id {
            guard persistEntryIntents([]) else {
                phase = .error("Saved navigation needs recovery before changing accounts.")
                return
            }
            pendingEntryIntents = []
        }
        if featureJWT != nil {
            notifyFeatureSessionBoundary()
        }
        if review {
            guard defaults.set(true, forKey: AccountLocalState.reviewAccountKey(userID: res.user.id)) else {
                phase = .error("Saved data needs recovery before reviewer sign-in.")
                return
            }
        }
        if !review {
            AccountLocalState.bindLegacyState(userID: res.user.id, defaults: defaults)
        }
        featureSessionEpoch &+= 1
        tokenStore.save(res.jwt)
        jwt = res.jwt
        userID = res.user.id
        defaults.set(res.user.id, forKey: Self.userIDKey)
        accountDeletionPending = defaults.string(
            forKey: AccountLocalState.accountDeletionKey(
                userID: res.user.id)) != nil
        appleCredentialUserID = appleUserID
        if let appleUserID {
            defaults.set(
                appleUserID,
                forKey: AccountLocalState.appleCredentialUserKey(
                    userID: res.user.id))
        }
        reauthenticationReason = nil
        let onboardingKey = AccountLocalState.onboardedKey(userID: res.user.id)
        if review || defaults.object(forKey: onboardingKey) == nil {
            defaults.set(review, forKey: onboardingKey)
        }
        onboardingComplete = defaults.bool(forKey: onboardingKey)
        bindEntryIntents(to: res.user.id)
        phase = .signedIn
    }

    /// Decode unverified claims only to bind local account state and schedule
    /// renewal. The Worker remains the authority and verifies the signature on
    /// every authenticated request.
    private static func claims(of token: String) -> [String: Any]? {
        let parts = token.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 3 else { return nil }
        var encoded = String(parts[1])
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        let padding = (4 - encoded.count % 4) % 4
        encoded += String(repeating: "=", count: padding)
        guard let data = Data(base64Encoded: encoded) else { return nil }
        return try? JSONSerialization.jsonObject(with: data) as? [String: Any]
    }

    static func subject(of token: String) -> String? {
        guard let subject = claims(of: token)?["sub"] as? String,
              !subject.isEmpty
        else { return nil }
        return subject
    }

    static func expirationDate(of token: String) -> Date? {
        guard let exp = claims(of: token)?["exp"] as? NSNumber else { return nil }
        return Date(timeIntervalSince1970: exp.doubleValue)
    }

    static func shouldRenew(_ token: String, now: Date) -> Bool {
        guard let expiry = expirationDate(of: token) else { return true }
        return expiry.timeIntervalSince(now) <= renewalWindow
    }

    /// Renew before expiry while keeping the current signed-in surface usable.
    /// A network/offline failure preserves the existing JWT and local state;
    /// an authoritative 401 transitions to same-user reauthentication.
    func renewSessionIfNeeded(force: Bool = false) async {
        guard !isRenewing, let token = jwt else { return }
        guard force || Self.shouldRenew(token, now: now()) else { return }
        let initiatingUserID = userID
        isRenewing = true
        defer { isRenewing = false }
        do {
            let renewed = try await api.renewAppSession(jwt: token)
            guard jwt == token, userID == initiatingUserID else { return }
            guard Self.subject(of: renewed.jwt) == initiatingUserID else {
                requireReauthentication(
                    reason: "Your renewed session could not be matched to this account. Sign in again to reconnect it.")
                return
            }
            tokenStore.save(renewed.jwt)
            jwt = renewed.jwt
        } catch let APIError.http(code, _) where code == 401 {
            guard jwt == token, userID == initiatingUserID else { return }
            requireReauthentication()
        } catch {
            // Offline/transport failure is intentionally soft. The existing
            // token may still be valid and account-scoped state must survive.
        }
    }

    /// Ask Apple whether the persisted Sign in with Apple grant is still
    /// authorized. Revoked/not-found credentials move to a recoverable sign-in
    /// state while retaining the account id and all scoped queued data.
    /// Provider errors and transferred-team identities are soft: Apple's
    /// transferred subject requires a server-side migration, so ordinary
    /// reauthentication must not create a fresh empty account.
    func checkAppleCredentialState() async {
        guard
            let initiatingToken = jwt,
            let initiatingUserID = userID,
            let initiatingAppleUserID = appleCredentialUserID
        else { return }
        let state = await appleCredentialChecker.state(for: initiatingAppleUserID)
        guard
            jwt == initiatingToken,
            userID == initiatingUserID,
            appleCredentialUserID == initiatingAppleUserID
        else { return }
        switch state {
        case .authorized, .unavailable, .transferred:
            return
        case .revoked, .notFound:
            requireReauthentication(
                reason: "Your Apple authorization needs to be renewed. Sign in again to reconnect this account. Your queued workouts remain on this device.")
        }
    }

    /// Called on a 401. Drop only the invalid bearer: retain userID so the
    /// next Apple exchange can recover the same account namespace without
    /// erasing its outboxes, connection flags, or HealthKit anchor.
    func requireReauthentication(reason: String? = nil) {
        if accountDeletionPending, jwt != nil, userID != nil {
            reauthenticationReason = reason
                ?? "Account deletion is awaiting confirmation. Retry account deletion to finish."
            phase = .signedIn
            return
        }
        notifyFeatureSessionBoundary()
        featureSessionEpoch &+= 1
        tokenStore.clear()
        jwt = nil
        reauthenticationReason = reason
        phase = .signedOut
    }

    /// Explicit sign-out removes the current account pointer. Feature state is
    /// keyed by user id and remains isolated for a later return to that account.
    func signOut() {
        guard !accountDeletionPending else {
            reauthenticationReason =
                "Account deletion is awaiting confirmation. Retry account deletion to finish."
            return
        }
        guard persistEntryIntents([]) else { return }
        notifyFeatureSessionBoundary()
        featureSessionEpoch &+= 1
        tokenStore.clear()
        defaults.removeObject(forKey: Self.userIDKey)
        pendingEntryIntents = []
        entryPersistenceError = nil
        onboardingComplete = false
        jwt = nil
        userID = nil
        appleCredentialUserID = nil
        reauthenticationReason = nil
        phase = .signedOut
    }

    /// Permanently delete the server account, then erase only that account's
    /// local namespace. Nothing is cleared before the Worker confirms the
    /// account is gone through an acknowledgement or authenticated absence: a
    /// network/server failure leaves the signed-in account and every queued
    /// write intact so the user can retry safely.
    func deleteAccount() async throws {
        guard let token = jwt, let accountID = userID else {
            throw APIError.http(401, "missing_session")
        }
        let requiresAppleRevocation = !isReviewAccount
        let deletionKeyName = AccountLocalState.accountDeletionKey(userID: accountID)
        let idempotencyKey: String
        if let existingKey = defaults.string(forKey: deletionKeyName) {
            idempotencyKey = existingKey
        } else {
            idempotencyKey = UUID().uuidString
            defaults.set(idempotencyKey, forKey: deletionKeyName)
        }
        if userID == accountID, !accountDeletionPending {
            notifyFeatureSessionBoundary()
        }
        if userID == accountID {
            accountDeletionPending = true
        }
        let response: AccountDeletionResponse
        do {
            response = try await api.deleteAccount(
                jwt: token,
                idempotencyKey: idempotencyKey)
        } catch let APIError.http(code, body) where code == 401 {
            // A key-bound receipt retry is accepted even after the account row
            // is gone. An authoritative 401 means this bearer/key pair cannot
            // complete the deletion and ordinary reauthentication is needed.
            // Other failures preserve the key and bearer so an uncertain
            // request can be retried exactly.
            defaults.removeObject(forKey: deletionKeyName)
            if userID == accountID {
                accountDeletionPending = false
                let reason = body.contains("reauthentication_required")
                    ? (requiresAppleRevocation
                        ? "Sign in with Apple again to confirm account deletion."
                        : "Sign in again to confirm account deletion.")
                    : nil
                requireReauthentication(reason: reason)
            }
            throw APIError.http(code, body)
        } catch let APIError.http(code, body)
            where code == 404
                && Self.serverErrorCode(in: body) == "account_not_found" {
            // Only the Worker's typed absence contract proves the account no
            // longer exists and this device's receipt is unknown. A generic or
            // misrouted 404 must propagate so it cannot erase queued local
            // training while the server account may still exist. The explicit
            // confirmation that started this request authorizes cleanup once
            // this exact absence is returned.
            try completeAccountDeletion(
                for: accountID,
                requiresManualAppleRevocation: requiresAppleRevocation)
            return
        }
        guard response.ok else {
            throw APIError.decoding("account deletion was not acknowledged")
        }

        try completeAccountDeletion(
            for: accountID,
            requiresManualAppleRevocation:
                requiresAppleRevocation && response.apple_revocation != .revoked)
    }

    /// Always erase the account that initiated deletion, even if a different
    /// account became current while the request was in flight. Current auth
    /// state is reset only when it still belongs to the deleted account.
    private func completeAccountDeletion(
        for accountID: String,
        requiresManualAppleRevocation: Bool
    ) throws {
        let entryCleanup = userID != accountID || defaults.eraseAfterAccountDeletion(forKey: Self.pendingEntryKey)
        guard entryCleanup, AccountLocalState.clear(userID: accountID, defaults: defaults) else {
            throw APIError.decoding("The account was deleted, but saved data could not be removed from this iPhone. Unlock it, check available storage, and retry Delete account.")
        }
        // The explicitly confirmed deletion event owns this handoff even if a
        // different account became current while the request was in flight.
        // The UI handoff never mutates the replacement account.
        if requiresManualAppleRevocation {
            defaults.set(true, forKey: Self.postDeletionAppleRevocationKey)
            postDeletionAppleRevocationRequired = true
        }
        guard userID == accountID else { return }
        featureSessionEpoch &+= 1
        accountDeletionPending = false
        tokenStore.clear()
        defaults.removeObject(forKey: Self.userIDKey)
        defaults.removeObject(forKey: Self.onboardedKey)
        pendingEntryIntents = []
        entryPersistenceError = nil
        jwt = nil
        userID = nil
        appleCredentialUserID = nil
        reauthenticationReason = nil
        onboardingComplete = false
        phase = .signedOut
    }

    func dismissPostDeletionAppleRevocationHandoff() {
        defaults.removeObject(forKey: Self.postDeletionAppleRevocationKey)
        postDeletionAppleRevocationRequired = false
    }

    /// Fetch a portable snapshot for the currently signed-in account. Export
    /// is an ordinary feature request (never allowed while deletion is
    /// pending), and an account change or feature-session removal while the
    /// request is in flight discards the old account's bytes instead of
    /// presenting them in a different account's Profile UI. A same-account
    /// token renewal is safe: the export principal did not change.
    func downloadAccountExport() async throws -> AccountExportFile {
        guard let token = featureJWT, let accountID = userID else {
            throw APIError.http(401, "missing_session")
        }
        do {
            let file = try await api.downloadAccountExport(jwt: token)
            guard userID == accountID, featureJWT != nil else {
                throw APIError.decoding(
                    "the signed-in account changed while the export was downloading")
            }
            return file
        } catch let APIError.http(code, body) where code == 401 {
            if userID == accountID, featureJWT == token {
                requireReauthentication()
            }
            throw APIError.http(code, body)
        }
    }

    // MARK: - Universal Link invites

    /// Preserve validated invite navigation across interrupted sign-in and
    /// onboarding. Signed-in intents remain bound to that account.
    func handleDeepLink(_ url: URL) {
        guard let code = Self.inviteCode(from: url) else { return }
        requestEntry(.invite(code))
    }

    /// Pure parser (no side effects, so the rule is obvious and testable):
    /// the host must match the API host and the path must be exactly
    /// `/join/<code>`, where <code> normalizes to 6 chars of the invite
    /// alphabet. Returns nil otherwise.
    static func inviteCode(from url: URL) -> String? {
        guard let host = url.host, host == Config.apiBaseURL.host else { return nil }
        let parts = url.pathComponents.filter { $0 != "/" } // ["join", "ABC123"]
        guard parts.count == 2, parts[0] == "join" else { return nil }
        return normalizedInviteCode(parts[1])
    }

    /// Uppercase, strip to the 6-char base-32 invite alphabet (no I/L/O/0/1),
    /// require exactly 6. Mirrors the server's `normalizeInviteCode`
    /// (src/routes/invites.ts) and the in-app code fields.
    static func normalizedInviteCode(_ raw: String) -> String? {
        let alphabet = "ABCDEFGHJKMNPQRSTUVWXYZ23456789"
        let cleaned = raw.uppercased().filter { alphabet.contains($0) }
        return cleaned.count == 6 ? cleaned : nil
    }
}
