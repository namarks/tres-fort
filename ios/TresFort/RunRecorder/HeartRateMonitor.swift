import CoreBluetooth
import Foundation

/// A Bluetooth heart rate strap for the run recorder (docs/plans/run-recorder,
/// from P3 feedback). The member picks one in the recorder, it is remembered
/// on this iPhone, and it reconnects whenever the recorder opens or a run
/// records. Bluetooth permission is asked only when the member sets one up.
@MainActor
final class HeartRateMonitor: ObservableObject {
    struct Strap: Codable, Equatable, Identifiable {
        /// CoreBluetooth's identifier for the strap, stable on this iPhone.
        var id: UUID
        var name: String
    }

    enum Bluetooth: Equatable {
        case unknown
        case on
        case off
        case denied
        case unsupported
    }

    @Published private(set) var saved: Strap?
    @Published private(set) var bluetooth: Bluetooth = .unknown
    @Published private(set) var isConnected = false
    @Published private(set) var latest: RecordedRun.HeartRateSample?
    /// Straps seen while the setup screen searches, in the order found.
    @Published private(set) var found: [Strap] = []
    @Published private(set) var isSearching = false

    /// Each reading from the saved strap, for the run being recorded.
    var onSample: ((RecordedRun.HeartRateSample) -> Void)?

    static let savedKey = "runRecorder.heartRateMonitor"

    private let defaults: UserDefaults
    private let makeCentral: @MainActor () -> HeartRateCentral
    private let now: @MainActor () -> Date
    private var central: HeartRateCentral?
    /// The recorder is open or a run records, so a dropped strap reconnects.
    private var wantsConnection = false

    init(defaults: UserDefaults = .standard,
         makeCentral: (@MainActor () -> HeartRateCentral)? = nil,
         now: @escaping @MainActor () -> Date = Date.init) {
        self.defaults = defaults
        self.makeCentral = makeCentral ?? { CoreBluetoothHeartRateCentral() }
        self.now = now
        saved = defaults.data(forKey: Self.savedKey).flatMap { try? JSONDecoder().decode(Strap.self, from: $0) }
    }

    /// One line for the recorder's start screen.
    var status: String {
        guard let saved else { return "No heart rate monitor" }
        switch bluetooth {
        case .off: return "Bluetooth is off"
        case .denied: return "Allow Bluetooth for Très Fort in Settings"
        case .unsupported: return "This iPhone can’t use Bluetooth heart rate monitors"
        case .unknown, .on: break
        }
        guard isConnected else { return "Looking for \(saved.name)…" }
        guard let latest else { return "\(saved.name) · waiting for a reading" }
        return "\(saved.name) · \(Int(latest.beatsPerMinute.rounded())) bpm"
    }

    // MARK: - Connection

    /// Connects the remembered strap, if there is one, and keeps it connected.
    func connectSaved() {
        guard let saved else { return }
        wantsConnection = true
        guard !isConnected else { return }
        activeCentral().connect(saved.id)
    }

    /// The recorder closed with no run recording, or the strap was forgotten.
    /// Searching stops with the setup screen, not here.
    func release() {
        wantsConnection = false
        central?.disconnect()
        isConnected = false
        latest = nil
    }

    // MARK: - Setup

    func startSearching() {
        found = []
        isSearching = true
        activeCentral().scan()
    }

    func stopSearching() {
        guard isSearching else { return }
        isSearching = false
        central?.stopScan()
    }

    /// Remembers this strap in place of any other and connects it.
    func choose(_ strap: Strap) {
        if let old = saved, old.id != strap.id {
            central?.disconnect()
            isConnected = false
            latest = nil
        }
        saved = strap
        defaults.set(try? JSONEncoder().encode(strap), forKey: Self.savedKey)
        connectSaved()
    }

    func forget() {
        release()
        saved = nil
        defaults.removeObject(forKey: Self.savedKey)
    }

    // MARK: - Events

    private func activeCentral() -> HeartRateCentral {
        if let central { return central }
        let central = makeCentral()
        central.onEvent = { [weak self] in self?.handle($0) }
        self.central = central
        return central
    }

    func handle(_ event: HeartRateCentralEvent) {
        switch event {
        case .bluetooth(let state):
            bluetooth = state
            if state == .on {
                if wantsConnection, !isConnected, let saved { central?.connect(saved.id) }
            } else {
                isConnected = false
                latest = nil
            }
        case .found(let strap):
            if let index = found.firstIndex(where: { $0.id == strap.id }) {
                found[index] = strap
            } else {
                found.append(strap)
            }
        case .connected(let id):
            guard id == saved?.id else { return }
            isConnected = true
        case .disconnected(let id):
            guard id == saved?.id else { return }
            isConnected = false
            latest = nil
            // CoreBluetooth waits for the strap to come back in range.
            if wantsConnection { central?.connect(id) }
        case .heartRate(let id, let beatsPerMinute):
            guard id == saved?.id, isConnected, beatsPerMinute > 0 else { return }
            let sample = RecordedRun.HeartRateSample(timestamp: now(), beatsPerMinute: Double(beatsPerMinute))
            latest = sample
            onSample?(sample)
        }
    }
}

enum HeartRateCentralEvent: Equatable {
    case bluetooth(HeartRateMonitor.Bluetooth)
    case found(HeartRateMonitor.Strap)
    case connected(UUID)
    case disconnected(UUID)
    case heartRate(UUID, Int)
}

/// The Bluetooth side, a protocol so the monitor's logic is tested without
/// a radio. One strap is connected at a time.
@MainActor
protocol HeartRateCentral: AnyObject {
    var onEvent: ((HeartRateCentralEvent) -> Void)? { get set }
    func scan()
    func stopScan()
    /// Connects and subscribes to heart rate, waiting for the strap to come
    /// in range. Does nothing until Bluetooth is on, when the monitor asks
    /// again.
    func connect(_ id: UUID)
    func disconnect()
}

/// The standard Bluetooth Heart Rate Measurement characteristic (0x2A37).
enum HeartRateMeasurement {
    /// Beats per minute, or nil when the packet is malformed or the strap
    /// reports it has lost skin contact.
    static func beatsPerMinute(from data: Data) -> Int? {
        let bytes = [UInt8](data)
        guard let flags = bytes.first else { return nil }
        let contactSupported = flags & 0x04 != 0
        let contactDetected = flags & 0x02 != 0
        if contactSupported && !contactDetected { return nil }
        if flags & 0x01 == 0 {
            guard bytes.count >= 2 else { return nil }
            return Int(bytes[1])
        }
        guard bytes.count >= 3 else { return nil }
        return Int(bytes[1]) | Int(bytes[2]) << 8
    }
}

/// Polar, Wahoo, Garmin HRM and most other straps advertise the standard
/// Heart Rate service, so no pairing in iOS Settings is needed.
@MainActor
final class CoreBluetoothHeartRateCentral: NSObject, HeartRateCentral {
    static let service = CBUUID(string: "180D")
    static let measurement = CBUUID(string: "2A37")

    var onEvent: ((HeartRateCentralEvent) -> Void)?

    private var manager: CBCentralManager!
    private var peripherals: [UUID: CBPeripheral] = [:]
    private var connecting: CBPeripheral?
    private var wantsScan = false

    override init() {
        super.init()
        // Creating the manager is what asks for Bluetooth permission.
        manager = CBCentralManager(delegate: self, queue: .main)
    }

    func scan() {
        wantsScan = true
        guard manager.state == .poweredOn else { return }
        // A strap already connected to this iPhone, by another app, no
        // longer advertises.
        for peripheral in manager.retrieveConnectedPeripherals(withServices: [Self.service]) {
            report(peripheral)
        }
        manager.scanForPeripherals(withServices: [Self.service])
    }

    func stopScan() {
        wantsScan = false
        if manager.state == .poweredOn { manager.stopScan() }
    }

    func connect(_ id: UUID) {
        guard manager.state == .poweredOn else { return }
        if let connecting, connecting.identifier != id {
            manager.cancelPeripheralConnection(connecting)
        }
        guard let peripheral = peripherals[id] ?? manager.retrievePeripherals(withIdentifiers: [id]).first else {
            return
        }
        peripheral.delegate = self
        peripherals[id] = peripheral
        connecting = peripheral
        if peripheral.state == .connected {
            onEvent?(.connected(id))
            peripheral.discoverServices([Self.service])
        } else {
            manager.connect(peripheral)
        }
    }

    func disconnect() {
        guard let connecting else { return }
        self.connecting = nil
        manager.cancelPeripheralConnection(connecting)
    }

    private func report(_ peripheral: CBPeripheral, advertisedName: String? = nil) {
        peripherals[peripheral.identifier] = peripheral
        let name = advertisedName ?? peripheral.name ?? "Heart rate monitor"
        onEvent?(.found(.init(id: peripheral.identifier, name: name)))
    }

    private static func bluetooth(_ state: CBManagerState) -> HeartRateMonitor.Bluetooth {
        switch state {
        case .poweredOn: .on
        case .poweredOff: .off
        case .unauthorized: .denied
        case .unsupported: .unsupported
        default: .unknown
        }
    }
}

// The manager calls back on the main queue.
extension CoreBluetoothHeartRateCentral: CBCentralManagerDelegate, CBPeripheralDelegate {
    nonisolated func centralManagerDidUpdateState(_ central: CBCentralManager) {
        MainActor.assumeIsolated {
            if central.state != .poweredOn {
                // Peripherals don't survive Bluetooth turning off.
                peripherals = [:]
                connecting = nil
            }
            onEvent?(.bluetooth(Self.bluetooth(central.state)))
            if central.state == .poweredOn, wantsScan { scan() }
        }
    }

    nonisolated func centralManager(_ central: CBCentralManager, didDiscover peripheral: CBPeripheral,
                                    advertisementData: [String: Any], rssi RSSI: NSNumber) {
        let name = advertisementData[CBAdvertisementDataLocalNameKey] as? String
        MainActor.assumeIsolated { report(peripheral, advertisedName: name) }
    }

    nonisolated func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
        MainActor.assumeIsolated {
            guard connecting?.identifier == peripheral.identifier else { return }
            onEvent?(.connected(peripheral.identifier))
            peripheral.discoverServices([Self.service])
        }
    }

    nonisolated func centralManager(_ central: CBCentralManager, didFailToConnect peripheral: CBPeripheral,
                                    error: Error?) {
        MainActor.assumeIsolated { onEvent?(.disconnected(peripheral.identifier)) }
    }

    nonisolated func centralManager(_ central: CBCentralManager, didDisconnectPeripheral peripheral: CBPeripheral,
                                    error: Error?) {
        MainActor.assumeIsolated { onEvent?(.disconnected(peripheral.identifier)) }
    }

    nonisolated func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: Error?) {
        MainActor.assumeIsolated {
            for service in peripheral.services ?? [] where service.uuid == Self.service {
                peripheral.discoverCharacteristics([Self.measurement], for: service)
            }
        }
    }

    nonisolated func peripheral(_ peripheral: CBPeripheral, didDiscoverCharacteristicsFor service: CBService,
                                error: Error?) {
        MainActor.assumeIsolated {
            for characteristic in service.characteristics ?? [] where characteristic.uuid == Self.measurement {
                peripheral.setNotifyValue(true, for: characteristic)
            }
        }
    }

    nonisolated func peripheral(_ peripheral: CBPeripheral, didUpdateValueFor characteristic: CBCharacteristic,
                                error: Error?) {
        MainActor.assumeIsolated {
            guard characteristic.uuid == Self.measurement, let data = characteristic.value,
                  let bpm = HeartRateMeasurement.beatsPerMinute(from: data) else { return }
            onEvent?(.heartRate(peripheral.identifier, bpm))
        }
    }
}
