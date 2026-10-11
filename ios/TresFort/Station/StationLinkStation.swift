import Combine
import Foundation

/// iPad side of the link. It turns an armed set from the iPhone into one live
/// counting trial and reports a finished count back. It holds no workout
/// writer: the iPhone decides whether the count becomes a logged set.
@MainActor
final class StationLinkStation: ObservableObject {
    @Published private(set) var connection: StationLinkTransport.Connection = .off
    @Published private(set) var arm: StationLinkArm?
    /// The arm the member took over by hand. It stays manual here, as on the
    /// iPhone, until a new set is armed.
    @Published private(set) var manualArmID: UUID?
    @Published private(set) var isCounting = false
    @Published private(set) var isEnabled = false
    /// No link key yet: the iPad must reach the server once to set up.
    @Published private(set) var needsKey = false
    @Published private(set) var display: WorkoutDisplayState?

    var onPartnerMessage: ((PartnerPacket) -> Void)?
    func sendPartner(_ packet: PartnerPacket) { transport.send(.partner(packet)) }

    private let transport: StationLinkTransport
    private var detector = StationSetEndDetector()
    private var lastProgress: StationLinkProgress?
    /// The count sent for the current arm, sent again on a new connection in
    /// case the one it replaced lost it. The iPhone acts on each count once.
    private var sentCompletion: StationLinkCompletion?
    private var cancellable: AnyCancellable?

    init(transport: StationLinkTransport? = nil) {
        self.transport = transport ?? StationLinkTransport(role: .station)
        cancellable = self.transport.$connection.sink { [weak self] value in
            guard let self else { return }
            self.connection = value
            if !value.isConnected { self.withdraw(); self.display = nil }
        }
        self.transport.onMessage = { [weak self] in self?.receive($0) }
        self.transport.onConnect = { [weak self] in self?.announce() }
    }

    /// Starts advertising with the account's link key, or records that the
    /// key could not be loaded.
    func enable(key: Data?) {
        guard let key else {
            stop()
            needsKey = true
            return
        }
        needsKey = false
        isEnabled = true
        transport.start(key: key)
    }

    func stop() {
        display = nil
        withdraw()
        isEnabled = false
        needsKey = false
        transport.stop()
    }

    /// Back in the foreground: reconnect unless the connection survived.
    func resume() { transport.resume() }

    func receive(_ message: StationLinkMessage) {
        switch message {
        case .partner(let packet): onPartnerMessage?(packet)
        case .display(let state): display = state
        case .arm(let next):
            guard StationLink.cameraCountingAvailable else {
                report(.manual, armID: next.armID)
                return
            }
            if arm?.armID == next.armID { return }
            withdraw()
            arm = next
        case .disarm(let armID):
            guard arm?.armID == armID else { return }
            withdraw()
        case .progress, .completion, .station, .challenge, .proof:
            break // only the iPad reports counts; the transport authenticates
        }
    }

    /// A new connection, possibly replacing one that died unnoticed, learns
    /// where this iPad is with the armed set.
    private func announce() {
        guard let arm else {
            report(.ready)
            return
        }
        if manualArmID == arm.armID {
            report(.manual, armID: arm.armID)
            return
        }
        report(isCounting ? .counting : .ready, armID: arm.armID)
        if let sentCompletion, sentCompletion.armID == arm.armID {
            transport.send(.completion(sentCompletion))
        }
    }

    /// The arm the iPad may still count: none once taken over by hand.
    var armToCount: StationLinkArm? {
        guard let arm, arm.armID != manualArmID else { return nil }
        return arm
    }

    /// The view started a fresh trial for the current arm.
    func beginCounting() {
        guard let arm = armToCount else { return }
        detector.reset()
        lastProgress = nil
        sentCompletion = nil
        isCounting = true
        report(.counting, armID: arm.armID)
    }

    /// The armed set can't be counted right now (camera off, recording busy).
    func report(_ state: StationLinkStationState, armID: UUID? = nil) {
        transport.send(.station(state, armID: armID ?? arm?.armID))
    }

    /// Feed every processed frame. Returns true when this frame finished the
    /// set; the completion has already been sent and counting has stopped.
    @discardableResult
    func observe(count: Int, leftCount: Int?, rightCount: Int?, status: StationTrackingStatus,
                 partial: Bool, at time: TimeInterval) -> Bool {
        guard isCounting, let arm else { return false }
        let progress = StationLinkProgress(armID: arm.armID, count: count, leftCount: leftCount,
                                           rightCount: rightCount, status: status.message)
        if progress != lastProgress {
            lastProgress = progress
            transport.send(.progress(progress))
        }
        guard detector.observe(count: count, leftCount: leftCount, rightCount: rightCount,
                               status: status, at: time) else { return false }
        complete(count: count, leftCount: leftCount, rightCount: rightCount, partial: partial)
        return true
    }

    /// The trial ended some other way: the member stopped it, or tracking
    /// was invalidated. A non-zero count is offered, never auto-logged when
    /// partial. Returns whether a count was sent; otherwise the arm can retry.
    @discardableResult
    func trialEnded(count: Int, leftCount: Int?, rightCount: Int?, partial: Bool) -> Bool {
        guard isCounting, arm != nil else { return false }
        guard count > 0 else {
            isCounting = false
            report(.stopped)
            return false
        }
        complete(count: count, leftCount: leftCount, rightCount: rightCount, partial: partial)
        return true
    }

    /// The member took over the iPad by hand; the iPhone keeps the set manual.
    /// This holds for an arm that never counted, or stopped with no reps.
    func abandon() {
        guard let arm = armToCount else { return }
        isCounting = false
        manualArmID = arm.armID
        report(.manual, armID: arm.armID)
    }

    private func complete(count: Int, leftCount: Int?, rightCount: Int?, partial: Bool) {
        guard let arm else { return }
        isCounting = false
        let completion = StationLinkCompletion(
            armID: arm.armID, eventID: UUID(), reps: count,
            leftCount: leftCount, rightCount: rightCount, partial: partial)
        sentCompletion = completion
        transport.send(.completion(completion))
    }

    private func withdraw() {
        arm = nil
        manualArmID = nil
        isCounting = false
        lastProgress = nil
        sentCompletion = nil
        detector.reset()
    }
}
