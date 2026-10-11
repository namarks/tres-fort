import Foundation
import MultipeerConnectivity
import UIKit

/// MultipeerConnectivity discovery for one transport start. Each start gets a
/// fresh local identity, so nothing from an earlier, possibly wedged attempt
/// carries over.
@MainActor
final class StationLinkMultipeerRadio: NSObject, StationLinkRadio {
    private let role: StationLinkTransport.Role
    private weak var transport: StationLinkTransport?
    private let peer: MCPeerID
    private var advertiser: MCNearbyServiceAdvertiser?
    private var browser: MCNearbyServiceBrowser?

    init(role: StationLinkTransport.Role, transport: StationLinkTransport) {
        self.role = role
        self.transport = transport
        peer = MCPeerID(displayName: UIDevice.current.name)
        super.init()
    }

    func startDiscovery(tag: String) {
        stopDiscovery()
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
    }

    func restartDiscovery() {
        browser?.stopBrowsingForPeers()
        browser?.startBrowsingForPeers()
    }

    func stopDiscovery() {
        advertiser?.stopAdvertisingPeer()
        advertiser?.delegate = nil
        advertiser = nil
        browser?.stopBrowsingForPeers()
        browser?.delegate = nil
        browser = nil
    }

    func invite(_ remote: MCPeerID, context: Data, timeout: TimeInterval) -> StationLinkChannel {
        let channel = StationLinkMultipeerChannel(local: peer, remote: remote, transport: transport)
        browser?.invitePeer(remote, to: channel.session, withContext: context, timeout: timeout)
        return channel
    }

    fileprivate func accept(_ remote: MCPeerID, transport: StationLinkTransport,
                            reply: @escaping (Bool, MCSession?) -> Void) -> StationLinkChannel {
        let channel = StationLinkMultipeerChannel(local: peer, remote: remote, transport: transport)
        reply(true, channel.session)
        return channel
    }

    /// Delegate callbacks hop to the main queue in arrival order.
    nonisolated private func onMain(_ work: @escaping @MainActor (StationLinkMultipeerRadio) -> Void) {
        DispatchQueue.main.async { MainActor.assumeIsolated { work(self) } }
    }
}

extension StationLinkMultipeerRadio: MCNearbyServiceBrowserDelegate {
    nonisolated func browser(_ browser: MCNearbyServiceBrowser, foundPeer peerID: MCPeerID,
                             withDiscoveryInfo info: [String: String]?) {
        onMain { radio in
            guard browser === radio.browser else { return }
            radio.transport?.handleFound(peerID, info: info)
        }
    }

    nonisolated func browser(_ browser: MCNearbyServiceBrowser, lostPeer peerID: MCPeerID) {
        onMain { radio in
            guard browser === radio.browser else { return }
            radio.transport?.handleLost(peerID)
        }
    }

    nonisolated func browser(_ browser: MCNearbyServiceBrowser, didNotStartBrowsingForPeers error: Error) {
        onMain { radio in
            guard browser === radio.browser else { return }
            radio.transport?.handleDiscoveryFailure()
        }
    }
}

extension StationLinkMultipeerRadio: MCNearbyServiceAdvertiserDelegate {
    nonisolated func advertiser(_ advertiser: MCNearbyServiceAdvertiser,
                                didReceiveInvitationFromPeer peerID: MCPeerID, withContext context: Data?,
                                invitationHandler: @escaping (Bool, MCSession?) -> Void) {
        onMain { radio in
            guard advertiser === radio.advertiser, let transport = radio.transport else {
                invitationHandler(false, nil)
                return
            }
            transport.handleInvitation(from: peerID, context: context) { accepted in
                guard accepted else {
                    invitationHandler(false, nil)
                    return nil
                }
                return radio.accept(peerID, transport: transport, reply: invitationHandler)
            }
        }
    }

    nonisolated func advertiser(_ advertiser: MCNearbyServiceAdvertiser, didNotStartAdvertisingPeer error: Error) {
        onMain { radio in
            guard advertiser === radio.advertiser else { return }
            radio.transport?.handleDiscoveryFailure()
        }
    }
}

/// One MCSession for one remote peer, so closing it never disturbs the
/// transport's other connection.
@MainActor
final class StationLinkMultipeerChannel: NSObject, StationLinkChannel {
    let session: MCSession
    private let remote: MCPeerID
    private weak var transport: StationLinkTransport?

    init(local: MCPeerID, remote: MCPeerID, transport: StationLinkTransport?) {
        session = MCSession(peer: local, securityIdentity: nil, encryptionPreference: .required)
        self.remote = remote
        self.transport = transport
        super.init()
        session.delegate = self
    }

    var peerName: String { remote.displayName }
    var isOpen: Bool { session.connectedPeers.contains(remote) }

    func send(_ data: Data) throws {
        try session.send(data, toPeers: [remote], with: .reliable)
    }

    func close() {
        session.delegate = nil
        session.disconnect()
    }

    /// Delegate callbacks hop to the main queue in arrival order: the sealed
    /// counter must see messages in the order the peer sent them.
    nonisolated private func onMain(_ work: @escaping @MainActor (StationLinkMultipeerChannel) -> Void) {
        DispatchQueue.main.async { MainActor.assumeIsolated { work(self) } }
    }
}

extension StationLinkMultipeerChannel: MCSessionDelegate {
    nonisolated func session(_ session: MCSession, peer peerID: MCPeerID, didChange state: MCSessionState) {
        onMain { channel in
            guard peerID == channel.remote else { return }
            switch state {
            case .connected: channel.transport?.handle(channel, connected: true)
            case .notConnected: channel.transport?.handle(channel, connected: false)
            case .connecting: break
            @unknown default: break
            }
        }
    }

    nonisolated func session(_ session: MCSession, didReceive data: Data, fromPeer peerID: MCPeerID) {
        onMain { channel in
            guard peerID == channel.remote else { return }
            channel.transport?.handle(channel, received: data)
        }
    }

    /// The session's own encryption needs no identity here: the challenge
    /// that follows decides whether the peer is trusted.
    nonisolated func session(_ session: MCSession, didReceiveCertificate certificate: [Any]?,
                             fromPeer peerID: MCPeerID, certificateHandler: @escaping (Bool) -> Void) {
        certificateHandler(true)
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
