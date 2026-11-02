import CoreLocation
import Foundation
import HealthKit

/// Totals the workout builder reports while a run records.
struct RunWorkoutMetrics: Equatable {
    var distanceMeters: Double
    /// Builder elapsed time, which excludes pauses.
    var movingSeconds: Double
    var heartRate: RecordedRun.HeartRateSample?
}

/// What ending a run left in Apple Health.
struct RunWorkoutEnd: Equatable {
    var metrics: RunWorkoutMetrics
    /// True only when Health saved the workout with everything sent to it:
    /// the route and any strap readings. When false, the copy on this iPhone
    /// is still needed.
    var savedAll: Bool
}

enum RunWorkoutRecovery: Equatable {
    case running
    case paused
}

/// The Apple Health side of a recording: the workout session, its live
/// builder and the route. A protocol so the recorder's own logic is tested
/// without HealthKit.
@MainActor
protocol RunWorkoutEngine: AnyObject {
    var onMetrics: ((RunWorkoutMetrics) -> Void)? { get set }
    /// The session failed or ended outside the app's control.
    var onFailure: ((String) -> Void)? { get set }
    func requestAuthorization() async throws
    func start(at date: Date, recordingID: UUID) async throws
    func pause()
    func resume()
    func addRoute(_ locations: [CLLocation])
    /// A reading from the member's Bluetooth strap, saved with the workout.
    func addHeartRate(_ sample: RecordedRun.HeartRateSample)
    /// Ends the session and saves the workout and its route to Health.
    /// Returns the builder's final totals and whether Health kept it all.
    func end(at date: Date) async throws -> RunWorkoutEnd
    func discard()
    /// Reattaches a session that survived the app being stopped, refilling the
    /// route from the checkpoint. Nil when no session is running.
    func recover(route: [CLLocation]) async -> RunWorkoutRecovery?
}

enum RunWorkoutEngineError: LocalizedError {
    case unavailable
    case notStarted

    var errorDescription: String? {
        switch self {
        case .unavailable: "Apple Health isn’t available on this iPhone."
        case .notStarted: "The workout didn’t start."
        }
    }
}

/// iPhone workout sessions arrived in iOS 26 (WWDC25 "Track workouts with
/// HealthKit on iOS and iPadOS"). Distance is the builder's, Apple's own
/// fusion of GPS and motion, never summed GPS points.
@available(iOS 26.0, *)
@MainActor
final class HealthRunWorkoutEngine: NSObject, RunWorkoutEngine {
    var onMetrics: ((RunWorkoutMetrics) -> Void)?
    var onFailure: ((String) -> Void)?

    private let store = HKHealthStore()
    private var session: HKWorkoutSession?
    private var builder: HKLiveWorkoutBuilder?
    private var routeBuilder: HKWorkoutRouteBuilder?
    private var stopped: CheckedContinuation<Void, Never>?
    private var ending = false
    /// Strap readings not yet added to the builder.
    private var heartRates: [HKQuantitySample] = []
    /// Whether this session sent Health route points or strap readings, and
    /// whether Health refused any readings. Ending reports a save as complete
    /// only when Health kept what was sent.
    private var sentRoute = false
    private var sentHeartRate = false
    private var heartRateRefused = false

    /// Strap readings go to the builder in batches.
    private static let heartRateBatch = 10

    private static var configuration: HKWorkoutConfiguration {
        let configuration = HKWorkoutConfiguration()
        configuration.activityType = .running
        configuration.locationType = .outdoor
        return configuration
    }

    func requestAuthorization() async throws {
        guard HKHealthStore.isHealthDataAvailable() else { throw RunWorkoutEngineError.unavailable }
        try await store.requestAuthorization(
            toShare: [HKObjectType.workoutType(), HKSeriesType.workoutRoute(), HKQuantityType(.heartRate)],
            read: [HKQuantityType(.distanceWalkingRunning), HKQuantityType(.heartRate),
                   HKQuantityType(.activeEnergyBurned)])
    }

    func start(at date: Date, recordingID: UUID) async throws {
        let configuration = Self.configuration
        let session = try HKWorkoutSession(healthStore: store, configuration: configuration)
        let builder = session.associatedWorkoutBuilder()
        attach(session: session, builder: builder, configuration: configuration)
        routeBuilder = HKWorkoutRouteBuilder(healthStore: store, device: nil)
        session.prepare()
        session.startActivity(with: date)
        try await builder.beginCollection(at: date)
        try await builder.addMetadata([
            HKMetadataKeyExternalUUID: RunRecordingHealthTag.externalID(for: recordingID),
            HKMetadataKeyIndoorWorkout: false,
        ])
    }

    func pause() { session?.pause() }
    func resume() { session?.resume() }

    func addRoute(_ locations: [CLLocation]) {
        guard let routeBuilder, !locations.isEmpty else { return }
        sentRoute = true
        routeBuilder.insertRouteData(locations) { _, _ in }
    }

    func addHeartRate(_ sample: RecordedRun.HeartRateSample) {
        guard builder != nil else { return }
        sentHeartRate = true
        let bpm = HKUnit.count().unitDivided(by: .minute())
        heartRates.append(HKQuantitySample(
            type: HKQuantityType(.heartRate),
            quantity: HKQuantity(unit: bpm, doubleValue: sample.beatsPerMinute),
            start: sample.timestamp, end: sample.timestamp))
        if heartRates.count >= Self.heartRateBatch {
            builder?.add(takeHeartRates()) { [weak self] success, _ in
                guard !success else { return }
                Task { @MainActor in self?.heartRateRefused = true }
            }
        }
    }

    /// Without Health permission to save heart rate, the builder refuses
    /// these; the readings still go to intervals.icu with the route.
    private func takeHeartRates() -> [HKQuantitySample] {
        defer { heartRates = [] }
        return heartRates
    }

    func end(at date: Date) async throws -> RunWorkoutEnd {
        guard let session, let builder else { throw RunWorkoutEngineError.notStarted }
        ending = true
        if session.state != .stopped && session.state != .ended {
            await withCheckedContinuation { continuation in
                stopped = continuation
                session.stopActivity(with: date)
            }
        }
        // Whether or not Health saves the workout, the session ends here: the
        // recorder keeps the run and moves on either way.
        defer {
            session.end()
            clear()
        }
        if !heartRates.isEmpty {
            let samples = takeHeartRates()
            let added: Bool = await withCheckedContinuation { continuation in
                builder.add(samples) { success, _ in continuation.resume(returning: success) }
            }
            if !added { heartRateRefused = true }
        }
        do {
            try await builder.endCollection(at: date)
            let totals = Self.metrics(from: builder)
            let workout = try await builder.finishWorkout()
            // The route is saved separately, and a failure there leaves the
            // workout in Health without it.
            var routeSaved = !sentRoute
            if let workout, let routeBuilder, sentRoute {
                do {
                    _ = try await routeBuilder.finishRoute(with: workout, metadata: nil)
                    routeSaved = true
                } catch {}
            } else {
                routeBuilder?.discard()
            }
            // Without permission to save heart rate, Health drops the
            // strap's readings and keeps the workout.
            let heartRateSaved = !sentHeartRate || (!heartRateRefused
                && store.authorizationStatus(for: HKQuantityType(.heartRate)) == .sharingAuthorized)
            return RunWorkoutEnd(metrics: totals, savedAll: workout != nil && routeSaved && heartRateSaved)
        } catch {
            builder.discardWorkout()
            routeBuilder?.discard()
            throw error
        }
    }

    func discard() {
        builder?.discardWorkout()
        routeBuilder?.discard()
        ending = true
        session?.end()
        clear()
    }

    func recover(route: [CLLocation]) async -> RunWorkoutRecovery? {
        let recovered: HKWorkoutSession? = await withCheckedContinuation { continuation in
            store.recoverActiveWorkoutSession { session, _ in continuation.resume(returning: session) }
        }
        guard let recovered, recovered.state == .running || recovered.state == .paused else {
            return nil
        }
        let configuration = Self.configuration
        attach(session: recovered, builder: recovered.associatedWorkoutBuilder(), configuration: configuration)
        routeBuilder = HKWorkoutRouteBuilder(healthStore: store, device: nil)
        addRoute(route)
        return recovered.state == .paused ? .paused : .running
    }

    private func attach(session: HKWorkoutSession, builder: HKLiveWorkoutBuilder,
                        configuration: HKWorkoutConfiguration) {
        builder.dataSource = HKLiveWorkoutDataSource(healthStore: store, workoutConfiguration: configuration)
        session.delegate = self
        builder.delegate = self
        self.session = session
        self.builder = builder
        ending = false
        sentRoute = false
        sentHeartRate = false
        heartRateRefused = false
    }

    private func clear() {
        heartRates = []
        sentRoute = false
        sentHeartRate = false
        heartRateRefused = false
        session = nil
        builder = nil
        routeBuilder = nil
    }

    nonisolated private static func metrics(from builder: HKLiveWorkoutBuilder) -> RunWorkoutMetrics {
        let distance = builder.statistics(for: HKQuantityType(.distanceWalkingRunning))?
            .sumQuantity()?.doubleValue(for: .meter()) ?? 0
        var heartRate: RecordedRun.HeartRateSample?
        let bpm = HKUnit.count().unitDivided(by: .minute())
        if let stats = builder.statistics(for: HKQuantityType(.heartRate)),
           let quantity = stats.mostRecentQuantity(),
           let interval = stats.mostRecentQuantityDateInterval() {
            heartRate = .init(timestamp: interval.end, beatsPerMinute: quantity.doubleValue(for: bpm))
        }
        return RunWorkoutMetrics(distanceMeters: distance, movingSeconds: builder.elapsedTime, heartRate: heartRate)
    }
}

@available(iOS 26.0, *)
extension HealthRunWorkoutEngine: HKWorkoutSessionDelegate, HKLiveWorkoutBuilderDelegate {
    nonisolated func workoutSession(_ workoutSession: HKWorkoutSession, didChangeTo toState: HKWorkoutSessionState,
                                    from fromState: HKWorkoutSessionState, date: Date) {
        Task { @MainActor in
            if toState == .stopped, let stopped = self.stopped {
                self.stopped = nil
                stopped.resume()
            } else if toState == .ended, !self.ending {
                self.onFailure?("The workout ended unexpectedly. The run so far is saved on this iPhone.")
            }
        }
    }

    nonisolated func workoutSession(_ workoutSession: HKWorkoutSession, didFailWithError error: Error) {
        let message = error.localizedDescription
        Task { @MainActor in
            if let stopped = self.stopped {
                self.stopped = nil
                stopped.resume()
            }
            self.onFailure?("The workout stopped: \(message)")
        }
    }

    nonisolated func workoutBuilder(_ workoutBuilder: HKLiveWorkoutBuilder,
                                    didCollectDataOf collectedTypes: Set<HKSampleType>) {
        let metrics = Self.metrics(from: workoutBuilder)
        Task { @MainActor in self.onMetrics?(metrics) }
    }

    nonisolated func workoutBuilderDidCollectEvent(_ workoutBuilder: HKLiveWorkoutBuilder) {}
}

/// Marks a recording's Apple Health workout with the same external_id its
/// intervals.icu upload carries. The Health sync still pushes the summary;
/// the server retires that copy once the intervals.icu activity arrives.
enum RunRecordingHealthTag {
    static func externalID(for recordingID: UUID) -> String {
        "tresfort:recording:" + recordingID.uuidString.lowercased()
    }
}
