import Foundation
import XCTest
@testable import TresFort

@MainActor
final class FakeHeartRateCentral: HeartRateCentral {
    var onEvent: ((HeartRateCentralEvent) -> Void)?
    private(set) var calls: [String] = []

    func scan() { calls.append("scan") }
    func stopScan() { calls.append("stopScan") }
    func connect(_ id: UUID) { calls.append("connect") }
    func disconnect() { calls.append("disconnect") }

    func send(_ event: HeartRateCentralEvent) { onEvent?(event) }
}

@MainActor
final class HeartRateMonitorTests: XCTestCase {
    private var central: FakeHeartRateCentral!
    private var centralsMade = 0
    private var defaults: UserDefaults!
    private var defaultsSuite: String!
    private var clock = Date(timeIntervalSince1970: 1_793_000_000)
    private let polar = HeartRateMonitor.Strap(id: UUID(), name: "Polar H10 A1B2C3D4")
    private let tickr = HeartRateMonitor.Strap(id: UUID(), name: "TICKR 1234")

    override func setUp() async throws {
        central = FakeHeartRateCentral()
        centralsMade = 0
        defaultsSuite = "heart-rate-\(UUID())"
        defaults = UserDefaults(suiteName: defaultsSuite)
    }

    override func tearDown() async throws {
        defaults.removePersistentDomain(forName: defaultsSuite)
    }

    private func makeMonitor() -> HeartRateMonitor {
        HeartRateMonitor(defaults: defaults,
                         makeCentral: { [unowned self] in
                             self.centralsMade += 1
                             return self.central
                         },
                         now: { [unowned self] in self.clock })
    }

    func testMeasurementReadsEightAndSixteenBitHeartRates() {
        XCTAssertEqual(HeartRateMeasurement.beatsPerMinute(from: Data([0x00, 72])), 72)
        XCTAssertEqual(HeartRateMeasurement.beatsPerMinute(from: Data([0x01, 0x2C, 0x01])), 300)
        // Contact supported and detected, with RR intervals after the value.
        XCTAssertEqual(HeartRateMeasurement.beatsPerMinute(from: Data([0x16, 151, 0x10, 0x03])), 151)
    }

    func testMeasurementSkipsLostContactAndShortPackets() {
        XCTAssertNil(HeartRateMeasurement.beatsPerMinute(from: Data([0x04, 0])))
        XCTAssertNil(HeartRateMeasurement.beatsPerMinute(from: Data()))
        XCTAssertNil(HeartRateMeasurement.beatsPerMinute(from: Data([0x00])))
        XCTAssertNil(HeartRateMeasurement.beatsPerMinute(from: Data([0x01, 0x2C])))
    }

    func testNothingTouchesBluetoothUntilAStrapIsSetUp() {
        let monitor = makeMonitor()
        monitor.connectSaved()
        monitor.release()
        XCTAssertEqual(centralsMade, 0, "Creating the central would ask for Bluetooth permission")
        XCTAssertEqual(monitor.status, "No heart rate monitor")
    }

    func testChoosingAStrapRemembersAndConnectsIt() {
        let monitor = makeMonitor()
        monitor.startSearching()
        central.send(.bluetooth(.on))
        central.send(.found(polar))
        central.send(.found(tickr))
        central.send(.found(polar))
        XCTAssertEqual(monitor.found, [polar, tickr])

        monitor.choose(polar)
        XCTAssertEqual(monitor.status, "Looking for Polar H10 A1B2C3D4…")
        central.send(.connected(polar.id))
        XCTAssertEqual(monitor.status, "Polar H10 A1B2C3D4 · waiting for a reading")
        central.send(.heartRate(polar.id, 72))
        XCTAssertEqual(monitor.status, "Polar H10 A1B2C3D4 · 72 bpm")
        XCTAssertEqual(monitor.latest, RecordedRun.HeartRateSample(timestamp: clock, beatsPerMinute: 72))
        monitor.stopSearching()
        XCTAssertEqual(central.calls, ["scan", "connect", "stopScan"])

        XCTAssertEqual(makeMonitor().saved, polar, "The strap is remembered on this iPhone")
    }

    func testOnlyTheSavedStrapCountsAndADroppedOneReconnects() {
        defaults.set(try? JSONEncoder().encode(polar), forKey: HeartRateMonitor.savedKey)
        let monitor = makeMonitor()
        var samples: [Double] = []
        monitor.onSample = { samples.append($0.beatsPerMinute) }
        monitor.connectSaved()
        central.send(.bluetooth(.on))
        central.send(.connected(tickr.id))
        central.send(.heartRate(tickr.id, 90))
        XCTAssertFalse(monitor.isConnected)

        central.send(.connected(polar.id))
        central.send(.heartRate(polar.id, 0))
        central.send(.heartRate(polar.id, 140))
        XCTAssertEqual(samples, [140])

        central.send(.disconnected(polar.id))
        XCTAssertFalse(monitor.isConnected)
        XCTAssertNil(monitor.latest)
        XCTAssertEqual(central.calls, ["connect", "connect", "connect"],
                       "Asked on connectSaved, when Bluetooth came on and after the drop")

        monitor.release()
        central.send(.disconnected(polar.id))
        XCTAssertEqual(central.calls, ["connect", "connect", "connect", "disconnect"],
                       "A released strap doesn't reconnect")
    }

    func testBluetoothProblemsShowInTheStatus() {
        defaults.set(try? JSONEncoder().encode(polar), forKey: HeartRateMonitor.savedKey)
        let monitor = makeMonitor()
        monitor.connectSaved()
        central.send(.bluetooth(.on))
        central.send(.connected(polar.id))
        central.send(.bluetooth(.off))
        XCTAssertFalse(monitor.isConnected)
        XCTAssertEqual(monitor.status, "Bluetooth is off")
        central.send(.bluetooth(.denied))
        XCTAssertEqual(monitor.status, "Allow Bluetooth for Très Fort in Settings")
    }

    func testForgettingAStrapDisconnectsAndClearsIt() {
        let monitor = makeMonitor()
        monitor.choose(polar)
        central.send(.bluetooth(.on))
        central.send(.connected(polar.id))
        monitor.forget()
        XCTAssertNil(monitor.saved)
        XCTAssertFalse(monitor.isConnected)
        XCTAssertNil(defaults.data(forKey: HeartRateMonitor.savedKey))
        XCTAssertEqual(central.calls.last, "disconnect")
    }

    func testSwitchingStrapsDropsTheOldOne() {
        let monitor = makeMonitor()
        monitor.choose(polar)
        central.send(.bluetooth(.on))
        central.send(.connected(polar.id))
        monitor.choose(tickr)
        XCTAssertFalse(monitor.isConnected)
        central.send(.disconnected(polar.id))
        central.send(.connected(tickr.id))
        XCTAssertTrue(monitor.isConnected)
        XCTAssertEqual(monitor.saved, tickr)
    }
}
