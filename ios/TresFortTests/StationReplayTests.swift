import AVFoundation
import XCTest
@testable import TresFort

private actor ReplayReportGate {
    private var continuation: CheckedContinuation<StationReplayReport, Never>?
    private var report: StationReplayReport?

    func wait() async -> StationReplayReport {
        if let report { return report }
        return await withCheckedContinuation { continuation = $0 }
    }

    func release(_ report: StationReplayReport) {
        self.report = report
        continuation?.resume(returning: report)
        continuation = nil
    }
}

final class StationReplayTests: XCTestCase {
    func testIdentityGateRejectsAmbiguityDetectedOnlyByApple() {
        XCTAssertThrowsError(try StationReplayWorker.validateIdentity(applePersonCount: 2, mediaPipePersonCount: 1)) {
            guard case StationReplayError.multiplePeople = $0 else { return XCTFail("Expected identity rejection, got \($0)") }
        }
    }

    func testIdentityGateRejectsAmbiguityDetectedOnlyByMediaPipe() {
        XCTAssertThrowsError(try StationReplayWorker.validateIdentity(applePersonCount: 1, mediaPipePersonCount: 2)) {
            guard case StationReplayError.multiplePeople = $0 else { return XCTFail("Expected identity rejection, got \($0)") }
        }
    }

    func testIdentityGateAllowsNoPersonOrOnePersonFromEitherDetector() {
        for apple in 0...1 {
            for mediaPipe in 0...1 {
                XCTAssertNoThrow(try StationReplayWorker.validateIdentity(applePersonCount: apple, mediaPipePersonCount: mediaPipe))
            }
        }
    }

    func testSavedVideoAbortsAtAmbiguousFrameBeforeLaterFramesOrCompletedReport() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("station-ambiguous-replay-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try StationRecordingStore(rootURL: root)
        let recording = try await makeRecording(store: store)
        XCTAssertEqual(recording.frameCount, 4)
        var appleFrames = 0
        var report: StationReplayReport?
        do {
            report = try await StationReplayWorker.run(recording: recording, videoURL: store.videoURL(for: recording.id),
                session: store.session, appleDetection: { _, _ in
                    appleFrames += 1
                    return StationReplayPose(personCount: appleFrames == 2 ? 2 : 1, joints: [:], milliseconds: 0)
                }) { _ in }
            XCTFail("An ambiguous clip must not produce completed totals")
        } catch StationReplayError.multiplePeople {
            // The real decoder and MediaPipe runner stopped at the ambiguous frame.
        }
        XCTAssertEqual(appleFrames, 2, "Later single-person frames must not resume this comparison")
        XCTAssertNil(report)
    }

    @MainActor
    func testFailedRerunRemovesOldComparisonBeforeWorkerAndPublishesNoReport() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("station-failed-rerun-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let access = StationAccess(accountID: UUID().uuidString, epoch: 1,
            isCurrentSession: { true }, observeBoundary: { _ in })
        let store = try StationRecordingStore(session: access.session, baseURL: root)
        let previous = try JSONDecoder().decode(StationReplayReport.self, from: legacyReportData)
        let recording = try makeModelRecording(store: store, id: previous.recordingID)
        try store.saveComparison(previous, for: recording.id)
        let originals = try store.shareURLs(for: recording.id).filter { $0.lastPathComponent != "comparison.json" }
        XCTAssertEqual(try store.shareURLs(for: recording.id).count, 4)
        let replay = StationReplayModel(access: access) { _, _, _, _ in
            XCTAssertFalse(try store.shareURLs(for: recording.id).contains { $0.lastPathComponent == "comparison.json" })
            throw StationReplayError.multiplePeople
        }
        let task = try XCTUnwrap(replay.start(recording: recording, store: store))
        XCTAssertNil(replay.report)
        XCTAssertEqual(try store.shareURLs(for: recording.id), originals)
        await task.value
        XCTAssertNil(replay.report)
        XCTAssertFalse(replay.isRunning)
        XCTAssertEqual(replay.error, StationReplayError.multiplePeople.localizedDescription)
        XCTAssertEqual(try store.shareURLs(for: recording.id), originals)
        XCTAssertEqual(try store.load(id: recording.id), recording)
    }

    @MainActor
    func testCanceledRerunCannotRestoreOldComparisonFromLateWorkerResult() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("station-canceled-rerun-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let access = StationAccess(accountID: UUID().uuidString, epoch: 1,
            isCurrentSession: { true }, observeBoundary: { _ in })
        let store = try StationRecordingStore(session: access.session, baseURL: root)
        let previous = try JSONDecoder().decode(StationReplayReport.self, from: legacyReportData)
        let recording = try makeModelRecording(store: store, id: previous.recordingID)
        try store.saveComparison(previous, for: recording.id)
        let gate = ReplayReportGate()
        let started = expectation(description: "Rerun worker started")
        let replay = StationReplayModel(access: access) { _, _, _, _ in
            started.fulfill()
            return await gate.wait()
        }
        let task = try XCTUnwrap(replay.start(recording: recording, store: store))
        XCTAssertFalse(try store.shareURLs(for: recording.id).contains { $0.lastPathComponent == "comparison.json" })
        await fulfillment(of: [started], timeout: 3)
        replay.cancel()
        await gate.release(previous)
        await task.value
        XCTAssertNil(replay.report)
        XCTAssertNil(replay.error)
        XCTAssertFalse(replay.isRunning)
        XCTAssertFalse(try store.shareURLs(for: recording.id).contains { $0.lastPathComponent == "comparison.json" })
        XCTAssertEqual(try store.load(id: recording.id), recording)
    }

    func testLegacyReportKeepsPerArmCountsAndCounterVersionUnknownAfterRoundTrip() throws {
        let report = try JSONDecoder().decode(StationReplayReport.self, from: legacyReportData)
        let frame = try XCTUnwrap(report.frames.first)
        XCTAssertEqual(frame.appleCycles, 3)
        XCTAssertEqual(frame.mediaPipeCycles, 7)
        XCTAssertNil(frame.appleLeftCycles)
        XCTAssertNil(frame.appleRightCycles)
        XCTAssertNil(frame.mediaPipeLeftCycles)
        XCTAssertNil(frame.mediaPipeRightCycles)
        XCTAssertNil(report.counterVersion)

        let encoded = try JSONEncoder().encode(report)
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        let encodedFrame = try XCTUnwrap((object["frames"] as? [[String: Any]])?.first)
        for key in ["appleLeftCycles", "appleRightCycles", "mediaPipeLeftCycles", "mediaPipeRightCycles"] {
            XCTAssertNil(encodedFrame[key], "Legacy totals must not invent per-arm evidence")
        }
        XCTAssertNil(object["counterVersion"])
        let restored = try JSONDecoder().decode(StationReplayReport.self, from: encoded)
        XCTAssertEqual(restored.frames, report.frames)
        XCTAssertNil(restored.counterVersion)
    }

    func testCurrentReportRoundTripsIndependentArmCountsIncludingObservedZero() throws {
        let legacy = try JSONDecoder().decode(StationReplayReport.self, from: legacyReportData)
        var frame = try XCTUnwrap(legacy.frames.first)
        frame.appleLeftCycles = 3
        frame.appleRightCycles = 1
        frame.mediaPipeLeftCycles = 7
        frame.mediaPipeRightCycles = 0
        let report = StationReplayReport(schemaVersion: legacy.schemaVersion, recordingID: legacy.recordingID,
            createdAt: legacy.createdAt, appleRevision: legacy.appleRevision, mediaPipeModel: legacy.mediaPipeModel,
            mediaPipeRuntime: legacy.mediaPipeRuntime, mediaPipeModelSHA256: legacy.mediaPipeModelSHA256,
            osVersion: legacy.osVersion, appBuild: legacy.appBuild, frames: [frame],
            counterVersion: "independent-curl-arms-v1")

        let encoded = try JSONEncoder().encode(report)
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        let encodedFrame = try XCTUnwrap((object["frames"] as? [[String: Any]])?.first)
        XCTAssertEqual(encodedFrame["appleLeftCycles"] as? Int, 3)
        XCTAssertEqual(encodedFrame["appleRightCycles"] as? Int, 1)
        XCTAssertEqual(encodedFrame["mediaPipeLeftCycles"] as? Int, 7)
        XCTAssertEqual(encodedFrame["mediaPipeRightCycles"] as? Int, 0)
        XCTAssertEqual(object["counterVersion"] as? String, "independent-curl-arms-v1")
        let restored = try JSONDecoder().decode(StationReplayReport.self, from: encoded)
        XCTAssertEqual(restored.frames, [frame])
        XCTAssertEqual(restored.counterVersion, report.counterVersion)
    }

    func testInvalidTimestampsFailBeforeIntegerConversion() throws {
        for timestamp in [Double.nan, .infinity, -.infinity, .greatestFiniteMagnitude, -1, 47] {
            XCTAssertThrowsError(try StationReplayWorker.validatedMilliseconds(timestamp, after: -1, previousMilliseconds: -1))
        }
        XCTAssertThrowsError(try StationReplayWorker.validatedMilliseconds(1, after: 1, previousMilliseconds: 1000))
        XCTAssertThrowsError(try StationReplayWorker.validatedMilliseconds(1.0001, after: 1, previousMilliseconds: 1000))
        XCTAssertEqual(try StationReplayWorker.validatedMilliseconds(0, after: -1, previousMilliseconds: -1), 0)
        XCTAssertEqual(try StationReplayWorker.validatedMilliseconds(1.067, after: 1, previousMilliseconds: 1000), 1067)
    }
    func testMediaPipeCoordinatesBecomeUprightEqualUnitsWithoutCalibratingScores() {
        let points = Array(repeating: StationMediaPipeLandmark(
            x: 0.25, y: 0.75, z: -0.1, visibility: 0.9, presence: 0.4), count: 33)
        let input = StationMediaPipeDetection(poses: [points], worldPoses: [], inferenceMilliseconds: 12)
        let result = StationReplayWorker.adaptMediaPipe(input, aspect: 2)
        XCTAssertEqual(result.personCount, 1)
        XCTAssertEqual(result.joints.count, 12)
        let ankle = result.sample(at: 1).joints[.leftAnkle]
        XCTAssertEqual(ankle?.x, 0.5)
        XCTAssertEqual(ankle?.y, 0.25)
        XCTAssertEqual(ankle?.confidence, 0.4)
    }

    func testMissingScoresStayUnusableAndMultiplePeopleAreNeverSelectedSilently() {
        let points = Array(repeating: StationMediaPipeLandmark(
            x: 0.5, y: 0.5, z: 0, visibility: nil, presence: 0.9), count: 33)
        let single = StationReplayWorker.adaptMediaPipe(
            StationMediaPipeDetection(poses: [points], worldPoses: [], inferenceMilliseconds: 1), aspect: 1)
        XCTAssertEqual(single.joints[StationJoint.leftKnee.rawValue]?.score, 0)
        let multiple = StationReplayWorker.adaptMediaPipe(
            StationMediaPipeDetection(poses: [points, points], worldPoses: [], inferenceMilliseconds: 1), aspect: 1)
        XCTAssertEqual(multiple.personCount, 2)
        XCTAssertTrue(multiple.joints.isEmpty)
    }

    func testSavedVideoFeedsAlignedFramesAndRealMediaPipeAndExportsVersionedEvidence() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("station-replay-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try StationRecordingStore(rootURL: root)
        let recording = try await makeRecording(store: store)
        var appleFrames = 0
        // The iOS 26.2 simulator lacks cnn_human_pose.espresso.weights. Keep the
        // decoding/alignment integration executable using an explicit Apple fake;
        // the native-only test below exercises the real Vision request on device.
        let report = try await StationReplayWorker.run(recording: recording, videoURL: store.videoURL(for: recording.id),
                                                       session: store.session,
                                                       appleDetection: { pixels, orientation in
            XCTAssertEqual(CVPixelBufferGetWidth(pixels), 640)
            XCTAssertEqual(CVPixelBufferGetHeight(pixels), 480)
            XCTAssertEqual(orientation, .up)
            appleFrames += 1
            return StationReplayPose(personCount: 0, joints: [:], milliseconds: 0)
        }) { _ in }
        XCTAssertEqual(appleFrames, recording.frameCount)
        XCTAssertEqual(report.frames.count, recording.frameCount)
        XCTAssertEqual(report.frames.first?.timestamp, 0)
        XCTAssertEqual(report.frames.last?.timestamp ?? -1, recording.durationSeconds, accuracy: 0.001)
        XCTAssertEqual(report.mediaPipeModelSHA256, StationMediaPipeDetector.modelSHA256)
        XCTAssertEqual(report.counterVersion, "curl-confidence-grace-v2")
        XCTAssertTrue(report.frames.allSatisfy { $0.apple.personCount == 0 && $0.mediaPipe.personCount == 0 })
        XCTAssertTrue(report.frames.allSatisfy { $0.appleCycles == 0 && $0.mediaPipeCycles == 0 })
        XCTAssertTrue(report.frames.allSatisfy { $0.apple.milliseconds >= 0 && $0.mediaPipe.milliseconds >= 0 })
        let decoded = try JSONDecoder().decode(StationReplayReport.self, from: JSONEncoder().encode(report))
        XCTAssertEqual(decoded.frames, report.frames)
    }

    func testRealAppleAndMediaPipeOnSavedVideoOnDevice() async throws {
#if targetEnvironment(simulator)
        throw XCTSkip("The simulator runtime omits Apple's human pose model weights; this check requires a physical device.")
#else
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("station-native-replay-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try StationRecordingStore(rootURL: root)
        let recording = try await makeRecording(store: store)
        let report = try await StationReplayWorker.run(recording: recording, videoURL: store.videoURL(for: recording.id), session: store.session) { _ in }
        XCTAssertEqual(report.frames.count, recording.frameCount)
        XCTAssertTrue(report.frames.allSatisfy { $0.apple.personCount == 0 && $0.mediaPipe.personCount == 0 })
#endif
    }

    /// Model tests inject their runner, so only valid store files are needed;
    /// the separate worker integration tests decode an actual saved movie.
    private func makeModelRecording(store: StationRecordingStore, id: UUID) throws -> StationRecording {
        let recording = StationRecording(schemaVersion: 1, id: id, createdAt: Date(), exerciseRawValue: "squat",
            durationSeconds: 1, frameCount: 2, droppedFrameCount: 0, orientation: 1,
            width: 640, height: 480, imageAspectRatio: 4.0 / 3.0,
            finishReason: .userStopped, appBuild: "replay-model-test", actualReps: nil)
        let pending = try store.prepare(id: id)
        try Data([1, 2, 3]).write(to: pending.appendingPathComponent("clip.mov"))
        try Data().write(to: pending.appendingPathComponent("measurements.jsonl"))
        try store.publish(recording)
        return recording
    }

    private func makeRecording(store: StationRecordingStore) async throws -> StationRecording {
        try await withCheckedThrowingContinuation { continuation in
            let queue = DispatchQueue(label: "station.replay.fixture")
            queue.async {
                do {
                    let writer = try StationRecordingWriter(exercise: .squat, store: store)
                    var pixels: CVPixelBuffer?
                    let status = CVPixelBufferCreate(kCFAllocatorDefault, 640, 480, kCVPixelFormatType_32BGRA,
                                                    [kCVPixelBufferIOSurfacePropertiesKey: [:]] as CFDictionary, &pixels)
                    guard status == kCVReturnSuccess, let pixels else { throw StationReplayError.noFrames }
                    CVPixelBufferLockBaseAddress(pixels, [])
                    memset(CVPixelBufferGetBaseAddress(pixels), 0, CVPixelBufferGetDataSize(pixels))
                    CVPixelBufferUnlockBaseAddress(pixels, [])
                    for index in 0..<4 {
                        let timestamp = 10 + Double(index) / 5
                        let frame = StationComparisonFrame(
                            sample: StationPoseSample(timestamp: timestamp, joints: [:], personCount: 0),
                            applePose: nil, visionMilliseconds: 0, imageAspectRatio: 4.0 / 3.0)
                        var appended = false
                        for _ in 0..<100 where !appended {
                            appended = try writer.append(pixelBuffer: pixels, time: CMTime(seconds: timestamp, preferredTimescale: 600),
                                                         orientation: .up, frame: frame)
                            if !appended { Thread.sleep(forTimeInterval: 0.01) }
                        }
                        guard appended else { writer.cancel(); throw StationRecordingError.encodingFailed }
                    }
                    writer.finish(reason: .userStopped, queue: queue) { continuation.resume(with: $0) }
                } catch { continuation.resume(throwing: error) }
            }
        }
    }

    /// Explicit pre-arm-count wire format, with nonzero legacy totals. A
    /// decoder must preserve the missing evidence instead of assigning a side.
    private var legacyReportData: Data {
        Data("""
        {
          "schemaVersion": 1,
          "recordingID": "58D69D1A-1F63-452C-B189-2FCB6DF24D99",
          "createdAt": 0,
          "appleRevision": 1,
          "mediaPipeModel": "synthetic-model",
          "mediaPipeRuntime": "synthetic-runtime",
          "mediaPipeModelSHA256": "synthetic-sha",
          "osVersion": "test-os",
          "appBuild": "test-build",
          "frames": [{
            "timestamp": 0.25,
            "apple": { "personCount": 0, "joints": {}, "milliseconds": 1 },
            "mediaPipe": { "personCount": 0, "joints": {}, "milliseconds": 2 },
            "mediaPipeLandmarks": [],
            "mediaPipeWorldLandmarks": [],
            "appleCycles": 3,
            "mediaPipeCycles": 7
          }]
        }
        """.utf8)
    }
}
