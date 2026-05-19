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

    private let api = APIClient()

    init() {
        if let token = Keychain.load() {
            jwt = token
            phase = .signedIn
        }
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
            let res = try await api.authApple(identityToken: identityToken, fullName: fullName)
            Keychain.save(res.jwt)
            jwt = res.jwt
            phase = .signedIn
        } catch {
            phase = .error(error.localizedDescription)
        }
    }

    /// Called by the data layer on a 401 (stale JWT) → force re-auth.
    func invalidate() {
        Keychain.clear()
        jwt = nil
        phase = .signedOut
    }

    func signOut() { invalidate() }
}
