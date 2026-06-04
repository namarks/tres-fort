import AuthenticationServices
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

    private let api = APIClient()
    private static let userIDKey = "com.nmarkspdx.liftcoach.user-id.v1"
    private static let onboardedKey = "com.nmarkspdx.liftcoach.onboarded.v1"

    init() {
        let token = Keychain.load()
        if let token {
            jwt = token
            phase = .signedIn
        }
        userID = UserDefaults.standard.string(forKey: Self.userIDKey)
        // First launch of a build that has onboarding: if the user is
        // ALREADY signed in (an existing install updating in place), treat
        // them as onboarded so the app update never drops a returning user
        // back into the intro. Fresh installs (no keychain token) default to
        // NOT onboarded → they get the guided setup right after their first
        // sign-in. Sign-out does NOT reset this (invalidate leaves it), so a
        // returning user re-signing in skips onboarding.
        let defaults = UserDefaults.standard
        if defaults.object(forKey: Self.onboardedKey) == nil {
            defaults.set(token != nil, forKey: Self.onboardedKey)
        }
        onboardingComplete = defaults.bool(forKey: Self.onboardedKey)
    }

    /// Mark first-run setup done (finished or skipped through). Persists so
    /// `OnboardingView` never shows again on this device.
    func completeOnboarding() {
        UserDefaults.standard.set(true, forKey: Self.onboardedKey)
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
            Task { await exchange(identityToken: identityToken, fullName: name) }
        }
    }

    private func exchange(identityToken: String, fullName: String?) async {
        phase = .working("Signing in…")
        do {
            let res = try await api.authApple(
                identityToken: identityToken,
                fullName: fullName)
            Keychain.save(res.jwt)
            jwt = res.jwt
            userID = res.user.id
            UserDefaults.standard.set(res.user.id, forKey: Self.userIDKey)
            phase = .signedIn
        } catch {
            phase = .error(error.localizedDescription)
        }
    }

    /// Called by the data layer on a 401 (stale JWT) → force re-auth.
    /// Also clears every piece of PER-USER state persisted on the device:
    ///   - keychain JWT,
    ///   - userID (UserDefaults),
    ///   - the activity outbox (entries have no user_id baked in, so on
    ///     re-auth as a different account they would POST through the
    ///     new user's JWT and mis-attribute the rows),
    ///   - the intervals.icu connection record (the AppStorage key is
    ///     device-global but its content represents the current user's
    ///     athlete connection — a different signed-in user must not see
    ///     the previous user's athlete id as "connected").
    func invalidate() {
        Keychain.clear()
        UserDefaults.standard.removeObject(forKey: Self.userIDKey)
        UserDefaults.standard.removeObject(forKey: GroupModel.intervalsConnectionKey)
        ActivityOutboxStore.clear()
        jwt = nil
        userID = nil
        phase = .signedOut
    }

    func signOut() { invalidate() }

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
