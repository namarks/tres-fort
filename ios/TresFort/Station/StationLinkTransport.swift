import Foundation
import MultipeerConnectivity
import UIKit

/// Encrypted local peer-to-peer link between one iPhone and one iPad of the
/// same account. No internet is needed once both hold the account's link key.
/// The iPad advertises; the iPhone browses. A peer is trusted only after a
/// mutual challenge-response proves it holds the same key; until then nothing
/// it sends is delivered and nothing is sent to it. After that, every message
/// is sealed with a key bound to this connection's nonces, so a relay that
/// passed the challenge along still cannot forge, replay or reflect one.
@MainActor
final class StationLinkTransport: NSObject, ObservableObject {
    enum Role: String { case station, controller }
    enum Connection: Equatable {
        case off, searching, connected(String)
        var isConnected: Bool { if case .connected = self { return true }; return false }
    }

    @Published private(set) var connection: Connection = .off
    var onMessage: ((StationLinkMessage) -> Void)?
    var onConnect: (() -> Void)?

    private let role: Role
    private var key: Data?
    private var tag: String?
    private var session: MCSession?
    private var advertiser: MCNearbyServiceAdvertiser?
    private var browser: MCNearbyServiceBrowser?
    /// Peers invited (phone) or accepted (iPad) and not yet gone: one at a
    /// time, since only one candidate is authenticated.
    private var invited: Set<MCPeerID> = []
    // Authentication of the one connected peer.
    private var candidate: MCPeerID?
    private var ownNonce: Data?
    private var peerNonce: Data?
    private var sentProof = false
    private var peerVerified = false
    private var trustedPeer: MCPeerID?
    private var sessionKey: Data?
    private var sentCounter: UInt64 = 0
    private var receivedCounter: UInt64 = 0

    init(role: Role) {
        self.role = role
        super.init()
    }

    private var peerRole: Role { role == .station ? .controller : .station }

    func start(key: Data) {
        let tag = StationLink.discoveryTag(key: key)
        if session != nil, tag == self.tag { return }
        stop()
        self.key = key
        self.tag = tag
        let peer = MCPeerID(displayName: UIDevice.current.name)
        let session = MCSession(peer: peer, securityIdentity: nil, encryptionPreference: .required)
        session.delegate = self
        self.session = session
        switch role {
        case .station:
            let advertiser = MCNearbyServiceAdvertiser(
                peer: peer, discoveryInfo: ["tag": tag, "v": String(StationLink.protocolVersion)],
                serviceType: StationLink.serviceType)
            advertiser.delegate = self
            advertiser.startAdvertisingPeer()
            self.advertiser = advertiser
        case .controller:
            let browser = MCNearbyServiceBrowser(peer: peer, serviceType: StationLink.serviceType)
            browser.delegate = self
            browser.startBrowsingForPeers()
            self.browser = browser
        }
        connection = .searching
    }

    func stop() {
        advertiser?.stopAdvertisingPeer()
        advertiser?.delegate = nil
        browser?.stopBrowsingForPeers()
        browser?.delegate = nil
        session?.disconnect()
        session?.delegate = nil
        advertiser = nil
        browser = nil
        session = nil
        key = nil
        tag = nil
        invited.removeAll()
        resetAuthentication()
        connection = .off
    }

    /// Sends only to the authenticated peer, sealed for this connection.
    func send(_ message: StationLinkMessage) {
        guard let session, let trustedPeer, let sessionKey,
              session.connectedPeers.contains(trustedPeer) else { return }
        sentCounter += 1
        guard let data = StationLink.seal(message, sessionKey: sessionKey, senderRole: role.rawValue,
                                          counter: sentCounter) else { return }
        try? session.send(data, toPeers: [trustedPeer], with: .reliable)
    }

    /// Handshake messages only; they carry nothing the other side acts on.
    private func transmit(_ message: StationLinkMessage, to peer: MCPeerID) {
        guard let session, session.connectedPeers.contains(peer),
              let data = try? message.encoded() else { return }
        try? session.send(data, toPeers: [peer], with: .reliable)
    }

    private func resetAuthentication() {
        candidate = nil
        ownNonce = nil
        peerNonce = nil
        sentProof = false
        peerVerified = false
        trustedPeer = nil
        sessionKey = nil
        sentCounter = 0
        receivedCounter = 0
    }

    private func reject(_ source: MCSession) {
        resetAuthentication()
        source.disconnect()
        connection = .searching
        restartBrowsing()
    }

    private func restartBrowsing() {
        // A browser does not report a still-visible peer again on its own.
        browser?.stopBrowsingForPeers()
        browser?.startBrowsingForPeers()
    }

    // MARK: main-actor handlers for delegate callbacks

    private func handle(state: MCSessionState, peer: MCPeerID, from source: MCSession) {
        guard source === session else { return }
        switch state {
        case .connected:
            if let other = candidate ?? trustedPeer, other != peer {
                source.cancelConnectPeer(peer) // a second peer is never authenticated
                return
            }
            adopt(peer, in: source)
        case .notConnected:
            invited.remove(peer)
            guard peer == candidate || source.connectedPeers.isEmpty else { return }
            resetAuthentication()
            connection = .searching
            restartBrowsing()
        case .connecting:
            break
        @unknown default:
            break
        }
    }

    /// The first connected peer becomes the one candidate to authenticate.
    private func adopt(_ peer: MCPeerID, in source: MCSession) {
        guard candidate == nil, trustedPeer == nil else { return }
        candidate = peer
        sendChallenge(to: peer)
        // An unproven peer must not hold the link open.
        Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 10_000_000_000)
            guard let self, self.session === source, self.candidate == peer,
                  self.trustedPeer == nil else { return }
            self.reject(source)
        }
    }

    private func sendChallenge(to peer: MCPeerID) {
        guard ownNonce == nil else { return }
        let nonce = StationLink.newNonce()
        ownNonce = nonce
        transmit(.challenge(nonce), to: peer)
    }

    private func handle(data: Data, from peer: MCPeerID, source: MCSession) {
        guard source === session, let key else { return }
        if peer == trustedPeer {
            guard let sessionKey,
                  let opened = StationLink.open(data, sessionKey: sessionKey, senderRole: peerRole.rawValue,
                                                after: receivedCounter) else {
                reject(source) // forged, replayed or reflected
                return
            }
            receivedCounter = opened.counter
            switch opened.message {
            case .challenge, .proof: return
            default: onMessage?(opened.message)
            }
            return
        }
        guard let message = StationLinkMessage.decode(data) else { return }
        // Data can be delivered before this side's connected callback runs.
        if candidate == nil, source.connectedPeers.contains(peer) { adopt(peer, in: source) }
        guard peer == candidate else { return }
        switch message {
        case .challenge(let nonce):
            guard peerNonce == nil, nonce.count == 32 else { reject(source); return }
            peerNonce = nonce
            sendChallenge(to: peer)
            guard let ownNonce else { return }
            transmit(.proof(StationLink.proof(key: key, responderRole: role.rawValue,
                                              challengerNonce: nonce, responderNonce: ownNonce)), to: peer)
            sentProof = true
        case .proof(let proof):
            guard let ownNonce, let peerNonce,
                  StationLink.verify(proof, key: key, responderRole: peerRole.rawValue,
                                     challengerNonce: ownNonce, responderNonce: peerNonce) else {
                reject(source)
                return
            }
            peerVerified = true
        default:
            return // nothing else is accepted before authentication
        }
        if sentProof, peerVerified, let ownNonce, let peerNonce {
            let controllerNonce = role == .controller ? ownNonce : peerNonce
            let stationNonce = role == .controller ? peerNonce : ownNonce
            sessionKey = StationLink.sessionKey(key: key, controllerNonce: controllerNonce,
                                                stationNonce: stationNonce)
            trustedPeer = peer
            connection = .connected(peer.displayName)
            onConnect?()
        }
    }

    private func handleFound(peer: MCPeerID, info: [String: String]?, from source: MCNearbyServiceBrowser) {
        guard source === browser, let session, let tag, info?["tag"] == tag,
              invited.isEmpty, candidate == nil, trustedPeer == nil,
              session.connectedPeers.isEmpty else { return }
        invited.insert(peer)
        source.invitePeer(peer, to: session, withContext: Data(tag.utf8), timeout: 15)
        expireInvitation(peer)
    }

    /// An invitation that never became a connection must not block the next.
    private func expireInvitation(_ peer: MCPeerID) {
        let session = self.session
        Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 20_000_000_000)
            guard let self, self.session === session, self.invited.contains(peer),
                  self.candidate != peer, self.trustedPeer != peer else { return }
            self.invited.remove(peer)
            self.restartBrowsing()
        }
    }

    private func handleInvitation(from peer: MCPeerID, context: Data?,
                                  from source: MCNearbyServiceAdvertiser,
                                  reply: @escaping (Bool, MCSession?) -> Void) {
        // The tag only filters; the challenge decides trust after connecting.
        guard source === advertiser, let session, let tag, context == Data(tag.utf8),
              invited.isEmpty, candidate == nil, trustedPeer == nil,
              session.connectedPeers.isEmpty else {
            reply(false, nil)
            return
        }
        invited.insert(peer)
        reply(true, session)
        expireInvitation(peer)
    }
}

extension StationLinkTransport {
    /// Delegate callbacks hop to the main queue in arrival order: the sealed
    /// counter must see messages in the order the peer sent them.
    nonisolated private func onMain(_ work: @escaping @MainActor (StationLinkTransport) -> Void) {
        DispatchQueue.main.async { MainActor.assumeIsolated { work(self) } }
    }
}

extension StationLinkTransport: MCSessionDelegate {
    nonisolated func session(_ session: MCSession, peer peerID: MCPeerID, didChange state: MCSessionState) {
        onMain { $0.handle(state: state, peer: peerID, from: session) }
    }

    nonisolated func session(_ session: MCSession, didReceive data: Data, fromPeer peerID: MCPeerID) {
        onMain { $0.handle(data: data, from: peerID, source: session) }
    }

    nonisolated func session(_ session: MCSession, didReceive stream: InputStream,
                             withName streamName: String, fromPeer peerID: MCPeerID) {
        stream.close()
    }

    nonisolated func session(_ session: MCSession, didStartReceivingResourceWithName resourceName: String,
                             fromPeer peerID: MCPeerID, with progress: Progress) {
        progress.cancel()
    }

    nonisolated func session(_ session: MCSession, didFinishReceivingResourceWithName resourceName: String,
                             fromPeer peerID: MCPeerID, at localURL: URL?, withError error: Error?) {}
}

extension StationLinkTransport: MCNearbyServiceBrowserDelegate {
    nonisolated func browser(_ browser: MCNearbyServiceBrowser, foundPeer peerID: MCPeerID,
                             withDiscoveryInfo info: [String: String]?) {
        onMain { $0.handleFound(peer: peerID, info: info, from: browser) }
    }

    nonisolated func browser(_ browser: MCNearbyServiceBrowser, lostPeer peerID: MCPeerID) {
        onMain { _ = $0.invited.remove(peerID) }
    }

    nonisolated func browser(_ browser: MCNearbyServiceBrowser, didNotStartBrowsingForPeers error: Error) {
        onMain { if browser === $0.browser { $0.connection = .off } }
    }
}

extension StationLinkTransport: MCNearbyServiceAdvertiserDelegate {
    nonisolated func advertiser(_ advertiser: MCNearbyServiceAdvertiser,
                                didReceiveInvitationFromPeer peerID: MCPeerID, withContext context: Data?,
                                invitationHandler: @escaping (Bool, MCSession?) -> Void) {
        onMain { $0.handleInvitation(from: peerID, context: context, from: advertiser, reply: invitationHandler) }
    }

    nonisolated func advertiser(_ advertiser: MCNearbyServiceAdvertiser, didNotStartAdvertisingPeer error: Error) {
        onMain { if advertiser === $0.advertiser { $0.connection = .off } }
    }
}
