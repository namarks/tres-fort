import Combine
import Foundation

@MainActor
final class PartnerStationModel: ObservableObject {
    @Published private(set) var id: UUID?
    @Published private(set) var offer: PartnerOffer?
    @Published private(set) var invitation: PartnerInvitation?
    @Published private(set) var candidateName: String?
    @Published private(set) var partnerName = "Partner"
    @Published private(set) var hostSlots: [PartnerDisplaySlot] = []
    @Published private(set) var partnerSlots: [PartnerDisplaySlot] = []
    @Published private(set) var ready: Set<PartnerLane> = []
    @Published private(set) var state: PartnerSharedState?
    @Published private(set) var error: String?
    @Published private(set) var starting = false
    private var coordinator: PartnerCoordinator?
    private let accountID: String
    private var originalLink: StationLinkStation?
    private let invitationLink = StationLinkTransport(role: .station)
    private let hostLink = StationLinkTransport(role: .station)
    private let partnerLink = StationLinkTransport(role: .station)
    private var candidateFingerprint: Data?
    private var allowedFingerprint: Data?
    private var partnerKey: Data?
    private var nextSetupRetry = Date.distantPast
    private var startBarrier: PartnerStartBarrier?
    private var startRound: UUID? { startBarrier?.round }
    private var setupEnded = false
    private var subscriptions: Set<AnyCancellable> = []
    private var timer: Task<Void,Never>?
    var isOpen: Bool {id != nil}
    var canStart: Bool {ready.count == 2 && state == nil && !starting && error == nil}

    init(accountID: String) {
        self.accountID=accountID
        invitationLink.onMessage={ [weak self] message in
            if case .partner(let packet)=message { self?.receiveInvitation(packet) }
        }
        for (lane,link) in [(PartnerLane.host,hostLink),(.partner,partnerLink)] {
            link.onMessage={ [weak self] message in
                if case .partner(let packet)=message {self?.receive(packet,from:lane)}
            }
            link.onConnect = { [weak self] in
                guard let self else { return }
                if let state = self.state { self.send(.state(state), over: self.link(lane)) }
                else if let round = self.startRound, self.starting { self.send(.start(round: round), over: self.link(lane)) }
            }
            link.$connection.sink { [weak self] value in
                guard let self else {return}
                if !value.isConnected {
                    self.ready.remove(lane)
                    if self.coordinator != nil {
                        self.coordinator?.disconnect(lane,now:Date());self.broadcast()
                    }
                }
            }.store(in:&subscriptions)
        }
    }
    func begin(link: StationLinkStation) {
        guard id == nil,link.connection.isConnected else {error="Connect your iPhone to Station first.";return}
        id=UUID(); error=nil; originalLink=link
        link.onPartnerMessage={ [weak self] packet in self?.receiveHostSetup(packet) }
        link.sendPartner(.init(id:id!,message:.requestSetup))
        timer=Task { @MainActor [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds:500_000_000)
                guard !Task.isCancelled,let self else {return}
                self.tick()
            }
        }
    }
    private func receiveHostSetup(_ packet: PartnerPacket) {
        guard packet.id==id,!setupEnded,offer==nil else {return}
        switch packet.message {
        case .hostSetup(let offer,let key):
            guard offer.id==id,offer.isValid,key.count==32 else {error="The workout could not be shared.";return}
            self.offer=offer
            hostLink.start(key:key)
            let invitation=PartnerInvitation(id:offer.id)
            self.invitation=invitation;invitationLink.start(key:invitation.secret)
        case .failed(let message):error=message
        default:break
        }
    }
    private func receiveInvitation(_ packet: PartnerPacket) {
        guard packet.id==id,!setupEnded,state==nil,!starting,let invitation else {return}
        switch packet.message {
        case .join(let name,let fingerprint):
            guard fingerprint.count==32,!name.isEmpty,name.count<=80 else {return}
            guard fingerprint != invitation.fingerprint(accountID:accountID) else {
                send(.failed("Use a different account from the host."),over:invitationLink);return
            }
            if let allowedFingerprint {
                guard fingerprint==allowedFingerprint,let offer,let partnerKey else {return}
                send(.accept(offer,resumeKey:partnerKey),over:invitationLink)
            } else if invitation.expiresAt>Date() {candidateName=name;candidateFingerprint=fingerprint}
        case .resumeStored:
            guard allowedFingerprint != nil,let partnerKey else {return}
            partnerLink.start(key:partnerKey)
            // The invitation is spent. A photographed QR can no longer join.
            invitationLink.stop();self.invitation=nil;candidateName=nil
        default:break
        }
    }
    func allow() {
        guard let offer,let invitation,invitation.expiresAt>Date(),let fingerprint=candidateFingerprint,
              let name=candidateName,allowedFingerprint==nil else {return}
        allowedFingerprint=fingerprint;partnerName=name;partnerKey=StationLink.newNonce()
        candidateName=nil;candidateFingerprint=nil
        // Advertise before the ACK: a phone killed just after saving its key
        // must be able to prove that key and finish the handoff on relaunch.
        partnerLink.start(key:partnerKey!)
        send(.accept(offer,resumeKey:partnerKey!),over:invitationLink)
    }
    func decline() {
        candidateName=nil;candidateFingerprint=nil
        invitationLink.stop()
        guard let id else {return}
        let next=PartnerInvitation(id:id);invitation=next;invitationLink.start(key:next.secret)
    }
    func start() {
        guard canStart,let offer else {return}
        starting=true;startBarrier=PartnerStartBarrier(round:UUID())
        coordinator=PartnerCoordinator(steps:offer.steps)
        sendBoth(.start(round:startRound!))
    }
    private func receive(_ packet: PartnerPacket,from lane: PartnerLane) {
        guard packet.id==id,!setupEnded else {return}
        switch packet.message {
        case .resumeStored:
            guard lane == .partner, allowedFingerprint != nil else { return }
            invitationLink.stop(); invitation=nil; candidateName=nil
        case .ready(let name,let slots):
            guard state==nil,!name.isEmpty,name.count<=80,slots.count==offer?.workout.exercises.count else {return}
            if lane == .host {hostSlots=slots} else {partnerName=name;partnerSlots=slots}
            ready.insert(lane)
            if starting,let startRound {send(.start(round:startRound),over:link(lane))}
        case .started(let round):
            guard starting,round==startRound else {return}
            let active = startBarrier?.acknowledge(lane,round:round) == true
            coordinator?.receive(.init(),from:lane,now:Date())
            if active {starting=false;broadcast()}
        case .snapshot(let snapshot):
            guard !starting,coordinator != nil else {return}
            coordinator?.receive(snapshot,from:lane,now:Date());broadcast()
            if let state { send(.state(state),over:link(lane)) }
        case .skip(let stepID):
            guard !starting, let state, let offer, offer.steps.indices.contains(state.stepIndex),
                  offer.steps[state.stepIndex].id == stepID else {return}
            coordinator?.skipCurrent(now:Date());broadcast()
        case .skipRest(let stepID):
            guard let state, let offer, offer.steps.indices.contains(state.stepIndex),
                  offer.steps[state.stepIndex].id == stepID else {return}
            skipRest()
        case .leave:
            if state == nil { cancelSetup("A member left setup. Cancel and start again.") }
            else { coordinator?.close(lane,now:Date());broadcast() }
        case .cancel:
            if state == nil { cancelSetup("Setup cancelled on an iPhone.") }
        case .failed(let message):
            if state == nil { cancelSetup(message) } else { error=message }
        default:break
        }
    }
    private func cancelSetup(_ message: String) {
        guard !setupEnded else { return }
        setupEnded=true;startBarrier?.cancelSetup()
        starting=false;coordinator=nil;ready=[];error=message
        sendBoth(.cancel)
    }
    func skipRest() {coordinator?.skipRest(now:Date());broadcast()}
    private func tick() {
        if Date() >= nextSetupRetry, let id, error == nil {
            nextSetupRetry = Date().addingTimeInterval(3)
            if offer == nil { originalLink?.sendPartner(.init(id:id,message:.requestSetup)) }
            else if starting, let startRound { sendBoth(.start(round:startRound)) }
        }
        if let invitation,invitation.expiresAt<=Date(),allowedFingerprint==nil {
            invitationLink.stop();self.invitation=nil;candidateName=nil;error="Invitation expired. Cancel and start again."
        }
        if state != nil {coordinator?.reconcile(now:Date());broadcast()}
    }
    private func broadcast() {
        guard var value=coordinator?.state,!starting else {return}
        value.revision=state?.revision ?? 0
        guard value != state else { return }
        value.revision &+= 1
        state=value;sendBoth(.state(value))
    }
    private func link(_ lane: PartnerLane) -> StationLinkTransport {lane == .host ? hostLink : partnerLink}
    private func send(_ message: PartnerMessage,over link: StationLinkTransport) {
        guard let id else {return};link.send(.partner(.init(id:id,message:message)))
    }
    private func sendBoth(_ message: PartnerMessage) {send(message,over:hostLink);send(message,over:partnerLink)}
    func end() {
        sendBoth(state == nil ? .cancel : .leave)
        timer?.cancel();timer=nil
        invitationLink.stop();hostLink.stop();partnerLink.stop();originalLink?.onPartnerMessage=nil;originalLink=nil
        id=nil;offer=nil;invitation=nil;candidateName=nil;candidateFingerprint=nil;allowedFingerprint=nil
        partnerKey=nil;hostSlots=[];partnerSlots=[];ready=[];state=nil;coordinator=nil
        partnerName="Partner";starting=false;startBarrier=nil;setupEnded=false;error=nil
    }
}
