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
        if let token {
            jwt = token
            phase = .signedIn
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
        let persistedUserID = defaults.string(forKey: Self.userIDKey)
        userID = persistedUserID
        if let persistedUserID {
            appleCredentialUserID = defaults.string(
                forKey: AccountLocalState.appleCredentialUserKey(
                    userID: persistedUserID))
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
            tokenStore.save(res.jwt)
            jwt = res.jwt
            userID = res.user.id
            defaults.set(res.user.id, forKey: Self.userIDKey)
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

    /// Decode the unverified expiry claim only to schedule renewal. The Worker
    /// remains the authority and verifies the signature on /auth/renew.
    static func expirationDate(of token: String) -> Date? {
        let parts = token.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 3 else { return nil }
        var encoded = String(parts[1])
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        let padding = (4 - encoded.count % 4) % 4
        encoded += String(repeating: "=", count: padding)
        guard let data = Data(base64Encoded: encoded),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let exp = object["exp"] as? NSNumber
        else { return nil }
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
    /// authorized. Revoked/not-found/transferred credentials move to a
    /// recoverable sign-in state while retaining the account id and all scoped
    /// queued data. Provider errors are soft so offline launch remains usable.
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
        case .authorized, .unavailable:
            return
        case .revoked, .notFound, .transferred:
            requireReauthentication(
                reason: "Your Apple authorization needs to be renewed. Sign in with Apple again to reconnect this account. Your queued workouts remain on this device.")
        }
    }

    /// Called on a 401. Drop only the invalid bearer: retain userID so the
    /// next Apple exchange can recover the same account namespace without
    /// erasing its outboxes, connection flags, or HealthKit anchor.
    func requireReauthentication(reason: String? = nil) {
        tokenStore.clear()
        jwt = nil
        reauthenticationReason = reason
        phase = .signedOut
    }

    /// Explicit sign-out removes the current account pointer. Feature state is
    /// keyed by user id and remains isolated for a later return to that account.
    func signOut() {
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
        let response = try await api.deleteAccount(
            jwt: token,
            idempotencyKey: idempotencyKey)
        guard response.ok else {
            throw APIError.decoding("account deletion was not acknowledged")
        }

        // Always erase the account that initiated deletion, even if the user
        // signed out or switched accounts while the request was in flight.
        AccountLocalState.clear(userID: accountID, defaults: defaults)
        if userID == accountID {
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
