import XCTest
@testable import TresFort

final class StationHoldTimerTests: XCTestCase {
    func testPlankAndWallSitWaitForStablePositionThenCountObservedSeconds() {
        for kind in [StationHoldKind.plank, .wallSit] {
            var timer = StationHoldTimer(kind: kind, targetSeconds: 2)
            timer.process(pose(kind, at: 0))
            XCTAssertEqual(timer.state, .idle)
            timer.start()
            feed(&timer, kind, from: 0, through: 1)
            XCTAssertEqual(timer.state, .holding)
            XCTAssertEqual(timer.elapsed, 0)
            feed(&timer, kind, from: 1.25, through: 3)
            XCTAssertEqual(timer.state, .reached)
            XCTAssertEqual(timer.remaining, 0)
            timer.process(pose(kind, at: 4))
            XCTAssertEqual(timer.elapsed, 2)
            timer.start()
            XCTAssertEqual(timer.elapsed, 0)
            XCTAssertEqual(timer.state, .seeking)
        }
    }

    func testSlowWallSitDescentRestartsAcquisitionAndReacquisition() {
        for reacquiring in [false, true] {
            var timer = StationHoldTimer(kind: .wallSit, targetSeconds: 30)
            timer.start()
            if reacquiring {
                feed(&timer, .wallSit, from: 0, through: 2)
                timer.process(.init(timestamp: 2.25, joints: [:], personCount: 0))
            }
            let start = reacquiring ? 2.5 : 0.0
            let credited = timer.elapsed
            // Each 0.01 step is smaller than the jitter allowance, but the
            // accumulated descent must not qualify as a steady one-second hold.
            for frame in 0...12 {
                let sample = loweringWallSit(at: start + Double(frame) * 0.25, offset: 0.06 - Double(frame) * 0.01)
                timer.process(sample)
                XCTAssertEqual(timer.state, .stabilizing, "Every frame remains valid wall-sit geometry")
                XCTAssertEqual(timer.elapsed, credited)
            }
            for frame in 1...3 {
                timer.process(loweringWallSit(at: start + 3 + Double(frame) * 0.25, offset: -0.06))
                XCTAssertEqual(timer.state, .stabilizing)
            }
            timer.process(loweringWallSit(at: start + 4, offset: -0.06))
            XCTAssertEqual(timer.state, .holding)
            XCTAssertEqual(timer.elapsed, credited, "Settling time is never credited")
            timer.process(loweringWallSit(at: start + 4.25, offset: -0.06))
            XCTAssertEqual(timer.elapsed, credited + 0.25)
        }
    }

    func testSmallPoseJitterAllowsAcquisitionAtDifferentBodyScales() {
        for kind in [StationHoldKind.plank, .wallSit] {
            for scale in [0.5, 1.0] {
                var timer = StationHoldTimer(kind: kind, targetSeconds: 30)
                timer.start()
                for frame in 0...4 {
                    let sample = pose(kind, at: Double(frame) * 0.25)
                    let jitter = frame.isMultiple(of: 2) ? 0.002 : -0.002
                    let joints = sample.joints.mapValues {
                        StationJointPoint(x: ($0.x + jitter) * scale, y: ($0.y - jitter) * scale, confidence: $0.confidence)
                    }
                    timer.process(.init(timestamp: sample.timestamp, joints: joints, personCount: 1))
                }
                XCTAssertEqual(timer.state, .holding)
                XCTAssertEqual(timer.elapsed, 0)
            }
        }
    }

    func testLostJointsPositionAndCaptureGapsPauseWithoutCreditingUnseenTime() {
        for interruption in 0...3 {
            var timer = StationHoldTimer(kind: .plank, targetSeconds: 30)
            timer.start()
            feed(&timer, .plank, from: 0, through: 2)
            XCTAssertEqual(timer.elapsed, 1)
            var sample = pose(.plank, at: interruption == 3 ? 5 : 2.25)
            if interruption == 0 { sample = .init(timestamp: sample.timestamp, joints: [:], personCount: 1) }
            if interruption == 1 { sample = .init(timestamp: sample.timestamp, joints: sample.joints, personCount: 0) }
            if interruption == 2 { sample = pose(.wallSit, at: sample.timestamp) }
            timer.process(sample)
            XCTAssertEqual(timer.state, .paused)
            XCTAssertTrue(timer.wasInterrupted)
            XCTAssertEqual(timer.elapsed, 1)
            let resume = sample.timestamp + 0.25
            feed(&timer, .plank, from: resume, through: resume + 1)
            XCTAssertEqual(timer.elapsed, 1, "Reacquisition dwell must not count")
            timer.process(pose(.plank, at: resume + 1.25))
            XCTAssertEqual(timer.elapsed, 1.25)
        }
    }

    func testMultiplePeopleAndLifecycleInvalidationRequireExplicitRestart() {
        for personCount in [1, 2] {
            var timer = StationHoldTimer(kind: .wallSit, targetSeconds: 30)
            timer.start()
            feed(&timer, .wallSit, from: 0, through: 2)
            if personCount == 2 {
                let p = pose(.wallSit, at: 2.25)
                timer.process(.init(timestamp: p.timestamp, joints: p.joints, personCount: 2))
            } else { timer.invalidate() }
            XCTAssertEqual(timer.state, .invalidated)
            timer.process(pose(.wallSit, at: 2.5))
            XCTAssertEqual(timer.elapsed, 1)
            timer.start()
            XCTAssertEqual(timer.elapsed, 0)
        }
    }

    func testCannotSwitchVisibleSidesWithoutNewDwell() {
        var timer = StationHoldTimer(kind: .plank, targetSeconds: 30)
        timer.start()
        feed(&timer, .plank, from: 0, through: 2)
        timer.process(pose(.plank, at: 2.25, right: true))
        XCTAssertEqual(timer.elapsed, 1)
        XCTAssertEqual(timer.state, .paused)
        for t in stride(from: 2.5, through: 3.5, by: 0.25) { timer.process(pose(.plank, at: t, right: true)) }
        XCTAssertEqual(timer.elapsed, 1)
        timer.process(pose(.plank, at: 3.75, right: true))
        XCTAssertEqual(timer.elapsed, 1.25)
    }

    func testStaleFramesCannotAddTimeAndNonfiniteInputCannotArm() {
        var timer = StationHoldTimer(kind: .plank, targetSeconds: 30)
        timer.start()
        feed(&timer, .plank, from: 0, through: 2)
        timer.process(pose(.plank, at: 1.5))
        timer.process(pose(.plank, at: 2))
        XCTAssertEqual(timer.elapsed, 1)
        timer.process(pose(.plank, at: .nan))
        XCTAssertEqual(timer.state, .invalidated)
        timer.start()
        var joints = pose(.plank, at: 0).joints
        joints[.leftHip] = .init(x: .nan, y: 0.4, confidence: 1)
        for t in stride(from: 0.0, through: 3, by: 0.25) {
            timer.process(.init(timestamp: t, joints: joints, personCount: 1))
        }
        XCTAssertEqual(timer.elapsed, 0)
        XCTAssertEqual(timer.state, .seeking)
    }

    func testLyingDownStraightArmsBentKneesAndUnclearJointsDoNotStartPlank() {
        for change in 0...3 {
            var timer = StationHoldTimer(kind: .plank, targetSeconds: 30)
            timer.start()
            var joints = pose(.plank, at: 0).joints
            switch change {
            case 0: joints[.leftShoulder] = .init(x: 0.25, y: 0.2, confidence: 1)
            case 1: joints[.leftWrist] = .init(x: 0.25, y: 0.05, confidence: 1)
            case 2: joints[.leftKnee] = .init(x: 0.5, y: 0.05, confidence: 1)
            default: joints[.leftAnkle] = .init(x: 0.9, y: 0.2, confidence: 0.4)
            }
            for t in stride(from: 0.0, through: 3, by: 0.25) {
                timer.process(.init(timestamp: t, joints: joints, personCount: 1))
            }
            XCTAssertEqual(timer.elapsed, 0)
            XCTAssertEqual(timer.state, .seeking)
        }
    }

    func testStopFreezesCountdownAndTargetIsBounded() {
        XCTAssertEqual(StationHoldTimer(kind: .plank, targetSeconds: -1).targetSeconds, 1)
        XCTAssertEqual(StationHoldTimer(kind: .plank, targetSeconds: Int.max).targetSeconds, 3600)
        var timer = StationHoldTimer(kind: .plank, targetSeconds: 30)
        timer.start()
        feed(&timer, .plank, from: 0, through: 2)
        timer.stop()
        timer.process(pose(.plank, at: 2.25))
        XCTAssertEqual(timer.elapsed, 1)
        XCTAssertEqual(timer.state, .stopped)
    }

    private func loweringWallSit(at time: Double, offset: Double) -> StationPoseSample {
        let sample = pose(.wallSit, at: time)
        var joints = sample.joints
        for joint in [StationJoint.leftShoulder, .leftHip] {
            let point = joints[joint]!
            joints[joint] = .init(x: point.x, y: point.y + offset, confidence: point.confidence)
        }
        return .init(timestamp: time, joints: joints, personCount: 1)
    }

    private func feed(_ timer: inout StationHoldTimer, _ kind: StationHoldKind, from: Double, through: Double) {
        for t in stride(from: from, through: through, by: 0.25) { timer.process(pose(kind, at: t)) }
    }

    private func pose(_ kind: StationHoldKind, at time: Double, right: Bool = false) -> StationPoseSample {
        let names: [StationJoint] = right
            ? [.rightShoulder, .rightHip, .rightKnee, .rightAnkle, .rightElbow, .rightWrist]
            : [.leftShoulder, .leftHip, .leftKnee, .leftAnkle, .leftElbow, .leftWrist]
        let coordinates: [(Double, Double)] = kind == .plank
            ? [(0.25, 0.45), (0.5, 0.354), (0.7, 0.277), (0.9, 0.2), (0.25, 0.2), (0.1, 0.2)]
            : [(0.3, 0.85), (0.3, 0.55), (0.6, 0.55), (0.6, 0.2), (0.35, 0.65), (0.55, 0.65)]
        return .init(timestamp: time, joints: Dictionary(uniqueKeysWithValues: zip(names, coordinates).map {
            ($0.0, StationJointPoint(x: $0.1.0, y: $0.1.1, confidence: 0.95))
        }), personCount: 1)
    }
}
