import AuthenticationServices
import SwiftUI

struct RootView: View {
    @EnvironmentObject private var model: AuthModel

    var body: some View {
        Group {
            switch model.phase {
            case .signedIn:
                MainTabView(auth: model)
            default:
                ZStack {
                    Color.black.ignoresSafeArea()
                    VStack(spacing: 28) {
                        Text("TRES FORTE")
                            .font(Theme.display(40)).tracking(2)
                            .foregroundStyle(.white)
                        if case let .working(msg) = model.phase {
                            ProgressView(msg).tint(.white).foregroundStyle(.white)
                        } else {
                            signedOut
                        }
                    }
                    .padding(32)
                }
                .preferredColorScheme(.dark)
            }
        }
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
}
