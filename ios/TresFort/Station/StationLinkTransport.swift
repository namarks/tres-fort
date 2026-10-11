import Foundation
import MultipeerConnectivity

/// One local session dedicated to a single remote peer. The transport keeps
/// its authenticated connection and a newer attempt in separate channels, so
/// retiring one never disconnects the other.
@MainActor
protocol StationLinkChannel: AnyObject {
    var peerName: String { get }
    /// The session still lists its peer as connected.
    var isOpen: Bool { get }
    func send(_ data: Data) throws
    func close()
}

/// Discovery for one role: the iPad advertises and accepts invitations, the
/// iPhone browses and invites. Callbacks reach the transport on the main actor.
@MainActor
protocol StationLinkRadio: AnyObject {
    func startDiscovery(tag: String)
    /// A browser reports each peer once, so looking again needs a restart.
    func restartDiscovery()
    func stopDiscovery()
    /// Invites a discovered peer into a new channel (iPhone only).
    func invite(_ peer: MCPeerID, context: Data, timeout: TimeInterval) -> StationLinkChannel
}

/// Encrypted local peer-to-peer link between one iPhone and one iPad of the
/// same account. No internet is needed once both hold the account's link key.
/// The iPad advertises; the iPhone browses. A peer is trusted only after a
/// mutual challenge-response proves it holds the same key; until then nothing
/// it sends is delivered and nothing is sent to it. After that, every message
/// is sealed with a key bound to this connection's nonces, so a relay that
/// passed the challenge along still cannot forge, replay or reflect one.
///
/// Neither side waits for a dead connection to time out. A quiet connection
/// carries a heartbeat, so a peer that has gone silent is dropped within
/// `silenceLimit`; a failed send drops it at once. The iPad keeps a connection
/// in use against any newcomer. Once a newcomer proves the key, it replaces a
/// connection the same iPhone abandoned, or one that stayed quiet throughout,
/// so the old connection serves until then.
@MainActor
final class StationLinkTransport: ObservableObject {
    enum Role: String { case station, controller }
    enum Connection: Equatable {
        case off, searching, unavailable, connected(String)
        var isConnected: Bool { if case .connected = self { return true }; return false }
    }

    /// Seconds between heartbeats on an otherwise quiet connection.
    static let heartbeatInterval: TimeInterval = 2
    /// Silence after which a peer that sends heartbeats is presumed gone.
    static let silenceLimit: TimeInterval = 8
    /// Silence, two missed heartbeats, after which a newcomer may take over.
    static let takeoverLimit: TimeInterval = 4
    /// Time one attempt has to connect and prove the key.
    static let attemptLimit: TimeInterval = 20
    /// Time the iPad has to accept an invitation.
    static let invitationTimeout: TimeInterval = 10
    /// Pause before the iPhone invites again after an attempt failed.
    static let retryDelay: TimeInterval = 2

    @Published private(set) var connection: Connection = .off
    var onMessage: ((StationLinkMessage) -> Void)?
    var onConnect: (() -> Void)?

    private let role: Role
    private let makeRadio: @MainActor (Role, StationLinkTransport) -> StationLinkRadio
    private let now: () -> Date
    private let ticksAutomatically: Bool
    private var radio: StationLinkRadio?
    private var key: Data?
    private var tag: String?
    private var discoveryFailed = false
    /// The authenticated connection.
    private var active: PeerLink?
    /// The one connection still proving the key. A newer invitation replaces it.
    private var pending: PeerLink?
    /// iPhone only: matching iPads the browser reports, the latest found last.
    private var nearby: [MCPeerID] = []
    /// iPhone only: iPads whose attempt failed since discovery last restarted.
    private var tried: Set<MCPeerID> = []
    private var nextInvite = Date.distantPast
    private var ticker: Task<Void, Never>?

    /// Tests inject the radio and clock and call `tick()` themselves.
    init(role: Role,
         radio makeRadio: (@MainActor (Role, StationLinkTransport) -> StationLinkRadio)? = nil,
         now: @escaping () -> Date = Date.init,
         ticksAutomatically: Bool = true) {
        self.role = role
        self.makeRadio = makeRadio ?? { StationLinkMultipeerRadio(role: $0, transport: $1) }
        self.now = now
        self.ticksAutomatically = ticksAutomatically
    }

    private var peerRole: Role { role == .station ? .controller : .station }

    /// Connected, the session still lists the peer, and a peer that sends
    /// heartbeats has been heard from recently.
    var isHealthy: Bool {
        guard let active, active.channel.isOpen else { return false }
        return !active.peerSendsHeartbeats || now().timeIntervalSince(active.lastReceived) < Self.silenceLimit
    }

    func start(key: Data) {
        let tag = StationLink.discoveryTag(key: key)
        if radio != nil, tag == self.tag { return }
        stop()
        self.key = key
        self.tag = tag
        let radio = makeRadio(role, self)
        self.radio = radio
        connection = .searching
        radio.startDiscovery(tag: tag)
        if ticksAutomatically { startTicker() }
    }

    func stop() {
        ticker?.cancel()
        ticker = nil
        radio?.stopDiscovery()
        radio = nil
        pending?.channel.close()
        pending = nil
        active?.channel.close()
        active = nil
        nearby.removeAll()
        tried.removeAll()
        nextInvite = .distantPast
        key = nil
        tag = nil
        discoveryFailed = false
        connection = .off
    }

    /// Discovery from scratch with the same key: a fresh local identity and
    /// no session left over from an attempt that may be wedged.
    func restart() {
        guard let key else { return }
        stop()
        start(key: key)
    }

    /// The app is back in the foreground. Suspension closes every session,
    /// sometimes without telling this side, so rebuild unless still connected.
    /// An attempt in progress, as after a permission alert, is left to finish:
    /// one that suspension broke is abandoned at `attemptLimit`.
    func resume() {
        guard key != nil, !isHealthy, pending == nil else { return }
        restart()
    }

    /// Sends only to the authenticated peer, sealed for this connection.
    func send(_ message: StationLinkMessage) {
        guard let link = active, let sessionKey = link.sessionKey else { return }
        link.sentCounter += 1
        guard let data = StationLink.seal(message, sessionKey: sessionKey, senderRole: role.rawValue,
                                          counter: link.sentCounter) else { return }
        transmit(data, on: link)
    }

    // MARK: radio events, always on the main actor

    func handleFound(_ peer: MCPeerID, info: [String: String]?) {
        guard role == .controller, radio != nil, let tag else { return }
        discoveryWorks()
        guard info?["tag"] == tag else { return }
        nearby.removeAll { $0 == peer }
        nearby.append(peer)
        inviteNext()
    }

    func handleLost(_ peer: MCPeerID) {
        nearby.removeAll { $0 == peer }
        // An iPad that stopped advertising, as when it came back under a new
        // identity, won't answer an invitation that hasn't connected yet.
        guard let pending, pending.peer == peer, !pending.channel.isOpen else { return }
        drop(pending)
        // It went away rather than failed: no pause, and welcome if it returns.
        tried.remove(peer)
        nextInvite = .distantPast
        inviteNext()
    }

    /// `accept` answers the invitation exactly once and returns the channel
    /// that joined it.
    func handleInvitation(from peer: MCPeerID, context: Data?, accept: (Bool) -> StationLinkChannel?) {
        // The tag only filters; the challenge decides trust after connecting.
        guard role == .station, radio != nil, let tag, context == Data(tag.utf8) else {
            _ = accept(false)
            return
        }
        discoveryWorks()
        // Another device, or a takeover too soon to tell, is turned away
        // while the connection in use keeps the link. The same phone invites
        // again only once it has given up on its connection.
        if let active, active.peer != peer, inUse(active) {
            _ = accept(false)
            return
        }
        // A newer invitation replaces an attempt that hasn't proved the key.
        if let pending { drop(pending) }
        guard let channel = accept(true) else { return }
        pending = PeerLink(channel: channel, peer: peer, at: now())
    }

    func handleDiscoveryFailure() {
        discoveryFailed = true
        refreshConnection()
    }

    func handle(_ channel: StationLinkChannel, connected: Bool) {
        guard let link = link(for: channel) else { return }
        guard connected else { drop(link); return }
        if link === pending { advanceHandshake(link) }
    }

    func handle(_ channel: StationLinkChannel, received data: Data) {
        guard let link = link(for: channel) else { return }
        if link.sessionKey == nil { receiveHandshake(data, on: link) } else { receiveSealed(data, on: link) }
    }

    /// Runs every second while started: abandons a wedged attempt, drops a
    /// silent peer, keeps a quiet connection alive and retries discovery.
    func tick() {
        let time = now()
        if let pending, time.timeIntervalSince(pending.started) >= Self.attemptLimit { drop(pending) }
        if let active {
            if active.peerSendsHeartbeats, time.timeIntervalSince(active.lastReceived) >= Self.silenceLimit {
                drop(active)
            } else if time.timeIntervalSince(active.lastSent) >= Self.heartbeatInterval {
                sendHeartbeat(on: active)
            }
        }
        inviteNext()
    }

    // MARK: connections

    private func link(for channel: StationLinkChannel) -> PeerLink? {
        if let active, active.channel === channel { return active }
        if let pending, pending.channel === channel { return pending }
        return nil
    }

    private func drop(_ link: PeerLink) {
        link.channel.close()
        let failedAttempt = pending === link
        let lostConnection = active === link
        if failedAttempt { pending = nil }
        if lostConnection { active = nil }
        refreshConnection()
        guard role == .controller, radio != nil, active == nil, pending == nil else { return }
        if lostConnection {
            // The iPad may hold the old session a while longer: meet it again
            // under a new identity, so the two sessions share nothing.
            renewRadio()
            return
        }
        if failedAttempt {
            tried.insert(link.peer)
            nextInvite = now().addingTimeInterval(Self.retryDelay)
        }
        if nearby.isEmpty { rediscover() } else { inviteNext() }
    }

    /// Still in use, so a newcomer is turned away: open, and either heard
    /// from within `takeoverLimit` or from before heartbeats.
    private func inUse(_ link: PeerLink) -> Bool {
        guard link.channel.isOpen else { return false }
        return !link.peerSendsHeartbeats || now().timeIntervalSince(link.lastReceived) < Self.takeoverLimit
    }

    /// The iPhone invites one iPad at a time: the one found most recently
    /// that hasn't failed since discovery restarted, so a stale advertisement
    /// can't hold up the iPad that is really there.
    private func inviteNext() {
        guard role == .controller, let radio, let tag, active == nil, pending == nil,
              now() >= nextInvite else { return }
        guard let peer = nearby.last(where: { !tried.contains($0) }) else {
            if !tried.isEmpty { rediscover() } // every iPad in view failed: look again
            return
        }
        let channel = radio.invite(peer, context: Data(tag.utf8), timeout: Self.invitationTimeout)
        pending = PeerLink(channel: channel, peer: peer, at: now())
    }

    private func rediscover() {
        nearby.removeAll()
        tried.removeAll()
        radio?.restartDiscovery()
    }

    /// Discovery from scratch under a new local identity, keeping the key.
    private func renewRadio() {
        guard let tag else { return }
        radio?.stopDiscovery()
        nearby.removeAll()
        tried.removeAll()
        nextInvite = .distantPast
        let radio = makeRadio(role, self)
        self.radio = radio
        radio.startDiscovery(tag: tag)
    }

    /// A peer was found or an invitation arrived, so an earlier failure to
    /// start discovery no longer describes the link.
    private func discoveryWorks() {
        guard discoveryFailed else { return }
        discoveryFailed = false
        refreshConnection()
    }

    private func refreshConnection() {
        let next: Connection
        if let active { next = .connected(active.channel.peerName) }
        else if radio == nil { next = .off }
        else if discoveryFailed { next = .unavailable }
        else { next = .searching }
        if next != connection { connection = next }
    }

    private func startTicker() {
        ticker?.cancel()
        ticker = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 1_000_000_000)
                guard !Task.isCancelled, let self else { return }
                self.tick()
            }
        }
    }

    /// A send fails only when the peer is gone: search again rather than
    /// keep reporting a connection that delivers nothing.
    private func transmit(_ data: Data, on link: PeerLink) {
        do {
            try link.channel.send(data)
            link.lastSent = now()
        } catch {
            drop(link)
        }
    }

    // MARK: authentication

    /// Handshake messages only; they carry nothing the other side acts on.
    private func transmitHandshake(_ message: StationLinkMessage, on link: PeerLink) -> Bool {
        guard let data = try? message.encoded() else { return false }
        do {
            try link.channel.send(data)
            return true
        } catch {
            // Before the session connects, its connected callback tries again.
            if link.channel.isOpen { drop(link) }
            return false
        }
    }

    /// Sends what this side still owes: its challenge, then its proof once
    /// the peer's challenge has arrived. Data can be delivered before this
    /// side's connected callback runs, so either event may call this.
    private func advanceHandshake(_ link: PeerLink) {
        guard let key, link === pending else { return }
        if link.ownNonce == nil {
            let nonce = StationLink.newNonce()
            guard transmitHandshake(.challenge(nonce), on: link) else { return }
            link.ownNonce = nonce
        }
        if !link.sentProof, let ownNonce = link.ownNonce, let peerNonce = link.peerNonce {
            let proof = StationLink.proof(key: key, responderRole: role.rawValue,
                                          challengerNonce: peerNonce, responderNonce: ownNonce)
            guard transmitHandshake(.proof(proof), on: link) else { return }
            link.sentProof = true
        }
        if link.sentProof, link.peerVerified { authenticate(link) }
    }

    private func receiveHandshake(_ data: Data, on link: PeerLink) {
        guard let key, link === pending, let message = StationLinkMessage.decode(data) else { return }
        switch message {
        case .challenge(let nonce):
            guard link.peerNonce == nil, nonce.count == 32 else { drop(link); return }
            link.peerNonce = nonce
        case .proof(let proof):
            guard !link.peerVerified, let ownNonce = link.ownNonce, let peerNonce = link.peerNonce,
                  StationLink.verify(proof, key: key, responderRole: peerRole.rawValue,
                                     challengerNonce: ownNonce, responderNonce: peerNonce) else {
                drop(link)
                return
            }
            link.peerVerified = true
        default:
            return // nothing else is accepted before authentication
        }
        advanceHandshake(link)
    }

    private func authenticate(_ link: PeerLink) {
        guard let key, let ownNonce = link.ownNonce, let peerNonce = link.peerNonce else { return }
        if let previous = active, previous.peer != link.peer, inUse(previous) {
            // The connection it was to replace was heard from again meanwhile.
            drop(link)
            return
        }
        let controllerNonce = role == .controller ? ownNonce : peerNonce
        let stationNonce = role == .controller ? peerNonce : ownNonce
        link.sessionKey = StationLink.sessionKey(key: key, controllerNonce: controllerNonce,
                                                 stationNonce: stationNonce)
        link.lastReceived = now()
        pending = nil
        // Its phone abandoned the connection this replaces, or it stayed quiet.
        if let previous = active { previous.channel.close() }
        active = link
        connection = .connected(link.channel.peerName)
        onConnect?()
        // Tells the peer at once that this side sends heartbeats.
        if active === link { sendHeartbeat(on: link) }
    }

    private func receiveSealed(_ data: Data, on link: PeerLink) {
        guard let sessionKey = link.sessionKey,
              let frame = StationLink.openFrame(data, sessionKey: sessionKey, senderRole: peerRole.rawValue,
                                                after: link.receivedCounter) else {
            drop(link) // forged, replayed or reflected
            return
        }
        link.receivedCounter = frame.counter
        link.lastReceived = now()
        switch StationLinkMessage.inbound(frame.body) {
        case .heartbeat:
            link.peerSendsHeartbeats = true
        case .message(.challenge), .message(.proof):
            return
        case .message(let message):
            onMessage?(message)
        case .unreadable:
            return // from a newer version; the connection itself is sound
        }
    }

    private func sendHeartbeat(on link: PeerLink) {
        guard let sessionKey = link.sessionKey else { return }
        link.sentCounter += 1
        guard let data = StationLink.sealHeartbeat(sessionKey: sessionKey, senderRole: role.rawValue,
                                                   counter: link.sentCounter) else { return }
        transmit(data, on: link)
    }
}

/// One connection, from invitation through authentication.
@MainActor
private final class PeerLink {
    let channel: StationLinkChannel
    let peer: MCPeerID
    let started: Date
    var ownNonce: Data?
    var peerNonce: Data?
    var sentProof = false
    var peerVerified = false
    var sessionKey: Data?
    var sentCounter: UInt64 = 0
    var receivedCounter: UInt64 = 0
    var lastReceived: Date
    var lastSent: Date
    /// Learned from its first heartbeat; peers from before heartbeats are
    /// never dropped for being quiet.
    var peerSendsHeartbeats = false

    init(channel: StationLinkChannel, peer: MCPeerID, at time: Date) {
        self.channel = channel
        self.peer = peer
        started = time
        lastReceived = time
        lastSent = time
    }
}
