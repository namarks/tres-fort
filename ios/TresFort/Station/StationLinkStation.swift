import Combine
import Foundation

/// iPad side of the link. It turns an armed set from the iPhone into one live
/// counting trial and reports a finished count back. It holds no workout
/// writer: the iPhone decides whether the count becomes a logged set.
@MainActor
final class StationLinkStation: ObservableObject {
    @Published private(set) var connection: StationLinkTransport.Connection = .off
    @Published private(set) var arm: StationLinkArm?
    @Published private(set) var isCounting = false
    @Published private(set) var isEnabled = false

    private let transport: StationLinkTransport
    private var detector = StationSetEndDetector()
    private var lastProgress: StationLinkProgress?
    private var cancellable: AnyCancellable?

    init(transport: StationLinkTransport? = nil) {
        self.transport = transport ?? StationLinkTransport(role: .station)
        cancellable = self.transport.$connection.sink { [weak self] value in
            guard let self else { return }
            self.connection = value
            if !value.isConnected { self.withdraw() }
        }
        self.transport.onMessage = { [weak self] in self?.receive($0) }
        self.transport.onConnect = { [weak self] in self?.report(.ready) }
    }

    func setEnabled(_ enabled: Bool, accountID: String) {
        isEnabled = enabled && !accountID.isEmpty
        if isEnabled { transport.start(accountID: accountID) } else { stop() }
    }

    func stop() {
        withdraw()
        isEnabled = false
        transport.stop()
    }

    func receive(_ message: StationLinkMessage) {
        switch message {
        case .arm(let next):
            if arm?.armID == next.armID { return }
            withdraw()
            arm = next
        case .disarm(let armID):
            guard arm?.armID == armID else { return }
            withdraw()
        case .progress, .completion, .station:
            break // only the iPad reports counts
        }
    }

    /// The view started a fresh trial for the current arm.
    func beginCounting() {
        guard let arm else { return }
        detector.reset()
        lastProgress = nil
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
        guard detector.observe(count: count, status: status, at: time) else { return false }
        complete(count: count, leftCount: leftCount, rightCount: rightCount, partial: partial)
        return true
    }

    /// The trial ended some other way: the member stopped it, or tracking
    /// was invalidated. A non-zero count is offered, never auto-logged when partial.
    func trialEnded(count: Int, leftCount: Int?, rightCount: Int?, partial: Bool) {
        guard isCounting, arm != nil else { return }
        if count > 0 {
            complete(count: count, leftCount: leftCount, rightCount: rightCount, partial: partial)
        } else {
            isCounting = false
            report(.stopped)
        }
    }

    /// The member took over the iPad by hand; the iPhone keeps the set manual.
    func abandon() {
        guard isCounting else { return }
        isCounting = false
        report(.stopped)
    }

    private func complete(count: Int, leftCount: Int?, rightCount: Int?, partial: Bool) {
        guard let arm else { return }
        isCounting = false
        transport.send(.completion(StationLinkCompletion(
            armID: arm.armID, eventID: UUID(), reps: count,
            leftCount: leftCount, rightCount: rightCount, partial: partial)))
    }

    private func withdraw() {
        arm = nil
        isCounting = false
        lastProgress = nil
        detector.reset()
    }
}
