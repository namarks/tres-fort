import AuthenticationServices
import Foundation
import SwiftUI

struct RootView: View {
    @EnvironmentObject private var model: AuthModel

    var body: some View {
        Group {
            switch model.phase {
            case .signedIn:
                if model.onboardingComplete {
                    MainTabView(auth: model)
                } else {
                    OnboardingView(auth: model)
                }
            default:
                ZStack {
                    Color.black.ignoresSafeArea()
                    VStack(spacing: 28) {
                        Text("TRÈS FORT")
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
        // Universal Link entry: a tapped https://…/join/<code> routes here
        // (onOpenURL on iOS 14+, plus the canonical web-browsing activity
        // hook for belt-and-suspenders). Both funnel into AuthModel, which
        // validates + stashes the code for MainTabView to present — so it
        // works whether or not we're signed in yet.
        .onOpenURL { model.handleDeepLink($0) }
        .onContinueUserActivity(NSUserActivityTypeBrowsingWeb) { activity in
            if let url = activity.webpageURL { model.handleDeepLink(url) }
        }
    }

    private var signedOut: some View {
        SignedOutView(model: model)
    }
}

/// Open sign-in. Anyone can sign in with Apple; no invite code required.
/// Invited friends sign in first, then redeem their code from inside the
/// Group tab via "Join with code" — that path lives entirely in the
/// signed-in app surface, so the sign-in screen stays a single button.
private struct SignedOutView: View {
    @ObservedObject var model: AuthModel

    var body: some View {
        VStack(spacing: 16) {
            Text("Your coach owns the plan.\nSign in to sync.")
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)

            SignInWithAppleButton(.signIn,
                                  onRequest: { req in
                                      req.requestedScopes = [.fullName, .email]
                                  },
                                  onCompletion: model.handleAppleResult)
                .signInWithAppleButtonStyle(.white)
                .frame(height: 50)
                .cornerRadius(10)

            if case let .error(msg) = model.phase {
                Text(msg)
                    .font(.footnote)
                    .foregroundStyle(.red)
                    .multilineTextAlignment(.center)
            }
        }
    }
}
