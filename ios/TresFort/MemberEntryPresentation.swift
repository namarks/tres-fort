import SwiftUI

/// Consume navigation at the sheet's dismissal boundary. Keep the original
/// intent and epoch until that callback, including interactive dismissals.
struct MemberEntryPresentation: ViewModifier {
    @ObservedObject var auth: AuthModel
    @ObservedObject var sync: SyncModel
    @ObservedObject var groupModel: GroupModel
    var onJoined: () -> Void
    var onCoach: () -> Void
    var onWorkout: () -> Void

    private struct Presentation: Identifiable {
        let intent: MemberEntryIntent
        let epoch: UInt64
        var id: UUID { intent.id }
    }
    @State private var presented: Presentation?
    @State private var sheet: Presentation?
    @State private var startingWorkout = false

    func body(content: Content) -> some View {
        content
            .task(id: auth.nextEntryIntent?.id) { presentNext() }
            .onChange(of: auth.pendingEntryIntents) { _, _ in presentNext() }
            .sheet(item: $sheet, onDismiss: finishPresented) { presentation in
                if auth.isReviewAccount && presentation.intent.destination.requiresPersonalAccount {
                    ContentUnavailableView("Personal sign-in required", systemImage: "person.crop.circle",
                        description: Text("Sign out in Profile > Account and use Sign in with Apple for personal connections and groups."))
                } else {
                    switch presentation.intent.destination {
                    case let .invite(code):
                        JoinInviteConfirmSheet(groupModel: groupModel, code: code) {
                            guard auth.isCurrentFeatureSession(
                                accountID: presentation.intent.accountID, epoch: presentation.epoch) else { return }
                            onJoined()
                        }
                    case .coach:
                        NavigationStack {
                            CoachConnectView(groupModel: groupModel, onHandoff: { sheet = nil })
                                .toolbar {
                                    ToolbarItem(placement: .cancellationAction) {
                                        Button("Done") { sheet = nil }
                                    }
                                }
                        }
                    case let .coachApproval(request):
                        CoachApprovalView(auth: auth, requestID: request,
                            accountName: groupModel.me?.display_name ?? "Your signed-in Très Fort account") { sheet = nil }
                    case .workouts:
                        CreateWorkoutView(sync: sync)
                    case let .workout(id):
                        MemberWorkoutEntryView(sync: sync, workoutID: id) { id in
                            startWorkout(id, from: presentation)
                        }
                        .disabled(startingWorkout)
                    }
                }
            }
    }

    private func startWorkout(_ id: String, from presentation: Presentation) {
        guard !startingWorkout,
              auth.isCurrentFeatureSession(accountID: presentation.intent.accountID, epoch: presentation.epoch),
              sync.workout(id: id) != nil else { return }
        startingWorkout = true
        Task { @MainActor in
            await RestCue.requestNotificationPermissionIfNeeded()
            defer { startingWorkout = false }
            guard !Task.isCancelled,
                  auth.isCurrentFeatureSession(accountID: presentation.intent.accountID, epoch: presentation.epoch),
                  sheet?.id == presentation.id, sync.workout(id: id) != nil else { return }
            onWorkout()
            if sync.hasResumableWorkout && sync.resumableCheckpoint?.selectedDayID == id { sync.resumeWorkout() }
            else { sync.startOverride(dayID: id) }
            sheet = nil
        }
    }

    private func finishPresented() {
        guard let presentation = presented else { return }
        auth.finishEntry(presentation.intent, epoch: presentation.epoch)
        presented = nil
        presentNext()
    }

    private func presentNext() {
        if let presentation = presented {
            // A copied link can return while setup is still open. Consume that
            // setup at dismissal, then present the account-bound approval.
            if presentation.intent.destination == .coach,
               auth.isCurrentFeatureSession(accountID: presentation.intent.accountID, epoch: presentation.epoch),
               hasCoachApproval(for: presentation.intent.accountID) {
                sheet = nil
            }
            return
        }
        guard sheet == nil, let intent = auth.nextEntryIntent else { return }
        // Also handle a cold launch with setup persisted ahead of the return.
        if intent.destination == .coach, hasCoachApproval(for: intent.accountID) {
            guard auth.finishEntry(intent, epoch: auth.featureSessionEpoch) else { return }
            presentNext()
            return
        }
        presented = Presentation(intent: intent, epoch: auth.featureSessionEpoch)
        if intent.destination == .coach { onCoach() }
        sheet = presented
    }

    private func hasCoachApproval(for accountID: String?) -> Bool {
        guard let accountID, accountID == auth.userID else { return false }
        return auth.pendingEntryIntents.contains { intent in
            if case .coachApproval = intent.destination { return intent.accountID == accountID }
            return false
        }
    }
}

/// Load after the acknowledged creation rather than showing a cached library
/// from before setup. An unavailable or deleted identity never selects another
/// workout, and a failed pull offers retry before enabling Start.
private struct MemberWorkoutEntryView: View {
    @ObservedObject var sync: SyncModel
    let workoutID: String
    let onStart: (String) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var loaded = false
    @State private var loading = true

    var body: some View {
        Group {
            if loaded {
                WorkoutDetailsView(sync: sync, workoutID: workoutID, onStart: onStart)
            } else {
                NavigationStack {
                    VStack(spacing: 16) {
                        if loading {
                            ProgressView("Loading your workout…")
                        } else {
                            Text("Couldn’t load your saved workout.").font(.headline)
                            Text("Your workout is saved. Try again when connected.")
                                .foregroundStyle(Theme.muted)
                            Button("Try again") { Task { await load() } }
                                .buttonStyle(WorkoutPrimaryButtonStyle())
                                .accessibilityIdentifier("memberWorkout.retry")
                        }
                    }
                    .padding(24)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(Theme.background)
                    .foregroundStyle(Theme.text)
                    .navigationTitle("Your workout")
                    .navigationBarTitleDisplayMode(.inline)
                    .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Done") { dismiss() } } }
                }
            }
        }
        .preferredColorScheme(.dark)
        .task { await load() }
    }

    private func load() async {
        loading = true
        await sync.loadAfterMutation()
        guard !Task.isCancelled else { return }
        loaded = sync.hasVerifiedPlanState && !sync.isUsingCachedState && sync.loadError == nil
        loading = false
    }
}
