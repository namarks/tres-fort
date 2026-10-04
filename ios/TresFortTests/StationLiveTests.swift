import XCTest
@testable import TresFort

@MainActor
final class StationLiveTests: XCTestCase {
    private func frame(_ angle: Double, at time: Double, people: Int = 1,
                       detector: StationPoseDetector = .mediaPipe) -> StationComparisonFrame {
        let radians = angle * .pi / 180
        let joints: [StationJoint: StationJointPoint] = [
            .leftHip: .init(x: 0, y: 1, confidence: 0.95),
            .leftKnee: .init(x: 0, y: 0, confidence: 0.95),
            .leftAnkle: .init(x: sin(radians), y: cos(radians), confidence: 0.95)
        ]
        return StationComparisonFrame(sample: .init(timestamp: time, joints: joints, personCount: people),
                                      inferenceMilliseconds: 25, imageAspectRatio: 1, detector: detector)
    }

    func testMediaPipeCountsWithoutAnApplePoseOrWindowWarmup() {
        let model = StationLiveModel()
        model.start(exercise: .squat)
        let angles = [170.0, 170, 170, 140, 100, 100, 100, 140, 170, 170, 170]
        for (i, angle) in angles.enumerated() {
            // Flexion start to extension arrival is 0.60 s, above the 0.55 s
            // minimum; endpoint confirmation time does not lengthen a rep.
            let frame = frame(angle, at: Double(i) * 0.12)
            XCTAssertNil(frame.applePose)
            model.process(frame)
        }
        XCTAssertEqual(model.count, 1)
        XCTAssertEqual(model.observedFrames, 11)
        XCTAssertEqual(model.inferenceMilliseconds, 25)
        XCTAssertFalse(model.hasIncompleteCoverage)
        model.stop()
        XCTAssertEqual(model.state, .finished)
    }

    func testASecondPersonStopsTheTrialUntilExplicitRestart() {
        let model = StationLiveModel()
        model.start(exercise: .squat)
        model.process(frame(170, at: 0))
        model.process(frame(100, at: 0.1, people: 2))
        XCTAssertTrue(model.state.isTerminal)
        XCTAssertTrue(model.hasIncompleteCoverage)
        XCTAssertEqual(model.status, .multiplePeople)
        model.process(frame(170, at: 0.2))
        XCTAssertEqual(model.observedFrames, 1)
        model.start(exercise: .squat)
        XCTAssertEqual(model.observedFrames, 0)
        XCTAssertFalse(model.hasIncompleteCoverage)
    }

    func testCaptureGapCannotCompleteAnUnseenRepAndStaleFrameIsIgnored() {
        let model = StationLiveModel()
        model.start(exercise: .squat)
        for (i, angle) in [170.0, 170, 170, 140, 100, 100, 100].enumerated() {
            model.process(frame(angle, at: Double(i) * 0.1))
        }
        model.process(frame(170, at: 2))
        XCTAssertTrue(model.hasIncompleteCoverage)
        XCTAssertEqual(model.count, 0)
        let observed = model.observedFrames
        model.process(frame(100, at: 0.8))
        XCTAssertEqual(model.observedFrames, observed)
        XCTAssertEqual(model.count, 0)
    }

    func testSourceChangeRequiresRestartRatherThanSilentFallback() {
        let model = StationLiveModel()
        model.start(exercise: .squat)
        model.process(frame(170, at: 0, detector: .appleVision))
        XCTAssertTrue(model.state.isTerminal)
        XCTAssertEqual(model.observedFrames, 0)
    }

    func testMediaPipeMeasurementIdentifiesItsSourceWithoutMislabelingVisionTime() throws {
        let row = StationRecordingMeasurement(frame: frame(170, at: 12), timestampSeconds: 0)
        let data = try JSONEncoder().encode(row)
        let decoded = try JSONDecoder().decode(StationRecordingMeasurement.self, from: data)
        XCTAssertEqual(decoded.detector, .mediaPipe)
        XCTAssertEqual(decoded.inferenceMilliseconds, 25)
        XCTAssertNil(decoded.visionMilliseconds)
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertNil(json["visionMilliseconds"])
    }

    func testLegacyMeasurementRemainsReadable() throws {
        let original = StationRecordingMeasurement(frame: frame(170, at: 12), timestampSeconds: 0)
        let data = try JSONEncoder().encode(original)
        var json = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        json.removeValue(forKey: "detector")
        json.removeValue(forKey: "inferenceMilliseconds")
        json["visionMilliseconds"] = 6.0
        let legacy = try JSONDecoder().decode(StationRecordingMeasurement.self,
            from: JSONSerialization.data(withJSONObject: json))
        XCTAssertNil(legacy.detector)
        XCTAssertEqual(legacy.visionMilliseconds, 6)
    }
}
