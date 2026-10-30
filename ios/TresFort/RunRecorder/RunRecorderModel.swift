import CoreLocation
import Foundation
import HealthKit
import UIKit

/// Records one outdoor run at a time (docs/plans/run-recorder P1(b)). The
/// workout engine saves it to Apple Health; the route, totals and heart rate
/// are checkpointed into `RunRecordingStore` every few seconds, so a crash or
/// a dead battery keeps the run, and a finished run uploads to intervals.icu
/// through `RunRecordingUploader` on finish, launch and foreground.
@MainActor
final class RunRecorderModel: ObservableObject {
    enum Phase: Equatable {
        case idle
        case starting
        case running
        case paused
        case ending
        case finished
        case failed(String)
    }

    enum UploadStatus: Equatable {
        case idle
        case uploading
        case uploaded
        /// The run stays on this iPhone and retries on the next launch or
        /// foreground.
        case waiting
    }

    @Published private(set) var phase: Phase = .idle
    @Published private(set) var run: RecordedRun?
    @Published private(set) var uploadStatus: UploadStatus = .idle
    /// Something the member should know about a kept run, such as Apple
    /// Health not saving the workout.
    @Published private(set) var note: String?
    @Published private(set) var latestHeartRate: RecordedRun.HeartRateSample?

    /// Seconds between checkpoints while route points arrive.
    static let checkpointInterval: TimeInterval = 10

    private let accountID: String?
    private let baseURL: URL?
    private let api: RecordingUploadAPI
    private let jwt: @MainActor () -> String?
    private let onUnauthorized: @MainActor () -> Void
    private let onUploaded: @MainActor () -> Void
    private let makeEngine: @MainActor () -> RunWorkoutEngine?
    private let makeLocation: @MainActor () -> RunLocationSource
    private let now: @MainActor () -> Date

    private var cachedStore: RunRecordingStore?
    private var engine: RunWorkoutEngine?
    private var location: RunLocationSource?
    private var lastCheckpoint: Date?
    private var builderMoving: Double = 0
    private var isUploading = false

    /// iPhone on iOS 26 or later with Health data, outside the App Store
    /// build until the device checks in P3 pass.
    static var isSupported: Bool {
#if APP_STORE_BUILD
        return false
#else
        guard #available(iOS 26.0, *) else { return false }
        return HKHealthStore.isHealthDataAvailable() && UIDevice.current.userInterfaceIdiom == .phone
#endif
    }

    init(accountID: String?,
         baseURL: URL? = nil,
         api: RecordingUploadAPI = APIClient(),
         jwt: @escaping @MainActor () -> String?,
         onUnauthorized: @escaping @MainActor () -> Void = {},
         onUploaded: @escaping @MainActor () -> Void = {},
         makeEngine: (@MainActor () -> RunWorkoutEngine?)? = nil,
         makeLocation: (@MainActor () -> RunLocationSource)? = nil,
         now: @escaping @MainActor () -> Date = Date.init) {
        self.accountID = accountID
        self.baseURL = baseURL
        self.api = api
        self.jwt = jwt
        self.onUnauthorized = onUnauthorized
        self.onUploaded = onUploaded
        self.makeEngine = makeEngine ?? {
            guard #available(iOS 26.0, *) else { return nil }
            return HealthRunWorkoutEngine()
        }
        self.makeLocation = makeLocation ?? { CoreLocationRunSource() }
        self.now = now
    }

    var isRecording: Bool { phase == .running || phase == .paused || phase == .ending }

    // MARK: - Storage

    private func store(creating: Bool) -> RunRecordingStore? {
        if let cachedStore { return cachedStore }
        guard let accountID else { return nil }
        if !creating, let directory = try? RunRecordingStore.accountDirectory(accountID: accountID, baseURL: baseURL),
           !FileManager.default.fileExists(atPath: directory.path) {
            return nil
        }
        cachedStore = try? RunRecordingStore(accountID: accountID, baseURL: baseURL)
        return cachedStore
    }

    private func checkpoint(force: Bool = false) {
        guard let run else { return }
        let time = now()
        if !force, let lastCheckpoint, time.timeIntervalSince(lastCheckpoint) < Self.checkpointInterval { return }
        guard let store = store(creating: true) else { return }
        do {
            try store.save(run)
            lastCheckpoint = time
        } catch {
            note = "This run couldn’t be saved on the iPhone. Keep the app open until you end it."
        }
    }

    // MARK: - Recording

    func start() async {
        guard phase == .idle || phase == .finished || isFailed else { return }
        phase = .starting
        note = nil
        uploadStatus = .idle
        latestHeartRate = nil
        builderMoving = 0
        guard store(creating: true) != nil else {
            return fail("Très Fort couldn’t save a run on this iPhone. Check its storage and try again.")
        }
        let location = makeLocation()
        switch await location.requestAccess() {
        case .granted: break
        case .denied:
            return fail("Allow location for Très Fort in Settings to record the route.")
        case .approximate:
            return fail("Turn on Precise Location for Très Fort in Settings to record the route.")
        }
        guard let engine = makeEngine() else {
            return fail("Recording a run needs iOS 26 or later on iPhone.")
        }
        do {
            try await engine.requestAuthorization()
        } catch {
            return fail("Allow Apple Health access to record a run. \(error.localizedDescription)")
        }
        let startedAt = now()
        var run = RecordedRun(startedAt: startedAt)
        run.name = "Run"
        do {
            try await engine.start(at: startedAt, recordingID: run.id)
        } catch {
            engine.discard()
            return fail("The workout didn’t start. \(error.localizedDescription)")
        }
        bind(engine: engine, location: location)
        self.run = run
        phase = .running
        checkpoint(force: true)
        location.start()
    }

    func pause() {
        guard phase == .running, var run else { return }
        run.pauses.append(.init(start: now(), end: nil))
        self.run = run
        phase = .paused
        engine?.pause()
        checkpoint(force: true)
    }

    func resume() {
        guard phase == .paused, var run else { return }
        run.closePause(at: now())
        self.run = run
        phase = .running
        engine?.resume()
        checkpoint(force: true)
    }

    /// Saves the run to Health, keeps it for upload and sends it.
    func end() async {
        guard phase == .running || phase == .paused, var run else { return }
        phase = .ending
        let endedAt = now()
        location?.stop()
        run.closePause(at: endedAt)
        self.run = run
        if let engine {
            do {
                apply(try await engine.end(at: endedAt))
            } catch {
                note = "Apple Health didn’t save this workout. The run still uploads to intervals.icu."
            }
        }
        guard var finished = self.run else { return }
        finished.endedAt = endedAt
        finished.movingSeconds = builderMoving > 0 ? builderMoving : finished.activeSeconds(at: endedAt)
        self.run = finished
        unbind()
        if finished.points.isEmpty && finished.distanceMeters < 1 {
            // Nothing a provider could analyze; don't leave an upload that
            // fails forever.
            try? store(creating: false)?.remove(id: finished.id)
            note = "No route was recorded, so there’s nothing to upload."
            phase = .finished
            return
        }
        checkpoint(force: true)
        phase = .finished
        await uploadPending()
    }

    /// Throws the run away: no Health workout, no upload.
    func discard() {
        guard let run, phase == .running || phase == .paused || isFailed else { return }
        location?.stop()
        engine?.discard()
        unbind()
        try? store(creating: false)?.remove(id: run.id)
        self.run = nil
        phase = .idle
    }

    /// Back to the start screen once a finished or failed run is dismissed.
    func reset() {
        guard !isRecording, phase != .starting else { return }
        run = nil
        note = nil
        latestHeartRate = nil
        phase = .idle
    }

    private var isFailed: Bool {
        if case .failed = phase { return true }
        return false
    }

    private func fail(_ message: String) {
        phase = .failed(message)
    }

    private func bind(engine: RunWorkoutEngine, location: RunLocationSource) {
        self.engine = engine
        self.location = location
        engine.onMetrics = { [weak self] in self?.apply($0) }
        engine.onFailure = { [weak self] in self?.engineFailed($0) }
        location.onLocations = { [weak self] in self?.handle($0) }
    }

    private func unbind() {
        engine?.onMetrics = nil
        engine?.onFailure = nil
        location?.onLocations = nil
        engine = nil
        location = nil
        lastCheckpoint = nil
    }

    /// The Health session died under the run. Keep what was recorded as a
    /// finished run so it still uploads.
    private func engineFailed(_ message: String) {
        guard phase == .running || phase == .paused, var run else { return }
        location?.stop()
        let endedAt = run.points.last?.timestamp ?? now()
        run.closePause(at: endedAt)
        run.endedAt = endedAt
        run.movingSeconds = builderMoving > 0 ? builderMoving : run.activeSeconds(at: endedAt)
        self.run = run
        unbind()
        checkpoint(force: true)
        note = message
        phase = .finished
        Task { await uploadPending() }
    }

    func apply(_ metrics: RunWorkoutMetrics) {
        guard var run else { return }
        if metrics.distanceMeters > 0 { run.distanceMeters = metrics.distanceMeters }
        if metrics.movingSeconds > 0 { builderMoving = metrics.movingSeconds }
        if let sample = metrics.heartRate, sample.beatsPerMinute > 0,
           run.heartRates.last.map({ sample.timestamp > $0.timestamp }) ?? true {
            run.heartRates.append(sample)
            latestHeartRate = sample
        }
        self.run = run
    }

    func handle(_ locations: [CLLocation]) {
        guard phase == .running, var run else { return }
        var accepted: [CLLocation] = []
        for location in locations {
            let point = RecordedRun.RoutePoint(location)
            guard RunLocationFilter.accepts(point, after: run.points.last, startedAt: run.startedAt) else {
                continue
            }
            run.points.append(point)
            accepted.append(location)
        }
        guard !accepted.isEmpty else { return }
        self.run = run
        engine?.addRoute(accepted)
        checkpoint()
    }

    // MARK: - Recovery and upload

    /// On launch: reattach a run whose Health session survived, or finish one
    /// that didn't from its last checkpoint. Then send anything waiting.
    /// Returns true when a run is recording again.
    @discardableResult
    func recover() async -> Bool {
        guard phase == .idle, let store = store(creating: false),
              let unfinished = try? store.unfinished() else {
            await uploadPending()
            return false
        }
        if let engine = makeEngine(),
           let state = await engine.recover(route: unfinished.points.map(Self.location(from:))) {
            let location = makeLocation()
            bind(engine: engine, location: location)
            var run = unfinished
            if state == .running { run.closePause(at: now()) }
            if state == .paused && !run.isPaused { run.pauses.append(.init(start: now(), end: nil)) }
            self.run = run
            phase = state == .paused ? .paused : .running
            checkpoint(force: true)
            location.start()
            return true
        }
        var finished = unfinished
        let endedAt = max(finished.points.last?.timestamp ?? finished.startedAt,
                          finished.pauses.last?.start ?? finished.startedAt)
        finished.closePause(at: endedAt)
        finished.endedAt = endedAt
        if finished.movingSeconds <= 0 { finished.movingSeconds = finished.activeSeconds(at: endedAt) }
        if finished.points.isEmpty && finished.distanceMeters < 1 {
            try? store.remove(id: finished.id)
        } else {
            try? store.save(finished)
        }
        await uploadPending()
        return false
    }

    func uploadPending() async {
        guard !isUploading, let store = store(creating: false),
              let pending = try? store.pendingUploads(), !pending.isEmpty else { return }
        guard let jwt = jwt() else {
            uploadStatus = .waiting
            return
        }
        isUploading = true
        uploadStatus = .uploading
        defer { isUploading = false }
        do {
            let summary = try await RunRecordingUploader.uploadPending(store: store, api: api, jwt: jwt)
            if summary.unauthorized { onUnauthorized() }
            if !summary.uploaded.isEmpty { onUploaded() }
            uploadStatus = summary.failed.isEmpty ? .uploaded : .waiting
        } catch {
            uploadStatus = .waiting
        }
    }

    private static func location(from point: RecordedRun.RoutePoint) -> CLLocation {
        CLLocation(
            coordinate: CLLocationCoordinate2D(latitude: point.latitude, longitude: point.longitude),
            altitude: point.altitude ?? 0,
            horizontalAccuracy: point.horizontalAccuracy,
            verticalAccuracy: point.altitude == nil ? -1 : 10,
            timestamp: point.timestamp)
    }
}
