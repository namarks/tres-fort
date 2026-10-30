import CoreLocation
import Foundation
import XCTest
@testable import TresFort

@MainActor
private final class FakeRunEngine: RunWorkoutEngine {
    var onMetrics: ((RunWorkoutMetrics) -> Void)?
    var onFailure: ((String) -> Void)?
    private(set) var calls: [String] = []
    private(set) var route: [CLLocation] = []
    var finalMetrics = RunWorkoutMetrics(distanceMeters: 0, movingSeconds: 0, heartRate: nil)
    var endError: Error?
    var recovery: RunWorkoutRecovery?
    /// Holds `recover` until `releaseRecovery()`, like a slow Health query.
    var holdRecovery = false
    private var heldRecovery: CheckedContinuation<Void, Never>?

    func releaseRecovery() {
        heldRecovery?.resume()
        heldRecovery = nil
    }

    func requestAuthorization() async throws { calls.append("authorize") }
    func start(at date: Date, recordingID: UUID) async throws { calls.append("start") }
    func pause() { calls.append("pause") }
    func resume() { calls.append("resume") }
    func addRoute(_ locations: [CLLocation]) { route += locations }
    func end(at date: Date) async throws -> RunWorkoutMetrics {
        calls.append("end")
        if let endError { throw endError }
        return finalMetrics
    }
    func discard() { calls.append("discard") }
    func recover(route: [CLLocation]) async -> RunWorkoutRecovery? {
        calls.append("recover")
        if holdRecovery {
            await withCheckedContinuation { heldRecovery = $0 }
        }
        if recovery != nil { self.route = route }
        return recovery
    }
}

@MainActor
private final class FakeLocationSource: RunLocationSource {
    var onLocations: (([CLLocation]) -> Void)?
    var access: RunLocationAccess = .granted
    private(set) var running = false

    func requestAccess() async -> RunLocationAccess { access }
    func start() { running = true }
    func stop() { running = false }
}

@MainActor
private final class FakeLiveActivity: RunLiveActivityPresenting {
    private(set) var shown: [RunActivityAttributes.ContentState] = []
    private(set) var recordingIDs: [String] = []
    private(set) var endCount = 0

    func show(recordingID: String, state: RunActivityAttributes.ContentState) {
        recordingIDs.append(recordingID)
        shown.append(state)
    }
    func endAll() { endCount += 1 }
}

@MainActor
private final class FakeSpeaker: RunSplitSpeaking {
    private(set) var spoken: [String] = []
    func speak(_ text: String) { spoken.append(text) }
}

private final class RecorderUploadStub: RecordingUploadAPI {
    var error: Error?
    private(set) var uploaded: [RecordedRun] = []

    func uploadRecording(_ run: RecordedRun, jwt: String) async throws -> RecordingUploadResult {
        if let error { throw error }
        uploaded.append(run)
        return RecordingUploadResult(ok: true, deduplicated: false, recording_id: run.uploadID,
                                     intervals_activity_id: "i1")
    }
}

@MainActor
final class RunRecorderTests: XCTestCase {
    private var base: URL!
    private var clock = Date(timeIntervalSince1970: 1_793_000_000)
    private var engine: FakeRunEngine!
    private var location: FakeLocationSource!
    private var api: RecorderUploadStub!
    private var liveActivity: FakeLiveActivity!
    private var speaker: FakeSpeaker!
    private var defaults: UserDefaults!
    private var defaultsSuite: String!
    private var unauthorized = 0
    private var uploads = 0

    override func setUp() async throws {
        base = FileManager.default.temporaryDirectory.appendingPathComponent("run-recorder-\(UUID())")
        engine = FakeRunEngine()
        location = FakeLocationSource()
        api = RecorderUploadStub()
        liveActivity = FakeLiveActivity()
        speaker = FakeSpeaker()
        defaultsSuite = "run-recorder-\(UUID())"
        defaults = UserDefaults(suiteName: defaultsSuite)
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: base)
        defaults.removePersistentDomain(forName: defaultsSuite)
        RunRecorderControl.handler = nil
    }

    private func makeModel(jwt: String? = "jwt") -> RunRecorderModel {
        RunRecorderModel(
            accountID: "user-a", baseURL: base, api: api,
            jwt: { jwt },
            onUnauthorized: { [unowned self] in self.unauthorized += 1 },
            onUploaded: { [unowned self] in self.uploads += 1 },
            makeEngine: { [unowned self] in self.engine },
            makeLocation: { [unowned self] in self.location },
            now: { [unowned self] in self.clock },
            defaults: defaults,
            liveActivity: liveActivity,
            makeSpeaker: { [unowned self] in self.speaker })
    }

    private func store() throws -> RunRecordingStore {
        try RunRecordingStore(accountID: "user-a", baseURL: base)
    }

    /// About 30 m north of Pioneer Square per step.
    private func fix(_ step: Int, seconds: TimeInterval, accuracy: CLLocationAccuracy = 5) -> CLLocation {
        CLLocation(
            coordinate: CLLocationCoordinate2D(latitude: 45.5190 + Double(step) * 0.00027, longitude: -122.6793),
            altitude: 15, horizontalAccuracy: accuracy, verticalAccuracy: 3,
            timestamp: clock.addingTimeInterval(seconds))
    }

    private func point(_ step: Int, seconds: TimeInterval, accuracy: Double = 5,
                       from start: Date) -> RecordedRun.RoutePoint {
        .init(timestamp: start.addingTimeInterval(seconds), latitude: 45.5190 + Double(step) * 0.00027,
              longitude: -122.6793, altitude: nil, horizontalAccuracy: accuracy)
    }

    // MARK: - Pure helpers

    func testLocationFilterDropsImpreciseStaleAndImpossibleFixes() {
        let start = clock
        let first = point(0, seconds: 0, from: start)
        XCTAssertTrue(RunLocationFilter.accepts(first, after: nil, startedAt: start))
        XCTAssertFalse(RunLocationFilter.accepts(point(0, seconds: 0, accuracy: 65, from: start),
                                                 after: nil, startedAt: start))
        XCTAssertFalse(RunLocationFilter.accepts(point(0, seconds: 0, accuracy: -1, from: start),
                                                 after: nil, startedAt: start))
        // A cached fix from before the start.
        XCTAssertFalse(RunLocationFilter.accepts(point(0, seconds: -5, from: start), after: nil, startedAt: start))
        // 30 m in 10 s is a run; the same fix again, or 300 m in 10 s, is not.
        XCTAssertTrue(RunLocationFilter.accepts(point(1, seconds: 10, from: start), after: first, startedAt: start))
        XCTAssertFalse(RunLocationFilter.accepts(point(0, seconds: 0, from: start), after: first, startedAt: start))
        XCTAssertFalse(RunLocationFilter.accepts(point(10, seconds: 10, from: start), after: first, startedAt: start))
    }

    func testFormattingAndAveragePace() {
        XCTAssertEqual(RunFormat.duration(65.9), "1:05")
        XCTAssertEqual(RunFormat.duration(3725), "1:02:05")
        XCTAssertEqual(RunFormat.miles(1_609.344 * 3.1), "3.10")
        XCTAssertEqual(RunFormat.pace(485), "8:05")
        XCTAssertEqual(RunFormat.pace(nil), "–")
        XCTAssertEqual(RunFormat.pace(4000), "–")
        XCTAssertEqual(try XCTUnwrap(RunPace.average(movingSeconds: 1940, meters: 1_609.344 * 4)), 485, accuracy: 0.001)
        XCTAssertNil(RunPace.average(movingSeconds: 30, meters: 5))
    }

    func testCurrentPaceUsesTheLastThirtySecondsSinceThePause() throws {
        var run = RecordedRun(startedAt: clock)
        run.points = (0...6).map { point($0, seconds: Double($0) * 10, from: clock) }
        // Three 30 m steps in 30 s: 3 m/s is about 8:56 per mile.
        XCTAssertEqual(try XCTUnwrap(RunPace.current(run)), 536, accuracy: 2)

        // A pause that just started has no current pace.
        run.pauses = [.init(start: clock.addingTimeInterval(61), end: nil)]
        XCTAssertNil(RunPace.current(run))
        // After resuming, only the new segment counts, and one point isn't enough.
        run.pauses[0].end = clock.addingTimeInterval(120)
        run.points.append(point(7, seconds: 125, from: clock))
        XCTAssertNil(RunPace.current(run))
    }

    func testActiveSecondsExcludePauses() {
        var run = RecordedRun(startedAt: clock)
        run.pauses = [.init(start: clock.addingTimeInterval(100), end: clock.addingTimeInterval(160))]
        XCTAssertEqual(run.activeSeconds(at: clock.addingTimeInterval(300)), 240)
        run.pauses.append(.init(start: clock.addingTimeInterval(250), end: nil))
        XCTAssertTrue(run.isPaused)
        XCTAssertEqual(run.activeSeconds(at: clock.addingTimeInterval(300)), 190)
        run.closePause(at: clock.addingTimeInterval(280))
        run.endedAt = clock.addingTimeInterval(400)
        XCTAssertEqual(run.activeSeconds(at: clock.addingTimeInterval(999)), 310)
    }

    func testKilometersConvertDistanceAndPace() throws {
        XCTAssertEqual(RunFormat.distance(5_000, in: .kilometers), "5.00")
        XCTAssertEqual(RunFormat.distance(5_000, in: .miles), "3.11")
        XCTAssertEqual(try XCTUnwrap(RunPace.average(movingSeconds: 1500, meters: 5_000, unit: .kilometers)), 300,
                       accuracy: 0.001)
        var run = RecordedRun(startedAt: clock)
        run.points = (0...3).map { point($0, seconds: Double($0) * 10, from: clock) }
        let perMile = try XCTUnwrap(RunPace.current(run))
        XCTAssertEqual(try XCTUnwrap(RunPace.current(run, unit: .kilometers)), perMile / 1.609344, accuracy: 0.001)
    }

    func testSplitTrackerReportsEachWholeUnit() {
        var miles = RunSplitTracker(unit: .miles)
        XCTAssertNil(miles.update(meters: 1_500, movingSeconds: 450))
        XCTAssertEqual(miles.update(meters: 1_610, movingSeconds: 480),
                       RunSplit(number: 1, unit: .miles, seconds: 480, averagePace: 480 / (1_610 / 1_609.344)))
        XCTAssertNil(miles.update(meters: 1_700, movingSeconds: 500))
        XCTAssertEqual(miles.update(meters: 3_219, movingSeconds: 950)?.seconds, 470)
        // A jump over two units reports the latest, sharing out the time.
        let jump = miles.update(meters: 6_438, movingSeconds: 1_950)
        XCTAssertEqual(jump?.number, 4)
        XCTAssertEqual(jump?.seconds, 500)

        var kilometers = RunSplitTracker(unit: .kilometers)
        XCTAssertEqual(kilometers.update(meters: 1_000, movingSeconds: 300)?.number, 1)
    }

    func testARecoveredTrackerSkipsSplitsAlreadyRun() throws {
        // 2.5 miles in 25 minutes: two splits done, about 20 minutes in.
        var tracker = RunSplitTracker(unit: .miles, meters: 1_609.344 * 2.5, movingSeconds: 1_500)
        XCTAssertEqual(tracker.completed, 2)
        XCTAssertNil(tracker.update(meters: 1_609.344 * 2.9, movingSeconds: 1_740))
        let third = tracker.update(meters: 1_609.344 * 3.01, movingSeconds: 1_800)
        XCTAssertEqual(third?.number, 3)
        XCTAssertEqual(try XCTUnwrap(third?.seconds), 600, accuracy: 0.001)
    }

    func testSplitAnnouncementReadsAsWords() {
        let split = RunSplit(number: 3, unit: .miles, seconds: 512, averagePace: 521)
        XCTAssertEqual(split.spokenText,
                       "Mile 3. Split 8 minutes 32 seconds. Average pace 8 minutes 41 seconds per mile.")
        XCTAssertEqual(RunSplit(number: 1, unit: .kilometers, seconds: 300, averagePace: 300).spokenText,
                       "Kilometer 1. Split 5 minutes. Average pace 5 minutes per kilometer.")
        XCTAssertEqual(RunSplit.spoken(3_661), "1 hour 1 minute 1 second")
        XCTAssertEqual(RunSplit.spoken(0.2), "0 seconds")
    }

    func testHealthWorkoutCarriesTheUploadExternalID() {
        let id = UUID()
        XCTAssertEqual(RunRecordingHealthTag.externalID(for: id), "tresfort:recording:" + id.uuidString.lowercased())
    }

    // MARK: - Recorder

    func testRecordsCheckpointsAndUploadsWhenTheRunEnds() async throws {
        let model = makeModel()
        await model.start()
        XCTAssertEqual(model.phase, .running)
        XCTAssertEqual(engine.calls, ["authorize", "start"])
        XCTAssertTrue(location.running)
        let id = try XCTUnwrap(model.run?.id)
        XCTAssertEqual(try store().unfinished()?.id, id)

        location.onLocations?([fix(0, seconds: 1), fix(1, seconds: 11), fix(2, seconds: 21, accuracy: 80)])
        XCTAssertEqual(model.run?.points.count, 2)
        XCTAssertEqual(engine.route.count, 2)
        engine.onMetrics?(.init(distanceMeters: 31, movingSeconds: 11,
                                heartRate: .init(timestamp: clock.addingTimeInterval(11), beatsPerMinute: 150)))
        XCTAssertEqual(model.run?.distanceMeters, 31)
        XCTAssertEqual(model.latestHeartRate?.beatsPerMinute, 150)

        clock = clock.addingTimeInterval(30)
        model.pause()
        XCTAssertEqual(model.phase, .paused)
        // Fixes while paused don't join the route.
        location.onLocations?([fix(3, seconds: 35)])
        XCTAssertEqual(model.run?.points.count, 2)
        XCTAssertTrue(try XCTUnwrap(store().load(id: id)).isPaused)
        clock = clock.addingTimeInterval(20)
        model.resume()
        XCTAssertEqual(model.phase, .running)

        engine.finalMetrics = .init(distanceMeters: 64, movingSeconds: 40, heartRate: nil)
        clock = clock.addingTimeInterval(20)
        await model.end()

        XCTAssertEqual(model.phase, .finished)
        XCTAssertEqual(engine.calls, ["authorize", "start", "pause", "resume", "end"])
        XCTAssertFalse(location.running)
        let uploaded = try XCTUnwrap(api.uploaded.first)
        XCTAssertEqual(uploaded.id, id)
        XCTAssertEqual(uploaded.distanceMeters, 64)
        XCTAssertEqual(uploaded.movingSeconds, 40)
        XCTAssertEqual(uploaded.endedAt, clock)
        XCTAssertEqual(uploaded.pauses.count, 1)
        XCTAssertEqual(uploaded.heartRates.count, 1)
        XCTAssertEqual(model.uploadStatus, .uploaded)
        XCTAssertEqual(uploads, 1)
        XCTAssertEqual(try store().all(), [])
    }

    func testLiveActivityFollowsTheRunAndEndsWithIt() async throws {
        let model = makeModel()
        await model.start()
        let id = try XCTUnwrap(model.run?.uploadID)
        XCTAssertEqual(liveActivity.recordingIDs, [id])
        XCTAssertEqual(liveActivity.shown.last?.clockStart, clock)
        XCTAssertEqual(liveActivity.shown.last?.isPaused, false)
        XCTAssertEqual(liveActivity.shown.last?.unit, .miles)

        // Distance updates wait five seconds between Lock Screen updates.
        clock = clock.addingTimeInterval(2)
        engine.onMetrics?(.init(distanceMeters: 8, movingSeconds: 2, heartRate: nil))
        XCTAssertEqual(liveActivity.shown.count, 1)
        clock = clock.addingTimeInterval(4)
        engine.onMetrics?(.init(distanceMeters: 20, movingSeconds: 6, heartRate: nil))
        XCTAssertEqual(liveActivity.shown.count, 2)
        XCTAssertEqual(liveActivity.shown.last?.meters, 20)

        // Pause shows at once with the clock stopped; resume moves the clock
        // start later by the pause.
        model.pause()
        XCTAssertEqual(liveActivity.shown.last?.pausedSeconds, 6)
        clock = clock.addingTimeInterval(30)
        model.resume()
        XCTAssertNil(liveActivity.shown.last?.pausedSeconds)
        XCTAssertEqual(liveActivity.shown.last?.clockStart, clock.addingTimeInterval(-6))

        location.onLocations?([fix(0, seconds: 1), fix(1, seconds: 11)])
        clock = clock.addingTimeInterval(20)
        await model.end()
        XCTAssertEqual(liveActivity.endCount, 1)
        XCTAssertEqual(Set(liveActivity.recordingIDs), [id])
    }

    func testDiscardAndAnUnfinishedLaunchEndTheLiveActivity() async throws {
        let model = makeModel()
        await model.start()
        model.discard()
        XCTAssertEqual(liveActivity.endCount, 1)
        // At launch with nothing recording, a leftover activity ends.
        let recording = await makeModel().recover()
        XCTAssertFalse(recording)
        XCTAssertEqual(liveActivity.endCount, 2)
    }

    func testLockScreenControlsPauseResumeAndFinishOnlyThisRun() async throws {
        let model = makeModel()
        await model.start()
        let id = try XCTUnwrap(model.run?.uploadID)
        location.onLocations?([fix(0, seconds: 1), fix(1, seconds: 11)])
        let handler = try XCTUnwrap(RunRecorderControl.handler)

        let otherRun = await handler(UUID().uuidString.lowercased(), "pause")
        XCTAssertFalse(otherRun)
        XCTAssertEqual(model.phase, .running)
        let unknown = await handler(id, "stop")
        XCTAssertFalse(unknown)

        let paused = await handler(id, "pause")
        XCTAssertTrue(paused)
        XCTAssertEqual(model.phase, .paused)
        let pausedAgain = await handler(id, "pause")
        XCTAssertTrue(pausedAgain, "A repeated tap that already happened counts as done")
        clock = clock.addingTimeInterval(20)
        let resumed = await handler(id, "resume")
        XCTAssertTrue(resumed)
        XCTAssertEqual(model.phase, .running)

        clock = clock.addingTimeInterval(20)
        let finished = await handler(id, "finish")
        XCTAssertTrue(finished)
        XCTAssertEqual(model.phase, .finished)
        XCTAssertEqual(api.uploaded.map(\.uploadID), [id])
        XCTAssertNil(RunRecorderControl.handler, "A finished run stops answering the Lock Screen")
    }

    func testSplitsAreSpokenOnlyWhenTurnedOnAndPreferencesPersist() async throws {
        let model = makeModel()
        XCTAssertEqual(model.unit, .miles)
        XCTAssertFalse(model.announcesSplits)
        await model.start()
        clock = clock.addingTimeInterval(480)
        engine.onMetrics?(.init(distanceMeters: 1_610, movingSeconds: 480, heartRate: nil))
        XCTAssertEqual(speaker.spoken, [], "Announcements start off")

        model.announcesSplits = true
        clock = clock.addingTimeInterval(470)
        engine.onMetrics?(.init(distanceMeters: 3_219, movingSeconds: 950, heartRate: nil))
        XCTAssertEqual(speaker.spoken.count, 1)
        XCTAssertTrue(speaker.spoken[0].hasPrefix("Mile 2. Split 7 minutes 50 seconds."))

        // Nothing is spoken while paused, even if the distance settles.
        model.pause()
        engine.onMetrics?(.init(distanceMeters: 4_830, movingSeconds: 950, heartRate: nil))
        XCTAssertEqual(speaker.spoken.count, 1)
        model.discard()

        model.unit = .kilometers
        let reopened = makeModel()
        XCTAssertEqual(reopened.unit, .kilometers)
        XCTAssertTrue(reopened.announcesSplits)
    }

    func testDeniedOrApproximateLocationFailsBeforeHealth() async throws {
        location.access = .denied
        let model = makeModel()
        await model.start()
        guard case .failed(let message) = model.phase else { return XCTFail("expected a failure") }
        XCTAssertTrue(message.contains("Allow location"))
        location.access = .approximate
        await model.start()
        guard case .failed(let approximate) = model.phase else { return XCTFail("expected a failure") }
        XCTAssertTrue(approximate.contains("Precise Location"))
        XCTAssertEqual(engine.calls, [])
        XCTAssertEqual(try store().all(), [])
    }

    func testHealthSaveFailureStillUploadsTheRun() async throws {
        let model = makeModel()
        await model.start()
        location.onLocations?([fix(0, seconds: 1), fix(1, seconds: 11)])
        engine.endError = RunWorkoutEngineError.notStarted
        clock = clock.addingTimeInterval(20)
        await model.end()
        XCTAssertEqual(model.phase, .finished)
        XCTAssertNotNil(model.note)
        let uploaded = try XCTUnwrap(api.uploaded.first)
        // No builder total: moving time falls back to the clock.
        XCTAssertEqual(uploaded.movingSeconds, 20)
    }

    func testARunWithNoRouteLeavesNothingToUpload() async throws {
        let model = makeModel()
        await model.start()
        clock = clock.addingTimeInterval(5)
        await model.end()
        XCTAssertEqual(model.phase, .finished)
        XCTAssertEqual(api.uploaded.count, 0)
        XCTAssertEqual(try store().all(), [])
    }

    func testFailedUploadKeepsTheRunAndARejectedBearerReauthenticates() async throws {
        api.error = APIError.http(401, "expired")
        let model = makeModel()
        await model.start()
        location.onLocations?([fix(0, seconds: 1), fix(1, seconds: 11)])
        clock = clock.addingTimeInterval(20)
        await model.end()
        XCTAssertEqual(model.uploadStatus, .waiting)
        XCTAssertEqual(unauthorized, 1)
        XCTAssertEqual(try store().pendingUploads().count, 1)

        api.error = nil
        await model.uploadPending()
        XCTAssertEqual(model.uploadStatus, .uploaded)
        XCTAssertEqual(try store().all(), [])
    }

    func testWithoutABearerTheRunWaits() async throws {
        let model = makeModel(jwt: nil)
        await model.start()
        location.onLocations?([fix(0, seconds: 1), fix(1, seconds: 11)])
        clock = clock.addingTimeInterval(20)
        await model.end()
        XCTAssertEqual(model.uploadStatus, .waiting)
        XCTAssertEqual(try store().pendingUploads().count, 1)
    }

    func testDiscardRemovesTheRunWithoutSaving() async throws {
        let model = makeModel()
        await model.start()
        location.onLocations?([fix(0, seconds: 1)])
        model.discard()
        XCTAssertEqual(model.phase, .idle)
        XCTAssertNil(model.run)
        XCTAssertEqual(engine.calls, ["authorize", "start", "discard"])
        XCTAssertEqual(try store().all(), [])
        XCTAssertEqual(api.uploaded.count, 0)
    }

    func testEngineFailureFinishesTheRunAndUploadsIt() async throws {
        let model = makeModel()
        await model.start()
        location.onLocations?([fix(0, seconds: 1), fix(1, seconds: 11)])
        engine.onFailure?("The workout stopped.")
        XCTAssertEqual(model.phase, .finished)
        XCTAssertEqual(model.note, "The workout stopped.")
        XCTAssertEqual(model.run?.endedAt, clock.addingTimeInterval(11))
        for _ in 0..<100 where api.uploaded.isEmpty {
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTAssertEqual(api.uploaded.count, 1)
    }

    func testRecoveryReattachesASurvivingWorkout() async throws {
        var checkpoint = RecordedRun(startedAt: clock)
        checkpoint.points = [point(0, seconds: 1, from: clock), point(1, seconds: 11, from: clock)]
        try store().save(checkpoint)
        engine.recovery = .running
        clock = clock.addingTimeInterval(60)

        let model = makeModel()
        let recording = await model.recover()

        XCTAssertTrue(recording)
        XCTAssertEqual(model.phase, .running)
        XCTAssertEqual(model.run?.id, checkpoint.id)
        XCTAssertEqual(engine.route.map(\.timestamp), checkpoint.points.map(\.timestamp))
        XCTAssertTrue(location.running)
        XCTAssertEqual(api.uploaded.count, 0)
        XCTAssertEqual(liveActivity.recordingIDs, [checkpoint.uploadID], "The Lock Screen picks the run back up")
        XCTAssertEqual(liveActivity.endCount, 0)
    }

    func testRecoveryFinishesAnOrphanFromItsCheckpoint() async throws {
        var checkpoint = RecordedRun(startedAt: clock)
        checkpoint.points = [point(0, seconds: 1, from: clock), point(1, seconds: 11, from: clock)]
        checkpoint.distanceMeters = 30
        checkpoint.pauses = [.init(start: clock.addingTimeInterval(15), end: nil)]
        try store().save(checkpoint)
        engine.recovery = nil
        clock = clock.addingTimeInterval(3600)

        let model = makeModel()
        let recording = await model.recover()

        XCTAssertFalse(recording)
        XCTAssertEqual(model.phase, .idle)
        let uploaded = try XCTUnwrap(api.uploaded.first)
        // The run ends at the open pause, not an hour later.
        XCTAssertEqual(uploaded.endedAt, checkpoint.startedAt.addingTimeInterval(15))
        XCTAssertEqual(uploaded.movingSeconds, 15)
        XCTAssertFalse(uploaded.isPaused)
        XCTAssertEqual(try store().all(), [])
        XCTAssertEqual(liveActivity.endCount, 1, "The lost run's Lock Screen activity ends")
    }

    func testNothingStartsWhileRecoveryIsWaitingOnHealth() async throws {
        var checkpoint = RecordedRun(startedAt: clock)
        checkpoint.points = [point(0, seconds: 1, from: clock)]
        try store().save(checkpoint)
        engine.recovery = .running
        engine.holdRecovery = true
        let model = makeModel()

        let recovery = Task { await model.recover() }
        for _ in 0..<100 where !engine.calls.contains("recover") {
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTAssertEqual(model.phase, .recovering)
        await model.start()
        XCTAssertEqual(engine.calls, ["recover"])

        engine.releaseRecovery()
        let recording = await recovery.value
        XCTAssertTrue(recording)
        XCTAssertEqual(model.phase, .running)
        XCTAssertEqual(model.run?.id, checkpoint.id)
    }

    func testStartPicksUpAnUnfinishedRunFirst() async throws {
        var checkpoint = RecordedRun(startedAt: clock)
        checkpoint.points = [point(0, seconds: 1, from: clock)]
        try store().save(checkpoint)
        engine.recovery = .running

        let model = makeModel()
        await model.start()

        XCTAssertEqual(model.phase, .running)
        XCTAssertEqual(model.run?.id, checkpoint.id)
        XCTAssertEqual(engine.calls, ["recover"])

        // An orphan instead finishes and uploads, then the new run starts.
        model.discard()
        var orphan = RecordedRun(startedAt: clock)
        orphan.points = [point(0, seconds: 1, from: clock), point(1, seconds: 11, from: clock)]
        try store().save(orphan)
        engine.recovery = nil
        clock = clock.addingTimeInterval(600)
        await model.start()
        XCTAssertEqual(api.uploaded.map(\.id), [orphan.id])
        XCTAssertEqual(model.phase, .running)
        XCTAssertNotEqual(model.run?.id, orphan.id)
        XCTAssertEqual(engine.calls, ["recover", "discard", "recover", "authorize", "start"])
    }

    func testRecoveryWithoutStoredRunsCreatesNoDirectory() async throws {
        let recording = await makeModel().recover()
        XCTAssertFalse(recording)
        XCTAssertFalse(FileManager.default.fileExists(atPath: base.path))
        XCTAssertEqual(engine.calls, [])
    }
}
