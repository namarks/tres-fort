import AuthenticationServices
import SwiftUI

struct RootView: View {
    @EnvironmentObject private var model: AuthModel

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            VStack(spacing: 28) {
                Text("LIFT-COACH")
                    .font(.system(size: 34, weight: .heavy, design: .default))
                    .tracking(2)
                    .foregroundStyle(.white)

                switch model.phase {
                case .signedOut, .error:
                    signedOut
                case let .working(msg):
                    ProgressView(msg).tint(.white).foregroundStyle(.white)
                case .signedIn:
                    signedIn
                }
            }
            .padding(32)
        }
        .preferredColorScheme(.dark)
    }

    private var signedOut: some View {
        VStack(spacing: 16) {
            Text("Your coach owns the plan.\nSign in to sync.")
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)

            SignInWithAppleButton(.signIn,
                                   onRequest: { $0.requestedScopes = [.fullName, .email] },
                                   onCompletion: model.handleAppleResult)
                .signInWithAppleButtonStyle(.white)
                .frame(height: 50)
                .cornerRadius(10)

            if case let .error(msg) = model.phase {
                Text(msg).font(.footnote).foregroundStyle(.red).multilineTextAlignment(.center)
            }
        }
    }

    private var signedIn: some View {
        VStack(spacing: 20) {
            Image(systemName: "checkmark.seal.fill")
                .font(.system(size: 44)).foregroundStyle(.green)
            Text("Connected to the live backend")
                .foregroundStyle(.white).fontWeight(.semibold)
            Text(model.stateSummary ?? "Loading…")
                .font(.system(.body, design: .monospaced))
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)

            HStack(spacing: 12) {
                Button("Refresh") { Task { await model.refreshState() } }
                    .buttonStyle(.borderedProminent).tint(.white).foregroundStyle(.black)
                Button("Sign out") { model.signOut() }
                    .buttonStyle(.bordered).tint(.gray)
            }
        }
    }
}
