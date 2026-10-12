import Combine
import Foundation

/// iPad side of the link. It shows the iPhone's workout, sends the controls
/// the member taps there, turns an armed set into one live counting trial and
/// reports a finished count back. It holds no workout writer: the iPhone
/// decides whether a control or a count changes the workout.
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
    /// The display outlived its connection. It stays up through a short drop
    /// so the workout doesn't vanish mid-set, with its controls off until
    /// the iPhone sends a fresh one.
    @Published private(set) var displayIsStale = false
    /// A control sent to the iPhone and not yet answered. Controls wait for
    /// it, so one tap is never applied twice.
    @Published private(set) var pendingCommand: StationLinkCommand?
    /// Why the last control didn't take effect, shown for a few seconds.
    @Published private(set) var commandNotice: String?

    /// Seconds a control waits for the iPhone's answer.
    static let commandTimeout: TimeInterval = 5
    /// Seconds a lost connection's display stays up while reconnecting.
    static let staleDisplayLimit: TimeInterval = 120
    static let noticeDuration: TimeInterval = 6

    /// The connected iPhone applies controls tapped on this iPad. An iPhone
    /// from before controls never says so, and gets none.
    var acceptsCommands: Bool {
        connection.isConnected && !displayIsStale && display?.acceptsCommands == true
    }

    var onPartnerMessage: ((PartnerPacket) -> Void)?
    func sendPartner(_ packet: PartnerPacket) { transport.send(.partner(packet)) }

    private let transport: StationLinkTransport
    private var detector = StationSetEndDetector()
    private var lastProgress: StationLinkProgress?
    /// The count sent for the current arm, sent again on each new connection
    /// in case it was lost with the old one. The iPhone acts on each count once.
    private var sentCompletion: StationLinkCompletion?
    /// The state last reported for the current arm, repeated on a new
    /// connection, where the iPhone's re-sent arm prompts no fresh report.
    private var reportedState: StationLinkStationState?
    private var cancellable: AnyCancellable?
    private var commandTimer: Task<Void, Never>?
    private var staleTimer: Task<Void, Never>?
    private var staleSince: Date?
    private var noticeTimer: Task<Void, Never>?
    private let now: () -> Date

    init(transport: StationLinkTransport? = nil, now: @escaping () -> Date = Date.init) {
        self.transport = transport ?? StationLinkTransport(role: .station)
        self.now = now
        cancellable = self.transport.$connection.sink { [weak self] value in
            guard let self else { return }
            self.connection = value
            // The armed set and its count stay, so a reconnect delivers a
            // count the lost connection missed; the iPhone withdraws a set it
            // has moved past meanwhile.
            if !value.isConnected { self.connectionLost() }
        }
        self.transport.onMessage = { [weak self] in self?.receive($0) }
        self.transport.onConnect = { [weak self] in
            // A connection can replace one whose loss was never reported.
            // Treat it as that loss: the display waits for this iPhone's own.
            self?.connectionLost()
            self?.announce()
        }
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
        clearDisplay()
        commandNotice = nil
        noticeTimer?.cancel()
        withdraw()
        isEnabled = false
        needsKey = false
        transport.stop()
    }

    /// Back in the foreground: reconnect unless the connection survived. A
    /// display from a drop that outlasted its grace while suspended goes now.
    func resume() {
        if let staleSince, now().timeIntervalSince(staleSince) >= Self.staleDisplayLimit {
            expireStaleDisplay()
        }
        transport.resume()
    }

    /// Sends a control for the step shown, nil when none is, in the phase
    /// and exercise shown now. Returns false, sending nothing, while the
    /// iPhone can't take one or the last one is unanswered.
    @discardableResult
    func send(_ action: StationLinkCommand.Action, for step: WorkoutDisplayState.Step?) -> Bool {
        guard acceptsCommands, pendingCommand == nil else { return false }
        let command = StationLinkCommand(action, step: step, phase: display?.phase,
                                         currentSlotID: display?.currentSlotID)
        pendingCommand = command
        commandNotice = nil
        commandTimer?.cancel()
        commandTimer = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(Self.commandTimeout * 1_000_000_000))
            guard !Task.isCancelled else { return }
            self?.commandTimedOut(command.id)
        }
        deliver(command)
        return true
    }

    private func deliver(_ command: StationLinkCommand) {
        #if DEBUG && targetEnvironment(simulator)
        if let uiFixturePhone { return uiFixturePhone(command) }
        #endif
        transport.send(.command(command))
    }

    #if DEBUG && targetEnvironment(simulator)
    private var uiFixturePhone: ((StationLinkCommand) -> Void)?

    /// UI journeys only: a synthetic iPhone answers controls in place of the
    /// transport, which stays off.
    func installUIFixturePhone(_ phone: @escaping (StationLinkCommand) -> Void) {
        uiFixturePhone = phone
        connection = .connected("Synthetic iPhone")
    }

    /// UI journeys only: the synthetic iPhone's connection drops.
    func dropUIFixturePhone() {
        uiFixturePhone = nil
        connection = .searching
        connectionLost()
    }
    #endif

    /// No answer came: free the controls and say so.
    func commandTimedOut(_ id: UUID) {
        guard pendingCommand?.id == id else { return }
        finishCommand()
        notify("Your iPhone didn’t answer. Keep Très Fort open on your iPhone and try again.")
    }

    /// The drop outlasted the grace period: show the connection screen.
    func expireStaleDisplay() {
        guard displayIsStale else { return }
        clearDisplay()
    }

    private func connectionLost() {
        // An answer can't arrive on another connection; the iPhone's fresh
        // display shows whether the control took effect.
        finishCommand()
        guard display != nil, !displayIsStale else { return }
        displayIsStale = true
        staleSince = now()
        staleTimer?.cancel()
        staleTimer = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(Self.staleDisplayLimit * 1_000_000_000))
            guard !Task.isCancelled else { return }
            self?.expireStaleDisplay()
        }
    }

    private func clearDisplay() {
        finishCommand()
        endStaleness()
        display = nil
    }

    private func endStaleness() {
        staleTimer?.cancel()
        staleTimer = nil
        staleSince = nil
        displayIsStale = false
    }

    private func finishCommand() {
        commandTimer?.cancel()
        commandTimer = nil
        pendingCommand = nil
    }

    private func notify(_ message: String) {
        commandNotice = message
        noticeTimer?.cancel()
        noticeTimer = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(Self.noticeDuration * 1_000_000_000))
            guard !Task.isCancelled, self?.commandNotice == message else { return }
            self?.commandNotice = nil
        }
    }

    func receive(_ message: StationLinkMessage) {
        switch message {
        case .partner(let packet): onPartnerMessage?(packet)
        case .display(let state):
            guard let state else {
                // The iPhone closed or changed workouts: nothing here applies.
                clearDisplay()
                commandNotice = nil
                return
            }
            endStaleness()
            display = state
        case .commandReceipt(let receipt):
            guard receipt.id == pendingCommand?.id else { return }
            finishCommand()
            if !receipt.accepted {
                notify(receipt.message ?? "Your iPhone didn’t apply that. Check your iPhone.")
            }
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
        case .progress, .completion, .station, .command, .challenge, .proof:
            break // only the iPad reports counts and sends controls; the transport authenticates
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
        let state: StationLinkStationState
        if isCounting {
            state = .counting
        } else if let reportedState, reportedState != .counting {
            state = reportedState // camera off, or stopped with no reps
        } else {
            state = .ready // not started yet, or its count is finished
        }
        report(state, armID: arm.armID)
        if isCounting, let lastProgress { transport.send(.progress(lastProgress)) }
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
        let armID = armID ?? arm?.armID
        if let armID, armID == arm?.armID { reportedState = state }
        transport.send(.station(state, armID: armID))
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
        reportedState = nil
        detector.reset()
    }
}
