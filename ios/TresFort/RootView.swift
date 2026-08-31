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
        // ActivityKit restores records independently of authentication and
        // onboarding. RootView is always mounted, so process-death cleanup also
        // runs for signed-out, expired-credential, and first-run launches.
        .task {
            // A process-death rest owns both ActivityKit UI and a local
            // notification. Neither has a recoverable timer in the new model,
            // so clear the pair at the same always-mounted launch boundary.
            RestCue.cancelNotification()
            await RestLiveActivity.endStaleActivities()
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
        .alert(
            "Finish disconnecting Apple sign-in",
            isPresented: Binding(
                get: { model.postDeletionAppleRevocationRequired },
                set: { isPresented in
                    if !isPresented {
                        model.dismissPostDeletionAppleRevocationHandoff()
                    }
                }
            )
        ) {
            Button("Done") {
                model.dismissPostDeletionAppleRevocationHandoff()
            }
        } message: {
            Text("The account deletion completed, but Apple could not confirm that its Sign in with Apple access was revoked. To remove it manually, open Settings > [your name] > Sign in with Apple > Tres Fort > Delete.")
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

            if let reason = model.reauthenticationReason {
                Text(reason)
                    .font(.footnote)
                    .multilineTextAlignment(.center)
                    .foregroundStyle(.orange)
            }

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
