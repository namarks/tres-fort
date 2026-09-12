import SwiftUI

/// Consume navigation at the sheet's dismissal boundary. Keep the original
/// intent and epoch until that callback, including interactive dismissals.
struct MemberEntryPresentation: ViewModifier {
    @ObservedObject var auth: AuthModel
    @ObservedObject var sync: SyncModel
    @ObservedObject var groupModel: GroupModel
    var onJoined: () -> Void
    var onCoach: () -> Void

    private struct Presentation {
        let intent: MemberEntryIntent
        let epoch: UInt64
    }
    @State private var presented: Presentation?
    @State private var showing = false

    func body(content: Content) -> some View {
        content
            .task(id: auth.nextEntryIntent?.id) { presentNext() }
            .sheet(isPresented: $showing, onDismiss: finishPresented) {
                if let presentation = presented {
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
                            CoachConnectView(groupModel: groupModel)
                                .toolbar {
                                    ToolbarItem(placement: .cancellationAction) {
                                        Button("Done") { showing = false }
                                    }
                                }
                        }
                    case .workouts:
                        WorkoutsView(sync: sync)
                    }
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
        guard presented == nil, !showing, let intent = auth.nextEntryIntent else { return }
        presented = Presentation(intent: intent, epoch: auth.featureSessionEpoch)
        if intent.destination == .coach { onCoach() }
        showing = true
    }
}
