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

/// A separate opt-in from workout sync. Only the preference is persisted;
/// weight samples never enter the API, outbox, account export, or group feed.
@MainActor
final class BodyWeightModel: ObservableObject {
    @Published private(set) var enabled: Bool
    @Published private(set) var isConnecting = false
    @Published private(set) var isReading = false
    @Published private(set) var history: BodyWeightHistory?
    @Published private(set) var errorMessage: String?

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
            errorMessage = "Couldn’t request weight access. Please try again."
        }
    }

    func refresh() async {
        guard isCurrent else { clearDisplay(); return }
        guard enabled, isAvailable, !isBusy else { return }
        isReading = true
        errorMessage = nil
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
            errorMessage = "Couldn’t read weight from Apple Health. Unlock your iPhone and try again."
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
        errorMessage = nil
        isConnecting = false
        isReading = false
    }
}
