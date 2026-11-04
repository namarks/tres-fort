import AuthenticationServices
import Foundation
import UIKit

// intervals.icu OAuth — the iOS half of the "Connect with intervals.icu" flow.
//
// Flow: POST /auth/intervals/start (app-JWT) → authorize URL → open it in an
// ASWebAuthenticationSession → the user logs in to intervals.icu and approves
// → intervals redirects to our Worker callback, which (server-side) exchanges
// the code for a bearer token and bounces back to `tresfort://intervals-
// connected?completion=...`. The original app session submits that secret to
// /finish before the Worker activates the connection. Provider tokens stay on
// the Worker; the browser return alone cannot acknowledge a connection.

extension APIClient {
    /// Begin the OAuth flow; returns the intervals.icu authorize URL the app
    /// should hand to ASWebAuthenticationSession. The Worker has stored a
    /// single-use state→user mapping behind it.
    func startIntervalsOAuth(jwt: String) async throws -> URL {
        struct Resp: Decodable { let authorize_url: String }
        let r: Resp = try await post("auth/intervals/start", body: [:], jwt: jwt)
        guard let url = URL(string: r.authorize_url) else {
            throw APIError.decoding("malformed authorize_url")
        }
        return url
    }
    func finishIntervalsOAuth(completion: String, jwt: String) async throws -> IntervalsOAuthResult {
        try await post("auth/intervals/finish", body: ["completion": completion], jwt: jwt)
    }

}

struct IntervalsOAuthResult: Decodable, Equatable {
    let connected: Bool
    var credentialGeneration: Int? = nil
    var activitySyncAfter: Int? = nil
    var completion: String? = nil
    enum CodingKeys: String, CodingKey {
        case connected
        case credentialGeneration = "credential_generation"
        case activitySyncAfter = "activity_sync_after"
    }

    static func parse(_ url: URL) throws -> Self {
        guard url.scheme == "tresfort", url.host == "intervals-connected" else {
            throw APIError.decoding("invalid intervals callback")
        }
        let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
        guard items.count == 1, items[0].name == "completion", let secret = items[0].value,
              secret.count == 43,
              secret.allSatisfy({ "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789_-".contains($0) }) else {
            throw APIError.decoding("invalid intervals completion")
        }
        return Self(connected: false, completion: secret)
    }
}

/// Runs one ASWebAuthenticationSession and resolves to connected / cancelled.
/// Plain NSObject (not @MainActor) so it can satisfy the synchronous, non-
/// isolated `presentationAnchor` requirement cleanly; callers invoke
/// `authorize` from the main actor (GroupModel is @MainActor). Retains the
/// session itself for the duration so the caller only needs to hold the runner.
final class IntervalsWebAuth: NSObject, ASWebAuthenticationPresentationContextProviding {
    /// The custom scheme the Worker callback redirects to. Intercepted by the
    /// session — no Info.plist URL-type registration is required for this.
    static let callbackScheme = "tresfort"

    private var session: ASWebAuthenticationSession?

    func presentationAnchor(for _: ASWebAuthenticationSession) -> ASPresentationAnchor {
        UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .flatMap { $0.windows }
            .first { $0.isKeyWindow } ?? ASPresentationAnchor()
    }

    /// Present the auth sheet. Returns the accepted connection/import outcome,
    /// or `connected: false` if dismissed/cancelled, and throws on a real
    /// failure (intervals error, malformed callback, couldn't start).
    @MainActor
    func authorize(_ url: URL) async throws -> IntervalsOAuthResult {
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<IntervalsOAuthResult, Error>) in
            let s = ASWebAuthenticationSession(
                url: url,
                callbackURLScheme: Self.callbackScheme
            ) { [weak self] callbackURL, error in
                self?.session = nil
                if let error {
                    // A user-dismissed sheet is a benign cancel, not an error.
                    if (error as? ASWebAuthenticationSessionError)?.code == .canceledLogin {
                        cont.resume(returning: .init(connected: false))
                    } else {
                        cont.resume(throwing: error)
                    }
                    return
                }
                guard let callbackURL else {
                    // No error AND no callback URL → an interrupted/dismissed
                    // session (a documented edge case). Treat it as a benign
                    // cancel so the user can simply retry, not a hard failure.
                    cont.resume(returning: .init(connected: false))
                    return
                }
                do { cont.resume(returning: try IntervalsOAuthResult.parse(callbackURL)) }
                catch { cont.resume(throwing: error) }
            }
            s.presentationContextProvider = self
            // Reuse an existing intervals.icu web session if the user is
            // already logged in there (don't force a fresh login each time).
            s.prefersEphemeralWebBrowserSession = false
            session = s
            if !s.start() {
                session = nil
                cont.resume(throwing: APIError.http(0, "couldn't start web auth"))
            }
        }
    }
}
