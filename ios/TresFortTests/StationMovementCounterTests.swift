import XCTest
@testable import TresFort

final class StationMovementCounterTests: XCTestCase {
    private let cycle = [145.0, 130, 100, 50, 50, 50, 50, 100, 130, 145, 170, 170, 170]

    func testEitherWorkingArmCountsDespiteClearerRestingArm() {
        for movingLeft in [true, false] {
            var counter = StationMovementCounter(exercise: .curl)
            var time = 0.0
            feed(Array(repeating: (170.0, 170.0), count: 3), to: &counter, time: &time,
                 leftConfidence: movingLeft ? 0.8 : 0.95, rightConfidence: movingLeft ? 0.95 : 0.8)
            for _ in 0..<3 {
                feed(cycle.map { movingLeft ? ($0, 170) : (170, $0) }, to: &counter, time: &time,
                     leftConfidence: movingLeft ? 0.8 : 0.95, rightConfidence: movingLeft ? 0.95 : 0.8)
            }
            XCTAssertEqual(counter.leftCount, movingLeft ? 3 : 0)
            XCTAssertEqual(counter.rightCount, movingLeft ? 0 : 3)
            XCTAssertEqual(counter.count, 3)
            XCTAssertEqual(counter.leftStatus, .ready)
            XCTAssertEqual(counter.rightStatus, .ready)
        }
    }

    func testAlternatingCurlsRetainSeparateArmCounts() {
        var counter = StationMovementCounter(exercise: .curl)
        var time = 0.0
        feed(Array(repeating: (170.0, 170.0), count: 3), to: &counter, time: &time)
        for rep in 1...3 {
            feed(cycle.map { ($0, 170) }, to: &counter, time: &time)
            XCTAssertEqual(counter.leftCount, rep)
            XCTAssertEqual(counter.rightCount, rep - 1)
            feed(cycle.map { (170, $0) }, to: &counter, time: &time)
            XCTAssertEqual(counter.leftCount, rep)
            XCTAssertEqual(counter.rightCount, rep)
        }
        XCTAssertEqual(counter.count, 3, "Legacy scalar is max per arm, not the six alternating arm repetitions")
    }

    func testSimultaneousCurlsDoNotDoubleTheCompatibilityCount() {
        var counter = StationMovementCounter(exercise: .curl)
        var time = 0.0
        feed(Array(repeating: (170.0, 170.0), count: 3), to: &counter, time: &time)
        for _ in 0..<3 { feed(cycle.map { ($0, $0) }, to: &counter, time: &time) }
        XCTAssertEqual(counter.leftCount, 3)
        XCTAssertEqual(counter.rightCount, 3)
        XCTAssertEqual(counter.count, 3)
    }

    func testLossOfOneArmDoesNotDiscardTheOtherArmsCycle() {
        for lostLeft in [true, false] {
            var counter = StationMovementCounter(exercise: .curl)
            var time = 0.0
            feed(Array(repeating: (170.0, 170.0), count: 3), to: &counter, time: &time)
            feed([130, 100, 50, 50, 50].map { ($0, $0) }, to: &counter, time: &time)
            counter.process(sample(left: 50, right: 50, time: time,
                                   leftConfidence: lostLeft ? 0.59 : 0.9,
                                   rightConfidence: lostLeft ? 0.9 : 0.59))
            time += 0.1
            XCTAssertEqual(lostLeft ? counter.leftStatus : counter.rightStatus, .trackingLost)
            XCTAssertEqual(lostLeft ? counter.rightStatus : counter.leftStatus, .moving)
            feed([50, 100, 130, 170, 170, 170].map { ($0, $0) }, to: &counter, time: &time)
            XCTAssertEqual(counter.leftCount, lostLeft ? 0 : 1)
            XCTAssertEqual(counter.rightCount, lostLeft ? 1 : 0)
        }
    }

    func testEndpointsFromDifferentArmsCannotCompleteACycle() {
        var counter = StationMovementCounter(exercise: .curl)
        var time = 0.0
        // Left is extended while right starts flexed; then they exchange poses.
        // Neither arm has independently completed extension -> flexion -> extension.
        feed(Array(repeating: (170.0, 50.0), count: 3), to: &counter, time: &time)
        feed([(130, 100), (100, 130), (50, 170), (50, 170), (50, 170)], to: &counter, time: &time)
        XCTAssertEqual(counter.leftCount, 0)
        XCTAssertEqual(counter.rightCount, 0)
        XCTAssertEqual(counter.count, 0)
    }

    func testMultiplePeopleAndGapsInvalidateBothInFlightCycles() {
        for frameGap in [false, true] {
            var counter = StationMovementCounter(exercise: .curl)
            var time = 0.0
            feed(Array(repeating: (170.0, 170.0), count: 3), to: &counter, time: &time)
            feed([130, 100, 50, 50, 50].map { ($0, $0) }, to: &counter, time: &time)
            if frameGap { time += 1 }
            counter.process(sample(left: 50, right: 50, time: time, personCount: frameGap ? 1 : 2))
            time += 0.1
            XCTAssertEqual(counter.leftStatus, frameGap ? .trackingLost : .multiplePeople)
            XCTAssertEqual(counter.rightStatus, frameGap ? .trackingLost : .multiplePeople)
            feed([100, 130, 170, 170, 170].map { ($0, $0) }, to: &counter, time: &time)
            XCTAssertEqual(counter.leftCount, 0)
            XCTAssertEqual(counter.rightCount, 0)
            feed(cycle.map { ($0, $0) }, to: &counter, time: &time)
            XCTAssertEqual(counter.leftCount, 1)
            XCTAssertEqual(counter.rightCount, 1)
        }
    }

    func testOtherExercisesKeepOneCounterAndNoArmBreakdown() {
        for exercise in [StationExercise.squat, .benchPress] {
            var counter = StationMovementCounter(exercise: exercise)
            var time = 0.0
            feed(Array(repeating: (170.0, 170.0), count: 3), to: &counter, time: &time)
            feed(cycle.map { ($0, $0) }, to: &counter, time: &time)
            XCTAssertEqual(counter.count, 1)
            XCTAssertEqual(counter.status, .ready)
            XCTAssertNil(counter.leftCount)
            XCTAssertNil(counter.rightCount)
            XCTAssertNil(counter.leftStatus)
            XCTAssertNil(counter.rightStatus)
        }
    }

    func testResetClearsBothArmsAndChangesExercise() {
        var counter = StationMovementCounter(exercise: .curl)
        var time = 0.0
        feed((Array(repeating: 170.0, count: 3) + cycle).map { ($0, $0) }, to: &counter, time: &time)
        XCTAssertEqual(counter.leftCount, 1)
        XCTAssertEqual(counter.rightCount, 1)
        counter.reset(exercise: .squat)
        XCTAssertEqual(counter.count, 0)
        XCTAssertNil(counter.leftCount)
        counter.reset(exercise: .curl)
        XCTAssertEqual(counter.leftCount, 0)
        XCTAssertEqual(counter.rightCount, 0)
        XCTAssertEqual(counter.leftStatus, .seekingPosition)
        XCTAssertEqual(counter.rightStatus, .seekingPosition)
        time = 0
        feed((Array(repeating: 170.0, count: 3) + cycle).map { ($0, $0) }, to: &counter, time: &time)
        XCTAssertEqual(counter.leftCount, 1)
        XCTAssertEqual(counter.rightCount, 1)
    }

#if DEBUG
    func testCurlDiagnosticsKeepMovingAndRestingArmsSeparate() throws {
        var counter = StationMovementCounter(exercise: .curl)
        var time = 0.0
        feed(Array(repeating: (170.0, 170.0), count: 3), to: &counter, time: &time)
        feed([130, 100, 50, 50, 50].map { ($0, 170) }, to: &counter, time: &time)
        XCTAssertNil(counter.diagnosticSnapshot)
        let left = try XCTUnwrap(counter.leftDiagnosticSnapshot)
        let right = try XCTUnwrap(counter.rightDiagnosticSnapshot)
        XCTAssertEqual(try XCTUnwrap(left.angle), 50, accuracy: 0.0001)
        XCTAssertEqual(try XCTUnwrap(right.angle), 170, accuracy: 0.0001)
        XCTAssertEqual(left.phase, "returning")
        XCTAssertEqual(right.phase, "armed")
        counter.reset(exercise: .squat)
        XCTAssertNotNil(counter.diagnosticSnapshot)
        XCTAssertNil(counter.leftDiagnosticSnapshot)
        XCTAssertNil(counter.rightDiagnosticSnapshot)
    }
#endif

    private func sample(left: Double, right: Double, time: Double,
                        leftConfidence: Float = 0.8, rightConfidence: Float = 0.95,
                        personCount: Int = 1) -> StationPoseSample {
        func points(_ angle: Double, left: Bool, confidence: Float) -> [StationJoint: StationJointPoint] {
            let x = left ? 0.5 : 1.3
            let radians = angle * .pi / 180
            let first = StationJointPoint(x: x, y: 0.8, confidence: confidence)
            let pivot = StationJointPoint(x: x, y: 0.5, confidence: confidence)
            let last = StationJointPoint(x: x + sin(radians) * 0.25,
                                         y: 0.5 + cos(radians) * 0.25, confidence: confidence)
            return left
                ? [.leftShoulder: first, .leftElbow: pivot, .leftWrist: last,
                   .leftHip: first, .leftKnee: pivot, .leftAnkle: last]
                : [.rightShoulder: first, .rightElbow: pivot, .rightWrist: last,
                   .rightHip: first, .rightKnee: pivot, .rightAnkle: last]
        }
        var joints = points(left, left: true, confidence: leftConfidence)
        joints.merge(points(right, left: false, confidence: rightConfidence), uniquingKeysWith: { _, right in right })
        return StationPoseSample(timestamp: time, joints: joints, personCount: personCount)
    }

    private func feed(_ angles: [(Double, Double)], to counter: inout StationMovementCounter,
                      time: inout Double, leftConfidence: Float = 0.8, rightConfidence: Float = 0.95) {
        for (left, right) in angles {
            counter.process(sample(left: left, right: right, time: time,
                                   leftConfidence: leftConfidence, rightConfidence: rightConfidence))
            time += 0.1
        }
    }
}
