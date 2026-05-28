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
    /// Newly-redeemed group id (only set when /auth/apple was called with
    /// an invite_code). GroupModel watches this and pre-selects the group
    /// after first login. Cleared once GroupModel consumes it.
    @Published var pendingGroupID: String?

    private let api = APIClient()
    private static let userIDKey = "com.nmarkspdx.liftcoach.user-id.v1"
    /// Invite code captured from the sign-in form. Pulled in by the next
    /// `handleAppleResult` call so we don't have to thread it through the
    /// SignInWithAppleButton's `onCompletion`.
    var pendingInviteCode: String?

    init() {
        if let token = Keychain.load() {
            jwt = token
            phase = .signedIn
        }
        userID = UserDefaults.standard.string(forKey: Self.userIDKey)
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
            let code = pendingInviteCode
            pendingInviteCode = nil   // consume; one-shot
            Task { await exchange(identityToken: identityToken, fullName: name,
                                  inviteCode: code) }
        }
    }

    private func exchange(identityToken: String,
                          fullName: String?,
                          inviteCode: String?) async {
        phase = .working("Signing in…")
        do {
            let res = try await api.authApple(
                identityToken: identityToken,
                fullName: fullName,
                inviteCode: inviteCode)
            Keychain.save(res.jwt)
            jwt = res.jwt
            userID = res.user.id
            UserDefaults.standard.set(res.user.id, forKey: Self.userIDKey)
            if let gid = res.group_id { pendingGroupID = gid }
            phase = .signedIn
        } catch let APIError.http(code, body) where code == 403 && body.contains("not_invited") {
            // Map the backend's `not_invited` 403 to a friendly message —
            // this is the most common new-user failure (typo'd code, expired
            // code, or no code on a non-owner Apple sub).
            phase = .error("This invite is invalid or expired.")
        } catch {
            phase = .error(error.localizedDescription)
        }
    }

    /// Called by the data layer on a 401 (stale JWT) → force re-auth.
    func invalidate() {
        Keychain.clear()
        UserDefaults.standard.removeObject(forKey: Self.userIDKey)
        jwt = nil
        userID = nil
        pendingGroupID = nil
        phase = .signedOut
    }

    func signOut() { invalidate() }
}
