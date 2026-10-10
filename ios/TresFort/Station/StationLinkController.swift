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
    @Published private(set) var lastLogged: StationLinkLoggedSet?
    /// An undone iPad set whose deletion is still on its way. Runner progress
    /// counts the set until then, so the iPad waits instead of counting the
    /// set after it; the runner arms the undone set afresh once it is gone.
    @Published private(set) var pendingUndo: StationLinkLoggedSet?
    /// No link key yet: the device must reach the server once to set up.
    @Published private(set) var needsKey = false
    @Published private(set) var display: WorkoutDisplayState?
    @Published private(set) var connectionAttempt = 0

    /// Retry discovery without discarding an acknowledged set or its Undo.
    func retryConnection() {
        transport.stop()
        connectionAttempt += 1
    }

    var onPartnerMessage: ((PartnerPacket) -> Void)?
    func sendPartner(_ packet: PartnerPacket) { transport.send(.partner(packet)) }

    private let transport: StationLinkTransport
    private var seenEvents: Set<UUID> = []
    private var completedArmID: UUID?
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
            guard let self else { return }
            self.resendCurrentState()
        }
    }

    deinit {
        // A torn-down runner (sign-out, a replaced session) publishes no
        // disconnect: stop the link and give the phone its sleep policy back.
        let transport = self.transport
        let previous = previousIdleTimerDisabled
        DispatchQueue.main.async {
            MainActor.assumeIsolated {
                transport.stop()
                if let previous { UIApplication.shared.isIdleTimerDisabled = previous }
            }
        }
    }

    var isConnected: Bool { connection.isConnected }

    var displayToResend: WorkoutDisplayState? { display }

    /// The existing authenticated transport owns reconnect delivery. Publishing
    /// can happen before pairing, so a fresh peer receives the latest state.
    func publishDisplay(_ state: WorkoutDisplayState?) {
        guard display != state else { return }
        display = state
        transport.send(.display(state))
    }

    func resendCurrentState() {
        transport.send(.display(displayToResend))
        if let arm = armToResend { transport.send(.arm(arm)) }
    }

    /// The arm a reconnected iPad should count, if any. An arm whose count
    /// already arrived (waiting for a tap, handed to Edit, or logged) is spent:
    /// only a new set or "Not right" asks the iPad to count again.
    var armToResend: StationLinkArm? {
        guard proposal == nil, let arm, arm.armID != completedArmID else { return nil }
        return arm
    }

    func start(key: Data) {
        needsKey = false
        transport.start(key: key)
    }

    func keyUnavailable() {
        publishDisplay(nil)
        transport.stop()
        needsKey = true
    }

    func stop() {
        publishDisplay(nil)
        request(nil)
        transport.stop()
        needsKey = false
        proposal = nil
        lastLogged = nil
        pendingUndo = nil
        seenEvents.removeAll()
    }

    /// Arms the iPad for the runner's current set, or disarms it with nil.
    /// While a proposal waits, the arm is kept so the iPad doesn't count rest.
    func request(_ target: StationLinkTarget?) {
        guard StationLink.cameraCountingAvailable else { return }
        if StationLinkPolicy.arm(arm, matches: target) { return }
        if let proposal, target?.slotID != proposal.slotID || target?.setNumber != proposal.setNumber
            || target?.exerciseName != proposal.exerciseName {
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

    /// The runner was minimized: disarm the iPad, but keep a finished count
    /// that waits for a tap (the iPad is already stopped) until it returns.
    func pause() {
        guard proposal == nil else { return }
        request(nil)
    }

    /// The member rejected the count. The set stays manual and the iPad
    /// counts the same set again under a fresh arm.
    func dismissProposal() {
        guard let proposal else { return }
        seenEvents.insert(proposal.eventID)
        self.proposal = nil
        rearm()
    }

    /// An iPad-logged set was undone and its deletion is queued.
    func undoQueued(_ logged: StationLinkLoggedSet) {
        if lastLogged == logged { lastLogged = nil }
        pendingUndo = logged
    }

    private func rearm() {
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

    /// Saving the count failed: keep it on screen for a tap instead of
    /// logging it again on its own.
    func holdProposal(_ eventID: UUID) {
        guard let proposal, proposal.eventID == eventID, proposal.logsAutomatically else { return }
        self.proposal = StationLinkProposal(
            eventID: proposal.eventID, slotID: proposal.slotID, setNumber: proposal.setNumber,
            exerciseName: proposal.exerciseName, reps: proposal.reps, leftCount: proposal.leftCount,
            rightCount: proposal.rightCount, partial: proposal.partial, logsAutomatically: false)
    }

    /// A Station count was logged; it stays undoable until the next count.
    func recordLogged(_ logged: StationLinkLoggedSet) { lastLogged = logged }

    func clearLogged() { lastLogged = nil }

    func receive(_ message: StationLinkMessage) {
        switch message {
        case .partner(let packet): onPartnerMessage?(packet)
        case .progress(let value):
            guard StationLink.cameraCountingAvailable, value.armID == arm?.armID else { return }
            progress = value
        case .completion(let completion):
            guard StationLink.cameraCountingAvailable, proposal == nil,
                  let next = StationLinkPolicy.proposal(for: completion, arm: arm,
                                                        seenEvents: seenEvents) else { return }
            seenEvents.insert(completion.eventID)
            completedArmID = completion.armID
            lastLogged = nil
            proposal = next
        case .station(let state, let armID):
            guard StationLink.cameraCountingAvailable else { return }
            guard armID == nil || armID == arm?.armID else { return }
            stationState = state
            // A set taken over by hand stays manual, even across a reconnect.
            if state == .manual, let armID { completedArmID = armID }
        case .display, .arm, .disarm, .challenge, .proof:
            break // only the iPhone arms sets; the transport authenticates
        }
    }
}
