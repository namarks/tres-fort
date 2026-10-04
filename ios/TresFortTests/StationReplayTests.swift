import AVFoundation
import XCTest
@testable import TresFort

final class StationReplayTests: XCTestCase {
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
}
