import Combine
import Foundation
import UIKit

/// iPhone side of the iPad Station link. It mirrors which set is armed, shows
/// the iPad's live count and holds a finished count as a proposal. Logging
/// itself stays in the runner view, through SyncModel's ordinary set path.
@MainActor
final class StationLinkController: ObservableObject {
    @Published private(set) var connection: StationLinkTransport.Connection = .off
    @Published private(set) var arm: StationLinkArm?
    @Published private(set) var progress: StationLinkProgress?
    @Published private(set) var stationState: StationLinkStationState?
    @Published private(set) var proposal: StationLinkProposal?

    private let transport: StationLinkTransport
    private var seenEvents: Set<UUID> = []
    private var cancellable: AnyCancellable?
    /// The phone must stay awake to receive counts; restore the prior policy.
    private var previousIdleTimerDisabled: Bool?

    init(transport: StationLinkTransport? = nil) {
        self.transport = transport ?? StationLinkTransport(role: .controller)
        cancellable = self.transport.$connection.sink { [weak self] value in
            guard let self else { return }
            self.connection = value
            if value.isConnected {
                if self.previousIdleTimerDisabled == nil {
                    self.previousIdleTimerDisabled = UIApplication.shared.isIdleTimerDisabled
                    UIApplication.shared.isIdleTimerDisabled = true
                }
            } else {
                self.progress = nil
                self.stationState = nil
                if let previous = self.previousIdleTimerDisabled {
                    UIApplication.shared.isIdleTimerDisabled = previous
                    self.previousIdleTimerDisabled = nil
                }
            }
        }
        self.transport.onMessage = { [weak self] in self?.receive($0) }
        // A fresh connection learns the current arm, if any.
        self.transport.onConnect = { [weak self] in
            guard let self, let arm = self.arm else { return }
            self.transport.send(.arm(arm))
        }
    }

    var isConnected: Bool { connection.isConnected }

    func start(accountID: String) { transport.start(accountID: accountID) }

    func stop() {
        request(nil)
        transport.stop()
        proposal = nil
        seenEvents.removeAll()
    }

    /// Arms the iPad for the runner's current set, or disarms it with nil.
    /// While a proposal waits, the arm is kept so the iPad doesn't count rest.
    func request(_ target: StationLinkTarget?) {
        if StationLinkPolicy.arm(arm, matches: target) { return }
        if let proposal, target?.slotID != proposal.slotID || target?.setNumber != proposal.setNumber {
            // The runner moved on (logged by hand, skipped, navigated): a count
            // for the previous set must not follow it.
            seenEvents.insert(proposal.eventID)
            self.proposal = nil
        }
        if let old = arm { transport.send(.disarm(armID: old.armID)) }
        progress = nil
        guard let target else { arm = nil; return }
        let next = StationLinkArm(armID: UUID(), slotID: target.slotID, setNumber: target.setNumber,
                                  exercise: target.exercise, exerciseName: target.exerciseName,
                                  targetReps: target.targetReps)
        arm = next
        transport.send(.arm(next))
    }

    /// The member rejected the count. The set stays manual and the iPad
    /// counts the same set again under a fresh arm.
    func dismissProposal() {
        guard let proposal else { return }
        seenEvents.insert(proposal.eventID)
        self.proposal = nil
        guard let old = arm else { return }
        let fresh = StationLinkArm(armID: UUID(), slotID: old.slotID, setNumber: old.setNumber,
                                   exercise: old.exercise, exerciseName: old.exerciseName,
                                   targetReps: old.targetReps)
        transport.send(.disarm(armID: old.armID))
        progress = nil
        arm = fresh
        transport.send(.arm(fresh))
    }

    /// The runner logged the count, or handed it to the rep control (Edit).
    func finishProposal(_ eventID: UUID) {
        seenEvents.insert(eventID)
        if proposal?.eventID == eventID { proposal = nil }
    }

    func receive(_ message: StationLinkMessage, now: Date = Date()) {
        switch message {
        case .progress(let value):
            guard value.armID == arm?.armID else { return }
            progress = value
        case .completion(let completion):
            guard proposal == nil,
                  let next = StationLinkPolicy.proposal(for: completion, arm: arm,
                                                        seenEvents: seenEvents, now: now) else { return }
            seenEvents.insert(completion.eventID)
            proposal = next
        case .station(let state, let armID):
            guard armID == nil || armID == arm?.armID else { return }
            stationState = state
        case .arm, .disarm:
            break // only the iPhone arms sets
        }
    }
}
