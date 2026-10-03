import CreateMLComponents
import XCTest
@testable import TresFort

@MainActor
private final class ControlledStationAppleEngine: StationAppleCountingEngine {
    private var eventHandler: (@MainActor (StationAppleCounterEvent) -> Void)?
    private(set) var inputs: [StationAppleInput] = []
    private(set) var appendAttempts = 0
    private(set) var finishCalls = 0
    private(set) var cancelCalls = 0
    var acceptedInputLimit: Int?

    func start(onEvent: @escaping @MainActor (StationAppleCounterEvent) -> Void) {
        eventHandler = onEvent
    }

    func append(_ input: StationAppleInput) -> Bool {
        appendAttempts += 1
        if let acceptedInputLimit, inputs.count >= acceptedInputLimit { return false }
        inputs.append(input)
        return true
    }

    func finish() { finishCalls += 1 }
    func cancel() { cancelCalls += 1 }

    // Deliberately retain the callback after cancellation, as an inference task
    // that already finished can still have a result queued for the main actor.
    func emit(_ event: StationAppleCounterEvent) { eventHandler?(event) }
}

@MainActor
final class StationComparisonTests: XCTestCase {
    func testBothCountersReceiveTheSameAdmittedFramesAndCaptureTimestamps() {
        let engine = ControlledStationAppleEngine()
        let model = StationComparisonModel(appleEngineFactory: { engine })
        model.start(exercise: .curl)
        var expected = StationRepCounter(exercise: .curl)
        let samples = (0..<120).map { sample(index: $0, angle: angle(at: $0)) }
        for sample in samples {
            model.process(frame(sample))
            expected.process(sample)
        }

        XCTAssertGreaterThan(expected.count, 0, "The parity fixture must include real custom-counter cycles")
        XCTAssertEqual(model.customCount, expected.count)
        XCTAssertEqual(engine.inputs.map(\.timestamp), samples.map(\.timestamp))
        XCTAssertEqual(engine.inputs.map(\.frameIndex), Array(1...samples.count))
        XCTAssertEqual(model.metrics.acceptedFrames, samples.count)
        XCTAssertNil(model.appleCount, "The absence of an Apple estimate must not look like a zero count")

        engine.emit(.estimate(estimate(1.375, through: 90)))
        XCTAssertEqual(model.appleCount, 1.375, "Preserve Apple's fractional estimate without integer rounding")
        XCTAssertEqual(model.metrics.appleCoveredFrames, 90)
        XCTAssertEqual(model.metrics.pendingFrames, 30)
        model.invalidate(reason: "Test completed")
    }

    func testSelectedAppleJointCoordinatesRemainNormalizedAndExcludeTheOtherSide() throws {
        let engine = ControlledStationAppleEngine()
        let model = StationComparisonModel(appleEngineFactory: { engine })
        model.start(exercise: .curl)
        let aspectRatio = 16.0 / 9
        let jointPairs: [(StationJoint, JointKey)] = [
            (.leftShoulder, .leftShoulder), (.leftElbow, .leftElbow), (.leftWrist, .leftWrist),
            (.rightShoulder, .rightShoulder), (.rightElbow, .rightElbow), (.rightWrist, .rightWrist)
        ]
        let selectedKeys: Set<JointKey> = [.leftShoulder, .leftElbow, .leftWrist]

        for index in 0..<45 {
            let original = sample(index: index, angle: angle(at: index))
            var customJoints = original.joints.filter { [.leftShoulder, .leftElbow, .leftWrist].contains($0.key) }
            // A stationary, lower-confidence far arm must neither determine the
            // custom count nor reach the Apple engine's selected-joint stream.
            customJoints[.rightShoulder] = StationJointPoint(x: 1.35, y: 0.8, confidence: 0.75)
            customJoints[.rightElbow] = StationJointPoint(x: 1.35, y: 0.5, confidence: 0.75)
            customJoints[.rightWrist] = StationJointPoint(x: 1.35, y: 0.2, confidence: 0.75)
            var applePoints: [JointKey: JointPoint] = [:]
            for (customKey, appleKey) in jointPairs {
                let point = try XCTUnwrap(customJoints[customKey])
                applePoints[appleKey] = JointPoint(
                    appleKey, location: CGPoint(x: point.x / aspectRatio, y: point.y),
                    confidence: point.confidence)
            }
            applePoints[.nose] = JointPoint(.nose, location: CGPoint(x: 0.31, y: 0.95), confidence: 0.99)
            let expectedPoints = applePoints.filter { selectedKeys.contains($0.key) }
            let customSample = StationPoseSample(timestamp: original.timestamp, joints: customJoints, personCount: 1)
            model.process(StationComparisonFrame(sample: customSample, applePose: Pose(from: applePoints),
                                                 visionMilliseconds: 2))

            XCTAssertEqual(engine.inputs.count, index + 1)
            let admitted = try XCTUnwrap(engine.inputs.last)
            // JointsSelector masks unselected joints with zeros; it does not
            // remove their keys from the pose dictionary.
            XCTAssertEqual(Set(admitted.pose.keypoints.keys), Set(applePoints.keys))
            XCTAssertEqual(admitted.pose.keypoints.filter { selectedKeys.contains($0.key) }, expectedPoints,
                           "Selection must preserve original Apple coordinates and confidence exactly")
            for (key, point) in admitted.pose.keypoints where !selectedKeys.contains(key) {
                XCTAssertEqual(point.location, .zero, "Unselected joint \(key) must carry no position")
                XCTAssertEqual(point.confidence, 0, "Unselected joint \(key) must carry no confidence")
            }
            XCTAssertEqual(admitted.timestamp, original.timestamp)
            let wrist = try XCTUnwrap(admitted.pose.keypoints[.leftWrist])
            let customWrist = try XCTUnwrap(customJoints[.leftWrist])
            XCTAssertEqual(Double(wrist.location.x), customWrist.x / aspectRatio, accuracy: 0.000_001)
            XCTAssertNotEqual(Double(wrist.location.x), customWrist.x,
                              "Aspect-correct custom coordinates must not replace normalized Apple coordinates")
        }
        XCTAssertEqual(model.metrics.acceptedFrames, 45)
        XCTAssertEqual(model.customCount, 1, "The selected moving arm completes the same admitted cycle")
        model.invalidate(reason: "Test completed")
    }

    func testEngineBackpressureEndsComparisonBeforeCustomCanConsumeRejectedFrame() {
        let engine = ControlledStationAppleEngine()
        engine.acceptedInputLimit = 35
        let model = StationComparisonModel(appleEngineFactory: { engine })
        model.start(exercise: .curl)
        var expected = StationRepCounter(exercise: .curl)
        for index in 0..<80 {
            let sample = sample(index: index, angle: angle(at: index))
            model.process(frame(sample))
            if index < 35 { expected.process(sample) }
        }

        XCTAssertEqual(engine.inputs.count, 35)
        XCTAssertEqual(engine.appendAttempts, 36, "Once parity fails, neither counter may continue independently")
        XCTAssertEqual(model.metrics.acceptedFrames, 35)
        XCTAssertEqual(expected.count, 0)
        var rejectedFrameProbe = expected
        rejectedFrameProbe.process(sample(index: 35, angle: angle(at: 35)))
        XCTAssertEqual(rejectedFrameProbe.count, 1, "The rejected frame would have completed a custom rep")
        XCTAssertEqual(model.customCount, expected.count)
        assertIncomplete(model.state)
        XCTAssertGreaterThanOrEqual(engine.cancelCalls, 1)
    }

    func testInitialIncompletePoseWaitsWithoutStartingAComparisonHistory() {
        let engine = ControlledStationAppleEngine()
        let model = StationComparisonModel(appleEngineFactory: { engine })
        model.start(exercise: .squat)
        var incompleteJoints = sample(index: 0).joints
        incompleteJoints.removeValue(forKey: .leftAnkle)
        incompleteJoints.removeValue(forKey: .rightAnkle)
        model.process(frame(StationPoseSample(timestamp: 0, joints: incompleteJoints, personCount: 1)))
        model.process(StationComparisonFrame(sample: sample(index: 1), applePose: nil, visionMilliseconds: 2))
        XCTAssertEqual(model.metrics.acceptedFrames, 0)
        XCTAssertEqual(engine.inputs.count, 0)
        XCTAssertNil(model.appleCount)
        XCTAssertEqual(model.state, .waitingForPose)

        model.process(frame(sample(index: 2)))
        XCTAssertEqual(model.metrics.acceptedFrames, 1)
        XCTAssertEqual(engine.inputs.map(\.timestamp), [2.0 / 15])
        model.invalidate(reason: "Test completed")
    }

    func testTrackingLossStopsBothCountersAndRequiresAnExplicitNewTrial() {
        for kind in 0..<5 {
            let engine = ControlledStationAppleEngine()
            let model = StationComparisonModel(appleEngineFactory: { engine })
            model.start(exercise: .curl)
            feed(0..<95, to: model)
            let previousCount = model.customCount
            var joints = sample(index: 95).joints
            var people = 1
            var pose: Pose? = Pose(from: [:])
            switch kind {
            case 0: people = 0
            case 1: people = 2
            case 2: joints.removeValue(forKey: .leftWrist)
            case 3:
                let point = joints[.leftWrist]!
                joints[.leftWrist] = StationJointPoint(x: point.x, y: point.y, confidence: 0.2)
            default: pose = nil
            }
            model.process(StationComparisonFrame(
                sample: StationPoseSample(timestamp: 95.0 / 15, joints: joints, personCount: people),
                applePose: pose, visionMilliseconds: 2))
            feed(96..<140, to: model)
            assertIncomplete(model.state)
            XCTAssertEqual(model.customCount, previousCount)
            XCTAssertEqual(model.metrics.acceptedFrames, 95)
            XCTAssertEqual(engine.inputs.count, 95)
            XCTAssertGreaterThanOrEqual(engine.cancelCalls, 1)
        }
    }

    func testIrrelevantOccludedJointsDoNotExcludeAVisibleSideView() {
        let engine = ControlledStationAppleEngine()
        let model = StationComparisonModel(appleEngineFactory: { engine })
        model.start(exercise: .curl)
        var expected = StationRepCounter(exercise: .curl)
        for index in 0..<95 {
            let original = sample(index: index, angle: angle(at: index))
            let joints = original.joints.filter { [.leftShoulder, .leftElbow, .leftWrist].contains($0.key) }
            let visibleSide = StationPoseSample(timestamp: original.timestamp, joints: joints, personCount: 1)
            model.process(frame(visibleSide))
            expected.process(visibleSide)
        }
        XCTAssertGreaterThan(expected.count, 0)
        XCTAssertEqual(model.metrics.acceptedFrames, 95)
        XCTAssertEqual(engine.inputs.count, 95)
        XCTAssertEqual(model.customCount, expected.count)

        // The other side becoming visible cannot replace the selected arm after
        // it disappears. A new trial is needed to establish another shared limb.
        let original = sample(index: 95)
        let otherSide = original.joints.filter { [.rightShoulder, .rightElbow, .rightWrist].contains($0.key) }
        model.process(frame(StationPoseSample(timestamp: original.timestamp, joints: otherSide, personCount: 1)))
        assertIncomplete(model.state)
        XCTAssertEqual(engine.inputs.count, 95)
        XCTAssertEqual(model.customCount, expected.count)
    }

    func testFrameGapEndsBothHistoriesInsteadOfBridgingMovement() {
        let engine = ControlledStationAppleEngine()
        let model = StationComparisonModel(appleEngineFactory: { engine })
        model.start(exercise: .curl)
        feed(0..<25, to: model)
        model.process(frame(sample(index: 40)))
        feed(41..<100, to: model)
        assertIncomplete(model.state)
        XCTAssertEqual(engine.inputs.count, 25)
        XCTAssertEqual(model.metrics.acceptedFrames, 25)
    }

    func testDuplicateAndStaleFramesAreIgnoredByBothCounters() {
        let engine = ControlledStationAppleEngine()
        let model = StationComparisonModel(appleEngineFactory: { engine })
        model.start(exercise: .curl)
        feed(0..<30, to: model)
        model.process(frame(sample(index: 29, angle: 50)))
        model.process(frame(sample(index: 2, angle: 50)))
        feed(30..<95, to: model)
        XCTAssertEqual(engine.inputs.map(\.frameIndex), Array(1...95))
        XCTAssertEqual(engine.inputs.map(\.timestamp), (0..<95).map { Double($0) / 15 })
        XCTAssertEqual(model.metrics.acceptedFrames, 95)
        XCTAssertFalse(model.state.isTerminal)
        model.invalidate(reason: "Test completed")
    }

    func testResetRejectsQueuedOutputsFromThePreviousEngine() async {
        let oldEngine = ControlledStationAppleEngine()
        let newEngine = ControlledStationAppleEngine()
        var engines = [oldEngine, newEngine]
        let model = StationComparisonModel(appleEngineFactory: { engines.removeFirst() })
        model.start(exercise: .curl)
        feed(0..<100, to: model)
        oldEngine.emit(.estimate(estimate(2.25, through: 90)))
        model.reset(exercise: .squat)

        let lateDelivery = Task { @MainActor in
            oldEngine.emit(.estimate(self.estimate(99.75, through: 100)))
            oldEngine.emit(.finished)
            oldEngine.emit(.failed("Old run failed"))
        }
        await lateDelivery.value
        XCTAssertEqual(model.state, .idle)
        XCTAssertEqual(model.customCount, 0)
        XCTAssertNil(model.appleCount)
        XCTAssertEqual(model.metrics.acceptedFrames, 0)
        XCTAssertGreaterThanOrEqual(oldEngine.cancelCalls, 1)

        model.start(exercise: .squat)
        feed(0..<90, to: model)
        newEngine.emit(.estimate(estimate(0.875, through: 90)))
        XCTAssertEqual(model.appleCount, 0.875)
        XCTAssertEqual(newEngine.inputs.first?.frameIndex, 1)
        model.invalidate(reason: "Test completed")
    }

    func testStopWaitsForPendingEstimateAndOnlyThenFinishes() {
        let engine = ControlledStationAppleEngine()
        let model = StationComparisonModel(appleEngineFactory: { engine })
        model.start(exercise: .curl)
        feed(0..<100, to: model)
        engine.emit(.estimate(estimate(2.125, through: 95)))
        model.stop()
        XCTAssertEqual(model.state, .finishing)
        XCTAssertEqual(engine.finishCalls, 1)
        XCTAssertEqual(model.metrics.pendingFrames, 5)

        feed(100..<120, to: model)
        XCTAssertEqual(engine.inputs.count, 100, "Stop closes admission while the existing tail drains")
        engine.emit(.estimate(estimate(2.625, through: 100)))
        XCTAssertEqual(model.state, .finishing)
        XCTAssertEqual(model.appleCount, 2.625)
        XCTAssertEqual(model.metrics.pendingFrames, 0)
        engine.emit(.finished)
        XCTAssertEqual(model.state, .finished)

        engine.emit(.estimate(estimate(200, through: 100)))
        XCTAssertEqual(model.appleCount, 2.625, "A finished comparison is immutable")
    }

    func testStopWithUncoveredFramesIsIncompleteEvenWhenAnEstimateExists() {
        let engine = ControlledStationAppleEngine()
        let model = StationComparisonModel(appleEngineFactory: { engine })
        model.start(exercise: .curl)
        feed(0..<97, to: model)
        engine.emit(.estimate(estimate(1.75, through: 95)))
        model.stop()
        engine.emit(.finished)
        assertIncomplete(model.state)
        XCTAssertEqual(model.appleCount, 1.75)
        XCTAssertEqual(model.metrics.pendingFrames, 2)
    }

    func testStopBeforeFirstWindowDoesNotInventAnAppleCount() {
        let engine = ControlledStationAppleEngine()
        let model = StationComparisonModel(appleEngineFactory: { engine })
        model.start(exercise: .curl)
        feed(0..<40, to: model)
        model.stop()
        engine.emit(.finished)
        assertIncomplete(model.state)
        XCTAssertNil(model.appleCount)
        XCTAssertEqual(model.metrics.pendingFrames, 40)
    }

    func testRestartDuringFinishingRejectsPriorRunCompletion() async {
        let oldEngine = ControlledStationAppleEngine()
        let newEngine = ControlledStationAppleEngine()
        var engines = [oldEngine, newEngine]
        let model = StationComparisonModel(appleEngineFactory: { engines.removeFirst() })
        model.start(exercise: .curl)
        feed(0..<90, to: model)
        model.stop()
        model.start(exercise: .benchPress)
        feed(0..<90, to: model)
        let lateDelivery = Task { @MainActor in
            oldEngine.emit(.estimate(self.estimate(900, through: 90)))
            oldEngine.emit(.finished)
        }
        await lateDelivery.value
        XCTAssertNil(model.appleCount)
        XCTAssertFalse(model.state.isTerminal)
        XCTAssertEqual(model.metrics.acceptedFrames, 90)
        newEngine.emit(.estimate(estimate(1.125, through: 90)))
        XCTAssertEqual(model.appleCount, 1.125)
        model.stop()
        newEngine.emit(.finished)
        XCTAssertEqual(model.state, .finished)
    }

    func testTerminalEngineFailureStopsAdmissionAndRejectsLateResults() async {
        let engine = ControlledStationAppleEngine()
        let model = StationComparisonModel(appleEngineFactory: { engine })
        model.start(exercise: .curl)
        feed(0..<95, to: model)
        engine.emit(.estimate(estimate(1.375, through: 90)))
        engine.emit(.failed("Injected inference failure"))
        guard case .failed = model.state else { return XCTFail("Inference failure must be terminal") }
        let count = model.customCount
        let lateDelivery = Task { @MainActor in
            engine.emit(.estimate(self.estimate(100, through: 95)))
            engine.emit(.finished)
        }
        await lateDelivery.value
        feed(95..<140, to: model)
        guard case .failed = model.state else { return XCTFail("Late output must not erase a failure") }
        XCTAssertEqual(model.appleCount, 1.375)
        XCTAssertEqual(model.customCount, count)
        XCTAssertEqual(engine.inputs.count, 95)
        XCTAssertGreaterThanOrEqual(engine.cancelCalls, 1)
    }

    func testWindowBuilderRetainsOnlyNinetyRealPosesWithFiveFrameStride() throws {
        var builder = StationAppleWindowBuilder()
        var windows: [StationAppleWindow] = []
        let timestamps: [Double] = (1...240).map { index in
            let regularTime = Double(index) * 0.07
            let irregularOffset = Double(index / 30) * 0.002
            return regularTime + irregularOffset
        }
        for index in 1...240 {
            let input = StationAppleInput(pose: Pose(from: [:]), timestamp: timestamps[index - 1], frameIndex: index)
            if let window = builder.append(input) { windows.append(window) }
            XCTAssertEqual(builder.bufferedPoseCount, min(index, 90), "Retained input must stay bounded")
            if index < 90 { XCTAssertTrue(windows.isEmpty, "A short first window cannot be fabricated") }
        }
        XCTAssertEqual(windows.map(\.throughFrame), Array(stride(from: 90, through: 240, by: 5)))
        for window in windows {
            XCTAssertEqual(window.poses.count, 90)
            XCTAssertEqual(window.firstTimestamp, timestamps[window.throughFrame - 90])
            XCTAssertEqual(window.lastTimestamp, timestamps[window.throughFrame - 1])
        }
        let lastWindow = try XCTUnwrap(windows.last)
        XCTAssertEqual(lastWindow.lastTimestamp - lastWindow.firstTimestamp,
                       timestamps[239] - timestamps[150], accuracy: 0.000_001,
                       "History uses capture timestamps, not a fabricated fixed frame interval")
    }

    func testShortFinalTailRemainsUncoveredInsteadOfRepeatingFrames() {
        var builder = StationAppleWindowBuilder()
        var coveredThrough: [Int] = []
        for index in 1...97 {
            if let window = builder.append(StationAppleInput(
                pose: Pose(from: [:]), timestamp: Double(index - 1) / 15, frameIndex: index)) {
                coveredThrough.append(window.throughFrame)
            }
        }
        XCTAssertEqual(coveredThrough, [90, 95])
        XCTAssertEqual(builder.bufferedPoseCount, 90)
    }

    private func assertIncomplete(_ state: StationComparisonState,
                                  file: StaticString = #filePath, line: UInt = #line) {
        guard case .incomplete = state else {
            return XCTFail("Expected incomplete comparison, got \(state)", file: file, line: line)
        }
    }

    private func estimate(_ count: Float, through frames: Int) -> StationAppleEstimate {
        StationAppleEstimate(cumulativeCount: count, throughFrame: frames,
                             throughTimestamp: Double(frames - 1) / 15,
                             windowDuration: 89.0 / 15, processingMilliseconds: 12)
    }

    private func frame(_ sample: StationPoseSample) -> StationComparisonFrame {
        StationComparisonFrame(sample: sample, applePose: Pose(from: [:]), visionMilliseconds: 2)
    }

    private func feed(_ indices: Range<Int>, to model: StationComparisonModel) {
        for index in indices { model.process(frame(sample(index: index, angle: angle(at: index)))) }
    }

    private func angle(at index: Int) -> Double {
        switch index % 45 {
        case 0..<7: return 170
        case 7..<13: return 125
        case 13..<24: return 50
        case 24..<32: return 125
        default: return 170
        }
    }

    private func sample(index: Int, angle: Double = 170) -> StationPoseSample {
        let radians = angle * .pi / 180
        let top = StationJointPoint(x: 0.5, y: 0.8, confidence: 0.9)
        let pivot = StationJointPoint(x: 0.5, y: 0.5, confidence: 0.9)
        let end = StationJointPoint(x: 0.5 + sin(radians) * 0.25,
                                    y: 0.5 + cos(radians) * 0.25, confidence: 0.9)
        let joints: [StationJoint: StationJointPoint] = [
            .leftShoulder: top, .leftElbow: pivot, .leftWrist: end,
            .rightShoulder: top, .rightElbow: pivot, .rightWrist: end,
            .leftHip: top, .leftKnee: pivot, .leftAnkle: end,
            .rightHip: top, .rightKnee: pivot, .rightAnkle: end
        ]
        return StationPoseSample(timestamp: Double(index) / 15, joints: joints, personCount: 1)
    }
}
