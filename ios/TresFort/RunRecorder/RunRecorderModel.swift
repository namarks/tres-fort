import CoreLocation
import Foundation
import HealthKit
import UIKit

/// Records one outdoor run at a time (docs/plans/run-recorder P1(b)). The
/// workout engine saves it to Apple Health; the route, totals and heart rate
/// are checkpointed into `RunRecordingStore` every few seconds, so a crash or
/// a dead battery keeps the run, and a finished run uploads to Tres Fort,
/// which keeps it with its route and sends a copy to intervals.icu when the
/// account is connected (P5), through `RunRecordingUploader` on finish,
/// launch and foreground. A run started from a planned workout logs that
/// slot as done when saved (docs/plans/planned-runs P7). While it
/// records, a Live Activity mirrors it on the Lock Screen with pause, resume
/// and finish, and each mile or kilometer can be announced (P2). A Bluetooth
/// heart rate strap the member set up reconnects while the recorder is open
/// or a run records, and its readings join the run. After a saved run the
/// strap keeps feeding the summary live, and its readings one and two
/// minutes after the stop are kept as the run's heart rate recovery (P7).
/// The barometer records the run's climb, and the summary scores the run's
/// training load from the member's run thresholds (P7).
@MainActor
final class RunRecorderModel: ObservableObject {
    enum Phase: Equatable {
        case idle
        /// Looking for a run the app stopped in the middle of; nothing can
        /// start until it is reattached or finished.
        case recovering
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
        /// Tres Fort kept the run and intervals.icu has a copy.
        case uploaded
        /// Tres Fort kept the run; intervals.icu isn't connected.
        case keptInTresFort
        /// Tres Fort kept the run, but the intervals.icu copy failed. The
        /// file stays on this iPhone to retry it.
        case waitingForIntervals
        /// The run stays on this iPhone and retries on the next launch or
        /// foreground.
        case waiting
        /// An older Worker without intervals.icu: Apple Health has the run
        /// with its route, so nothing waits on this iPhone.
        case notConnected
    }

    @Published private(set) var phase: Phase = .idle
    @Published private(set) var run: RecordedRun?
    @Published private(set) var uploadStatus: UploadStatus = .idle
    /// Something the member should know about a kept run, such as Apple
    /// Health not saving the workout.
    @Published private(set) var note: String?
    @Published private(set) var latestHeartRate: RecordedRun.HeartRateSample?
    /// The cool-down after a saved run, while the strap stays connected:
    /// the heart rate at the stop and one and two minutes later (P7). Nil
    /// without a strap reading at the stop.
    @Published private(set) var recovery: HeartRateRecoveryMeasurement?
    /// The run whose cool-down is being measured; it uploads once that ends.
    @Published private(set) var measuringRecoveryOf: UUID?
    /// Horizontal accuracy of the latest GPS fix, in meters, while the
    /// recorder is open or recording.
    @Published private(set) var gpsAccuracy: CLLocationAccuracy?
    /// The plan slot the recorder was opened for, if any. It stays through
    /// the run and clears when the member closes the recorder.
    @Published var plannedRun: PlannedRun?
    /// The member's thresholds, kept on this iPhone so a run recorded
    /// offline still shows its load. Refreshed when the recorder opens.
    @Published private(set) var thresholds: [AthleteThreshold] = []
    /// The planned workout a saved run marked done, by name. Nil until then.
    @Published private(set) var completedWorkoutName: String?
    /// The steps the recording run follows, read from its checkpoint. Empty
    /// for a run without a plan.
    @Published private(set) var planSteps: [RunPlan.ExpandedStep] = []
    /// Per-device choices, kept between runs.
    @Published var unit: RunDistanceUnit {
        didSet {
            guard unit != oldValue else { return }
            defaults.set(unit.rawValue, forKey: Self.unitKey)
            if let run, isRecording {
                splits = RunSplitTracker(unit: unit, meters: run.distanceMeters,
                                         movingSeconds: run.activeSeconds(at: now()))
                refreshLiveActivity(force: true)
            }
        }
    }
    @Published var announcesSplits: Bool {
        didSet { defaults.set(announcesSplits, forKey: Self.announceKey) }
    }
    /// Pause when the runner stops and resume when they go again. On unless
    /// the member turns it off.
    @Published var autoPauses: Bool {
        didSet { defaults.set(autoPauses, forKey: Self.autoPauseKey) }
    }
    /// The large-number running layout instead of the map.
    @Published var showsGlance: Bool {
        didSet { defaults.set(showsGlance, forKey: Self.glanceKey) }
    }
    /// The numbers the running layout shows, top to bottom.
    @Published var glanceMetrics: [RunMetric] {
        didSet { defaults.set(glanceMetrics.map(\.rawValue), forKey: Self.glanceMetricsKey) }
    }
    let heartRateMonitor: HeartRateMonitor

    static let unitKey = RunDistanceUnit.preferenceKey
    static let announceKey = "runRecorder.announceSplits"
    static let autoPauseKey = "runRecorder.autoPause"
    static let glanceKey = "runRecorder.glance"
    static let glanceMetricsKey = "runRecorder.glanceMetrics"

    /// Seconds between checkpoints while route points arrive.
    static let checkpointInterval: TimeInterval = 10
    /// Seconds between Live Activity updates for distance and pace; the
    /// clock runs on its own, and pause and resume update at once.
    static let liveActivityInterval: TimeInterval = 5
    /// A fix this precise means GPS has locked on and the run can start.
    static let gpsReadyAccuracy: CLLocationAccuracy = 20
    /// Auto-pause: slower than walking pace (about 2.9 km/h) for this long
    /// pauses, and faster than an easy walk for this long resumes.
    static let autoPauseSpeed: CLLocationSpeed = 0.8
    static let autoPauseDelay: TimeInterval = 5
    static let autoResumeSpeed: CLLocationSpeed = 1.4
    static let autoResumeDelay: TimeInterval = 2
    /// A run shorter than either of these has nothing worth analyzing, so it
    /// isn't saved or uploaded.
    static let minimumSeconds: TimeInterval = 60
    static let minimumMeters: Double = 100

    private let accountID: String?
    private let baseURL: URL?
    private let api: RecordingUploadAPI
    private let jwt: @MainActor () -> String?
    private let onUnauthorized: @MainActor () -> Void
    private let onUploaded: @MainActor () -> Void
    /// Logs a saved planned run against its slot (slot id, run date, moving
    /// seconds); true when the plan recorded it.
    private let onPlannedRunSaved: @MainActor (String, String, Int) async -> Bool
    private let makeEngine: @MainActor () -> RunWorkoutEngine?
    private let makeLocation: @MainActor () -> RunLocationSource
    private let makeAltimeter: @MainActor () -> RunAltimeter
    private let loadThresholds: @MainActor (String) async throws -> [AthleteThreshold]
    private let now: @MainActor () -> Date
    private let defaults: UserDefaults
    private let liveActivity: RunLiveActivityPresenting
    private let makeSpeaker: @MainActor () -> RunSplitSpeaking

    private var cachedStore: RunRecordingStore?
    private var engine: RunWorkoutEngine?
    private var location: RunLocationSource?
    private var altimeter: RunAltimeter?
    /// Added to this altimeter session's readings so they carry on from the
    /// run's last kept reading, also after the app was stopped mid-run.
    private var altitudeBase: Double?
    /// GPS started when the recorder opened, handed to the run on start.
    private var warmLocation: RunLocationSource?
    private var lastCheckpoint: Date?
    private var builderMoving: Double = 0
    private var isUploading = false
    /// A run's cool-down ended while an upload ran, so another pass sends it.
    private var uploadAgain = false
    private var splits: RunSplitTracker?
    private var speaker: RunSplitSpeaking?
    private var lastActivityUpdate: Date?
    /// The recorder screen is showing.
    private var isOpen = false
    /// When GPS speed first fell below, or rose above, the auto-pause speeds.
    private var slowSince: Date?
    private var fastSince: Date?
    /// The latest fix auto-pause considered, so a late or repeated fix
    /// can't count twice.
    private var lastSpeedFix: Date?
    /// Moves the plan on once a second, so a timed step ends on time even
    /// when no new distance or heart rate arrives.
    private var planTicker: Task<Void, Never>?
    /// The progress before each step the plan ended on its own since the
    /// last skip, so a pause dated back to a GPS fix can undo a step that
    /// only ended because of the time the pause removes.
    private var planHistory: [RunPlanProgress] = []
    /// Decides when to say the run is off or back on the step's target.
    private var targetCoach = RunTargetCoach()
    /// Heart rate cues use the average over this many seconds.
    static let heartRateWindow: TimeInterval = 15
    /// After the run, the strap's reading shows live for this long.
    static let liveHeartRateWindow: TimeInterval = 5 * 60
    /// A reading older than this isn't live any more.
    static let heartRateFreshness: TimeInterval = 15
    /// Settles the cool-down's marks once a second, for a strap that goes
    /// quiet or drops.
    private var recoveryTicker: Task<Void, Never>?

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
         onPlannedRunSaved: @escaping @MainActor (String, String, Int) async -> Bool = { _, _, _ in false },
         makeEngine: (@MainActor () -> RunWorkoutEngine?)? = nil,
         makeLocation: (@MainActor () -> RunLocationSource)? = nil,
         makeAltimeter: (@MainActor () -> RunAltimeter)? = nil,
         loadThresholds: (@MainActor (String) async throws -> [AthleteThreshold])? = nil,
         now: @escaping @MainActor () -> Date = Date.init,
         defaults: UserDefaults = .standard,
         liveActivity: RunLiveActivityPresenting? = nil,
         makeSpeaker: (@MainActor () -> RunSplitSpeaking)? = nil,
         heartRateMonitor: HeartRateMonitor? = nil) {
        self.accountID = accountID
        self.baseURL = baseURL
        self.api = api
        self.jwt = jwt
        self.onUnauthorized = onUnauthorized
        self.onUploaded = onUploaded
        self.onPlannedRunSaved = onPlannedRunSaved
        self.makeEngine = makeEngine ?? {
            guard #available(iOS 26.0, *) else { return nil }
            return HealthRunWorkoutEngine()
        }
        self.makeLocation = makeLocation ?? { CoreLocationRunSource() }
        self.makeAltimeter = makeAltimeter ?? { BarometerRunAltimeter() }
        self.loadThresholds = loadThresholds ?? { token in try await APIClient().athleteThresholds(jwt: token) }
        self.now = now
        self.defaults = defaults
        self.liveActivity = liveActivity ?? SystemRunLiveActivity()
        self.makeSpeaker = makeSpeaker ?? { SystemRunSplitSpeaker() }
        self.heartRateMonitor = heartRateMonitor ?? HeartRateMonitor(defaults: defaults, now: now)
        unit = defaults.string(forKey: RunRecorderModel.unitKey).flatMap(RunDistanceUnit.init(rawValue:)) ?? .miles
        announcesSplits = defaults.bool(forKey: RunRecorderModel.announceKey)
        autoPauses = defaults.object(forKey: RunRecorderModel.autoPauseKey) as? Bool ?? true
        showsGlance = defaults.bool(forKey: RunRecorderModel.glanceKey)
        let metrics = (defaults.stringArray(forKey: RunRecorderModel.glanceMetricsKey) ?? [])
            .compactMap(RunMetric.init(rawValue:))
        glanceMetrics = metrics.isEmpty ? RunMetric.glanceDefault : metrics
        if let key = thresholdsCacheKey, let data = defaults.data(forKey: key),
           let cached = try? JSONDecoder().decode([AthleteThreshold].self, from: data) {
            thresholds = cached
        }
    }

    var isRecording: Bool { phase == .running || phase == .paused || phase == .ending }

    var gpsReady: Bool { (gpsAccuracy ?? .infinity) <= Self.gpsReadyAccuracy }

    /// The current pause was started by auto-pause, so moving again resumes
    /// it. Kept in the checkpoint, so a recovered run still resumes.
    var isAutoPaused: Bool { phase == .paused && run?.pauses.last?.automatic == true }

    /// Ending now would save nothing: under a minute or 100 m.
    var isTooShortToSave: Bool {
        guard let run else { return true }
        return run.activeSeconds(at: now()) < Self.minimumSeconds || run.distanceMeters < Self.minimumMeters
    }

    // MARK: - Opening and closing

    /// The recorder opened: reconnect the heart rate strap. GPS warms up from
    /// the view, whenever the start screen shows.
    func opened() {
        isOpen = true
        heartRateMonitor.connectSaved()
        Task { await refreshThresholds() }
    }

    // MARK: - Training load

    /// Erased with the account (`AccountLocalState.clear`).
    private var thresholdsCacheKey: String? { accountID.map { AccountLocalState.runThresholdsKey(userID: $0) } }

    /// Reads the member's thresholds and keeps them for the next run. A
    /// failure keeps the ones from before.
    func refreshThresholds() async {
        guard let token = jwt(), let rows = try? await loadThresholds(token) else { return }
        thresholds = rows
        if let key = thresholdsCacheKey, let data = try? JSONEncoder().encode(rows) {
            defaults.set(data, forKey: key)
        }
    }

    /// The saved run's training load, scored as Tres Fort scores it from
    /// the run thresholds in effect on its date. Nil before the run is saved
    /// and when there is nothing to score it against.
    var load: RunLoad.Result? {
        guard phase == .finished, let run, run.isFinished else { return nil }
        let heartRate = AthleteThresholdHistory.inEffect(thresholds, sport: .run, metric: .heartRate, on: run.date)
        let pace = AthleteThresholdHistory.inEffect(thresholds, sport: .run, metric: .pace, on: run.date)
        return RunLoad.estimate(run, movingSeconds: run.movingSeconds,
                                thresholdHeartRate: heartRate?.value, thresholdPacePerKm: pace?.value)
    }

    /// Whether the member set a run threshold heart rate or pace at all.
    var hasRunThresholds: Bool {
        thresholds.contains { $0.sport == ThresholdSport.run.rawValue
            && ($0.metric == ThresholdMetric.heartRate.rawValue || $0.metric == ThresholdMetric.pace.rawValue) }
    }

    /// The recorder closed. A run that records keeps its GPS and strap.
    func closed() {
        isOpen = false
        finishRecovery()
        coolDownGPS()
        if !isRecording && phase != .starting && phase != .recovering { heartRateMonitor.release() }
    }

    // MARK: - GPS before the start

    /// Asks for location when the recorder opens and starts GPS, so the first
    /// fix (often 10 to 30 seconds outdoors) arrives before the run starts.
    /// A refusal is left for Start to explain.
    func warmUpGPS() async {
        guard phase == .idle || isFailed, warmLocation == nil, location == nil else { return }
        let source = makeLocation()
        guard await source.requestAccess() == .granted,
              phase == .idle || isFailed, warmLocation == nil, location == nil else { return }
        source.onLocations = { [weak self] in self?.handle($0) }
        source.warmUp()
        warmLocation = source
    }

    /// The recorder closed without starting a run.
    func coolDownGPS() {
        guard let warmLocation, location == nil, phase != .starting else { return }
        warmLocation.stop()
        warmLocation.onLocations = nil
        self.warmLocation = nil
        gpsAccuracy = nil
    }

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
        finishRecovery()
        recovery = nil
        // An unfinished run comes first, even before launch recovery got to it.
        if (try? store(creating: false)?.unfinished()) != nil {
            phase = .idle
            if await recover() { return }
            guard phase == .idle else { return }
        }
        phase = .starting
        note = nil
        uploadStatus = .idle
        completedWorkoutName = nil
        latestHeartRate = nil
        builderMoving = 0
        guard store(creating: true) != nil else {
            return fail("Très Fort couldn’t save a run on this iPhone. Check its storage and try again.")
        }
        let location = warmLocation ?? makeLocation()
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
        let altimeter = makeAltimeter()
        await altimeter.requestAccess()
        let startedAt = now()
        var run = RecordedRun(startedAt: startedAt)
        // The uploaded run carries the planned workout's name.
        run.name = plannedRun?.workoutName ?? "Run"
        run.plannedSlotID = plannedRun?.id
        if let steps = plannedRun?.runSteps, RunPlan(json: steps) != nil {
            run.plan = RunPlanFollowing(runSteps: steps)
        }
        do {
            try await engine.start(at: startedAt, recordingID: run.id)
        } catch {
            engine.discard()
            return fail("The workout didn’t start. \(error.localizedDescription)")
        }
        self.run = run
        bind(engine: engine, location: location, altimeter: altimeter)
        follow(run)
        splits = RunSplitTracker(unit: unit)
        phase = .running
        checkpoint(force: true)
        refreshLiveActivity(force: true)
        location.start()
        announceStep()
    }

    /// A pause the member asked for stays paused until they resume.
    func pause() { pause(auto: false) }

    /// An automatic pause starts at the fix that triggered it, which can
    /// arrive a few seconds later in a batch.
    private func pause(auto: Bool, at fixTime: Date? = nil) {
        guard phase == .running, var run else { return }
        let time = now()
        let floor = max(run.startedAt, run.pauses.last?.end ?? run.startedAt)
        let start = fixTime.map { min(max($0, floor), time) } ?? time
        run.pauses.append(.init(start: start, end: nil, automatic: auto ? true : nil))
        self.run = run
        phase = .paused
        slowSince = nil
        fastSince = nil
        if start < time { reconcilePlan() }
        engine?.pause()
        checkpoint(force: true)
        refreshLiveActivity(force: true)
        if auto { speak("Run paused.") }
    }

    func resume() { resume(at: nil) }

    /// An automatic resume ends the pause at the fix that triggered it, so
    /// the fixes kept after it count as moving.
    private func resume(at fixTime: Date?) {
        guard phase == .paused, var run else { return }
        let wasAuto = isAutoPaused
        let time = now()
        let floor = run.pauses.last?.start ?? run.startedAt
        run.closePause(at: fixTime.map { min(max($0, floor), time) } ?? time)
        self.run = run
        phase = .running
        slowSince = nil
        fastSince = nil
        engine?.resume()
        checkpoint(force: true)
        refreshLiveActivity(force: true)
        if wasAuto { speak("Run resumed.") }
    }

    private enum AutoPause { case pause, resume }

    /// Watches GPS speed while recording, one fix at a time. Only a fix the
    /// route would accept counts: precise enough, from this run, newer than
    /// the last, and carrying a speed.
    private func autoPause(after location: CLLocation) -> AutoPause? {
        let time = location.timestamp
        guard autoPauses, location.speed >= 0, let run,
              location.horizontalAccuracy >= 0,
              location.horizontalAccuracy <= RunLocationFilter.maximumHorizontalAccuracy,
              time >= run.startedAt, lastSpeedFix.map({ time > $0 }) ?? true else { return nil }
        lastSpeedFix = time
        if phase == .running {
            slowSince = location.speed < Self.autoPauseSpeed ? slowSince ?? time : nil
            if let slowSince, time.timeIntervalSince(slowSince) >= Self.autoPauseDelay { return .pause }
        } else if isAutoPaused {
            fastSince = location.speed > Self.autoResumeSpeed ? fastSince ?? time : nil
            if let fastSince, time.timeIntervalSince(fastSince) >= Self.autoResumeDelay { return .resume }
        }
        return nil
    }

    /// Saves the run to Health, keeps it for upload and sends it.
    func end() async {
        guard phase == .running || phase == .paused, var run else { return }
        if isTooShortToSave {
            // Nothing a provider could analyze; don't save a Health workout
            // or leave an upload.
            location?.stop()
            engine?.discard()
            unbind()
            liveActivity.endAll()
            try? store(creating: false)?.remove(id: run.id)
            note = "Runs under a minute or 100 m aren’t saved."
            phase = .finished
            return
        }
        phase = .ending
        let endedAt = now()
        location?.stop()
        run.closePause(at: endedAt)
        self.run = run
        var savedToHealth = false
        if let engine {
            if let climb = RunAltitude.climb(run) { engine.setElevationAscended(climb) }
            do {
                let ended = try await engine.end(at: endedAt)
                apply(ended.metrics)
                savedToHealth = ended.savedAll
                if !ended.savedAll {
                    note = "Apple Health didn’t keep the whole run. It stays on this iPhone until it uploads."
                }
            } catch {
                note = "Apple Health didn’t save this workout. The run stays on this iPhone until it uploads."
            }
        }
        guard var finished = self.run else { return }
        finished.endedAt = endedAt
        finished.savedToHealth = savedToHealth
        finished.movingSeconds = builderMoving > 0 ? builderMoving : finished.activeSeconds(at: endedAt)
        self.run = finished
        unbind()
        liveActivity.endAll()
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
        beginRecovery(finished)
        // The checkpoint carries the slot, so a run recovered after the app
        // was stopped still marks its workout done.
        if let slotID = finished.plannedSlotID,
           await onPlannedRunSaved(slotID, finished.date, Int(finished.movingSeconds.rounded())) {
            completedWorkoutName = finished.name ?? plannedRun?.workoutName
        }
        // A run whose cool-down is measured uploads when that ends.
        if measuringRecoveryOf != finished.id { await uploadPending() }
    }

    // MARK: - After the run

    var isMeasuringRecovery: Bool { measuringRecoveryOf != nil }

    /// The strap's reading while it streams after a saved run: until Done,
    /// the strap drops or five minutes pass. Nil otherwise, when the summary
    /// falls back to the run's own heart rate.
    func liveHeartRate(at date: Date) -> Double? {
        guard phase == .finished, let endedAt = run?.endedAt,
              date.timeIntervalSince(endedAt) < Self.liveHeartRateWindow,
              heartRateMonitor.isConnected, let sample = heartRateMonitor.latest,
              date.timeIntervalSince(sample.timestamp) < Self.heartRateFreshness else { return nil }
        return sample.beatsPerMinute
    }

    /// Starts the cool-down when the strap is still connected and read the
    /// heart rate at the stop. Its readings never join the run.
    private func beginRecovery(_ run: RecordedRun) {
        guard heartRateMonitor.isConnected, let endedAt = run.endedAt,
              let measurement = HeartRateRecoveryMeasurement(run: run, stoppedAt: endedAt) else { return }
        recovery = measurement
        measuringRecoveryOf = run.id
        heartRateMonitor.onSample = { [weak self] in self?.recordRecovery($0) }
        recoveryTicker = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(1))
                guard !Task.isCancelled, let self else { return }
                self.tickRecovery()
            }
        }
    }

    /// A strap reading during the cool-down.
    func recordRecovery(_ sample: RecordedRun.HeartRateSample) {
        guard isMeasuringRecovery, var measurement = recovery else { return }
        measurement.add(sample)
        recovery = measurement
        if measurement.isComplete { finishRecovery() }
    }

    /// Ends the cool-down when the strap dropped, and settles marks the
    /// clock passed without a reading.
    func tickRecovery() {
        guard isMeasuringRecovery, var measurement = recovery else { return }
        guard heartRateMonitor.isConnected else { return finishRecovery() }
        measurement.expire(at: now())
        recovery = measurement
        if measurement.isComplete { finishRecovery() }
    }

    /// Keeps what the cool-down measured with the run and sends it. Done,
    /// closing the recorder or the strap dropping ends it early with what
    /// it has.
    private func finishRecovery() {
        guard let id = measuringRecoveryOf else { return }
        measuringRecoveryOf = nil
        recoveryTicker?.cancel()
        recoveryTicker = nil
        heartRateMonitor.onSample = nil
        if let result = recovery?.result, var run, run.id == id {
            run.recovery = result
            self.run = run
            checkpoint(force: true)
        }
        if isUploading {
            uploadAgain = true
        } else {
            Task { await self.uploadPending() }
        }
    }

    /// Throws the run away: no Health workout, no upload.
    func discard() {
        guard let run, phase == .running || phase == .paused || isFailed else { return }
        location?.stop()
        engine?.discard()
        unbind()
        liveActivity.endAll()
        try? store(creating: false)?.remove(id: run.id)
        self.run = nil
        planSteps = []
        phase = .idle
    }

    /// Back to the start screen once a finished or failed run is dismissed.
    func reset() {
        guard !isRecording, phase != .starting, phase != .recovering else { return }
        finishRecovery()
        recovery = nil
        run = nil
        note = nil
        latestHeartRate = nil
        plannedRun = nil
        completedWorkoutName = nil
        planSteps = []
        phase = .idle
    }

    private var isFailed: Bool {
        if case .failed = phase { return true }
        return false
    }

    private func fail(_ message: String) {
        phase = .failed(message)
    }

    private func bind(engine: RunWorkoutEngine, location: RunLocationSource, altimeter: RunAltimeter) {
        self.engine = engine
        self.location = location
        self.altimeter = altimeter
        altitudeBase = nil
        warmLocation = nil
        engine.onMetrics = { [weak self] in self?.apply($0) }
        engine.onFailure = { [weak self] in self?.engineFailed($0) }
        location.onLocations = { [weak self] in self?.handle($0) }
        heartRateMonitor.onSample = { [weak self] in self?.record($0) }
        heartRateMonitor.connectSaved()
        altimeter.onAltitude = { [weak self] in self?.recordAltitude($0) }
        altimeter.start()
        RunRecorderControl.handler = { [weak self] id, action in
            await self?.control(recordingID: id, action: action) ?? false
        }
    }

    private func unbind() {
        engine?.onMetrics = nil
        engine?.onFailure = nil
        location?.onLocations = nil
        heartRateMonitor.onSample = nil
        altimeter?.stop()
        altimeter?.onAltitude = nil
        altimeter = nil
        altitudeBase = nil
        // A run recovered or finished from the Lock Screen, with the
        // recorder closed, lets the strap go.
        if !isOpen { heartRateMonitor.release() }
        engine = nil
        location = nil
        lastCheckpoint = nil
        lastActivityUpdate = nil
        gpsAccuracy = nil
        slowSince = nil
        fastSince = nil
        lastSpeedFix = nil
        splits = nil
        planTicker?.cancel()
        planTicker = nil
        planHistory = []
        RunRecorderControl.handler = nil
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
        run.savedToHealth = false
        self.run = run
        unbind()
        liveActivity.endAll()
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
        if phase == .running {
            announceSplitIfDue()
            advancePlan()
        }
        refreshLiveActivity()
    }

    /// A reading from the Bluetooth strap. The builder hands the same reading
    /// back later; the timestamp check keeps it from counting twice.
    func record(_ sample: RecordedRun.HeartRateSample) {
        guard phase == .running || phase == .paused, var run, sample.beatsPerMinute > 0,
              run.heartRates.last.map({ sample.timestamp > $0.timestamp }) ?? true else { return }
        run.heartRates.append(sample)
        latestHeartRate = sample
        self.run = run
        engine?.addHeartRate(sample)
    }

    /// A barometer reading. Readings while paused are kept, and the climb
    /// leaves them out, as the uploaded track leaves out paused GPS fixes.
    func recordAltitude(_ sample: RecordedRun.AltitudeSample) {
        guard phase == .running || phase == .paused, var run, sample.meters.isFinite,
              sample.timestamp >= run.startedAt else { return }
        var altitudes = run.altitudes ?? []
        guard altitudes.last.map({ sample.timestamp > $0.timestamp }) ?? true else { return }
        let base = altitudeBase ?? (altitudes.last?.meters ?? 0) - sample.meters
        altitudeBase = base
        altitudes.append(.init(timestamp: sample.timestamp, meters: sample.meters + base))
        run.altitudes = altitudes
        self.run = run
    }

    func handle(_ locations: [CLLocation]) {
        if let last = locations.last {
            gpsAccuracy = last.horizontalAccuracy >= 0 ? last.horizontalAccuracy : nil
        }
        guard phase == .running || phase == .paused else { return }
        // In order, so a pause or resume part-way through a batch keeps the
        // fixes run before it and drops only those taken while paused.
        var running: [CLLocation] = []
        for location in locations {
            if phase == .running { running.append(location) }
            guard let change = autoPause(after: location) else { continue }
            addRoute(running)
            running = []
            switch change {
            case .pause: pause(auto: true, at: location.timestamp)
            case .resume: resume(at: location.timestamp)
            }
        }
        addRoute(running)
    }

    private func addRoute(_ locations: [CLLocation]) {
        guard !locations.isEmpty, var run else { return }
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
        advancePlan()
        checkpoint()
        refreshLiveActivity()
    }

    // MARK: - Following a planned run

    /// Reads the steps a run follows and starts moving through them.
    private func follow(_ run: RecordedRun) {
        planSteps = run.plan.flatMap { RunPlan(json: $0.runSteps) }?.expandedSteps ?? []
        planHistory = []
        targetCoach = RunTargetCoach()
        planTicker?.cancel()
        planTicker = nil
        guard !planSteps.isEmpty else { return }
        planTicker = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(1))
                guard !Task.isCancelled else { return }
                self?.advancePlan()
            }
        }
    }

    /// The step the run is on, and the progress through it. Nil without a
    /// plan or once the plan is done.
    var currentPlanStep: RunPlan.ExpandedStep? {
        guard let index = run?.plan?.progress.stepIndex, planSteps.indices.contains(index) else { return nil }
        return planSteps[index]
    }

    /// Ends every step the run has finished, by moving time or distance.
    func advancePlan() {
        guard phase == .running, var run, var following = run.plan, !planSteps.isEmpty else { return }
        let before = following.progress
        let stepEnded = following.progress.advance(planSteps, movingSeconds: run.activeSeconds(at: now()),
                                                   meters: run.distanceMeters)
        if following.progress != before {
            run.plan = following
            self.run = run
        }
        if stepEnded {
            planHistory.append(before)
            if planHistory.count > 50 { planHistory.removeFirst() }
            checkpoint(force: true)
            announceStep()
        } else {
            coachTarget()
        }
    }

    /// Says the step the run is now on, or that the plan is done, and starts
    /// watching the new step's target.
    private func announceStep() {
        guard let run, let progress = run.plan?.progress, !planSteps.isEmpty else { return }
        targetCoach.startStep(at: run.activeSeconds(at: now()))
        if let step = currentPlanStep {
            speak(RunPlanFormat.spoken(step, index: progress.stepIndex, count: planSteps.count, unit: unit))
        } else {
            speak("Plan complete. Keep going or end the run.")
        }
    }

    /// Speaks when pace or heart rate leaves the step's target or comes back.
    private func coachTarget() {
        guard phase == .running, let run, let progress = run.plan?.progress,
              let target = currentPlanStep?.step.target else { return }
        let time = now()
        let moving = run.activeSeconds(at: time)
        let value: Double?
        switch target {
        case .pace:
            value = RunPace.fresh(run, at: time, unit: .kilometers)
        case .heartRate:
            let recent = run.heartRates.filter { time.timeIntervalSince($0.timestamp) <= Self.heartRateWindow }
            value = recent.isEmpty ? nil : recent.map(\.beatsPerMinute).reduce(0, +) / Double(recent.count)
        }
        if let cue = targetCoach.update(target: target, value: value,
                                        stepSeconds: moving - progress.stepStartSeconds, movingSeconds: moving) {
            speak(cue)
        }
    }

    /// The member moves on to the next step before this one is done.
    func skipPlanStep() {
        guard phase == .running || phase == .paused, var run, var following = run.plan,
              !following.progress.isComplete(planSteps) else { return }
        following.progress.skip(planSteps, movingSeconds: run.activeSeconds(at: now()), meters: run.distanceMeters)
        run.plan = following
        self.run = run
        // A skip is the member's choice; a later pause never undoes it.
        planHistory = []
        checkpoint(force: true)
        announceStep()
    }

    /// A pause dated back to the fix that triggered it removes moving time
    /// the plan may already have counted. Undo any step that started after
    /// the run's corrected moving time; the run's next update ends it again
    /// if its distance was really done.
    private func reconcilePlan() {
        guard var run, var following = run.plan else { return }
        let moving = run.activeSeconds(at: now())
        var progress = following.progress
        while progress.stepStartSeconds > moving, let previous = planHistory.popLast() {
            progress = previous
        }
        if let last = progress.lastSeconds, last > moving { progress.lastSeconds = moving }
        guard progress != following.progress else { return }
        let stepUndone = progress.stepIndex != following.progress.stepIndex
        following.progress = progress
        run.plan = following
        self.run = run
        if stepUndone { targetCoach.startStep(at: moving) }
    }

    // MARK: - Lock Screen and splits

    /// What the Live Activity shows now: the clock start shifted by every
    /// pause, or the frozen time while paused.
    func liveActivityState() -> RunActivityAttributes.ContentState? {
        guard let run else { return nil }
        let time = now()
        let moving = run.activeSeconds(at: time)
        return .init(clockStart: time.addingTimeInterval(-moving),
                     pausedSeconds: phase == .paused ? moving : nil,
                     meters: run.distanceMeters,
                     currentPace: RunPace.current(run, unit: unit),
                     unit: unit)
    }

    private func refreshLiveActivity(force: Bool = false) {
        guard phase == .running || phase == .paused, let run, let state = liveActivityState() else { return }
        let time = now()
        if !force, let lastActivityUpdate,
           time.timeIntervalSince(lastActivityUpdate) < Self.liveActivityInterval { return }
        lastActivityUpdate = time
        liveActivity.show(recordingID: run.uploadID, state: state)
    }

    /// Keeps counting splits while announcements are off, so turning them on
    /// mid-run speaks only the next one.
    private func announceSplitIfDue() {
        guard let run, var tracker = splits else { return }
        let split = tracker.update(meters: run.distanceMeters, movingSeconds: run.activeSeconds(at: now()))
        splits = tracker
        guard let split else { return }
        speak(split.spokenText)
    }

    /// Spoken only while announcements are on.
    private func speak(_ text: String) {
        guard announcesSplits else { return }
        if speaker == nil { speaker = makeSpeaker() }
        speaker?.speak(text)
    }

    /// A Live Activity button. Only the run being recorded answers; a
    /// repeated tap that already happened counts as done.
    func control(recordingID: String, action: String) async -> Bool {
        guard let run, run.uploadID == recordingID,
              let action = RunRecorderControlIntent.Action(rawValue: action) else { return false }
        switch action {
        case .pause:
            if phase == .running { pause() }
            return phase == .paused
        case .resume:
            if phase == .paused { resume() }
            return phase == .running
        case .finish:
            if phase == .running || phase == .paused { await end() }
            return phase == .finished
        }
    }

    // MARK: - Recovery and upload

    /// On launch: reattach a run whose Health session survived, or finish one
    /// that didn't from its last checkpoint. Then send anything waiting.
    /// Returns true when a run is recording again.
    @discardableResult
    func recover() async -> Bool {
        guard phase == .idle else {
            await uploadPending()
            return false
        }
        guard let store = store(creating: false), let unfinished = try? store.unfinished() else {
            // Nothing is recording, so any run activity is left over.
            liveActivity.endAll()
            await uploadPending()
            return false
        }
        phase = .recovering
        if let engine = makeEngine(),
           let state = await engine.recover(route: unfinished.points.map(Self.location(from:))) {
            let location = warmLocation ?? makeLocation()
            var run = unfinished
            if state == .running { run.closePause(at: now()) }
            if state == .paused && !run.isPaused { run.pauses.append(.init(start: now(), end: nil)) }
            self.run = run
            bind(engine: engine, location: location, altimeter: makeAltimeter())
            follow(run)
            splits = RunSplitTracker(unit: unit, meters: run.distanceMeters,
                                     movingSeconds: run.activeSeconds(at: now()))
            phase = state == .paused ? .paused : .running
            checkpoint(force: true)
            refreshLiveActivity(force: true)
            location.start()
            return true
        }
        liveActivity.endAll()
        var finished = unfinished
        let endedAt = max(finished.points.last?.timestamp ?? finished.startedAt,
                          finished.pauses.last?.start ?? finished.startedAt)
        finished.closePause(at: endedAt)
        finished.endedAt = endedAt
        if finished.movingSeconds <= 0 { finished.movingSeconds = finished.activeSeconds(at: endedAt) }
        // Its Health session didn't survive, so this iPhone holds the only copy.
        finished.savedToHealth = false
        if finished.points.isEmpty && finished.distanceMeters < 1 {
            try? store.remove(id: finished.id)
        } else {
            try? store.save(finished)
        }
        phase = .idle
        await uploadPending()
        return false
    }

    func uploadPending() async {
        guard !isUploading else { return }
        isUploading = true
        defer { isUploading = false }
        repeat {
            uploadAgain = false
            await uploadOnce()
        } while uploadAgain
    }

    private func uploadOnce() async {
        // A run whose cool-down is still measured waits for it.
        let waiting = Set([measuringRecoveryOf].compactMap { $0 })
        guard let store = store(creating: false),
              let pending = try? store.pendingUploads().filter({ !waiting.contains($0.id) }),
              !pending.isEmpty else { return }
        guard let jwt = jwt() else {
            uploadStatus = .waiting
            return
        }
        uploadStatus = .uploading
        do {
            let summary = try await RunRecordingUploader.uploadPending(
                store: store, api: api, jwt: jwt, waiting: waiting)
            if summary.unauthorized { onUnauthorized() }
            if !summary.uploaded.isEmpty { onUploaded() }
            if !summary.failed.isEmpty {
                let onlyIntervals = Set(summary.failed).isSubset(of: summary.keptAwaitingIntervals)
                uploadStatus = onlyIntervals ? .waitingForIntervals : .waiting
            } else if summary.uploaded.isEmpty && !summary.notConnected.isEmpty {
                uploadStatus = .notConnected
            } else if !summary.uploaded.isEmpty && Set(summary.uploaded).isSubset(of: summary.keptWithoutIntervals) {
                uploadStatus = .keptInTresFort
            } else {
                uploadStatus = .uploaded
            }
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
