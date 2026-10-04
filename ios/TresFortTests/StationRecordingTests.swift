import AVFoundation
import ImageIO
import XCTest
@testable import TresFort

// Tests opt into a named account and a disposable base directory. Production
// has no unscoped/default constructor for saved Station recordings.
extension StationRecordingStore {
    convenience init(rootURL: URL) throws {
        try self.init(session: StationSessionGate(accountID: "station-recording-test", epoch: 0), baseURL: rootURL)
    }
}

final class StationRecordingTests: XCTestCase {
    private var roots: [URL] = []

    override func tearDownWithError() throws {
        for root in roots where FileManager.default.fileExists(atPath: root.path) {
            try FileManager.default.removeItem(at: root)
        }
        roots = []
    }

    private func root() -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("StationRecordingTests-\(UUID())")
        roots.append(url)
        return url
    }

    private func recording(id: UUID = UUID(), createdAt: Date = Date()) -> StationRecording {
        StationRecording(schemaVersion: 1, id: id, createdAt: createdAt, exerciseRawValue: "squat",
                         durationSeconds: 1, frameCount: 16, droppedFrameCount: 0,
                         orientation: CGImagePropertyOrientation.right.rawValue,
                         width: 640, height: 480, imageAspectRatio: 0.75,
                         finishReason: .userStopped, appBuild: "test", actualReps: nil)
    }

    private func publishFixture(_ recording: StationRecording, in store: StationRecordingStore) throws {
        let pending = try store.prepare(id: recording.id)
        try Data().write(to: pending.appendingPathComponent("clip.mov"))
        try Data().write(to: pending.appendingPathComponent("measurements.jsonl"))
        try store.publish(recording)
    }

    func testPublishActualRepsAndDeletePreserveOtherTests() throws {
        let store = try StationRecordingStore(rootURL: root())
        let first = recording(createdAt: Date(timeIntervalSince1970: 1))
        let second = recording(createdAt: Date(timeIntervalSince1970: 2))
        try publishFixture(first, in: store)
        try publishFixture(second, in: store)
        XCTAssertEqual(try store.list().map(\.id), [second.id, first.id])
        XCTAssertEqual(try store.updateActualReps(5, for: first.id).actualReps, 5)
        XCTAssertEqual(try store.load(id: first.id).actualReps, 5)
        XCTAssertNil(try store.load(id: second.id).actualReps)
        XCTAssertThrowsError(try store.updateActualReps(-1, for: first.id))
        XCTAssertThrowsError(try store.updateActualReps(1_001, for: first.id))
        XCTAssertEqual(try store.load(id: first.id).actualReps, 5)
        XCTAssertNil(try store.updateActualReps(nil, for: first.id).actualReps)
        try store.delete(id: first.id)
        try store.delete(id: first.id)
        XCTAssertEqual(try store.list().map(\.id), [second.id])
        XCTAssertFalse(try FileManager.default.fileExists(atPath: store.videoURL(for: first.id).path))
    }

    func testIncompletePackageIsNotListedAndSecondStoreDoesNotDeleteActiveWriter() throws {
        let url = root()
        let store = try StationRecordingStore(rootURL: url)
        let id = UUID()
        let pending = try store.prepare(id: id)
        try Data([1, 2, 3]).write(to: pending.appendingPathComponent("clip.mov"))
        XCTAssertTrue(try store.list().isEmpty)
        let secondStore = try StationRecordingStore(rootURL: url)
        XCTAssertTrue(try secondStore.list().isEmpty)
        XCTAssertTrue(FileManager.default.fileExists(atPath: pending.path))
        store.discardPending(id: id)
        XCTAssertFalse(FileManager.default.fileExists(atPath: pending.path))
    }

    func testFirstStoreRemovesOnlyRecognizedCrashLeftoversAndExcludesBackup() throws {
        let url = root()
        let scoped = try StationRecordingStore.accountDirectory(accountID: "station-recording-test", baseURL: url)
        let pending = scoped.appendingPathComponent(".pending-\(UUID())")
        let unrelated = scoped.appendingPathComponent(".pending-user-file")
        try FileManager.default.createDirectory(at: pending, withIntermediateDirectories: true)
        try Data([1]).write(to: unrelated)
        let store = try StationRecordingStore(rootURL: url)
        XCTAssertFalse(FileManager.default.fileExists(atPath: pending.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: unrelated.path))
        XCTAssertEqual(try store.rootURL.resourceValues(forKeys: [.isExcludedFromBackupKey]).isExcludedFromBackup, true)
        let active = try store.prepare(id: UUID())
        XCTAssertEqual(try active.resourceValues(forKeys: [.isExcludedFromBackupKey]).isExcludedFromBackup, true)
    }

    func testSavedLimitRefusesNewCaptureWithoutDeletingOldClips() throws {
        let store = try StationRecordingStore(rootURL: root())
        for _ in 0..<StationRecordingStore.maximumSavedRecordings {
            try publishFixture(recording(), in: store)
        }
        XCTAssertThrowsError(try store.prepare(id: UUID())) { error in
            guard case StationRecordingError.storageFull = error else { return XCTFail("Unexpected error: \(error)") }
        }
        XCTAssertEqual(try store.list().count, StationRecordingStore.maximumSavedRecordings)
        let saved = try XCTUnwrap(store.list().first)
        try store.delete(id: saved.id)
        let replacement = recording()
        try publishFixture(replacement, in: store)
        XCTAssertEqual(try store.list().count, StationRecordingStore.maximumSavedRecordings)
    }

    func testCorruptPackageHasAnExplicitDeletionPathWhichPreservesValidTests() throws {
        let store = try StationRecordingStore(rootURL: root())
        let valid = recording()
        try publishFixture(valid, in: store)
        let invalid = UUID()
        try FileManager.default.createDirectory(at: store.directoryURL(for: invalid), withIntermediateDirectories: true)
        try Data("{broken".utf8).write(to: store.manifestURL(for: invalid))
        XCTAssertThrowsError(try store.list()) { error in
            guard case StationRecordingError.damagedRecording(let id) = error else { return XCTFail("Expected damaged recording") }
            XCTAssertEqual(id, invalid)
        }
        XCTAssertThrowsError(try store.load(id: invalid))
        try store.delete(id: invalid)
        XCTAssertEqual(try store.list().map(\.id), [valid.id])
    }

    func testInvalidManifestCannotProducePlausibleReplayMetadata() throws {
        let store = try StationRecordingStore(rootURL: root())
        let valid = recording()
        try publishFixture(valid, in: store)
        let original = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(valid)) as? [String: Any])
        let invalidValues: [(String, Any)] = [
            ("exerciseRawValue", "unknown"), ("imageAspectRatio", 1.0), ("orientation", 2),
            ("frameCount", 0), ("frameCount", 676), ("droppedFrameCount", -1),
            ("width", 0), ("durationSeconds", 46), ("actualReps", -1), ("actualReps", 1_001)
        ]
        for (key, value) in invalidValues {
            var invalid = original
            invalid[key] = value
            try JSONSerialization.data(withJSONObject: invalid).write(to: store.manifestURL(for: valid.id), options: .atomic)
            XCTAssertThrowsError(try store.load(id: valid.id), "Accepted invalid \(key)=\(value)")
        }
    }

    func testTimelineStartsWithFirstAcceptedFrameAndRejectsDuplicateBackwardAndLongFrames() throws {
        var timeline = StationRecordingTimeline()
        let first = CMTime(value: 60_000, timescale: 600)
        XCTAssertEqual(try XCTUnwrap(timeline.presentationTime(for: first)), .zero)
        // Asking for a time is not acceptance: a backpressured frame cannot move the origin.
        let accepted = CMTimeAdd(first, CMTime(value: 40, timescale: 600))
        XCTAssertEqual(try XCTUnwrap(timeline.presentationTime(for: accepted)), .zero)
        timeline.accept(accepted)
        XCTAssertNil(timeline.presentationTime(for: first))
        XCTAssertNil(timeline.presentationTime(for: accepted))
        XCTAssertNil(timeline.presentationTime(for: .invalid))
        XCTAssertNil(timeline.presentationTime(for: .positiveInfinity))
        let next = CMTimeAdd(accepted, CMTime(value: 40, timescale: 600))
        XCTAssertEqual(CMTimeGetSeconds(try XCTUnwrap(timeline.presentationTime(for: next))), 1.0 / 15, accuracy: 0.00001)
        timeline.accept(next)
        XCTAssertEqual(timeline.frameCount, 2)
        XCTAssertEqual(timeline.duration, 1.0 / 15, accuracy: 0.00001)
        XCTAssertNil(timeline.presentationTime(for: CMTimeAdd(accepted, CMTime(seconds: 45, preferredTimescale: 600))))
    }

    func testMeasurementIncludesEveryJointWithoutInventingMissingCoordinates() throws {
        let frame = StationComparisonFrame(
            sample: StationPoseSample(timestamp: 20, joints: [
                .leftHip: StationJointPoint(x: 0.4, y: 0.5, confidence: 0.75),
                .rightHip: StationJointPoint(x: .nan, y: .infinity, confidence: .nan)
            ], personCount: 1), applePose: nil, visionMilliseconds: 12, imageAspectRatio: 0.75)
        let measurement = StationRecordingMeasurement(frame: frame, timestampSeconds: 0)
        XCTAssertEqual(measurement.joints.count, 12)
        XCTAssertEqual(measurement.joints["leftHip"]?.x, 0.4)
        XCTAssertNil(measurement.joints["rightHip"]?.x)
        XCTAssertNil(measurement.joints["leftAnkle"]?.confidence)
        let data = try JSONEncoder().encode(measurement)
        XCTAssertEqual(try JSONDecoder().decode(StationRecordingMeasurement.self, from: data), measurement)
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        let joints = try XCTUnwrap(json["joints"] as? [String: [String: Any]])
        XCTAssertTrue(joints["leftAnkle"]?["confidence"] is NSNull)
    }

    func testPlaybackTransformsKeepAllPixelsInUprightBounds() {
        let native = CGRect(x: 0, y: 0, width: 640, height: 480)
        for orientation: CGImagePropertyOrientation in [.up, .down, .left, .right] {
            let transform = StationRecordingWriter.playbackTransform(orientation: orientation, width: 640, height: 480)
            let bounds = native.applying(transform)
            let rotated = orientation == .left || orientation == .right
            XCTAssertEqual(bounds, CGRect(x: 0, y: 0, width: rotated ? 480 : 640, height: rotated ? 640 : 480))
        }
    }

    func testFinishingWithoutFramesCleansUpAndReportsFailureExactlyOnce() async throws {
        let store = try StationRecordingStore(rootURL: root())
        let queue = DispatchQueue(label: "test.station.recording.empty")
        let finished = expectation(description: "Empty recording failed")
        finished.assertForOverFulfill = true
        queue.async {
            do {
                let writer = try StationRecordingWriter(exercise: .squat, store: store)
                writer.finish(reason: .cameraStopped, queue: queue) { result in
                    if case .success = result { XCTFail("Expected no frames error") }
                    finished.fulfill()
                }
                writer.finish(reason: .userStopped, queue: queue) { _ in XCTFail("Finished twice") }
            } catch { XCTFail("\(error)"); finished.fulfill() }
        }
        await fulfillment(of: [finished], timeout: 5)
        XCTAssertTrue(try store.list().isEmpty)
        XCTAssertTrue(try FileManager.default.contentsOfDirectory(at: store.rootURL, includingPropertiesForKeys: nil).isEmpty)
    }

    func testSavedMovieAndMeasurementsContainExactlyTheAcceptedFrames() async throws {
        let store = try StationRecordingStore(rootURL: root())
        let queue = DispatchQueue(label: "test.station.recording.video")
        let saved: StationRecording = try await withCheckedThrowingContinuation { continuation in
            queue.async {
                do {
                    let writer = try StationRecordingWriter(exercise: .squat, store: store)
                    var pixelBuffer: CVPixelBuffer?
                    let result = CVPixelBufferCreate(kCFAllocatorDefault, 64, 48, kCVPixelFormatType_32BGRA,
                                                    [kCVPixelBufferIOSurfacePropertiesKey: [:]] as CFDictionary, &pixelBuffer)
                    guard result == kCVReturnSuccess, let pixelBuffer else {
                        throw StationRecordingError.encodingFailed
                    }
                    CVPixelBufferLockBaseAddress(pixelBuffer, [])
                    if let bytes = CVPixelBufferGetBaseAddress(pixelBuffer) {
                        memset(bytes, 127, CVPixelBufferGetDataSize(pixelBuffer))
                    }
                    CVPixelBufferUnlockBaseAddress(pixelBuffer, [])
                    for index in 0..<10 {
                        let time = CMTime(value: 6_000 + Int64(index * 40), timescale: 600)
                        let frame = StationComparisonFrame(
                            sample: StationPoseSample(timestamp: CMTimeGetSeconds(time), joints: [:], personCount: 0),
                            applePose: nil, visionMilliseconds: 1, imageAspectRatio: 0.75)
                        try writer.append(pixelBuffer: pixelBuffer, time: time, orientation: .right, frame: frame)
                    }
                    writer.finish(reason: .userStopped, queue: queue) { continuation.resume(with: $0) }
                } catch { continuation.resume(throwing: error) }
            }
        }
        XCTAssertGreaterThan(saved.frameCount, 0)
        XCTAssertEqual(saved.frameCount + saved.droppedFrameCount, 10)
        let data = try Data(contentsOf: store.measurementsURL(for: saved.id))
        let rows = try data.split(separator: 0x0a).map { try JSONDecoder().decode(StationRecordingMeasurement.self, from: Data($0)) }
        XCTAssertEqual(rows.count, saved.frameCount)
        XCTAssertEqual(rows.first?.timestampSeconds, 0)
        XCTAssertEqual(try store.load(id: saved.id), saved)

        let asset = try AVURLAsset(url: store.videoURL(for: saved.id))
        let videoTracks = try await asset.loadTracks(withMediaType: .video)
        let audioTracks = try await asset.loadTracks(withMediaType: .audio)
        XCTAssertTrue(audioTracks.isEmpty)
        let track = try XCTUnwrap(videoTracks.first)
        let reader = try AVAssetReader(asset: asset)
        let output = AVAssetReaderTrackOutput(track: track, outputSettings: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA
        ])
        reader.add(output)
        XCTAssertTrue(reader.startReading())
        var times: [Double] = []
        while let sample = output.copyNextSampleBuffer() {
            times.append(CMTimeGetSeconds(CMSampleBufferGetPresentationTimeStamp(sample)))
        }
        XCTAssertEqual(reader.status, .completed)
        XCTAssertEqual(times.count, rows.count)
        for (time, row) in zip(times, rows) { XCTAssertEqual(time, row.timestampSeconds, accuracy: 0.0001) }
        let image = AVAssetImageGenerator(asset: asset)
        image.appliesPreferredTrackTransform = true
        let upright = try image.copyCGImage(at: .zero, actualTime: nil)
        XCTAssertEqual(upright.width, 48)
        XCTAssertEqual(upright.height, 64)
    }
}
