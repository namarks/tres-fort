import AuthenticationServices
import Foundation
import SwiftUI

struct RootView: View {
    @EnvironmentObject private var model: AuthModel
    @Environment(\.scenePhase) private var scenePhase
    @ObservedObject var defaults: LocalPersistence = .standard
    var now: () -> Date = Date.init

    var body: some View {
        Group {
            switch model.phase {
            case .signedIn:
                if model.onboardingComplete {
                    MainTabView(auth: model, defaults: defaults, now: now)
                        .id("\(model.featureSessionEpoch)-\(defaults.recoveryGeneration)")
                } else {
                    OnboardingView(auth: model, defaults: defaults)
                        .id("\(model.featureSessionEpoch)-\(defaults.recoveryGeneration)")
                }
            default:
                ZStack {
                    Color.black.ignoresSafeArea()
                    GeometryReader { geometry in
                        ScrollView {
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
                            .frame(maxWidth: .infinity, minHeight: geometry.size.height)
                        }
                    }
                }
                .preferredColorScheme(.dark)
            }
        }
        .safeAreaInset(edge: .top) {
            if defaults.hasFailure(userID: model.userID) || model.entryPersistenceError != nil {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Saved training needs attention").font(.headline)
                    Text("A local save or read failed. Unlock your iPhone and check its available storage, then retry. Keep the app installed to preserve unsynced workouts.")
                        .font(.footnote)
                    if let message = model.entryPersistenceError {
                        Text(message).font(.footnote)
                    }
                    HStack {
                        Button("Retry saved data") { defaults.retry(userID: model.userID) }
                        Link("Contact support", destination: AppInformation.supportURL)
                        if !defaults.hasFailure(userID: model.userID) {
                            Button("Dismiss") { model.dismissEntryPersistenceError() }
                        }
                    }
                }
                .padding().frame(maxWidth: .infinity, alignment: .leading)
                .background(.regularMaterial)
                .accessibilityIdentifier("storage.failure")
            }
        }
        .onChange(of: defaults.recoveryGeneration) { _, _ in
            model.recoverEntryIntents()
        }
        .onChange(of: scenePhase) { _, phase in
            // Complete file protection intentionally denies background reads
            // while locked. Retry on return so a normal unlock does not leave
            // the app paused; disk/corruption failures still show the banner.
            if phase == .active { defaults.retry(userID: model.userID) }
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
/// Invite links and the personal coach setup choice survive authentication;
/// the signed-in host presents their confirmation or setup destination.
private struct SignedOutView: View {
    @ObservedObject var model: AuthModel
    @State private var showReviewLogin = false
    @State private var reviewUsername = ""
    @State private var reviewPassword = ""

    var body: some View {
        VStack(spacing: 16) {
            Text("Build your workouts or connect your own Claude coach.\nSign in to keep your training in sync.")
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)

            if let reason = model.reauthenticationReason {
                Text(reason)
                    .font(.footnote)
                    .multilineTextAlignment(.center)
                    .foregroundStyle(.orange)
            }

            if model.pendingInviteCode != nil {
                Text("Your group invite will be ready after sign-in and setup.")
                    .font(.footnote).multilineTextAlignment(.center)
            }
            if model.pendingEntryIntents.contains(where: { $0.destination == .coach }) {
                Text("Sign in to continue to Coach Connect.")
                    .font(.footnote).multilineTextAlignment(.center)
            } else {
                Button("Set up my coach") { model.requestEntry(.coach) }
                    .frame(minHeight: 44)
            }

            signInControl
                .frame(height: 50)
                .cornerRadius(10)

            DisclosureGroup("Reviewer sign-in", isExpanded: $showReviewLogin) {
                VStack(spacing: 12) {
                    Text("Use the credentials supplied in App Review Information. This is a shared sample account. Use sample data only; personal connections and groups require your own Sign in with Apple account.")
                        .font(.footnote).foregroundStyle(.secondary)
                    TextField("User name", text: $reviewUsername)
                        .textContentType(.username).textInputAutocapitalization(.never)
                        .autocorrectionDisabled().accessibilityIdentifier("review.username")
                    SecureField("Password", text: $reviewPassword)
                        .textContentType(.password).accessibilityIdentifier("review.password")
                    Button("Sign in for review") {
                        let username = reviewUsername.trimmingCharacters(in: .whitespacesAndNewlines)
                        let password = reviewPassword
                        reviewPassword = ""
                        Task { await model.signInForReview(username: username, password: password) }
                    }
                    .disabled(reviewUsername.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || reviewPassword.isEmpty)
                    .accessibilityIdentifier("review.submit")
                }
                .padding(.top, 12)
            }

            HStack(spacing: 24) {
                PrivacyPolicyLink()
                Link("Contact support", destination: AppInformation.supportURL)
            }
            .font(.footnote)
            .frame(minHeight: 44)

            if case let .error(msg) = model.phase {
                Text(msg)
                    .font(.footnote)
                    .foregroundStyle(.red)
                    .multilineTextAlignment(.center)
            }
        }
    }

    @ViewBuilder private var signInControl: some View {
#if DEBUG && targetEnvironment(simulator)
        if UIFixtureScenario.selected != nil {
            // A synthetic intent must never launch a real Apple exchange,
            // including when someone manually explores the fixture screen.
            Button {
                if UIFixtureScenario.selected?.isActivation == true {
                    Task { await model.exchange(identityToken: "synthetic", fullName: nil) }
                } else {
                    model.phase = .working("Sign-in requested (synthetic)")
                }
            } label: {
                Label("Sign in with Apple", systemImage: "apple.logo")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .foregroundStyle(.black).background(.white)
            }
        } else {
            nativeSignInControl
        }
#else
        nativeSignInControl
#endif
    }

    private var nativeSignInControl: some View {
        SignInWithAppleButton(.signIn,
                                  onRequest: { req in
                                      req.requestedScopes = [.fullName, .email]
                                  },
                                  onCompletion: model.handleAppleResult)
                .signInWithAppleButtonStyle(.white)
    }
}
