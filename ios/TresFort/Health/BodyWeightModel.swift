import HealthKit
import SwiftUI

@MainActor
protocol BodyWeightReading {
    var isAvailable: Bool { get }
    func requestAuthorization() async throws
    func read(from: Date, through: Date) async throws -> [BodyWeightMeasurement]
}

@MainActor
final class HealthKitBodyWeightReader: BodyWeightReading {
    private let store = HKHealthStore()
    private let type = HKQuantityType(.bodyMass)
    var isAvailable: Bool { HKHealthStore.isHealthDataAvailable() }

    func requestAuthorization() async throws {
        try await store.requestAuthorization(toShare: [], read: [type])
    }

    func read(from: Date, through: Date) async throws -> [BodyWeightMeasurement] {
        // Also fetch the latest historical sample: an old reading must retain
        // its real date, even when the selected chart window has no readings.
        let latest = try await samples(from: nil, through: through, limit: 1)
        let recent = try await samples(from: from, through: through, limit: HKObjectQueryNoLimit)
        return latest + recent
    }

    private func samples(from: Date?, through: Date, limit: Int) async throws -> [BodyWeightMeasurement] {
        try await withCheckedThrowingContinuation { continuation in
            let predicate = HKQuery.predicateForSamples(withStart: from, end: through,
                                                       options: [.strictStartDate, .strictEndDate])
            let query = HKSampleQuery(sampleType: type, predicate: predicate, limit: limit,
                sortDescriptors: [NSSortDescriptor(key: HKSampleSortIdentifierStartDate, ascending: false)]) {
                    _, samples, error in
                if let error { continuation.resume(throwing: error); return }
                let values = (samples as? [HKQuantitySample] ?? []).map {
                    BodyWeightMeasurement(id: $0.uuid, date: $0.startDate,
                        kilograms: $0.quantity.doubleValue(for: .gramUnit(with: .kilo)),
                        source: $0.sourceRevision.source.name)
                }
                continuation.resume(returning: values)
            }
            store.execute(query)
        }
    }
}

/// Keep only an actionable category; raw HealthKit errors may contain private details.
enum BodyWeightFailure: Equatable {
    case locked, accessRequired, restricted, unavailable, connection, read

    enum Recovery { case reconnect, retry, none }

    init(_ error: Error, requestingAuthorization: Bool = false) {
        let error = error as NSError
        if error.domain == HKErrorDomain {
            switch HKError.Code(rawValue: error.code) {
            case .errorDatabaseInaccessible: self = .locked
            case .errorAuthorizationNotDetermined, .errorAuthorizationDenied: self = .accessRequired
            case .errorHealthDataRestricted: self = .restricted
            case .errorHealthDataUnavailable: self = .unavailable
            default: self = requestingAuthorization ? .connection : .read
            }
        } else {
            self = requestingAuthorization ? .connection : .read
        }
    }

    var title: String {
        switch self {
        case .locked: "Unlock to read weight"
        case .accessRequired: "Review weight access"
        case .restricted: "Health access is restricted"
        case .unavailable: "Apple Health is unavailable"
        case .connection: "Couldn’t connect to Apple Health"
        case .read: "Couldn’t read weight"
        }
    }

    var message: String {
        switch self {
        case .locked:
            "Apple Health couldn’t read your weight while this iPhone was locked. Unlock it, then try again."
        case .accessRequired:
            "Reconnect to review weight access. If Weight is turned off in Health, enable it there and try again."
        case .restricted:
            "This iPhone restricts access to Health data. Check Screen Time or device-management restrictions in Settings."
        case .unavailable:
            "Apple Health couldn’t provide data on this iPhone. Try again when Health is available."
        case .connection:
            "The weight access request didn’t finish. Try reconnecting again."
        case .read:
            "Apple Health couldn’t provide your weight. Reconnect to request access again and retry the read."
        }
    }

    var recovery: Recovery {
        switch self {
        case .accessRequired, .connection, .read: .reconnect
        case .locked, .unavailable: .retry
        case .restricted: .none
        }
    }
}

/// A separate opt-in from workout sync. Only the preference is persisted;
/// weight samples never enter the API, outbox, account export, or group feed.
@MainActor
final class BodyWeightModel: ObservableObject {
    @Published private(set) var enabled: Bool
    @Published private(set) var isConnecting = false
    @Published private(set) var isReading = false
    @Published private(set) var history: BodyWeightHistory?
    @Published private(set) var failure: BodyWeightFailure?
    var errorMessage: String? { failure?.message }

    private let reader: any BodyWeightReading
    private unowned let auth: AuthModel
    private let accountID: String?
    private let sessionEpoch: UInt64
    private let defaults: LocalPersistence
    private let storageGeneration: UInt64
    private let now: () -> Date
    private var generation: UInt64 = 0

    init(auth: AuthModel, defaults: LocalPersistence = .standard,
         reader: (any BodyWeightReading)? = nil,
         now: @escaping () -> Date = Date.init) {
        self.auth = auth
        self.accountID = auth.userID
        self.sessionEpoch = auth.featureSessionEpoch
        self.defaults = defaults
        self.storageGeneration = defaults.recoveryGeneration
        self.reader = reader ?? HealthKitBodyWeightReader()
        self.now = now
        self.enabled = auth.userID.map { defaults.bool(forKey: AccountLocalState.bodyWeightEnabledKey(userID: $0)) } ?? false
        auth.observeFeatureSessionBoundary { [weak self] in
            guard let self else { return false }
            self.clearDisplay()
            self.enabled = false
            return true
        }
    }

    var isAvailable: Bool { reader.isAvailable }
    var requiresPersonalSignIn: Bool { auth.isReviewAccount }
    var isBusy: Bool { isConnecting || isReading }

    private var isCurrent: Bool {
        !auth.isReviewAccount && defaults.recoveryGeneration == storageGeneration
            && auth.isCurrentFeatureSession(accountID: accountID, epoch: sessionEpoch)
    }

    func connect() async {
        guard isAvailable, isCurrent, !isBusy else { return }
        isConnecting = true
        failure = nil
        let ticket = generation
        defer { if ticket == generation { isConnecting = false } }
        do {
            try await reader.requestAuthorization()
            guard ticket == generation, isCurrent, let accountID else { return }
            // Completing the sheet records intent, not proof of read permission.
            defaults.set(true, forKey: AccountLocalState.bodyWeightEnabledKey(userID: accountID))
            enabled = true
            isConnecting = false
            await refresh()
        } catch {
            guard ticket == generation, isCurrent else { return }
            failure = BodyWeightFailure(error, requestingAuthorization: true)
        }
    }

    func refresh() async {
        guard isCurrent else { clearDisplay(); return }
        guard enabled, isAvailable, !isBusy else { return }
        isReading = true
        failure = nil
        let ticket = generation
        defer { if ticket == generation { isReading = false } }
        let date = now()
        // 90 displayed civil days plus six days for the first rolling average.
        let start = Calendar.current.date(byAdding: .day, value: -95,
                                          to: Calendar.current.startOfDay(for: date))!
        do {
            let measurements = try await reader.read(from: start, through: date)
            guard ticket == generation, enabled, isCurrent else { return }
            // Replace, never append: deletions or revoked access clear old data.
            history = BodyWeightHistory(measurements, asOf: date)
        } catch {
            guard ticket == generation, isCurrent else { return }
            history = nil
            failure = BodyWeightFailure(error)
        }
    }

    func recover() async {
        guard let failure else { return }
        switch failure.recovery {
        case .reconnect:
            // Re-request access without opting out or changing stored intent.
            await connect()
        case .retry:
            if enabled { await refresh() }
            else { await connect() }
        case .none:
            break
        }
    }

    func disconnect() {
        // Old model instances must not change a replacement session's opt-in.
        if isCurrent, let accountID {
            defaults.set(false, forKey: AccountLocalState.bodyWeightEnabledKey(userID: accountID))
        }
        enabled = false
        clearDisplay()
    }

    private func clearDisplay() {
        generation &+= 1
        history = nil
        failure = nil
        isConnecting = false
        isReading = false
    }
}
