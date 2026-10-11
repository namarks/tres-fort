import Combine
import MultipeerConnectivity
import XCTest
@testable import TresFort

/// Connection handling for the iPhone and iPad link, driven through fake
/// sessions and a fake clock so every reconnect path runs without radios.
@MainActor
final class StationLinkTransportTests: XCTestCase {
    private let key = Data(repeating: 4, count: 32)
    private let clock = TestClock()
    private let ipadPeer = MCPeerID(displayName: "iPad")
    private let phonePeer = MCPeerID(displayName: "iPhone")
    private var tag: String { StationLink.discoveryTag(key: key) }

    private func requireCameraCounting() throws {
        #if APP_STORE_BUILD
        throw XCTSkip("Camera counting is exercised in the beta variant; PublicStationTests verifies its exclusion.")
        #endif
    }

    private func makeArm() -> StationLinkArm {
        StationLinkArm(armID: UUID(), slotID: "slot-1", setNumber: 1, exercise: .squat,
                       exerciseName: "Back Squat", targetReps: 5)
    }

    /// Both devices started with the account key and joined in one session.
    private func pairedDevices() -> (phone: Device, ipad: Device, wire: Wire) {
        let phone = Device(.controller, clock: clock), ipad = Device(.station, clock: clock)
        phone.transport.start(key: key)
        ipad.transport.start(key: key)
        phone.transport.handleFound(ipadPeer, info: ["tag": tag])
        return (phone, ipad, answer(phone, by: ipad))
    }

    /// The iPad accepts the phone's latest invitation and both sessions connect.
    @discardableResult
    private func answer(_ phone: Device, by ipad: Device) -> Wire {
        let invitation = phone.radio.invitations[phone.radio.invitations.count - 1]
        let channel = FakeChannel(phonePeer.displayName)
        var accepted = false
        ipad.transport.handleInvitation(from: phonePeer, context: invitation.context) { accept in
            accepted = accept
            return accept ? channel : nil
        }
        XCTAssertTrue(accepted)
        let wire = Wire(phone: phone, phoneChannel: invitation.channel, ipad: ipad, ipadChannel: channel)
        wire.connect()
        return wire
    }

    /// An iPhone from before heartbeats: the same handshake, run by hand.
    private func connectOlderPhone(to ipad: Device) throws -> (channel: FakeChannel, sessionKey: Data) {
        let channel = FakeChannel(phonePeer.displayName)
        ipad.transport.handleInvitation(from: phonePeer, context: Data(tag.utf8)) { $0 ? channel : nil }
        ipad.transport.handle(channel, connected: true)
        guard case .challenge(let ipadNonce)? = channel.sent.first.flatMap({ StationLinkMessage.decode($0) }) else {
            XCTFail("The iPad challenges every newcomer")
            throw ChannelClosed()
        }
        let phoneNonce = StationLink.newNonce()
        ipad.transport.handle(channel, received: try StationLinkMessage.challenge(phoneNonce).encoded())
        ipad.transport.handle(channel, received: try StationLinkMessage.proof(StationLink.proof(
            key: key, responderRole: "controller", challengerNonce: ipadNonce, responderNonce: phoneNonce)).encoded())
        XCTAssertEqual(ipad.transport.connection, .connected("iPhone"))
        return (channel, StationLink.sessionKey(key: key, controllerNonce: phoneNonce, stationNonce: ipadNonce))
    }

    func testPairedDevicesProveTheKeyThenExchangeOnlyTheirMessages() {
        let (phone, ipad, wire) = pairedDevices()
        XCTAssertEqual(phone.radio.tag, tag)
        XCTAssertEqual(ipad.radio.tag, tag)
        XCTAssertEqual(phone.transport.connection, .connected("iPad"))
        XCTAssertEqual(ipad.transport.connection, .connected("iPhone"))
        XCTAssertEqual([phone.connects, ipad.connects], [1, 1])
        XCTAssertTrue(phone.transport.isHealthy)

        let arm = makeArm()
        phone.transport.send(.arm(arm))
        ipad.transport.send(.station(.ready, armID: arm.armID))
        wire.pump()
        XCTAssertEqual(ipad.received, [.arm(arm)], "The handshake and heartbeats are never delivered")
        XCTAssertEqual(phone.received, [.station(.ready, armID: arm.armID)])
    }

    func testThePhoneInvitesOnlyAMatchingIpadAndOneAtATime() {
        let phone = Device(.controller, clock: clock)
        phone.transport.handleFound(ipadPeer, info: ["tag": tag])
        XCTAssertTrue(phone.radios.all.isEmpty, "Nothing is invited before the link starts")
        phone.transport.start(key: key)
        phone.transport.handleFound(MCPeerID(displayName: "Another account's iPad"), info: ["tag": "0123"])
        phone.transport.handleFound(MCPeerID(displayName: "Unlabelled"), info: nil)
        XCTAssertTrue(phone.radio.invitations.isEmpty)
        phone.transport.handleFound(ipadPeer, info: ["tag": tag])
        phone.transport.handleFound(MCPeerID(displayName: "Second iPad"), info: ["tag": tag])
        XCTAssertEqual(phone.radio.invitations.map(\.peer), [ipadPeer])
        XCTAssertEqual(phone.radio.invitations.first?.context, Data(tag.utf8))

        let ipad = Device(.station, clock: clock)
        ipad.transport.start(key: key)
        var answers: [Bool] = []
        ipad.transport.handleInvitation(from: phonePeer, context: Data("not-the-tag".utf8)) { answers.append($0); return nil }
        ipad.transport.handleInvitation(from: phonePeer, context: nil) { answers.append($0); return nil }
        XCTAssertEqual(answers, [false, false])
        XCTAssertEqual(ipad.transport.connection, .searching)
    }

    func testTheIpadTakesAReconnectingPhoneAndRetiresTheOldConnectionOnlyOnceItProvesTheKey() {
        let (phone, ipad, first) = pairedDevices()
        // The phone's session ended; the iPad was never told.
        phone.transport.handle(first.phoneChannel, connected: false)
        XCTAssertTrue(first.phoneChannel.closed)
        XCTAssertEqual(phone.transport.connection, .searching)
        XCTAssertEqual(phone.radio.invitations.count, 2, "The phone invites the iPad it still sees at once")
        XCTAssertEqual(ipad.transport.connection, .connected("iPhone"))

        let second = answer(phone, by: ipad)
        XCTAssertTrue(first.ipadChannel.closed)
        XCTAssertFalse(second.ipadChannel.closed)
        XCTAssertEqual(phone.transport.connection, .connected("iPad"))
        XCTAssertEqual(ipad.connects, 2)
        XCTAssertFalse(ipad.states.drop(while: { !$0.isConnected }).contains(where: { !$0.isConnected }),
                       "The iPad never showed the phone as gone, so its display didn't blank")

        phone.transport.send(.display(nil))
        second.pump()
        XCTAssertEqual(ipad.received, [.display(nil)])
    }

    func testAnImpostorWithThePublicTagNeverDisplacesTheConnection() throws {
        let (phone, ipad, wire) = pairedDevices()
        let impostor = FakeChannel("Impostor")
        ipad.transport.handleInvitation(from: MCPeerID(displayName: "Impostor"), context: Data(tag.utf8)) {
            $0 ? impostor : nil
        }
        ipad.transport.handle(impostor, connected: true)
        guard case .challenge(let ipadNonce)? = impostor.sent.first.flatMap({ StationLinkMessage.decode($0) }) else {
            return XCTFail("The iPad challenges every newcomer")
        }
        let impostorNonce = StationLink.newNonce()
        ipad.transport.handle(impostor, received: try StationLinkMessage.challenge(impostorNonce).encoded())
        ipad.transport.handle(impostor, received: try StationLinkMessage.proof(StationLink.proof(
            key: Data(repeating: 5, count: 32), responderRole: "controller",
            challengerNonce: ipadNonce, responderNonce: impostorNonce)).encoded())
        XCTAssertTrue(impostor.closed)
        XCTAssertFalse(wire.ipadChannel.closed)
        XCTAssertEqual(ipad.transport.connection, .connected("iPhone"))
        XCTAssertEqual(ipad.connects, 1)

        let arm = makeArm()
        phone.transport.send(.arm(arm))
        wire.pump()
        XCTAssertEqual(ipad.received, [.arm(arm)])
    }

    func testANewerInvitationReplacesAnAttemptThatNeverConnected() {
        let ipad = Device(.station, clock: clock)
        ipad.transport.start(key: key)
        let stuck = FakeChannel(phonePeer.displayName)
        ipad.transport.handleInvitation(from: phonePeer, context: Data(tag.utf8)) { $0 ? stuck : nil }

        let phone = Device(.controller, clock: clock)
        phone.transport.start(key: key)
        phone.transport.handleFound(ipadPeer, info: ["tag": tag])
        answer(phone, by: ipad)
        XCTAssertTrue(stuck.closed)
        XCTAssertEqual(ipad.transport.connection, .connected("iPhone"))
        XCTAssertEqual(phone.transport.connection, .connected("iPad"))
    }

    func testAQuietConnectionCarriesHeartbeatsSoOnlyASilentPeerIsDropped() {
        let (phone, ipad, wire) = pairedDevices()
        for _ in 0..<5 {
            clock.advance(StationLinkTransport.heartbeatInterval)
            phone.transport.tick()
            ipad.transport.tick()
            wire.pump()
        }
        XCTAssertEqual(phone.transport.connection, .connected("iPad"))
        XCTAssertEqual(ipad.transport.connection, .connected("iPhone"))
        XCTAssertTrue(phone.received.isEmpty && ipad.received.isEmpty)

        // A connection carrying messages needs no heartbeat.
        phone.transport.send(.display(nil))
        let sent = wire.phoneChannel.sent.count
        clock.advance(StationLinkTransport.heartbeatInterval / 2)
        phone.transport.tick()
        XCTAssertEqual(wire.phoneChannel.sent.count, sent)
        clock.advance(StationLinkTransport.heartbeatInterval / 2)
        phone.transport.tick()
        XCTAssertEqual(wire.phoneChannel.sent.count, sent + 1)
        wire.pump()

        // The iPad goes silent without a disconnect, as a suspended app can.
        ipad.transport.send(.station(.ready, armID: nil))
        wire.pump()
        clock.advance(StationLinkTransport.silenceLimit - 1)
        phone.transport.tick()
        XCTAssertEqual(phone.transport.connection, .connected("iPad"))
        clock.advance(1)
        phone.transport.tick()
        XCTAssertEqual(phone.transport.connection, .searching)
        XCTAssertTrue(wire.phoneChannel.closed)
        XCTAssertEqual(phone.radio.invitations.count, 2, "The phone looks for the iPad again at once")
    }

    func testAnIphoneFromBeforeHeartbeatsIsNeverDroppedForBeingQuiet() throws {
        let ipad = Device(.station, clock: clock)
        ipad.transport.start(key: key)
        let (channel, sessionKey) = try connectOlderPhone(to: ipad)
        // What the older iPhone makes of the iPad's heartbeat: a disarm of no set.
        let heartbeat = try XCTUnwrap(channel.sent.last)
        XCTAssertEqual(StationLink.open(heartbeat, sessionKey: sessionKey, senderRole: "station", after: 0)?.message,
                       .disarm(armID: StationLink.heartbeatArmID))

        clock.advance(60)
        ipad.transport.tick()
        XCTAssertEqual(ipad.transport.connection, .connected("iPhone"))
        XCTAssertTrue(ipad.transport.isHealthy)
        let arm = makeArm()
        ipad.transport.handle(channel, received: try XCTUnwrap(
            StationLink.seal(.arm(arm), sessionKey: sessionKey, senderRole: "controller", counter: 1)))
        XCTAssertEqual(ipad.received, [.arm(arm)])
    }

    func testContentFromANewerVersionIsSkippedButAForgedFrameDropsTheLink() throws {
        let ipad = Device(.station, clock: clock)
        ipad.transport.start(key: key)
        let (channel, sessionKey) = try connectOlderPhone(to: ipad)
        let future = Data(#"{"version":2,"message":{"hologram":{}}}"#.utf8)
        ipad.transport.handle(channel, received: try XCTUnwrap(
            StationLink.seal(body: future, sessionKey: sessionKey, senderRole: "controller", counter: 1)))
        XCTAssertEqual(ipad.transport.connection, .connected("iPhone"), "A sound frame it can't read keeps the link")
        XCTAssertTrue(ipad.received.isEmpty)

        let arm = makeArm()
        let sealed = try XCTUnwrap(StationLink.seal(.arm(arm), sessionKey: sessionKey,
                                                    senderRole: "controller", counter: 2))
        ipad.transport.handle(channel, received: sealed)
        XCTAssertEqual(ipad.received, [.arm(arm)])

        ipad.transport.handle(channel, received: try XCTUnwrap(
            StationLink.seal(.arm(arm), sessionKey: Data(repeating: 9, count: 32), senderRole: "controller", counter: 3)))
        XCTAssertTrue(channel.closed)
        XCTAssertEqual(ipad.transport.connection, .searching)
        XCTAssertEqual(ipad.received, [.arm(arm)])
    }

    func testAFailedSendDropsTheLinkAndThePhoneInvitesAgain() {
        let (phone, _, wire) = pairedDevices()
        wire.phoneChannel.refusesSends = true // the session no longer lists the iPad
        phone.transport.send(.display(nil))
        XCTAssertTrue(wire.phoneChannel.closed)
        XCTAssertEqual(phone.transport.connection, .searching)
        XCTAssertEqual(phone.radio.invitations.count, 2)
    }

    func testAStuckAttemptIsAbandonedAndAnotherIpadIsTriedBeforeItAgain() {
        let phone = Device(.controller, clock: clock)
        phone.transport.start(key: key)
        let stale = MCPeerID(displayName: "Stale advertisement")
        phone.transport.handleFound(stale, info: ["tag": tag])
        phone.transport.handleFound(ipadPeer, info: ["tag": tag])
        XCTAssertEqual(phone.radio.invitations.map(\.peer), [stale])

        clock.advance(StationLinkTransport.attemptLimit)
        phone.transport.tick()
        XCTAssertTrue(phone.radio.invitations[0].channel.closed)
        XCTAssertEqual(phone.radio.invitations.count, 1, "A short pause before the next attempt")
        clock.advance(StationLinkTransport.retryDelay)
        phone.transport.tick()
        XCTAssertEqual(phone.radio.invitations.map(\.peer), [stale, ipadPeer])

        // That one fails too: with every iPad in view tried, discovery starts over.
        phone.transport.handle(phone.radio.invitations[1].channel, connected: false)
        clock.advance(StationLinkTransport.retryDelay)
        phone.transport.tick()
        XCTAssertEqual(phone.radio.restarts, 1)
        XCTAssertEqual(phone.radio.invitations.count, 2)
        phone.transport.handleFound(ipadPeer, info: ["tag": tag])
        XCTAssertEqual(phone.radio.invitations.map(\.peer), [stale, ipadPeer, ipadPeer])
    }

    func testResumeKeepsAHealthyConnectionAndRebuildsAStaleOne() {
        let phone = Device(.controller, clock: clock)
        phone.transport.resume()
        XCTAssertTrue(phone.radios.all.isEmpty, "Nothing to resume before the link starts")
        let (pairedPhone, ipad, wire) = pairedDevices()
        pairedPhone.transport.resume()
        XCTAssertEqual(pairedPhone.radios.all.count, 1, "A live connection survives a trip to the background")
        XCTAssertFalse(wire.phoneChannel.closed)

        // Suspension closed the session without a callback.
        wire.phoneChannel.isOpen = false
        pairedPhone.transport.resume()
        XCTAssertEqual(pairedPhone.radios.all.count, 2)
        XCTAssertTrue(pairedPhone.radios.all[0].stopped)
        XCTAssertTrue(wire.phoneChannel.closed)
        XCTAssertEqual(pairedPhone.radio.tag, tag)
        XCTAssertEqual(pairedPhone.transport.connection, .searching)

        // The iPad heard nothing while it was suspended.
        clock.advance(StationLinkTransport.silenceLimit)
        XCTAssertFalse(ipad.transport.isHealthy)
        ipad.transport.resume()
        XCTAssertEqual(ipad.radios.all.count, 2)
        XCTAssertEqual(ipad.transport.connection, .searching)

        ipad.transport.handleDiscoveryFailure()
        XCTAssertEqual(ipad.transport.connection, .unavailable)
        ipad.transport.restart()
        XCTAssertEqual(ipad.transport.connection, .searching)
    }

    func testRetryAndReturningToTheAppRestartTheLinkFromAnyTab() {
        let phone = Device(.controller, clock: clock)
        let controller = StationLinkController(transport: phone.transport)
        controller.retryConnection()
        XCTAssertTrue(phone.radios.all.isEmpty, "Without a key, Today loads one first")
        XCTAssertEqual(controller.connectionAttempt, 1)

        controller.start(key: key)
        controller.retryConnection()
        XCTAssertEqual(phone.radios.all.count, 2, "A loaded key restarts even while Today is off screen")
        XCTAssertEqual(phone.radio.tag, tag)
        XCTAssertEqual(controller.connectionAttempt, 2)
        XCTAssertEqual(controller.connection, .searching)

        controller.appBecameActive()
        XCTAssertEqual(phone.radios.all.count, 3, "Back in the foreground, the search starts afresh")
        XCTAssertEqual(controller.connectionAttempt, 2)

        controller.keyUnavailable()
        controller.appBecameActive()
        XCTAssertEqual(controller.connectionAttempt, 3, "A key that failed to load is requested again")
        XCTAssertEqual(phone.radios.all.count, 3)
    }

    /// A runner on the iPhone and a counting Station on the iPad, connected.
    private func linkedRunner() -> (controller: StationLinkController, station: StationLinkStation,
                                    phone: Device, ipad: Device, wire: Wire) {
        let phone = Device(.controller, clock: clock), ipad = Device(.station, clock: clock)
        let controller = StationLinkController(transport: phone.transport)
        let station = StationLinkStation(transport: ipad.transport)
        controller.start(key: key)
        station.enable(key: key)
        phone.transport.handleFound(ipadPeer, info: ["tag": tag])
        let wire = answer(phone, by: ipad)
        controller.request(StationLinkTarget(slotID: "slot-1", setNumber: 1, exercise: .squat,
                                             exerciseName: "Back Squat", targetReps: 5))
        wire.pump()
        return (controller, station, phone, ipad, wire)
    }

    func testAReplacedConnectionStillDeliversTheCountTheOldOneLost() throws {
        try requireCameraCounting()
        let (controller, station, phone, ipad, first) = linkedRunner()
        XCTAssertNotNil(station.arm)
        XCTAssertEqual(station.arm, controller.arm)
        station.beginCounting()
        first.pump()
        XCTAssertEqual(controller.stationState, .counting)

        // The phone loses the session just as the iPad sends the finished count.
        phone.transport.handle(first.phoneChannel, connected: false)
        XCTAssertTrue(station.trialEnded(count: 5, leftCount: nil, rightCount: nil, partial: false))
        XCTAssertNil(controller.proposal)

        let second = answer(phone, by: ipad)
        let proposal = try XCTUnwrap(controller.proposal, "The iPad sends the count again on the new connection")
        XCTAssertEqual(proposal.reps, 5)
        XCTAssertTrue(proposal.logsAutomatically)
        controller.finishProposal(proposal.eventID)

        // A later reconnect repeats the count; the iPhone has already used it.
        phone.transport.handle(second.phoneChannel, connected: false)
        answer(phone, by: ipad)
        XCTAssertNil(controller.proposal)
        XCTAssertEqual(ipad.transport.connection, .connected("iPhone"))
    }

    func testAReplacedConnectionWithdrawsASetThePhoneMovedPastMeanwhile() throws {
        try requireCameraCounting()
        let (controller, station, phone, ipad, first) = linkedRunner()
        XCTAssertNotNil(station.arm)
        phone.transport.handle(first.phoneChannel, connected: false)
        controller.request(nil) // the runner moved on; this disarm can't reach the iPad
        XCTAssertNil(controller.arm)
        XCTAssertNotNil(station.arm)

        answer(phone, by: ipad)
        XCTAssertNil(station.arm, "The iPad learns that the set it still held was withdrawn")
        XCTAssertEqual(ipad.transport.connection, .connected("iPhone"))
        XCTAssertNil(controller.stationState)
    }

    func testTheIpadKeepsCountingThroughALostConnectionAndDeliversTheCountAfter() throws {
        try requireCameraCounting()
        let (controller, station, phone, ipad, first) = linkedRunner()
        station.beginCounting()
        station.observe(count: 2, leftCount: nil, rightCount: nil, status: .ready, partial: false, at: 1)
        first.pump()
        XCTAssertEqual(controller.progress?.count, 2)

        // The iPad is first to notice that the session ended, mid-set.
        ipad.transport.handle(first.ipadChannel, connected: false)
        XCTAssertEqual(station.connection, .searching)
        XCTAssertNotNil(station.arm)
        XCTAssertTrue(station.isCounting, "The set keeps counting while the iPhone reconnects")
        phone.transport.handle(first.phoneChannel, connected: false)
        XCTAssertNil(controller.progress)

        let second = answer(phone, by: ipad)
        XCTAssertEqual(controller.stationState, .counting)
        XCTAssertEqual(controller.progress?.count, 2, "The live count shows again at once")

        // Lost again just as the set finishes: the count waits for the next connection.
        ipad.transport.handle(second.ipadChannel, connected: false)
        XCTAssertTrue(station.trialEnded(count: 5, leftCount: nil, rightCount: nil, partial: false))
        phone.transport.handle(second.phoneChannel, connected: false)
        XCTAssertNil(controller.proposal)
        answer(phone, by: ipad)
        let proposal = try XCTUnwrap(controller.proposal)
        XCTAssertEqual(proposal.reps, 5)
        XCTAssertEqual(station.arm, controller.arm)
    }

    func testAHeartbeatIsANoOpForBuildsThatPredateIt() throws {
        struct OlderEnvelope: Decodable {
            enum Message: Decodable, Equatable { case disarm(armID: UUID) }
            let version: Int
            let message: Message
        }
        let sessionKey = Data(repeating: 6, count: 32)
        let sealed = try XCTUnwrap(StationLink.sealHeartbeat(sessionKey: sessionKey, senderRole: "station", counter: 1))
        let frame = try XCTUnwrap(StationLink.openFrame(sealed, sessionKey: sessionKey, senderRole: "station", after: 0))
        XCTAssertEqual(frame.counter, 1)
        XCTAssertEqual(StationLinkMessage.inbound(frame.body), .heartbeat)
        let older = try JSONDecoder().decode(OlderEnvelope.self, from: frame.body)
        XCTAssertEqual(older.version, 1)
        XCTAssertEqual(older.message, .disarm(armID: StationLink.heartbeatArmID), "Older builds read a disarm")

        // Neither side of an older link acts on a disarm of a set it never armed.
        let station = StationLinkStation()
        let arm = makeArm()
        station.receive(.arm(arm))
        let armed = station.arm
        station.receive(.disarm(armID: StationLink.heartbeatArmID))
        XCTAssertEqual(station.arm, armed)
        let controller = StationLinkController()
        controller.receive(.disarm(armID: StationLink.heartbeatArmID))
        XCTAssertNil(controller.proposal)
        XCTAssertNil(controller.stationState)

        XCTAssertEqual(StationLinkMessage.inbound(try StationLinkMessage.arm(arm).encoded()), .message(.arm(arm)))
        XCTAssertEqual(StationLinkMessage.inbound(Data(#"{"version":2,"message":{}}"#.utf8)), .unreadable)
        XCTAssertEqual(StationLinkMessage.inbound(Data("not json".utf8)), .unreadable)
    }
}

private struct ChannelClosed: Error {}

private final class TestClock {
    var time = Date(timeIntervalSince1970: 2_000_000_000)
    func advance(_ seconds: TimeInterval) { time = time.addingTimeInterval(seconds) }
}

@MainActor
private final class FakeChannel: StationLinkChannel {
    let peerName: String
    var isOpen = true
    var refusesSends = false
    private(set) var closed = false
    private(set) var sent: [Data] = []

    init(_ peerName: String) { self.peerName = peerName }

    func send(_ data: Data) throws {
        guard isOpen, !closed, !refusesSends else { throw ChannelClosed() }
        sent.append(data)
    }

    func close() {
        closed = true
        isOpen = false
    }
}

@MainActor
private final class FakeRadio: StationLinkRadio {
    struct Invitation {
        let peer: MCPeerID
        let context: Data
        let channel: FakeChannel
    }

    private(set) var tag: String?
    private(set) var restarts = 0
    private(set) var stopped = false
    private(set) var invitations: [Invitation] = []

    func startDiscovery(tag: String) { self.tag = tag }
    func restartDiscovery() { restarts += 1 }
    func stopDiscovery() { stopped = true }

    func invite(_ peer: MCPeerID, context: Data, timeout: TimeInterval) -> StationLinkChannel {
        let channel = FakeChannel(peer.displayName)
        invitations.append(Invitation(peer: peer, context: context, channel: channel))
        return channel
    }
}

/// Every radio a transport has made: one per start.
@MainActor
private final class Radios {
    private(set) var all: [FakeRadio] = []

    func make() -> StationLinkRadio {
        let radio = FakeRadio()
        all.append(radio)
        return radio
    }
}

/// One device's transport and what it delivered.
@MainActor
private final class Device {
    let transport: StationLinkTransport
    let radios: Radios
    private(set) var received: [StationLinkMessage] = []
    private(set) var connects = 0
    private(set) var states: [StationLinkTransport.Connection] = []
    private var subscription: AnyCancellable?

    var radio: FakeRadio { radios.all[radios.all.count - 1] }

    init(_ role: StationLinkTransport.Role, clock: TestClock) {
        let radios = Radios()
        self.radios = radios
        transport = StationLinkTransport(role: role, radio: { _, _ in radios.make() },
                                         now: { clock.time }, ticksAutomatically: false)
        transport.onMessage = { [weak self] in self?.received.append($0) }
        transport.onConnect = { [weak self] in self?.connects += 1 }
        subscription = transport.$connection.sink { [weak self] in self?.states.append($0) }
    }
}

/// Carries what each side sends to the other, in order, like one session
/// between the two devices.
@MainActor
private final class Wire {
    let phone: Device
    let phoneChannel: FakeChannel
    let ipad: Device
    let ipadChannel: FakeChannel
    private var toIpad = 0
    private var toPhone = 0

    init(phone: Device, phoneChannel: FakeChannel, ipad: Device, ipadChannel: FakeChannel) {
        self.phone = phone
        self.phoneChannel = phoneChannel
        self.ipad = ipad
        self.ipadChannel = ipadChannel
    }

    func connect() {
        phone.transport.handle(phoneChannel, connected: true)
        ipad.transport.handle(ipadChannel, connected: true)
        pump()
    }

    func pump() {
        while !phoneChannel.closed, !ipadChannel.closed,
              toIpad < phoneChannel.sent.count || toPhone < ipadChannel.sent.count {
            if toIpad < phoneChannel.sent.count {
                let data = phoneChannel.sent[toIpad]
                toIpad += 1
                ipad.transport.handle(ipadChannel, received: data)
            } else {
                let data = ipadChannel.sent[toPhone]
                toPhone += 1
                phone.transport.handle(phoneChannel, received: data)
            }
        }
    }
}
