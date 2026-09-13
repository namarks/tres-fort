import Foundation
import Combine

/// Navigation only: never stores an Apple credential or a coach connect code.
/// Unbound links belong to the next successful sign-in. Once bound, an intent
/// cannot follow the member across an account change.
struct MemberEntryIntent: Codable, Equatable, Identifiable {
    enum Destination: Codable, Equatable {
        case invite(String)
        case coach
        case coachApproval(String)
        case workouts
    }
    let id: UUID
    let destination: Destination
    var accountID: String?
}

/// Every onboarding callback carries the original step and feature session.
/// Skip invalidates that checkpoint before an old request can complete.
@MainActor
final class OnboardingFlow: ObservableObject {
    enum Step: Int, CaseIterable { case welcome, group, intervals, coach }
    struct Checkpoint: Equatable {
        let step: Step
        let accountID: String?
        let epoch: UInt64
    }
    @Published private(set) var step: Step = .welcome
    private let accountID: String?
    private let epoch: UInt64
    private unowned let auth: AuthModel

    init(auth: AuthModel) {
        self.auth = auth
        accountID = auth.userID
        epoch = auth.featureSessionEpoch
    }

    var checkpoint: Checkpoint { Checkpoint(step: step, accountID: accountID, epoch: epoch) }

    func isCurrent(_ checkpoint: Checkpoint) -> Bool {
        checkpoint == self.checkpoint && auth.isCurrentFeatureSession(accountID: accountID, epoch: epoch)
            && !auth.onboardingComplete
    }

    func advance(from checkpoint: Checkpoint) {
        guard isCurrent(checkpoint), let next = Step(rawValue: step.rawValue + 1) else { return }
        // A linked invite already has a confirmation destination. Do not ask
        // the member to retype or redeem it in a competing onboarding step.
        step = next == .group && auth.pendingInviteCode != nil ? .intervals : next
    }

    func finish(from checkpoint: Checkpoint, destination: MemberEntryIntent.Destination? = nil) {
        guard isCurrent(checkpoint), step == .coach else { return }
        if let destination, !auth.requestEntry(destination) { return }
        auth.completeOnboarding()
    }
}
