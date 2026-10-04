import Foundation
import MultipeerConnectivity
import UIKit

/// Encrypted local peer-to-peer link between one iPhone and one iPad signed in
/// to the same account. No server, no internet: it works on gym Wi-Fi or with
/// peer-to-peer Wi-Fi alone. The iPad advertises; the iPhone browses.
@MainActor
final class StationLinkTransport: NSObject, ObservableObject {
    enum Role { case station, controller }
    enum Connection: Equatable {
        case off, searching, connected(String)
        var isConnected: Bool { if case .connected = self { return true }; return false }
    }

    @Published private(set) var connection: Connection = .off
    var onMessage: ((StationLinkMessage) -> Void)?
    var onConnect: (() -> Void)?

    private let role: Role
    private var accountTag: String?
    private var peerID: MCPeerID?
    private var session: MCSession?
    private var advertiser: MCNearbyServiceAdvertiser?
    private var browser: MCNearbyServiceBrowser?
    private var invited: Set<MCPeerID> = []

    init(role: Role) {
        self.role = role
        super.init()
    }

    var isRunning: Bool { session != nil }

    func start(accountID: String) {
        let tag = StationLink.accountTag(for: accountID)
        if session != nil, tag == accountTag { return }
        stop()
        accountTag = tag
        let peer = MCPeerID(displayName: UIDevice.current.name)
        let session = MCSession(peer: peer, securityIdentity: nil, encryptionPreference: .required)
        session.delegate = self
        self.peerID = peer
        self.session = session
        switch role {
        case .station:
            let advertiser = MCNearbyServiceAdvertiser(
                peer: peer, discoveryInfo: ["acct": tag, "v": String(StationLink.protocolVersion)],
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
        peerID = nil
        accountTag = nil
        invited.removeAll()
        connection = .off
    }

    func send(_ message: StationLinkMessage) {
        guard let session, !session.connectedPeers.isEmpty, let data = try? message.encoded() else { return }
        try? session.send(data, toPeers: session.connectedPeers, with: .reliable)
    }

    // MARK: main-actor handlers for delegate callbacks

    private func handle(state: MCSessionState, peer: MCPeerID, from source: MCSession) {
        guard source === session else { return }
        switch state {
        case .connected:
            connection = .connected(peer.displayName)
            onConnect?()
        case .notConnected:
            invited.remove(peer)
            guard source.connectedPeers.isEmpty else { return }
            connection = .searching
            // A browser does not report a still-visible peer again on its own.
            browser?.stopBrowsingForPeers()
            browser?.startBrowsingForPeers()
        case .connecting:
            break
        @unknown default:
            break
        }
    }

    private func handle(data: Data, from source: MCSession) {
        guard source === session, let message = StationLinkMessage.decode(data) else { return }
        onMessage?(message)
    }

    private func handleFound(peer: MCPeerID, info: [String: String]?, from source: MCNearbyServiceBrowser) {
        guard source === browser, let session, let accountTag, info?["acct"] == accountTag,
              !invited.contains(peer), session.connectedPeers.isEmpty else { return }
        invited.insert(peer)
        source.invitePeer(peer, to: session, withContext: Data(accountTag.utf8), timeout: 15)
    }

    private func handleInvitation(from peer: MCPeerID, context: Data?,
                                  from source: MCNearbyServiceAdvertiser,
                                  reply: @escaping (Bool, MCSession?) -> Void) {
        guard source === advertiser, let session, let accountTag,
              context == Data(accountTag.utf8), session.connectedPeers.isEmpty else {
            reply(false, nil)
            return
        }
        reply(true, session)
    }
}

extension StationLinkTransport: MCSessionDelegate {
    nonisolated func session(_ session: MCSession, peer peerID: MCPeerID, didChange state: MCSessionState) {
        Task { @MainActor in self.handle(state: state, peer: peerID, from: session) }
    }

    nonisolated func session(_ session: MCSession, didReceive data: Data, fromPeer peerID: MCPeerID) {
        Task { @MainActor in self.handle(data: data, from: session) }
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
        Task { @MainActor in self.handleFound(peer: peerID, info: info, from: browser) }
    }

    nonisolated func browser(_ browser: MCNearbyServiceBrowser, lostPeer peerID: MCPeerID) {
        Task { @MainActor in self.invited.remove(peerID) }
    }

    nonisolated func browser(_ browser: MCNearbyServiceBrowser, didNotStartBrowsingForPeers error: Error) {
        Task { @MainActor in if browser === self.browser { self.connection = .off } }
    }
}

extension StationLinkTransport: MCNearbyServiceAdvertiserDelegate {
    nonisolated func advertiser(_ advertiser: MCNearbyServiceAdvertiser,
                                didReceiveInvitationFromPeer peerID: MCPeerID, withContext context: Data?,
                                invitationHandler: @escaping (Bool, MCSession?) -> Void) {
        Task { @MainActor in
            self.handleInvitation(from: peerID, context: context, from: advertiser, reply: invitationHandler)
        }
    }

    nonisolated func advertiser(_ advertiser: MCNearbyServiceAdvertiser, didNotStartAdvertisingPeer error: Error) {
        Task { @MainActor in if advertiser === self.advertiser { self.connection = .off } }
    }
}
