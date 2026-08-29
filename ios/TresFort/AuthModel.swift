import AuthenticationServices
import Foundation
import SwiftUI

@MainActor
final class AuthModel: ObservableObject {
    enum Phase: Equatable {
        case signedOut
        case working(String)
        case signedIn
        case error(String)
    }

    @Published var phase: Phase = .signedOut
    @Published var jwt: String?
    @Published private(set) var isRenewing = false
    @Published private(set) var appleCredentialUserID: String?
    @Published private(set) var reauthenticationReason: String?
    /// A durable DELETE /api/me attempt has not yet been acknowledged. While
    /// this is true the current bearer is the only credential that can replay
    /// the key-bound deletion receipt after a lost response, so background
    /// 401s and explicit sign-out must not discard it.
    @Published private(set) var accountDeletionPending = false
    /// Ordinary feature models must not use the bearer while DELETE /api/me
    /// is unresolved. `jwt` itself remains available only so AuthModel can
    /// replay the key-bound deletion receipt after a lost response.
    var featureJWT: String? {
        accountDeletionPending ? nil : jwt
    }
    /// Server user id, captured from /auth/apple's `user.id` and persisted
    /// in UserDefaults so GroupModel can survive an app relaunch with the
    /// keychain JWT alone. Used as the fallback for `is_me` comparisons
    /// against /api/groups members (the M2 list endpoint doesn't stamp
    /// `is_me` — only /feed and /stats do).
    @Published var userID: String?

    /// Drives whether RootView shows the first-run `OnboardingView` or the
    /// main app. `false` ⇒ a brand-new sign-in that hasn't been guided
    /// through setup yet. Persisted so it survives relaunch and never
    /// re-fires once completed. See the grandfathering logic in `init`.
    @Published var onboardingComplete: Bool

    /// A group invite code captured from a Universal Link
    /// (https://…/join/<code>) that hasn't been acted on yet. MainTabView
    /// observes this and presents the join-confirm sheet once the signed-in
    /// surface is on screen — so a link tapped while signed out or mid-
    /// onboarding is honored right after the user finishes signing in. Set by
    /// `handleDeepLink`, cleared when the sheet is dismissed.
    @Published var pendingInviteCode: String?

    private let api: any AuthAPI
    private let tokenStore: any AppTokenStore
    private let appleCredentialChecker: any AppleCredentialStateChecking
    private let defaults: UserDefaults
    private let now: () -> Date
    static let userIDKey = "com.nmarkspdx.liftcoach.user-id.v1"
    static let onboardedKey = "com.nmarkspdx.liftcoach.onboarded.v1"
    static let renewalWindow: TimeInterval = 7 * 24 * 60 * 60

    init(
        api: any AuthAPI = APIClient(),
        tokenStore: any AppTokenStore = KeychainTokenStore(),
        appleCredentialChecker: any AppleCredentialStateChecking =
            AppleCredentialStateChecker(),
        defaults: UserDefaults = .standard,
        now: @escaping () -> Date = Date.init
    ) {
        self.api = api
        self.tokenStore = tokenStore
        self.appleCredentialChecker = appleCredentialChecker
        self.defaults = defaults
        self.now = now
        let token = tokenStore.load()
        let persistedUserID = defaults.string(forKey: Self.userIDKey)
        userID = persistedUserID
        if let token, let tokenUserID = Self.subject(of: token) {
            if let persistedUserID, persistedUserID != tokenUserID {
                // A crash between the separate Keychain and UserDefaults
                // writes can leave account A's local namespace beside account
                // B's bearer. Never enter the signed-in surface with that
                // mixed pair; preserve A's pointer for explicit recovery.
                tokenStore.clear()
                reauthenticationReason =
                    "Your saved session could not be matched to this account. Sign in with Apple again to reconnect it."
            } else {
                if persistedUserID == nil {
                    // Upgrade older installs that have a valid app JWT but
                    // predate the persisted account namespace.
                    defaults.set(tokenUserID, forKey: Self.userIDKey)
                    userID = tokenUserID
                }
                jwt = token
                phase = .signedIn
            }
        } else if token != nil {
            // Server app JWTs always carry `sub`. A malformed or legacy
            // credential cannot safely be paired with account-scoped state.
            tokenStore.clear()
            reauthenticationReason =
                "Your saved session needs to be renewed. Sign in with Apple again to reconnect this account."
        }
        // First launch of a build that has onboarding: if the user is
        // ALREADY signed in (an existing install updating in place), treat
        // them as onboarded so the app update never drops a returning user
        // back into the intro. Fresh installs (no keychain token) default to
        // NOT onboarded → they get the guided setup right after their first
        // sign-in. Sign-out does NOT reset this, so a
        // returning user re-signing in skips onboarding.
        if defaults.object(forKey: Self.onboardedKey) == nil {
            defaults.set(token != nil, forKey: Self.onboardedKey)
        }
        onboardingComplete = defaults.bool(forKey: Self.onboardedKey)
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
        defaults.set(true, forKey: Self.onboardedKey)
        onboardingComplete = true
    }

    func handleAppleResult(_ result: Result<ASAuthorization, Error>) {
        switch result {
        case let .failure(error):
            phase = .error(error.localizedDescription)
        case let .success(auth):
            guard
                let cred = auth.credential as? ASAuthorizationAppleIDCredential,
                let tokenData = cred.identityToken,
                let identityToken = String(data: tokenData, encoding: .utf8)
            else {
                phase = .error("No Apple identity token")
                return
            }
            let name = cred.fullName.flatMap { comps -> String? in
                let s = PersonNameComponentsFormatter().string(from: comps)
                return s.isEmpty ? nil : s
            }
            Task {
                await exchange(
                    identityToken: identityToken,
                    fullName: name,
                    appleUserID: cred.user)
            }
        }
    }

    func exchange(
        identityToken: String,
        fullName: String?,
        appleUserID: String? = nil
    ) async {
        phase = .working("Signing in…")
        do {
            let res = try await api.authApple(
                identityToken: identityToken,
                fullName: fullName)
            guard Self.subject(of: res.jwt) == res.user.id else {
                throw APIError.decoding("session identity mismatch")
            }
            tokenStore.save(res.jwt)
            jwt = res.jwt
            userID = res.user.id
            defaults.set(res.user.id, forKey: Self.userIDKey)
            accountDeletionPending = defaults.string(
                forKey: AccountLocalState.accountDeletionKey(
                    userID: res.user.id)) != nil
            if let appleUserID {
                appleCredentialUserID = appleUserID
                defaults.set(
                    appleUserID,
                    forKey: AccountLocalState.appleCredentialUserKey(
                        userID: res.user.id))
            }
            reauthenticationReason = nil
            phase = .signedIn
        } catch {
            phase = .error(error.localizedDescription)
        }
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
                    reason: "Your renewed session could not be matched to this account. Sign in with Apple again to reconnect it.")
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
                reason: "Your Apple authorization needs to be renewed. Sign in with Apple again to reconnect this account. Your queued workouts remain on this device.")
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
        tokenStore.clear()
        defaults.removeObject(forKey: Self.userIDKey)
        jwt = nil
        userID = nil
        appleCredentialUserID = nil
        reauthenticationReason = nil
        phase = .signedOut
    }

    /// Permanently delete the server account, then erase only that account's
    /// local namespace. Nothing is cleared before the Worker acknowledges the
    /// transaction: a network/server failure leaves the signed-in account and
    /// every queued write intact so the user can retry safely.
    func deleteAccount() async throws {
        guard let token = jwt, let accountID = userID else {
            throw APIError.http(401, "missing_session")
        }
        let deletionKeyName = AccountLocalState.accountDeletionKey(userID: accountID)
        let idempotencyKey: String
        if let existingKey = defaults.string(forKey: deletionKeyName) {
            idempotencyKey = existingKey
        } else {
            idempotencyKey = UUID().uuidString
            defaults.set(idempotencyKey, forKey: deletionKeyName)
        }
        if userID == accountID {
            accountDeletionPending = true
        }
        let response: AccountDeletionResponse
        do {
            response = try await api.deleteAccount(
                jwt: token,
                idempotencyKey: idempotencyKey)
        } catch let APIError.http(code, body) where code == 401 || code == 404 {
            // A key-bound receipt retry is accepted even after the account row
            // is gone. An authoritative 401 or a 404 receipt mismatch therefore
            // means this bearer/key pair cannot complete the deletion and
            // ordinary reauthentication is needed. Other failures preserve the
            // key and bearer so an uncertain request can be retried exactly.
            defaults.removeObject(forKey: deletionKeyName)
            if userID == accountID {
                accountDeletionPending = false
                requireReauthentication()
            }
            throw APIError.http(code, body)
        }
        guard response.ok else {
            throw APIError.decoding("account deletion was not acknowledged")
        }

        // Always erase the account that initiated deletion, even if the user
        // signed out or switched accounts while the request was in flight.
        AccountLocalState.clear(userID: accountID, defaults: defaults)
        if userID == accountID {
            accountDeletionPending = false
            tokenStore.clear()
            defaults.removeObject(forKey: Self.userIDKey)
            defaults.removeObject(forKey: Self.onboardedKey)
            jwt = nil
            userID = nil
            appleCredentialUserID = nil
            reauthenticationReason = nil
            onboardingComplete = false
            phase = .signedOut
        }
    }

    // MARK: - Universal Link invites

    /// Handle an inbound Universal Link. If it carries a well-formed group
    /// invite code, stash it in `pendingInviteCode` for the signed-in surface
    /// to present. Anything else (including the intervals.icu OAuth callback,
    /// which never reaches here — `ASWebAuthenticationSession` consumes it) is
    /// ignored. Deliberately does NOT clear on a different sign-in: whoever
    /// signs in after tapping the link is the one who gets to join.
    func handleDeepLink(_ url: URL) {
        guard let code = Self.inviteCode(from: url) else { return }
        pendingInviteCode = code
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
