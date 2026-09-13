import SwiftUI

struct CoachApprovalPreview: Decodable, Equatable {
    let client_name: String
    let redirect_uri: String
    let expires_at: Double
}

struct CoachApprovalDecision: Decodable, Equatable {
    let redirect_uri: String
    let allowed: Bool
}

protocol CoachApprovalAPI {
    func coachApproval(id: String, jwt: String) async throws -> CoachApprovalPreview
    func decideCoachApproval(id: String, allow: Bool, jwt: String) async throws -> CoachApprovalDecision
}

extension APIClient: CoachApprovalAPI {
    func coachApproval(id: String, jwt: String) async throws -> CoachApprovalPreview {
        try await get("api/coach-requests/\(id)", jwt: jwt)
    }

    func decideCoachApproval(id: String, allow: Bool, jwt: String) async throws -> CoachApprovalDecision {
        try await post("api/coach-requests/\(id)", body: ["decision": allow ? "allow" : "deny"], jwt: jwt)
    }
}

@MainActor
final class CoachApprovalModel: ObservableObject {
    enum State: Equatable {
        case loading, review(CoachApprovalPreview), sending
        case finished(CoachApprovalDecision), failed(String)
    }
    @Published private(set) var state: State = .loading
    private let auth: AuthModel
    private let accountID: String?
    private let epoch: UInt64
    private let requestID: String
    private let api: any CoachApprovalAPI

    init(auth: AuthModel, requestID: String, api: any CoachApprovalAPI = APIClient()) {
        self.auth = auth
        accountID = auth.userID
        epoch = auth.featureSessionEpoch
        self.requestID = requestID
        self.api = api
    }

    private var isCurrent: Bool { auth.isCurrentFeatureSession(accountID: accountID, epoch: epoch) }

    func load() async {
        await load(retryAfterRenewal: true)
    }

    private func load(retryAfterRenewal: Bool) async {
        guard isCurrent, let jwt = auth.featureJWT, state == .loading else { return }
        do {
            let preview = try await api.coachApproval(id: requestID, jwt: jwt)
            guard isCurrent else { return }
            guard Self.httpsURL(preview.redirect_uri) != nil,
                  preview.expires_at > Date().timeIntervalSince1970 * 1000 else {
                state = .failed("This connection request has expired or is unavailable. Start connecting again in your AI app.")
                return
            }
            state = .review(preview)
        } catch {
            guard isCurrent else { return }
            if case APIError.http(401, _) = error {
                if auth.featureJWT == jwt {
                    auth.requireReauthentication(reason: "Sign in again to finish connecting your AI app.")
                    return
                }
                // A normal renewal can overtake this read. Retry once with
                // the new bearer without invalidating that healthy session.
                if retryAfterRenewal {
                    await load(retryAfterRenewal: false)
                    return
                }
            }
            state = .failed("Could not load this connection request. Start connecting again in your AI app.")
        }
    }

    func decide(allow: Bool) async {
        guard isCurrent, let jwt = auth.featureJWT, case let .review(preview) = state else { return }
        guard preview.expires_at > Date().timeIntervalSince1970 * 1000 else {
            state = .failed("This request expired. Start connecting again in your AI app.")
            return
        }
        state = .sending // Synchronous latch: repeated taps cannot issue two decisions.
        do {
            let decision = try await api.decideCoachApproval(id: requestID, allow: allow, jwt: jwt)
            if decision.allowed { auth.noteAccountStatePersisted(for: accountID) }
            guard isCurrent else { return }
            guard Self.httpsURL(decision.redirect_uri) != nil else {
                state = .failed("Your decision was saved, but the return link is unavailable. Return to your AI app to reconnect.")
                return
            }
            state = .finished(decision)
        } catch {
            guard isCurrent else { return }
            if case APIError.http(401, _) = error {
                // Auth middleware rejected this request before any write.
                // Retain the account-bound intent through reauthentication.
                // An old-bearer rejection reloads consent, never the decision.
                if auth.featureJWT == jwt {
                    auth.requireReauthentication(reason: "Sign in again to finish connecting your AI app.")
                } else {
                    state = .loading
                    await load()
                }
                return
            }
            // An uncertain response may already have committed. Never repeat
            // an approval or claim denial from a transport failure.
            state = .failed("Could not confirm your decision. Start a new connection in your AI app. You can disconnect AI apps in Profile to stop access.")
        }
    }

    static func httpsURL(_ value: String) -> URL? {
        guard let url = URL(string: value), url.scheme == "https", url.host != nil,
              url.user == nil, url.password == nil, url.fragment == nil else { return nil }
        return url
    }
}

struct CoachApprovalView: View {
    @StateObject private var model: CoachApprovalModel
    @Environment(\.openURL) private var openURL
    let accountName: String
    let onDone: () -> Void

    init(auth: AuthModel, requestID: String, accountName: String, onDone: @escaping () -> Void) {
        _model = StateObject(wrappedValue: CoachApprovalModel(auth: auth, requestID: requestID))
        self.accountName = accountName
        self.onDone = onDone
    }

    var body: some View {
        NavigationStack {
            List {
                switch model.state {
                case .loading, .sending:
                    ProgressView(model.state == .sending ? "Saving your decision…" : "Loading request…")
                case let .review(preview):
                    Section("Connect your account") {
                        Text(accountName).font(.headline)
                        Text("App name supplied by the connecting client: \(preview.client_name)")
                        Text("Return address: \(preview.redirect_uri)").font(.footnote)
                        Text("Only allow access if you started this connection in an app you trust.")
                    }
                    Section("Requested access") {
                        Text("Read your training profile and plan, workout history, saved feedback and available group information, including imported Apple Health and Intervals.icu workouts.")
                        Text("Change your plan and record training updates.")
                        Text("Your AI app and its configured model provider receive the information they request. Review their privacy policies before approving. Apple Health group sharing does not limit your own coach’s access.")
                        Text("Disconnect AI apps in Profile to stop future access. This does not delete data already retrieved into AI conversations.")
                        PrivacyPolicyLink()
                    }
                    Section {
                        Button("Allow access") { Task { await model.decide(allow: true) } }
                            .accessibilityIdentifier("coach-approval.allow")
                        Button("Deny access", role: .cancel) { Task { await model.decide(allow: false) } }
                            .accessibilityIdentifier("coach-approval.deny")
                    }
                case let .finished(decision):
                    Section {
                        Text(decision.allowed ? "Access allowed" : "Access denied").font(.headline)
                        Text("Continue in your AI app to finish connecting.")
                        if let url = CoachApprovalModel.httpsURL(decision.redirect_uri) {
                            Button("Continue to AI app") { openURL(url) }
                                .accessibilityIdentifier("coach-approval.continue")
                        }
                    }
                case let .failed(message):
                    Text(message).accessibilityIdentifier("coach-approval.error")
                }
            }
            .navigationTitle("Review AI access")
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Done", action: onDone) } }
            .task { await model.load() }
        }
    }
}
