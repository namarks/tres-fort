import XCTest
@testable import TresFort

/// Synthetic hip-centred 3D skeletons. Yaw rotates the whole body about the
/// vertical axis, standing in for a different camera position. These cases check
/// counting logic and view handling only; they do not measure MediaPipe accuracy.
private struct SyntheticPose {
    var depth = 0.0
    var leftCurl = 0.0
    var rightCurl = 0.0
    var yaw = 0.0
    var hiddenJoints: Set<Int> = []

    func landmarks(noise: inout SeededNoise, amplitude: Double = 0.01) -> [StationMediaPipeWorldLandmark] {
        var points = Array(repeating: (x: 0.0, y: 0.0, z: 0.0), count: 33)
        let phi = 80 * depth * .pi / 180
        let psi = 40 * depth * .pi / 180
        let tau = 35 * depth * .pi / 180
        for (side, x) in [(StationBodySide.left, -0.1), (StationBodySide.right, 0.1)] {
            let ids = side == .left ? (11, 13, 15, 23, 25, 27) : (12, 14, 16, 24, 26, 28)
            let hip = (x: x, y: 0.0, z: 0.0)
            let knee = (x: x, y: 0.45 * cos(phi), z: 0.45 * sin(phi))
            let ankle = (x: x, y: knee.y + 0.43 * cos(psi), z: knee.z - 0.43 * sin(psi))
            let shoulder = (x: x * 1.6, y: -0.5 * cos(tau), z: 0.5 * sin(tau))
            let elbow = (x: shoulder.x, y: shoulder.y + 0.28, z: shoulder.z)
            let beta = 140 * (side == .left ? leftCurl : rightCurl) * .pi / 180
            let wrist = (x: elbow.x, y: elbow.y + 0.25 * cos(beta), z: elbow.z + 0.25 * sin(beta))
            points[ids.0] = shoulder
            points[ids.1] = elbow
            points[ids.2] = wrist
            points[ids.3] = hip
            points[ids.4] = knee
            points[ids.5] = ankle
        }
        let c = cos(yaw * .pi / 180)
        let s = sin(yaw * .pi / 180)
        return points.enumerated().map { index, point in
            let score: Float = hiddenJoints.contains(index) ? 0.3 : 0.99
            return StationMediaPipeWorldLandmark(
                x: Float(point.x * c + point.z * s + noise.next(amplitude)),
                y: Float(point.y + noise.next(amplitude)),
                z: Float(-point.x * s + point.z * c + noise.next(amplitude)),
                visibility: score, presence: score)
        }
    }
}

private struct SeededNoise {
    private var state: UInt64
    init(seed: UInt64) { state = seed }
    mutating func next(_ amplitude: Double) -> Double {
        state = state &* 6364136223846793005 &+ 1442695040888963407
        let unit = Double(state >> 11) / Double(1 << 53)
        return (unit * 2 - 1) * amplitude
    }
}

private let frameRate = 30.0

private func bump(_ elapsed: Double, period: Double) -> Double {
    (1 - cos(2 * .pi * elapsed / period)) / 2
}

/// Standing lead-in, then repetitions of the given period separated by pauses.
private func repetitionSeries(reps: Int, period: Double = 2, pause: Double = 1, lead: Double = 1,
                              scale: (Int) -> Double = { _ in 1 }) -> [(time: Double, depth: Double)] {
    var series: [(time: Double, depth: Double)] = []
    var time = 0.0
    func append(_ duration: Double, _ value: (Double) -> Double) {
        let frames = Int((duration * frameRate).rounded())
        for frame in 0..<frames {
            series.append((time, value(Double(frame) / frameRate)))
            time += 1 / frameRate
        }
    }
    append(lead) { _ in 0 }
    for rep in 0..<reps {
        let amount = scale(rep)
        append(period) { amount * bump($0, period: period) }
        append(pause) { _ in 0 }
    }
    return series
}

final class StationGenericCounterTests: XCTestCase {
    private func countSquats(_ series: [(time: Double, depth: Double)], yaw: Double = 0,
                             region: StationBodyRegion = .lowerBody, noiseAmplitude: Double = 0.01,
                             hide: (Double) -> Set<Int> = { _ in [] },
                             skip: (Double) -> Bool = { _ in false }) -> StationGenericCounter {
        var counter = StationGenericCounter(region: region)
        var noise = SeededNoise(seed: 1)
        for (time, depth) in series where !skip(time) {
            let pose = SyntheticPose(depth: depth, yaw: yaw, hiddenJoints: hide(time))
            counter.process(StationWorldPoseSample(timestamp: time,
                                                   landmarks: pose.landmarks(noise: &noise, amplitude: noiseAmplitude),
                                                   personCount: 1))
        }
        return counter
    }

    func testCountsTheSameSquatsFromFrontSideDiagonalAndBehind() {
        for yaw in [0.0, 45, 90, 135, 180] {
            let counter = countSquats(repetitionSeries(reps: 5), yaw: yaw)
            XCTAssertEqual(counter.count, 5, "yaw \(yaw)")
            XCTAssertNotNil(counter.lockedSignal)
        }
    }

    func testWholeBodyHintStillFindsTheRepeatingJoint() {
        let counter = countSquats(repetitionSeries(reps: 5), region: .wholeBody)
        XCTAssertEqual(counter.count, 5)
        XCTAssertTrue(["leftKnee", "rightKnee", "leftHip", "rightHip"].contains(counter.lockedSignal ?? ""))
    }

    func testCountsTouchAndGoRepsWithoutAPause() {
        XCTAssertEqual(countSquats(repetitionSeries(reps: 5, period: 1.5, pause: 0)).count, 5)
        XCTAssertEqual(countSquats(repetitionSeries(reps: 5, period: 1, pause: 0)).count, 5)
    }

    func testToleratesLandmarkNoise() {
        XCTAssertEqual(countSquats(repetitionSeries(reps: 5), noiseAmplitude: 0.02).count, 5)
    }

    func testSmallMovementIsNotARepetition() {
        let counter = countSquats(repetitionSeries(reps: 5, scale: { _ in 0.15 }))
        XCTAssertEqual(counter.count, 0)
        XCTAssertNil(counter.lockedSignal)
    }

    func testPartialRepsAfterTheFirstRepSetsTheReferenceDoNotCount() {
        XCTAssertEqual(countSquats(repetitionSeries(reps: 5, scale: { $0 < 3 ? 1 : 0.4 })).count, 3)
    }

    func testGraduallyShrinkingRepsCannotLowerTheFirstRepReference() {
        // A moving average of accepted reps would lower the bar enough to count all seven.
        let scales = [1, 0.9, 0.75, 0.55, 0.5, 0.45, 0.4]
        XCTAssertEqual(countSquats(repetitionSeries(reps: scales.count, scale: { scales[$0] })).count, 3)
    }

    func testSlowRepetitionsAreNotAbsorbedIntoTheRestingPosition() {
        XCTAssertEqual(countSquats(repetitionSeries(reps: 3, period: 8)).count, 3)
    }

    func testLossDuringDescentCannotMakeTheBottomTheNewRest() {
        // Two reps, then joints vanish on the way down and return during a pause
        // at the bottom. Later full reps must still count.
        var series = repetitionSeries(reps: 2)
        let lossStart = (series.last?.time ?? 0) + 1 / frameRate + 0.5
        var time = (series.last?.time ?? 0) + 1 / frameRate
        func append(_ duration: Double, _ value: (Double) -> Double) {
            for frame in 0..<Int((duration * frameRate).rounded()) {
                series.append((time, value(Double(frame) / frameRate)))
                time += 1 / frameRate
            }
        }
        append(1) { bump($0, period: 2) }
        append(1) { _ in 1 }
        append(1) { bump($0 + 1, period: 2) }
        append(1) { _ in 0 }
        for _ in 0..<2 {
            append(2) { bump($0, period: 2) }
            append(1) { _ in 0 }
        }
        let lowerBody: Set<Int> = [11, 12, 23, 24, 25, 26, 27, 28]
        let counter = countSquats(series, hide: { (lossStart...lossStart + 0.3).contains($0) ? lowerBody : Set<Int>() })
        XCTAssertEqual(counter.count, 4)
    }

    func testClipEndingInsideTheLockWindowReportsTheCountWithItsSignal() {
        // The only rep returns to rest on the last frame, so the signal choice is
        // still pending when the clip ends.
        let counter = countSquats(repetitionSeries(reps: 1, pause: 0))
        XCTAssertEqual(counter.count, 1)
        XCTAssertTrue(["leftKnee", "rightKnee"].contains(counter.lockedSignal ?? ""))
    }

    func testChosenSignalWithMissingJointsIsReportedAsIncomplete() {
        // Ankles hidden while the shoulders and hips stay visible: the knees miss
        // frames but the person is still tracked, and a knee is still chosen.
        let start = repetitionSeries(reps: 5)
        let hiddenAnkles = countSquats(start, hide: { $0 < 0.5 ? [27, 28] : [] })
        XCTAssertEqual(hiddenAnkles.count, 5)
        XCTAssertTrue(["leftKnee", "rightKnee"].contains(hiddenAnkles.lockedSignal ?? ""))
        XCTAssertTrue(hiddenAnkles.chosenSignalMissedData)
        XCTAssertNotEqual(hiddenAnkles.status, .trackingLost)

        // Hiding only the hips' shoulder joints leaves the chosen knee complete.
        let hiddenShoulders = countSquats(start, hide: { $0 < 0.5 ? [11, 12] : [] })
        XCTAssertEqual(hiddenShoulders.count, 5)
        XCTAssertFalse(hiddenShoulders.chosenSignalMissedData)

        var movement = StationGenericMovementCounter(exercise: .squat)
        var noise = SeededNoise(seed: 8)
        for (time, depth) in start {
            let pose = SyntheticPose(depth: depth, hiddenJoints: time < 0.5 ? [27, 28] : [])
            movement.process(StationWorldPoseSample(timestamp: time, landmarks: pose.landmarks(noise: &noise),
                                                    personCount: 1))
        }
        XCTAssertEqual(movement.count, 5)
        XCTAssertTrue(movement.hasTrackingLoss)
    }

    func testCyclesFasterThanTheMinimumDurationDoNotCount() {
        XCTAssertEqual(countSquats(repetitionSeries(reps: 3, period: 0.3, pause: 0.5)).count, 0)
    }

    func testLostJointsRestartTheCycleAndKeepEarlierCounts() {
        // The third rep's lower body is unclear near the bottom; it must not count.
        let thirdRepStart = 1.0 + 2 * 3.0
        let lowerBody: Set<Int> = [11, 12, 23, 24, 25, 26, 27, 28]
        var sawLoss = false
        var counter = StationGenericCounter(region: .lowerBody)
        var noise = SeededNoise(seed: 3)
        for (time, depth) in repetitionSeries(reps: 5) {
            let hidden = (thirdRepStart + 0.8...thirdRepStart + 1.2).contains(time) ? lowerBody : Set<Int>()
            let pose = SyntheticPose(depth: depth, hiddenJoints: hidden)
            counter.process(StationWorldPoseSample(timestamp: time, landmarks: pose.landmarks(noise: &noise),
                                                   personCount: 1))
            sawLoss = sawLoss || counter.status == .trackingLost
        }
        XCTAssertTrue(sawLoss)
        XCTAssertEqual(counter.count, 4)
    }

    func testFrameGapNeverBridgesARepetition() {
        let secondRepStart = 1.0 + 3.0
        let counter = countSquats(repetitionSeries(reps: 5),
                                  skip: { (secondRepStart + 0.7...secondRepStart + 1.3).contains($0) })
        XCTAssertEqual(counter.count, 4)
    }

    func testMultiplePeopleStopCounting() {
        var counter = StationGenericCounter(region: .lowerBody)
        var noise = SeededNoise(seed: 4)
        for (index, sample) in repetitionSeries(reps: 5).enumerated() {
            let pose = SyntheticPose(depth: sample.depth)
            counter.process(StationWorldPoseSample(timestamp: sample.time, landmarks: pose.landmarks(noise: &noise),
                                                   personCount: index > 100 ? 2 : 1))
        }
        XCTAssertEqual(counter.count, 1)
        XCTAssertEqual(counter.status, .multiplePeople)
    }

    func testOutOfOrderSamplesAreIgnored() {
        var counter = StationGenericCounter(region: .lowerBody)
        var noise = SeededNoise(seed: 5)
        for (time, depth) in repetitionSeries(reps: 2) {
            let pose = SyntheticPose(depth: depth)
            counter.process(StationWorldPoseSample(timestamp: time, landmarks: pose.landmarks(noise: &noise), personCount: 1))
            // A stale deep pose must not complete or disturb a cycle.
            let stale = SyntheticPose(depth: 1)
            counter.process(StationWorldPoseSample(timestamp: max(0, time - 0.5),
                                                   landmarks: stale.landmarks(noise: &noise), personCount: 1))
        }
        XCTAssertEqual(counter.count, 2)
    }

    private func curlSeries(left: Int, right: Int, period: Double = 2, pause: Double = 0.8,
                            lead: Double = 1) -> [(time: Double, left: Double, right: Double)] {
        let total = lead + Double(max(left, right)) * (period + pause) + 0.5
        return (0..<Int(total * frameRate)).map { frame in
            let time = Double(frame) / frameRate
            func value(_ reps: Int) -> Double {
                let elapsed = time - lead
                guard elapsed >= 0 else { return 0 }
                let rep = Int(elapsed / (period + pause))
                let within = elapsed - Double(rep) * (period + pause)
                return rep < reps && within < period ? bump(within, period: period) : 0
            }
            return (time: time, left: value(left), right: value(right))
        }
    }

    func testCurlArmsCountSeparatelyAndAreNeverSummed() {
        for (left, right) in [(4, 2), (3, 3), (0, 5)] {
            var counter = StationGenericMovementCounter(exercise: .curl)
            var noise = SeededNoise(seed: 6)
            for sample in curlSeries(left: left, right: right) {
                let pose = SyntheticPose(leftCurl: sample.left, rightCurl: sample.right)
                counter.process(StationWorldPoseSample(timestamp: sample.time, landmarks: pose.landmarks(noise: &noise),
                                                       personCount: 1))
            }
            XCTAssertEqual(counter.leftCount, left, "left of \(left)/\(right)")
            XCTAssertEqual(counter.rightCount, right, "right of \(left)/\(right)")
            XCTAssertEqual(counter.count, max(left, right))
        }
    }

    func testPressingMovementCountsWithTheUpperBodyHint() {
        var counter = StationGenericMovementCounter(exercise: .benchPress)
        var noise = SeededNoise(seed: 7)
        for sample in curlSeries(left: 5, right: 5) {
            let pose = SyntheticPose(leftCurl: 0.8 * sample.left, rightCurl: 0.8 * sample.right)
            counter.process(StationWorldPoseSample(timestamp: sample.time, landmarks: pose.landmarks(noise: &noise),
                                                   personCount: 1))
        }
        XCTAssertEqual(counter.count, 5)
        XCTAssertNil(counter.leftCount)
        XCTAssertNotNil(counter.signalDescription)
    }

    func testMissingPoseReportsTrackingLoss() {
        var counter = StationGenericMovementCounter(exercise: .squat)
        counter.process(StationWorldPoseSample(timestamp: 0, landmarks: nil, personCount: 0))
        XCTAssertTrue(counter.hasTrackingLoss)
        XCTAssertEqual(counter.count, 0)
    }

    func testLegacyReplayFrameDecodesWithoutGenericFields() throws {
        let json = """
        {"timestamp":0,"apple":{"personCount":1,"joints":{},"milliseconds":1},
         "mediaPipe":{"personCount":1,"joints":{},"milliseconds":1},
         "mediaPipeLandmarks":[],"mediaPipeWorldLandmarks":[],"appleCycles":0,"mediaPipeCycles":2}
        """
        let frame = try JSONDecoder().decode(StationReplayFrame.self, from: Data(json.utf8))
        XCTAssertEqual(frame.mediaPipeCycles, 2)
        XCTAssertNil(frame.genericCycles)
        XCTAssertNil(frame.genericSignal)
    }
}
