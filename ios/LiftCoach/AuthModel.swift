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
    @Published var stateSummary: String?

    private let api = APIClient()

    init() {
        if let token = Keychain.load() {
            jwt = token
            phase = .signedIn
            Task { await refreshState() }
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
                let f = PersonNameComponentsFormatter()
                let s = f.string(from: comps)
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
            await refreshState()
        } catch {
            phase = .error(error.localizedDescription)
        }
    }

    func refreshState() async {
        guard let jwt else { return }
        do {
            let s = try await api.getState(jwt: jwt)
            let plan = s.plan.map { "\($0.name) (v\($0.version))" } ?? "no active plan"
            stateSummary = "Plan: \(plan)\nSessions: \(s.sessions.count) · Sets: \(s.sets.count)"
        } catch {
            // A 401 means the JWT is stale → force re-auth.
            if case let APIError.http(code, _) = error, code == 401 { signOut() }
            stateSummary = "State error: \(error.localizedDescription)"
        }
    }

    func signOut() {
        Keychain.clear()
        jwt = nil
        stateSummary = nil
        phase = .signedOut
    }
}
