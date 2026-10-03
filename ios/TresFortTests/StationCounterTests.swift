import XCTest
@testable import TresFort

final class StationCounterTests: XCTestCase {
    private enum Side { case left, right }
    private let cycle = [145.0, 130, 100, 50, 50, 50, 50, 100, 130, 145, 170, 170, 170]

    func testEachExerciseCountsOnlyCompleteCycles() {
        for exercise in StationExercise.allCases {
            var counter = StationRepCounter(exercise: exercise)
            var time = 0.0
            feed([170, 170, 170], to: &counter, time: &time)
            XCTAssertEqual(counter.status, .ready, exercise.title)
            feed(cycle, to: &counter, time: &time)
            XCTAssertEqual(counter.count, 1, exercise.title)
            feed(Array(repeating: 170, count: 20), to: &counter, time: &time)
            XCTAssertEqual(counter.count, 1, "An extended hold must not recount: \(exercise.title)")
            feed(cycle, to: &counter, time: &time)
            XCTAssertEqual(counter.count, 2, exercise.title)
        }
    }

    func testStartingFlexedRequiresExtensionBeforeFirstCycle() {
        var counter = StationRepCounter(exercise: .curl)
        var time = 0.0
        feed([50, 50, 50, 100, 170, 170, 170], to: &counter, time: &time)
        XCTAssertEqual(counter.count, 0)
        XCTAssertEqual(counter.status, .ready)
        feed(cycle, to: &counter, time: &time)
        XCTAssertEqual(counter.count, 1)
    }

    func testSlowRepAndLongMidRepPauseRemainOneCycle() {
        var counter = StationRepCounter(exercise: .squat)
        var time = 0.0
        feed([170, 170, 170], to: &counter, time: &time)
        feed([145, 135, 125], to: &counter, time: &time, interval: 0.3)
        feed(Array(repeating: 125, count: 100), to: &counter, time: &time)
        XCTAssertEqual(counter.count, 0)
        XCTAssertEqual(counter.status, .moving)
        feed([100, 100, 100], to: &counter, time: &time)
        feed(Array(repeating: 100, count: 100), to: &counter, time: &time)
        feed([125, 140, 170, 170, 170], to: &counter, time: &time, interval: 0.3)
        XCTAssertEqual(counter.count, 1)
    }

    func testPartialRepetitionsDoNotAccumulate() {
        for exercise in StationExercise.allCases {
            var counter = StationRepCounter(exercise: exercise)
            var time = 0.0
            feed([170, 170, 170], to: &counter, time: &time)
            for _ in 0..<5 {
                feed([130, 125, 125, 130, 170, 170, 170], to: &counter, time: &time)
            }
            XCTAssertEqual(counter.count, 0, exercise.title)
            feed(cycle, to: &counter, time: &time)
            XCTAssertEqual(counter.count, 1, exercise.title)
        }
    }

    func testBriefAngleSpikesCannotEstablishEndpoints() {
        var counter = StationRepCounter(exercise: .curl)
        var time = 0.0
        feed([170, 170, 170], to: &counter, time: &time)
        feed([120, 50, 120, 50, 120, 170, 170, 170], to: &counter, time: &time)
        XCTAssertEqual(counter.count, 0)
        feed(cycle, to: &counter, time: &time)
        XCTAssertEqual(counter.count, 1)
    }

    func testHysteresisAcceptsSmallJitterAroundAnEndpoint() {
        var counter = StationRepCounter(exercise: .curl)
        var time = 0.0
        feed([155, 148, 151], to: &counter, time: &time)
        XCTAssertEqual(counter.status, .ready)
        feed([130, 100, 64, 68, 67, 70, 100, 130, 153, 148, 151], to: &counter, time: &time)
        XCTAssertEqual(counter.count, 1)
    }

    func testTooFastCycleDoesNotBecomeValidByHoldingAtTheEnd() {
        var counter = StationRepCounter(exercise: .curl)
        var time = 0.0
        feed([170, 170, 170], to: &counter, time: &time)
        feed([100] + Array(repeating: 50, count: 9) + Array(repeating: 170, count: 30),
             to: &counter, time: &time, interval: 0.025)
        XCTAssertEqual(counter.count, 0)
        feed(cycle, to: &counter, time: &time)
        XCTAssertEqual(counter.count, 1)
    }

    func testTrackingLossInvalidatesTheInFlightCycle() {
        var counter = StationRepCounter(exercise: .squat)
        var time = 0.0
        feed([170, 170, 170, 130, 100, 100, 100], to: &counter, time: &time)
        counter.process(sample(angle: 100, time: time, personCount: 0))
        time += 0.1
        XCTAssertEqual(counter.status, .trackingLost)
        feed([100, 130, 170, 170, 170], to: &counter, time: &time)
        XCTAssertEqual(counter.count, 0)
        feed(cycle, to: &counter, time: &time)
        XCTAssertEqual(counter.count, 1)
    }

    func testAFrameGapCannotBridgeARepOrEndpointDwell() {
        var counter = StationRepCounter(exercise: .curl)
        var time = 0.0
        feed([170, 170, 170, 100, 50, 50, 50], to: &counter, time: &time)
        time += 1
        counter.process(sample(angle: 170, time: time))
        time += 0.1
        XCTAssertEqual(counter.status, .trackingLost)
        feed([170, 170, 170], to: &counter, time: &time)
        XCTAssertEqual(counter.count, 0)
        XCTAssertEqual(counter.status, .ready)
        feed(cycle, to: &counter, time: &time)
        XCTAssertEqual(counter.count, 1)
    }

    func testASecondPersonInvalidatesTheCycle() {
        var counter = StationRepCounter(exercise: .benchPress)
        var time = 0.0
        feed([170, 170, 170, 130, 90, 90, 90], to: &counter, time: &time)
        counter.process(sample(angle: 90, time: time, personCount: 2))
        time += 0.1
        XCTAssertEqual(counter.status, .multiplePeople)
        feed([130, 170, 170, 170], to: &counter, time: &time)
        XCTAssertEqual(counter.count, 0)
        feed(cycle, to: &counter, time: &time)
        XCTAssertEqual(counter.count, 1)
    }

    func testMissingJointOrLowConfidenceCannotBridgeTheCycle() {
        for invalidation in 0..<3 {
            var counter = StationRepCounter(exercise: .curl)
            var time = 0.0
            feed([170, 170, 170, 100, 50, 50, 50], to: &counter, time: &time)
            var joints = sample(angle: 50, time: time).joints
            if invalidation == 0 {
                joints.removeValue(forKey: .leftWrist)
            } else {
                let old = joints[.leftElbow]!
                joints[.leftElbow] = StationJointPoint(x: old.x, y: old.y,
                                                      confidence: invalidation == 1 ? 0.59 : .nan)
            }
            counter.process(StationPoseSample(timestamp: time, joints: joints, personCount: 1))
            time += 0.1
            XCTAssertEqual(counter.status, .trackingLost)
            feed([170, 170, 170], to: &counter, time: &time)
            XCTAssertEqual(counter.count, 0)
            feed(cycle, to: &counter, time: &time)
            XCTAssertEqual(counter.count, 1)
        }
    }

    func testSideCannotChangeDuringARep() {
        var counter = StationRepCounter(exercise: .curl)
        var time = 0.0
        feed([170, 170, 170, 100, 50, 50, 50], to: &counter, time: &time)
        feed([170], to: &counter, time: &time, side: .right)
        XCTAssertEqual(counter.status, .trackingLost)
        feed([170, 170, 170], to: &counter, time: &time, side: .right)
        XCTAssertEqual(counter.count, 0)
        feed(cycle, to: &counter, time: &time, side: .right)
        XCTAssertEqual(counter.count, 1)
    }

    func testHigherConfidenceOtherSideDoesNotReplaceSelectedSide() {
        var counter = StationRepCounter(exercise: .curl)
        var time = 0.0
        feed([170, 170, 170], to: &counter, time: &time)
        for angle in cycle {
            var joints = sample(angle: 170, time: time, confidence: 0.7).joints
            joints.merge(sample(angle: angle, time: time, side: .right, confidence: 1).joints,
                         uniquingKeysWith: { _, right in right })
            counter.process(StationPoseSample(timestamp: time, joints: joints, personCount: 1))
            time += 0.1
        }
        XCTAssertEqual(counter.count, 0)
        XCTAssertEqual(counter.status, .ready)
    }

    func testDuplicateAndStaleSamplesDoNotAdvanceOrInvalidateNewerState() {
        var counter = StationRepCounter(exercise: .curl)
        var time = 0.0
        feed([170, 170, 170, 100, 50, 50, 50], to: &counter, time: &time)
        let newestTimestamp = time - 0.1
        counter.process(sample(angle: 170, time: newestTimestamp, personCount: 2))
        counter.process(sample(angle: 170, time: newestTimestamp - 0.3, personCount: 0))
        XCTAssertEqual(counter.status, .moving)
        feed([100, 130, 170, 170, 170], to: &counter, time: &time)
        XCTAssertEqual(counter.count, 1)
    }

    func testInvalidTimestampsInvalidateWithoutPoisoningTheClock() {
        for invalidTime in [Double.nan, Double.infinity, -1] {
            var counter = StationRepCounter(exercise: .curl)
            var time = 0.0
            feed([170, 170, 170, 100, 50, 50, 50], to: &counter, time: &time)
            counter.process(sample(angle: 170, time: invalidTime))
            XCTAssertEqual(counter.status, .trackingLost)
            feed([170, 170, 170], to: &counter, time: &time)
            XCTAssertEqual(counter.count, 0)
            feed(cycle, to: &counter, time: &time)
            XCTAssertEqual(counter.count, 1)
        }
    }

    func testNonfiniteAndDegenerateCoordinatesDoNotCount() {
        for invalidation in 0..<4 {
            var counter = StationRepCounter(exercise: .curl)
            var time = 0.0
            feed([170, 170, 170, 100, 50, 50, 50], to: &counter, time: &time)
            var joints = sample(angle: 170, time: time).joints
            let elbow = joints[.leftElbow]!
            switch invalidation {
            case 0: joints[.leftWrist] = StationJointPoint(x: .nan, y: 0.5, confidence: 1)
            case 1: joints[.leftWrist] = StationJointPoint(x: 0.5, y: .infinity, confidence: 1)
            case 2: joints[.leftWrist] = elbow
            default: joints[.leftShoulder] = elbow
            }
            counter.process(StationPoseSample(timestamp: time, joints: joints, personCount: 1))
            time += 0.1
            XCTAssertEqual(counter.status, .trackingLost)
            feed([170, 170, 170], to: &counter, time: &time)
            XCTAssertEqual(counter.count, 0)
        }
    }

    func testResetClearsCountPhaseAndTimestampForANewExercise() {
        var counter = StationRepCounter(exercise: .curl)
        var time = 20.0
        feed([170, 170, 170] + cycle, to: &counter, time: &time)
        XCTAssertEqual(counter.count, 1)
        counter.reset(exercise: .squat)
        XCTAssertEqual(counter.count, 0)
        XCTAssertEqual(counter.status, .seekingPosition)
        time = 0
        feed([170, 170, 170] + cycle, to: &counter, time: &time)
        XCTAssertEqual(counter.count, 1)
    }

    // Both sets of joints are provided for one side so the same fixtures exercise
    // knee and elbow geometry. Right-side x exceeds 1, as aspect-correct landscape
    // camera coordinates can. No raw camera frame or human recording is needed.
    private func sample(angle: Double, time: Double, side: Side = .left,
                        confidence: Float = 0.9, personCount: Int = 1) -> StationPoseSample {
        let x = side == .left ? 0.5 : 1.3
        let radians = angle * .pi / 180
        let first = StationJointPoint(x: x, y: 0.8, confidence: confidence)
        let pivot = StationJointPoint(x: x, y: 0.5, confidence: confidence)
        let last = StationJointPoint(x: x + sin(radians) * 0.25,
                                     y: 0.5 + cos(radians) * 0.25, confidence: confidence)
        let joints: [StationJoint: StationJointPoint] = side == .left
            ? [.leftShoulder: first, .leftElbow: pivot, .leftWrist: last,
               .leftHip: first, .leftKnee: pivot, .leftAnkle: last]
            : [.rightShoulder: first, .rightElbow: pivot, .rightWrist: last,
               .rightHip: first, .rightKnee: pivot, .rightAnkle: last]
        return StationPoseSample(timestamp: time, joints: joints, personCount: personCount)
    }

    private func feed(_ angles: [Double], to counter: inout StationRepCounter,
                      time: inout Double, interval: Double = 0.1, side: Side = .left) {
        for angle in angles {
            counter.process(sample(angle: angle, time: time, side: side))
            time += interval
        }
    }
}
