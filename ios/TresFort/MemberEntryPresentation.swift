import SwiftUI

/// Consume navigation at the sheet's dismissal boundary. Keep the original
/// intent and epoch until that callback, including interactive dismissals.
struct MemberEntryPresentation: ViewModifier {
    @ObservedObject var auth: AuthModel
    @ObservedObject var sync: SyncModel
    @ObservedObject var groupModel: GroupModel
    var onJoined: () -> Void
    var onCoach: () -> Void

    private struct Presentation: Identifiable {
        let intent: MemberEntryIntent
        let epoch: UInt64
        var id: UUID { intent.id }
    }
    @State private var presented: Presentation?
    @State private var sheet: Presentation?

    func body(content: Content) -> some View {
        content
            .task(id: auth.nextEntryIntent?.id) { presentNext() }
            .onChange(of: auth.pendingEntryIntents) { _, _ in presentNext() }
            .sheet(item: $sheet, onDismiss: finishPresented) { presentation in
                if auth.isReviewAccount && presentation.intent.destination != .workouts {
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
                    }
                }
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
