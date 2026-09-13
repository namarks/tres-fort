import SwiftUI

/// First-run guided setup, shown once right after a brand-new sign-in (see
/// `AuthModel.onboardingComplete`). Returning users and existing installs are
/// grandfathered past it on update.
///
/// Every step is OPTIONAL — onboarding guides, it never gates. The same
/// actions (join a group, connect intervals.icu) live in the Group + Profile
/// tabs afterward, so skipping any step here costs the user nothing.
///
/// Owns its OWN `GroupModel` (a throwaway peer to MainTabView's) purely to
/// reuse `joinGroup` / `setIntervalsCredentials` / `refreshMe`. When
/// onboarding finishes, MainTabView spins up the real, retained instances and
/// pulls fresh server state — so nothing this view loads needs to survive.
struct OnboardingView: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @ObservedObject var auth: AuthModel
    @StateObject private var groupModel: GroupModel

    @StateObject private var flow: OnboardingFlow
    @State private var showTrainingSetup = false
    private var step: OnboardingFlow.Step { flow.step }

    init(auth: AuthModel, defaults: LocalPersistence = .standard) {
        self.auth = auth
        _flow = StateObject(wrappedValue: OnboardingFlow(auth: auth))
        _groupModel = StateObject(wrappedValue: GroupModel(auth: auth, defaults: defaults))
    }

    var body: some View {
        ZStack {
            Theme.background
            GeometryReader { geometry in
                ScrollView {
                    VStack(spacing: 0) {
                        ProgressDots(total: OnboardingFlow.Step.allCases.count, index: step.rawValue)
                            .padding(.top, 20)
                        Spacer(minLength: 12)
                        content
                            .padding(.horizontal, 28)
                            .frame(maxWidth: 480)
                        Spacer(minLength: 12)
                    }
                    .frame(maxWidth: .infinity, minHeight: geometry.size.height)
                }
                .scrollDismissesKeyboard(.interactively)
                .id(step)
            }
        }
        .preferredColorScheme(.dark)
        .sheet(isPresented: $showTrainingSetup) {
            let checkpoint = flow.checkpoint
            TrainingSetupView(auth: auth) {
                showTrainingSetup = false
                advance(from: checkpoint)
            }
        }
    }

    @ViewBuilder private var content: some View {
        let checkpoint = flow.checkpoint
        switch step {
        case .welcome:
            WelcomeStep(invitePending: auth.pendingInviteCode != nil,
                        onContinue: { showTrainingSetup = true })
        case .group:
            JoinGroupStep(groupModel: groupModel,
                          onDone: { advance(from: checkpoint) },
                          onSkip: { advance(from: checkpoint) })
        case .intervals:
            ConnectIntervalsStep(groupModel: groupModel,
                                 onDone: { advance(from: checkpoint) },
                                 onSkip: { advance(from: checkpoint) })
        case .coach:
            CoachIntroStep(
                onManual: { flow.finish(from: checkpoint, destination: .workouts) },
                onCoach: { flow.finish(from: checkpoint, destination: .coach) },
                onFinish: { flow.finish(from: checkpoint) })
        }
    }

    private func advance(from checkpoint: OnboardingFlow.Checkpoint) {
        withAnimation(reduceMotion ? nil : .snappy) { flow.advance(from: checkpoint) }
    }
}

// MARK: - Steps

private struct WelcomeStep: View {
    let invitePending: Bool
    let onContinue: () -> Void

    var body: some View {
        VStack(spacing: 22) {
            Text("TRÈS FORT")
                .font(Theme.display(46)).tracking(2)
                .foregroundStyle(Theme.text)
            Text("Your training, your way")
                .font(.headline)
                .foregroundStyle(Theme.muted)

            VStack(alignment: .leading, spacing: 18) {
                OnboardingBullet(icon: "dumbbell.fill", title: "Lift, logged",
                                 text: "Run your workout in the app — it tracks every set, rep, and rest.")
                OnboardingBullet(icon: "brain.head.profile", title: "A coach that adapts",
                                 text: "Build workouts yourself, or connect your own AI coach to review and adjust your plan.")
                OnboardingBullet(icon: "person.2.fill", title: "Your crew",
                                 text: "Share progress with family and friends in a private group.")
            }
            .padding(.vertical, 8)

            if invitePending {
                Text("Your group invite is saved. You can join after setup.")
                    .font(.footnote).foregroundStyle(Theme.text)
            }
            OnboardingPrimaryButton("Get started", action: onContinue)
        }
    }
}

private struct JoinGroupStep: View {
    @ObservedObject var groupModel: GroupModel
    let onDone: () -> Void
    let onSkip: () -> Void

    @State private var code = ""
    @State private var saving = false
    @State private var error: String?

    /// Invite codes are 6 chars of the uppercase base-32 alphabet (no
    /// I/L/O/0/1) — mirror JoinGroupSheet's normalization so a pasted or
    /// lower-case code still works.
    private static let alphabet = "ABCDEFGHJKMNPQRSTUVWXYZ23456789"

    var body: some View {
        VStack(spacing: 20) {
            StepHeader(icon: "person.2.fill",
                       title: "Join your group",
                       subtitle: "Got an invite code from a friend or family member? Enter it to share workouts and see each other's progress.")

            TextField("ABC123", text: $code)
                .textInputAutocapitalization(.characters)
                .disableAutocorrection(true)
                .font(Theme.mono(24, .bold))
                .multilineTextAlignment(.center)
                .foregroundStyle(Theme.text)
                .accessibilityLabel("Group invite code")
                .padding(.vertical, 16)
                .frame(maxWidth: .infinity)
                .background(Theme.surface, in: RoundedRectangle(cornerRadius: 12))
                .onChange(of: code) { _, new in
                    let cleaned = new.uppercased().filter { Self.alphabet.contains($0) }.prefix(6)
                    if String(cleaned) != new { code = String(cleaned) }
                }

            if let error {
                Text(error).font(.footnote).foregroundStyle(Theme.danger)
                    .multilineTextAlignment(.center)
            }

            OnboardingPrimaryButton(saving ? "Joining…" : "Join group",
                                    enabled: code.count == 6 && !saving,
                                    action: join)
            OnboardingSkipButton("I don't have a code", action: onSkip)
        }
    }

    private func join() {
        saving = true; error = nil
        let c = code
        Task {
            do {
                _ = try await groupModel.joinGroup(code: c)
                saving = false
                onDone()
            } catch let APIError.http(status, _) {
                error = Self.message(for: status); saving = false
            } catch {
                self.error = error.localizedDescription; saving = false
            }
        }
    }

    private static func message(for status: Int) -> String {
        switch status {
        case 404: return "Invalid code — check the characters and try again."
        case 409: return "You're already in this group."
        case 410: return "This invite has expired or already been used."
        default:  return "Couldn't join (HTTP \(status))."
        }
    }
}

private struct ConnectIntervalsStep: View {
    @ObservedObject var groupModel: GroupModel
    let onDone: () -> Void
    let onSkip: () -> Void

    @State private var apiKey = ""
    @State private var athleteID = ""
    @State private var saving = false        // manual (API-key) connect in flight
    @State private var oauthRunning = false  // OAuth web-auth sheet in flight
    @State private var error: String?
    @State private var showManual = false

    private var busy: Bool { saving || oauthRunning }
    // Gate the manual connect on `busy` (not just `saving`) so it can't fire
    // while the OAuth sheet is in flight — otherwise both success paths call
    // onDone() and the step advances twice (skipping the coach step).
    // Athlete ID is OPTIONAL (#1094): blank → "0" (the athlete owning the
    // key), so only the API key is required to connect.
    private var canConnectManual: Bool { !apiKey.isEmpty && !busy }

    var body: some View {
        VStack(spacing: 16) {
            StepHeader(icon: "bicycle",
                       title: "Connect intervals.icu",
                       subtitle: "Ride or run? Connecting intervals.icu lets your coach see your cardio and balance it against your lifting. Only lift? Skip this.")

            // Primary path: one-tap OAuth — log in to intervals.icu and approve.
            OnboardingPrimaryButton(oauthRunning ? "Connecting…" : "Connect with intervals.icu",
                                    enabled: !busy,
                                    action: connectOAuth)

            if showManual {
                VStack(spacing: 12) {
                    SecureField("API key", text: $apiKey)
                        .textContentType(.password)
                        .textInputAutocapitalization(.never)
                        .disableAutocorrection(true)
                        .onboardingField()
                    TextField("Athlete ID (optional)", text: $athleteID)
                        .textInputAutocapitalization(.never)
                        .disableAutocorrection(true)
                        .onboardingField()
                    Link(destination: URL(string: "https://intervals.icu/settings")!) {
                        Label("Open intervals.icu settings", systemImage: "arrow.up.right.square")
                            .font(.footnote.weight(.semibold))
                            .foregroundStyle(Theme.accent)
                    }
                    Text("Find your API key under Settings → Developer. Athlete ID is optional — leave it blank and we'll use the athlete tied to your key.")
                        .font(.caption)
                        .foregroundStyle(Theme.muted)
                        .multilineTextAlignment(.center)
                        .fixedSize(horizontal: false, vertical: true)
                    OnboardingPrimaryButton(saving ? "Connecting…" : "Connect with API key",
                                            enabled: canConnectManual, action: connectManual)
                }
                .transition(.opacity)
            } else {
                Button {
                    withAnimation(.snappy) { showManual = true }
                } label: {
                    Text("Use an API key instead")
                        .font(.footnote)
                        .foregroundStyle(Theme.muted)
                        .frame(minHeight: 44)
                }
            }

            if let error {
                Text(error).font(.footnote).foregroundStyle(Theme.danger)
                    .multilineTextAlignment(.center)
            }

            OnboardingSkipButton("Skip for now", action: onSkip)
        }
    }

    private func connectOAuth() {
        error = nil
        oauthRunning = true
        Task {
            do {
                let ok = try await groupModel.connectIntervalsViaOAuth()
                oauthRunning = false
                // `false` = the user dismissed the sheet → stay on the step so
                // they can retry, fall back to a key, or skip.
                if ok { onDone() }
            } catch {
                oauthRunning = false
                self.error = "Couldn't connect to intervals.icu. Try again, or use an API key."
            }
        }
    }

    private func connectManual() {
        saving = true; error = nil
        let key = apiKey, id = athleteID
        Task {
            do {
                try await groupModel.setIntervalsCredentials(apiKey: key, athleteID: id)
                saving = false
                onDone()
            } catch {
                self.error = "Couldn't connect — double-check your API key and Athlete ID."
                saving = false
            }
        }
    }
}

private struct CoachIntroStep: View {
    let onManual: () -> Void
    let onCoach: () -> Void
    let onFinish: () -> Void

    var body: some View {
        VStack(spacing: 22) {
            StepHeader(icon: "dumbbell.fill",
                       title: "Choose your first step",
                       subtitle: "Build and schedule your workouts here, or connect your own AI coach to help with your plan. Every member has their own Coach Connect, whether joining a group or training independently.")
            Text("Both paths use your same plan. Find Workouts in Today’s menu and Coach Connect in Profile whenever you're ready.")
                .font(.footnote).foregroundStyle(Theme.muted)
                .multilineTextAlignment(.center)
            OnboardingPrimaryButton("Build my first workout", action: onManual)
            OnboardingPrimaryButton("Set up my coach", action: onCoach)
            OnboardingSkipButton("Enter Très Fort", action: onFinish)
        }
    }
}

// MARK: - Shared building blocks

private struct StepHeader: View {
    let icon: String
    let title: String
    let subtitle: String

    var body: some View {
        VStack(spacing: 14) {
            Image(systemName: icon)
                .font(.system(size: 40, weight: .semibold))
                .foregroundStyle(Theme.accent)
            Text(title)
                .font(.title.weight(.bold))
                .foregroundStyle(Theme.text)
                .multilineTextAlignment(.center)
            Text(subtitle)
                .font(.subheadline)
                .foregroundStyle(Theme.muted)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

private struct OnboardingBullet: View {
    let icon: String
    let title: String
    let text: String

    var body: some View {
        HStack(alignment: .top, spacing: 14) {
            Image(systemName: icon)
                .font(.system(size: 20, weight: .semibold))
                .foregroundStyle(Theme.accent)
                .frame(width: 28)
            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(Theme.text)
                Text(text)
                    .font(.footnote)
                    .foregroundStyle(Theme.muted)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

private struct OnboardingPrimaryButton: View {
    let title: String
    let enabled: Bool
    let action: () -> Void

    init(_ title: String, enabled: Bool = true, action: @escaping () -> Void) {
        self.title = title
        self.enabled = enabled
        self.action = action
    }

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(.headline)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 15)
                .background(enabled ? Theme.accent : Theme.surface2,
                            in: RoundedRectangle(cornerRadius: 12))
                .foregroundStyle(enabled ? Color.black : Theme.dim)
        }
        .disabled(!enabled)
    }
}

private struct OnboardingSkipButton: View {
    let title: String
    let action: () -> Void

    init(_ title: String, action: @escaping () -> Void) {
        self.title = title
        self.action = action
    }

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(.subheadline)
                .foregroundStyle(Theme.muted)
                .frame(minWidth: 44, minHeight: 44).contentShape(Rectangle())
        }
    }
}

private struct ProgressDots: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let total: Int
    let index: Int

    var body: some View {
        HStack(spacing: 8) {
            ForEach(0..<total, id: \.self) { i in
                Capsule()
                    .fill(i == index ? Theme.accent : Theme.dim)
                    .frame(width: i == index ? 22 : 7, height: 7)
            }
        }
        .animation(reduceMotion ? nil : .snappy, value: index)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Step \(index + 1) of \(total)")
    }
}

private extension View {
    /// Dark rounded input chrome shared by the onboarding text fields.
    func onboardingField() -> some View {
        foregroundStyle(Theme.text)
            .padding(.horizontal, 14)
            .padding(.vertical, 13)
            .background(Theme.surface, in: RoundedRectangle(cornerRadius: 12))
    }
}
