import Combine
import Foundation

/// The phone alone owns API access and durable workout writes. Local-link
/// messages can coordinate its reviewed workout, never choose another account.
@MainActor
final class PartnerPhoneModel: ObservableObject {
    @Published private(set) var checkpoint: PartnerCheckpoint?
    @Published private(set) var connected = false
    @Published private(set) var joining = false
    @Published private(set) var busy = false
    @Published private(set) var error: String?
    @Published var name = "Member"
    private weak var auth: AuthModel?
    private weak var sync: SyncModel?
    private weak var originalLink: StationLinkController?
    private var accountID: String?
    private var epoch: UInt64 = 0
    private var invitation: PartnerInvitation?
    private let joinLink = StationLinkTransport(role: .controller)
    private let laneLink = StationLinkTransport(role: .controller)
    private var subscriptions: Set<AnyCancellable> = []
    private var timer: Task<Void, Never>?
    private var lastSnapshot: PartnerLaneSnapshot?
    private var startACK: SessionRow?
    private var laneKeyAvailable = false
    private var invalidated = false
    private var retryAfter = Date.distantPast
    private let api = APIClient()
    var isOpen: Bool { checkpoint != nil || joining }
    var isActive: Bool { checkpoint?.phase == .active }
    var needsReview: Bool { checkpoint?.phase == .reviewing || checkpoint?.phase == .saving }
    private var current: Bool {
        !invalidated && auth?.isCurrentFeatureSession(accountID: accountID, epoch: epoch) == true
    }

    func bind(auth: AuthModel, sync: SyncModel, link: StationLinkController) {
        guard self.auth !== auth || self.sync !== sync || accountID != auth.userID || epoch != auth.featureSessionEpoch else { return }
        stopLinks()
        self.auth = auth; self.sync = sync; originalLink = link
        accountID = auth.userID; epoch = auth.featureSessionEpoch; invalidated = false
        guard let accountID, current else { return }
        checkpoint = PartnerCheckpointStore.load(accountID)
        sync.partnerReserved = checkpoint != nil && checkpoint?.phase != .leaving
        sync.onPartnerSkip = { [weak self] in self?.skip() }
        link.onPartnerMessage = { [weak self] packet in self?.hostRequested(packet) }
        joinLink.onMessage = { [weak self] message in
            if case .partner(let packet) = message { self?.receiveInvitation(packet) }
        }
        laneLink.onMessage = { [weak self] message in
            if case .partner(let packet) = message { self?.receive(packet) }
        }
        laneLink.onConnect = { [weak self] in self?.announce() }
        laneLink.$connection.sink { [weak self] connection in
            self?.connected = connection.isConnected
        }.store(in: &subscriptions)
        auth.observeFeatureSessionBoundary { [weak self] in
            guard let self else { return false }
            self.send(.leave)
            if let accountID = self.accountID { PartnerLaneKeyStore.clear(accountID: accountID) }
            self.invalidated = true; self.stopLinks(); self.checkpoint = nil
            self.startACK = nil; self.name = "Member"; self.error = nil
            return false
        }
        if let checkpoint, let key = PartnerLaneKeyStore.load(checkpoint.id, accountID: accountID) {
            laneKeyAvailable = true; laneLink.start(key: key)
        } else if checkpoint != nil {
            error = "This lane is closed on this phone. Continue alone or cancel the empty start."
        }
        let boundEpoch = epoch
        Task { @MainActor [weak self] in
            guard let self, let jwt = auth.featureJWT,
                  let profile = try? await self.api.getMe(jwt: jwt), self.current,
                  self.accountID == accountID, self.epoch == boundEpoch else { return }
            if self.name == "Member", let name = profile.display_name, !name.isEmpty { self.name = String(name.prefix(80)) }
        }
        timer = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 500_000_000)
                guard !Task.isCancelled, let self, self.current else { return }
                self.refresh()
            }
        }
    }

    func join(_ code: String) {
        guard current, checkpoint == nil, let invitation = PartnerInvitation.parse(code),
              let sync, sync.hasVerifiedPlanState, !sync.isUsingCachedState else {
            error = "Refresh Today, then scan a fresh code from the iPad."; return
        }
        guard canSetUp else { error = "You already have sets or a finished workout today."; return }
        let cleaned = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleaned.isEmpty, cleaned.count <= 80 else { error = "Enter your name first."; return }
        name = cleaned; self.invitation = invitation; joining = true; error = nil
        joinLink.onConnect = { [weak self] in
            guard let self, self.current, let accountID = self.accountID, let invitation = self.invitation else { return }
            self.joinLink.send(.partner(.init(id: invitation.id,
                message: .join(name: self.name, fingerprint: invitation.fingerprint(accountID: accountID)))))
        }
        joinLink.start(key: invitation.secret)
    }

    private var canSetUp: Bool {
        guard let sync, sync.hasVerifiedPlanState, !sync.isUsingCachedState,
              !sync.sessions.contains(where: { $0.date == sync.todayString && $0.status == "completed" }),
              sync.setOutbox.pending.allSatisfy({ $0.date != sync.todayString }),
              sync.terminalOutbox.intent(for: sync.todayString) == nil,
              sync.setCorrections.allSatisfy({ $0.date != sync.todayString }) else { return false }
        let todayIDs = Set(sync.sessions.filter { $0.date == sync.todayString }.map(\.id))
        return !sync.sets.contains { todayIDs.contains($0.session_id) && $0.deleted_at == nil }
    }

    private func hostRequested(_ packet: PartnerPacket) {
        guard current, let sync, let accountID, case .requestSetup = packet.message else { return }
        if let saved = checkpoint, saved.id == packet.id,
           let key = PartnerLaneKeyStore.load(saved.id, accountID: accountID) {
            originalLink?.sendPartner(.init(id: saved.id, message: .hostSetup(saved.offer, resumeKey: key))); return
        }
        guard checkpoint == nil, canSetUp, let plan = sync.plan, let workout = sync.stationWorkout else {
            originalLink?.sendPartner(.init(id: packet.id, message: .failed("Start together before either person logs a set today."))); return
        }
        let offer = PartnerOffer(id: packet.id, hostName: name, planID: plan.id, planVersion: plan.version, workout: workout)
        guard offer.isValid else {
            originalLink?.sendPartner(.init(id: packet.id, message: .failed("This workout cannot be shared yet."))); return
        }
        let key = StationLink.newNonce()
        let value = PartnerCheckpoint(id: offer.id, lane: .host, offer: offer, name: name, phase: .ready,
            slotMap: Dictionary(uniqueKeysWithValues: workout.exercises.map { ($0.id, $0.id) }),
            receipt: .init(workout_id: workout.id, plan_id: plan.id, version: plan.version))
        guard PartnerCheckpointStore.load(accountID) == checkpoint,
              PartnerLaneKeyStore.save(key, id: offer.id, accountID: accountID), save(value) else {
            originalLink?.sendPartner(.init(id: packet.id, message: .failed("Couldn't save the host lane. Retry on the iPhone."))); return
        }
        sync.partnerReserved = true
        laneKeyAvailable = true; laneLink.start(key: key)
        originalLink?.sendPartner(.init(id: offer.id, message: .hostSetup(offer, resumeKey: key)))
    }

    private func receiveInvitation(_ packet: PartnerPacket) {
        guard current, packet.id == invitation?.id, let accountID, let sync else { return }
        switch packet.message {
        case .accept(let offer, let key):
            guard offer.id == packet.id, offer.isValid, key.count == 32 else { return }
            if checkpoint == nil {
                let draft = PartnerDraft.make(offer: offer, plan: sync.plan, history: sync.sets)
                let value = PartnerCheckpoint(id: offer.id, lane: .partner, offer: offer, name: name, phase: .reviewing,
                    slotMap: draft.map, copy: draft.request)
                guard PartnerCheckpointStore.load(accountID) == checkpoint,
              PartnerLaneKeyStore.save(key, id: offer.id, accountID: accountID), save(value) else { return }
            }
            guard checkpoint?.id == offer.id, PartnerLaneKeyStore.load(offer.id, accountID: accountID) == key else { return }
            sync.partnerReserved = true
            joinLink.send(.partner(.init(id: offer.id, message: .resumeStored)))
            // Keep the invitation transport until the new lane connects: an
            // interrupted key ACK may need to be sent again with the same key.
            laneKeyAvailable = true; laneLink.start(key: key); joining = false
        case .failed(let message): error = message
        default: break
        }
    }

    func changeWeight(slotID: String, weight: Double, unit: String) {
        guard current, var value = checkpoint, value.phase == .reviewing,
              weight.isFinite, ["lb", "kg"].contains(unit),
              let index = value.copy?.slots.firstIndex(where: { $0.id == slotID }) else { return }
        guard weight >= 0 || value.offer.workout.exercises.contains(where: {
            value.slotMap[$0.id] == slotID && $0.allowsAssistance
        }) else { return }
        let previousUnit = WeightUnit(rawValue: value.copy?.slots[index].target_weight_unit ?? "lb") ?? .lb
        value.copy?.slots[index].target_weight = previousUnit.convert(weight, to: WeightUnit(rawValue: unit) ?? .lb)
        value.copy?.slots[index].target_weight_unit = unit
        _ = save(value)
    }

    func ready() async {
        guard current, !busy, var value = checkpoint, [.reviewing, .saving].contains(value.phase),
              let copy = value.copy, let jwt = auth?.featureJWT else { return }
        value.phase = .saving
        guard save(value) else { return }
        busy = true; defer { busy = false }
        do {
            let receipt: PartnerCopyReceipt = try await api.partnerPost("/api/partner/workouts", body: copy, jwt: jwt)
            guard current, var latest = checkpoint, latest.id == value.id, latest.phase == .saving else { return }
            latest.receipt = receipt; latest.phase = .ready
            guard save(latest) else { return }
            await sync?.loadAfterMutation()
            guard current else { return }
            error = nil; announce()
        } catch { if current { self.error = "Couldn't save your workout. Retry keeps the same copy." } }
    }

    private func receive(_ packet: PartnerPacket) {
        guard current, let value = checkpoint, packet.id == value.id else { return }
        switch packet.message {
        case .start(let round):
            guard [.ready, .starting].contains(value.phase) else { return }
            Task { await start(round: round) }
        case .state(let state):
            guard [.starting, .active].contains(value.phase), value.attempt != nil,
                  state.stepIndex >= 0, state.stepIndex <= value.offer.steps.count,
                  state.revision > (value.shared?.revision ?? 0) else { return }
            var next = value; next.phase = .active; next.shared = state
            guard save(next) else { return }
            applyState(); publishSnapshot(force: true)
        case .cancel:
            guard value.phase != .active else { return }
            Task { await leave(cancel: true) }
        case .leave: Task { await leave(cancel: false) }
        case .failed(let message): error = message
        default: break
        }
    }

    private func start(round: UUID) async {
        guard current, !busy, var value = checkpoint, let receipt = value.receipt,
              [.ready, .starting].contains(value.phase), let sync, let jwt = auth?.featureJWT else { return }
        if value.start == nil {
            guard canSetUp, sync.plan?.id == receipt.plan_id, sync.plan?.version == receipt.version else {
                send(.failed("The workout changed or already has sets. Cancel and review it again.")); return
            }
            let observed = sync.sessions.first { $0.date == sync.todayString }
            value.start = .init(id: UUID().uuidString, session_id: observed?.id ?? UUID().uuidString,
                partner_workout_id: value.id.uuidString, date: sync.todayString, workout_id: receipt.workout_id,
                expected_plan_id: receipt.plan_id, expected_version: receipt.version, expected_attempt: observed?.attempt ?? 0)
        }
        value.phase = .starting; value.startRound = round
        guard save(value) else { return }
        busy = true; defer { busy = false }
        do {
            let response: PartnerSessionResponse = try await api.partnerPost("/api/partner/start", body: value.start!, jwt: jwt)
            guard current, var latest = checkpoint, latest.id == value.id else { return }
            startACK = response.session; latest.sessionID = response.session.id; latest.attempt = response.session.attempt
            guard save(latest) else { return }
            if latest.phase == .starting { send(.started(round: round)) }
        } catch {
            guard current else { return }
            self.error = "Start needs confirmation. Retry, or cancel the empty start."
            if case APIError.http(409, _) = error { send(.failed("A workout changed or already has sets. Cancel and review it again.")) }
        }
    }

    private func announce() {
        guard current, let value = checkpoint else { return }
        if value.phase == .leaving { send(.leave); return }
        if value.phase == .cancelling { send(.cancel); return }
        send(.resumeStored)
        joinLink.stop(); invitation = nil
        if value.phase == .active { applyState(); publishSnapshot(force: true) }
        else if value.phase == .starting, let round = value.startRound {
            if value.attempt != nil { send(.started(round: round)) }
            else { Task { await start(round: round) } }
        } else if value.phase == .ready {
            let slots = value.offer.workout.exercises.map { slot -> PartnerDisplaySlot in
                let own = value.copy?.slots.first { $0.id == value.slotMap[slot.id] }
                return .init(hostSlotID: slot.id, weight: own?.target_weight ?? slot.target_weight,
                             unit: own?.target_weight_unit ?? slot.targetWeightUnit.rawValue, reps: slot.target_reps)
            }
            send(.ready(name: value.name, slots: slots))
        }
    }

    private func refresh() {
        guard let value = checkpoint else {
            if let invitation, invitation.expiresAt <= Date() { stopJoin(); error = "Invitation expired. Scan a new code." }
            return
        }
        if [.cancelling, .leaving].contains(value.phase), !busy, Date() >= retryAfter {
            Task { await leave(cancel: value.phase == .cancelling) }; return
        }
        if value.phase == .active { applyState(); publishSnapshot(force: false) }
    }

    private func applyState() {
        guard laneKeyAvailable, let value = checkpoint, value.phase == .active, let state = value.shared, let sync else { return }
        if !sync.running || sync.todaySession?.id != value.sessionID || sync.todaySession?.attempt != value.attempt
            || sync.selectedDayID != value.receipt?.workout_id {
            guard let session = startACK ?? sync.sessions.first(where: { $0.id == value.sessionID && $0.attempt == value.attempt }),
                  sync.mountPartnerWorkout(session) else { error = "Refresh Today to recover this workout, or continue alone."; return }
        }
        sync.onPartnerSkip = { [weak self] in self?.skip() }
        let steps = value.offer.steps
        let step = steps.indices.contains(state.stepIndex) ? steps[state.stepIndex] : nil
        let logged = ownSnapshot(value).logged
        sync.applyPartnerControl(.init(slotID: step.flatMap { value.slotMap[$0.slotID] }, set: step?.set ?? 1,
            canLog: step.map { !logged.contains($0.id) && !state.skipped.contains($0.id) } == true && state.restUntil == nil,
            restUntil: state.restUntil, complete: step == nil))
    }
    private func ownSnapshot(_ value: PartnerCheckpoint) -> PartnerLaneSnapshot {
        guard let sync else { return .init() }
        var logged: Set<String> = []
        for step in value.offer.steps {
            guard let ownID = value.slotMap[step.slotID], let slot = sync.exercises.first(where: { $0.id == ownID }) else { continue }
            if sync.partnerLoggedIndices(slot).contains(step.set) { logged.insert(step.id) }
        }
        // Shared skips persist locally so a disconnected phone catches up. An
        // Undo clears a skip before publication rather than reintroducing it.
        var skips = value.shared?.skipped ?? []
        if let lastSnapshot { skips.subtract(lastSnapshot.logged.subtracting(logged)) }
        let currentSlot = sync.currentExercise.flatMap { own in value.slotMap.first(where: { $0.value == own.id })?.key }
        let display = currentSlot.map { PartnerDisplaySlot(hostSlotID: $0, weight: sync.weight,
            unit: sync.currentExercise?.targetWeightUnit.rawValue ?? "lb", reps: sync.reps) }
        return .init(logged: logged, skipped: skips, closed: false, display: display)
    }
    private func publishSnapshot(force: Bool) {
        guard let value = checkpoint, value.phase == .active, laneKeyAvailable, sync?.running == true,
              sync?.todaySession?.id == value.sessionID, sync?.todaySession?.attempt == value.attempt,
              sync?.selectedDayID == value.receipt?.workout_id else { return }
        let snapshot = ownSnapshot(value)
        guard force || snapshot != lastSnapshot else { return }
        lastSnapshot = snapshot; send(.snapshot(snapshot))
    }
    private func skip() {
        guard current, connected, let value = checkpoint, value.phase == .active else { return }
        guard let state = value.shared, value.offer.steps.indices.contains(state.stepIndex) else { return }
        send(.skip(stepID: value.offer.steps[state.stepIndex].id))
    }

    func skipRest() {
        guard connected, let value = checkpoint, let state = value.shared,
              value.offer.steps.indices.contains(state.stepIndex) else { return }
        send(.skipRest(stepID: value.offer.steps[state.stepIndex].id))
    }

    func retry() async {
        retryAfter = .distantPast
        guard let value = checkpoint else { return }
        if value.phase == .saving { await ready() }
        else if value.phase == .starting, let round = value.startRound { await start(round: round) }
        else if [.leaving, .cancelling].contains(value.phase) { await leave(cancel: value.phase == .cancelling) }
        else { await sync?.loadAfterMutation(); applyState(); announce() }
    }

    func leave(cancel: Bool) async {
        guard current, var value = checkpoint, let jwt = auth?.featureJWT else { stopJoin(); return }
        // Persist the final lane choice before waiting for a possibly committed
        // Start. A delayed acknowledgement must never reopen this lane.
        if ![.leaving, .cancelling].contains(value.phase) {
            value.phase = cancel ? .cancelling : .leaving
            guard save(value) else { return }
        }
        send(value.phase == .cancelling ? .cancel : .leave)
        if value.phase == .leaving {
            _ = sync?.continuePartnerAlone()
            if let accountID { PartnerLaneKeyStore.clear(accountID: accountID) }
        }
        guard !busy else { return }
        busy = true; defer { busy = false }
        do {
            if value.phase == .cancelling, let request = value.start {
                let result: PartnerCancelResponse = try await api.partnerPost("/api/partner/cancel-start", body: request, jwt: jwt)
                guard current, checkpoint?.id == value.id, result.cancelled else { return }
                guard sync?.releasePartnerWorkout(result.session) == true else { return }
            } else if let request = value.start {
                if value.attempt == nil {
                    let response: PartnerSessionResponse = try await api.partnerPost("/api/partner/start", body: request, jwt: jwt)
                    guard current, var latest = checkpoint, latest.id == value.id else { return }
                    latest.sessionID = response.session.id; latest.attempt = response.session.attempt
                    guard save(latest) else { return }; value = latest; startACK = response.session
                }
                guard let sessionID = value.sessionID, let attempt = value.attempt else { return }
                let body = PartnerLeaveRequest(partner_workout_id: value.id.uuidString, expected_attempt: attempt,
                                               cancel: value.phase == .cancelling)
                let result: PartnerSessionResponse = try await api.partnerPost("/api/partner/sessions/\(sessionID)/leave", body: body, jwt: jwt)
                guard current, checkpoint?.id == value.id else { return }
                if value.phase == .leaving, let sync, !sync.running { _ = sync.mountPartnerWorkout(result.session) }
                guard sync?.releasePartnerWorkout(result.session) == true else { return }
            } else { guard sync?.releasePartnerWorkout(nil) == true else { return } }
            guard save(nil) else { return }
            if let accountID { PartnerLaneKeyStore.clear(accountID: accountID) }
            laneLink.stop(); stopJoin(); lastSnapshot = nil; startACK = nil; laneKeyAvailable = false; error = nil
        } catch {
            retryAfter = Date().addingTimeInterval(10)
            if current { self.error = "Couldn't close the lane. Retry with a connection. Logged sets are kept." }
        }
    }

    private func send(_ message: PartnerMessage) {
        guard current, let id = checkpoint?.id else { return }
        laneLink.send(.partner(.init(id: id, message: message)))
    }
    @discardableResult
    private func save(_ value: PartnerCheckpoint?) -> Bool {
        guard current, let accountID,
              PartnerCheckpointStore.replace(value, expected: checkpoint, accountID: accountID) else {
            error = "Couldn't save this lane on your iPhone. Reopen Today before continuing."; return false
        }
        checkpoint = value; return true
    }
    func stopJoin() { joinLink.stop(); invitation = nil; joining = false }
    private func stopLinks() {
        timer?.cancel(); timer = nil; stopJoin(); laneLink.stop(); connected = false
        sync?.onPartnerSkip = nil
        subscriptions.removeAll(); originalLink?.onPartnerMessage = nil; lastSnapshot = nil; laneKeyAvailable = false
    }
}

struct PartnerCancelResponse: Decodable { let cancelled: Bool; let session: SessionRow? }

struct PartnerLeaveRequest: Encodable { let partner_workout_id: String; let expected_attempt: Int; let cancel: Bool }

/// Deterministic copy preparation, with IDs allocated once before any request.
enum PartnerDraft {
    static func make(offer: PartnerOffer, plan: PlanTree?, history: [SetLog], uuid: () -> String = { UUID().uuidString })
        -> (request: PartnerCopyRequest, map: [String: String]) {
        var groups: [String: String] = [:], map: [String: String] = [:]
        let slots = offer.workout.exercises.sorted { $0.order_index < $1.order_index }.enumerated().map { index, original in
            let id = uuid(); map[original.id] = id
            if let group = original.group_id, groups[group] == nil { groups[group] = uuid() }
            var slot = PartnerSlot(original, id: id, index: index, groupID: original.group_id.flatMap { groups[$0] })
            if !original.isWarmup, let previous = history.filter({
                $0.exercise_id == original.exercise_id && $0.is_warmup == 0 && $0.deleted_at == nil
            }).max(by: { $0.logged_at < $1.logged_at }) {
                slot.target_weight = previous.weight; slot.target_weight_unit = previous.weightUnit.rawValue
            }
            return slot
        }
        return (.init(workout_id: uuid(), name: offer.workout.name, expected_plan_id: plan?.id,
                      expected_version: plan?.version ?? 0, slots: slots), map)
    }
}
