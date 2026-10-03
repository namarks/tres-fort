#if DEBUG
import XCTest
@testable import TresFort

@MainActor
final class StationDiagnosticsTests: XCTestCase {
    private func pose(timestamp: Double = 1, confidence: Float = 1) -> StationDiagnosticPose {
        let joints: [StationJoint: StationJointPoint] = [
            .leftHip: .init(x: 0.3, y: 0.4, confidence: confidence),
            .rightHip: .init(x: 0.5, y: 0.4, confidence: confidence),
            .leftShoulder: .init(x: 0.3, y: 0.8, confidence: confidence),
            .rightShoulder: .init(x: 0.5, y: 0.8, confidence: confidence)
        ]
        return StationDiagnosticPose(frame: StationComparisonFrame(
            sample: StationPoseSample(timestamp: timestamp, joints: joints, personCount: 1),
            applePose: nil, visionMilliseconds: 4, imageAspectRatio: 1))
    }

    func testExplicitOptInAndDisableClearAllRetainedDiagnostics() {
        var lines: [String] = []
        let diagnostics = StationDiagnostics(now: { 0 }, emit: { lines.append($0) })
        diagnostics.record(pose: pose(), snapshot: .init())
        XCTAssertTrue(lines.isEmpty)
        XCTAssertTrue(diagnostics.history.isEmpty)
        diagnostics.isEnabled = true
        diagnostics.record(pose: pose(), snapshot: .init())
        XCTAssertEqual(lines.count, 1)
        XCTAssertNotNil(diagnostics.latest)
        diagnostics.isEnabled = false
        XCTAssertNil(diagnostics.latest)
        XCTAssertTrue(diagnostics.history.isEmpty)
        diagnostics.record(pose: pose(), snapshot: .init())
        XCTAssertEqual(lines.count, 1)
    }

    func testRejectedFrameIsObservedBeforeAdmissionAndEmitsSameFrameDecision() {
        var lines: [String] = []
        let diagnostics = StationDiagnostics(now: { 0 }, emit: { lines.append($0) })
        diagnostics.isEnabled = true
        defer { diagnostics.isEnabled = false }
        let model = StationComparisonModel()
        model.start(exercise: .squat)
        let frame = StationComparisonFrame(
            sample: StationPoseSample(timestamp: 7, joints: [:], personCount: 0),
            applePose: nil, visionMilliseconds: 3)
        diagnostics.observe(frame: frame, model: model)
        XCTAssertNil(diagnostics.latest, "Wait for this frame's actual admission decision")
        model.process(frame)
        XCTAssertEqual(diagnostics.latest?.pose?.timestamp, 7)
        XCTAssertEqual(diagnostics.latest?.pose?.personCount, 0)
        XCTAssertEqual(diagnostics.latest?.comparison.admission, "no_person")
        XCTAssertEqual(diagnostics.latest?.comparison.accepted, 0)
        XCTAssertEqual(diagnostics.latest?.comparison.rejected, 1)
        XCTAssertEqual(diagnostics.latest?.observedFrames, 1)
        XCTAssertEqual(model.customCount, 0)
        XCTAssertNil(model.appleCount)
        XCTAssertEqual(lines.count, 1)
    }

    func testTransitionsAreCoalescedAndEmissionNeverExceedsTwoHz() throws {
        var time = 0.0, lines: [String] = []
        let diagnostics = StationDiagnostics(now: { time }, emit: { lines.append($0) })
        diagnostics.isEnabled = true
        defer { diagnostics.isEnabled = false }
        diagnostics.record(pose: pose(), snapshot: .init())
        for index in 1..<50 {
            time = Double(index) / 100
            var snapshot = StationComparisonDiagnosticSnapshot()
            snapshot.state = "state\(index)"
            diagnostics.record(pose: pose(), snapshot: snapshot)
        }
        XCTAssertEqual(lines.count, 1)
        time = 0.5
        diagnostics.flush()
        XCTAssertEqual(lines.count, 2)
        XCTAssertEqual(diagnostics.latest?.comparison.state, "state49")
        XCTAssertLessThanOrEqual(diagnostics.latest?.changes.count ?? 0, 8)
        XCTAssertTrue(lines.allSatisfy { $0.hasPrefix("STATION_DIAGNOSTIC ") && !$0.contains("\n") })
        let encoded = String(try XCTUnwrap(lines.last).dropFirst("STATION_DIAGNOSTIC ".count))
        let decoded = try JSONDecoder().decode(StationDiagnosticSample.self, from: Data(encoded.utf8))
        XCTAssertEqual(decoded, diagnostics.latest)
    }

    func testHistoryExpiresAfterSixtySecondsAndStaysBounded() {
        var time = 0.0
        let diagnostics = StationDiagnostics(now: { time }, emit: { _ in })
        diagnostics.isEnabled = true
        defer { diagnostics.isEnabled = false }
        for index in 0...300 {
            time = Double(index) * 0.5
            diagnostics.record(pose: pose(), snapshot: .init())
        }
        XCTAssertLessThanOrEqual(diagnostics.history.count, 121)
        XCTAssertTrue(diagnostics.history.allSatisfy { time - $0.elapsedSeconds <= 60 })
        time += 61
        diagnostics.flush()
        XCTAssertTrue(diagnostics.history.isEmpty)
        XCTAssertNil(diagnostics.latest)
    }

    func testAngleExtremaIncludeFramesBetweenEmissionsButExcludeStaleCounterMeasurements() {
        var time = 0.0
        let diagnostics = StationDiagnostics(now: { time }, emit: { _ in })
        diagnostics.isEnabled = true
        defer { diagnostics.isEnabled = false }
        diagnostics.record(pose: pose(), snapshot: .init())
        for (index, angle) in [160.0, 80, 120].enumerated() {
            time = Double(index + 1) * 0.1
            var snapshot = StationComparisonDiagnosticSnapshot()
            snapshot.custom = .init(timestamp: 1, angle: angle, phase: "returning")
            diagnostics.record(pose: pose(), snapshot: snapshot)
        }
        time = 0.4
        var stale = StationComparisonDiagnosticSnapshot()
        stale.custom = .init(timestamp: 0, angle: 20, phase: "returning")
        diagnostics.record(pose: pose(), snapshot: stale)
        time = 0.5
        diagnostics.flush()
        XCTAssertEqual(diagnostics.latest?.angleMinimum, 80)
        XCTAssertEqual(diagnostics.latest?.angleMaximum, 160)
        XCTAssertNil(diagnostics.latest?.comparison.custom.angle)
    }

    func testFrontSignalsUseConfidentMidpointsAndMissingJointsAreNamed() throws {
        let clear = pose()
        XCTAssertEqual(try XCTUnwrap(clear.hipHeight), 0.4, accuracy: 0.001)
        XCTAssertEqual(try XCTUnwrap(clear.shoulderHeight), 0.8, accuracy: 0.001)
        XCTAssertEqual(try XCTUnwrap(clear.torsoScale), 0.4, accuracy: 0.001)
        XCTAssertTrue(clear.missingJoints.contains("leftKnee"))
        XCTAssertEqual(clear.confidences.count, 4)
        let unclear = pose(confidence: 0.5)
        XCTAssertNil(unclear.hipHeight)
        XCTAssertNil(unclear.shoulderHeight)
        XCTAssertNil(unclear.torsoScale)
        XCTAssertEqual(unclear.unclearJoints.count, 4)
    }

    func testNonfiniteInputCannotBreakJSONAndNoFullPoseCoordinatesAreRetained() throws {
        let value = pose(timestamp: .nan, confidence: .nan)
        XCTAssertNil(value.timestamp)
        XCTAssertTrue(value.confidences.isEmpty)
        let data = try JSONEncoder().encode(value)
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertNil(object["joints"])
        XCTAssertNil(object["applePose"])
        XCTAssertNil(object["image"])
        XCTAssertEqual(value.missingJoints.count, 12)
    }
}
#endif
