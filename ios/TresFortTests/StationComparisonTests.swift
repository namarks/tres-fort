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
        let model = StationComparisonModel(appleEngineFactory: { engine }, readinessDuration: 0)
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
        let model = StationComparisonModel(appleEngineFactory: { engine }, readinessDuration: 0)
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

    func testEngineBackpressureEndsSegmentBeforeCustomCanConsumeRejectedFrame() {
        let engine = ControlledStationAppleEngine()
        engine.acceptedInputLimit = 35
        let model = StationComparisonModel(appleEngineFactory: { engine }, readinessDuration: 0)
        model.start(exercise: .curl)
        var expected = StationRepCounter(exercise: .curl)
        for index in 0...35 {
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
        assertReacquiring(model.state)
        XCTAssertTrue(model.hasIncompleteCoverage)
        XCTAssertGreaterThanOrEqual(engine.cancelCalls, 1)
    }

    func testInitialIncompletePoseWaitsWithoutStartingAComparisonHistory() {
        let engine = ControlledStationAppleEngine()
        let model = StationComparisonModel(appleEngineFactory: { engine }, readinessDuration: 0)
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

    func testTrackingLossPausesBothCountersAndMultiplePeopleRequireExplicitRestart() {
        for kind in 0..<5 {
            let engine = ControlledStationAppleEngine()
            let model = StationComparisonModel(appleEngineFactory: { engine }, readinessDuration: 0)
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
            if kind == 1 {
                feed(96..<140, to: model)
                assertIncomplete(model.state)
            } else {
                assertReacquiring(model.state)
            }
            XCTAssertEqual(model.customCount, previousCount)
            XCTAssertEqual(model.metrics.acceptedFrames, 95)
            XCTAssertEqual(engine.inputs.count, 95)
            XCTAssertGreaterThanOrEqual(engine.cancelCalls, 1)
        }
    }

    func testIrrelevantOccludedJointsDoNotExcludeAVisibleSideView() {
        let engine = ControlledStationAppleEngine()
        let model = StationComparisonModel(appleEngineFactory: { engine }, readinessDuration: 0)
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
        // it disappears. Reacquisition must establish a fresh shared segment first.
        let original = sample(index: 95)
        let otherSide = original.joints.filter { [.rightShoulder, .rightElbow, .rightWrist].contains($0.key) }
        model.process(frame(StationPoseSample(timestamp: original.timestamp, joints: otherSide, personCount: 1)))
        assertReacquiring(model.state)
        XCTAssertEqual(engine.inputs.count, 95)
        XCTAssertEqual(model.customCount, expected.count)
    }

    func testFrameGapEndsBothHistoriesInsteadOfBridgingMovement() {
        let engine = ControlledStationAppleEngine()
        let model = StationComparisonModel(appleEngineFactory: { engine }, readinessDuration: 0)
        model.start(exercise: .curl)
        feed(0..<25, to: model)
        model.process(frame(sample(index: 40)))
        assertReacquiring(model.state)
        XCTAssertEqual(engine.inputs.count, 25)
        XCTAssertEqual(model.metrics.acceptedFrames, 25)
    }

    func testDuplicateAndStaleFramesAreIgnoredByBothCounters() {
        let engine = ControlledStationAppleEngine()
        let model = StationComparisonModel(appleEngineFactory: { engine }, readinessDuration: 0)
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
        let model = StationComparisonModel(appleEngineFactory: { engines.removeFirst() }, readinessDuration: 0)
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
        let model = StationComparisonModel(appleEngineFactory: { engine }, readinessDuration: 0)
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
        let model = StationComparisonModel(appleEngineFactory: { engine }, readinessDuration: 0)
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
        let model = StationComparisonModel(appleEngineFactory: { engine }, readinessDuration: 0)
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
        let model = StationComparisonModel(appleEngineFactory: { engines.removeFirst() }, readinessDuration: 0)
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
        let model = StationComparisonModel(appleEngineFactory: { engine }, readinessDuration: 0)
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

    func testWindowIdentifierRangesMatchAppleTransformerWithIrregularCaptureTimestamps() async throws {
        let pose = Pose(from: [:])
        var builder = StationAppleWindowBuilder()
        var built: [StationAppleWindow] = []
        let stream = AsyncStream<TemporalFeature<Pose>> { continuation in
            for index in 0..<100 {
                let ticks = index * 70_000 + (index / 30) * 2_000
                let id = TemporalSegmentIdentifier(source: "test", range: ticks..<(ticks + 1), timescale: 1_000_000)
                continuation.yield(TemporalFeature(id: id, feature: pose))
                let input = StationAppleInput(pose: pose, timestamp: Double(ticks) / 1_000_000, frameIndex: index + 1)
                if let window = builder.append(input) { built.append(window) }
            }
            continuation.finish()
        }
        let sequence = AnyTemporalSequence<Pose>(stream, count: 100)
        let official = try SlidingWindowTransformer<Pose>(stride: 5, length: 90)
            .applied(to: sequence, eventHandler: nil)
        var officialRanges: [Range<Int>] = []
        for try await window in official where window.feature.count == 90 {
            officialRanges.append(window.id.range)
        }
        XCTAssertEqual(officialRanges, [0..<90, 5..<95, 10..<100])
        XCTAssertEqual(built.map { $0.identifier(source: "test").range }, officialRanges,
                       "Model windows use pose indices, not camera microseconds")
        XCTAssertTrue(built.allSatisfy { $0.identifier(source: "test").range.count == 90 })
        XCTAssertEqual(built.last?.lastTimestamp, 6.936,
                       "Actual irregular capture time remains independent of the model's nominal clock")
    }

    func testRealAppleCounterProcessesTwoOverlappingWindows() async throws {
        let engine = StationAppleCounter()
        let first = expectation(description: "Real Apple result at frame 90")
        let second = expectation(description: "Real Apple result at frame 95")
        let finished = expectation(description: "Real Apple stream completes")
        var estimates: [StationAppleEstimate] = []
        var failure: String?
        engine.start { event in
            switch event {
            case .estimate(let estimate):
                estimates.append(estimate)
                if estimate.throughFrame == 90 { first.fulfill() }
                if estimate.throughFrame == 95 { second.fulfill() }
            case .finished: finished.fulfill()
            case .failed(let message): failure = message
            }
        }
        defer { engine.cancel() }
        for index in 1...90 { XCTAssertTrue(engine.append(realAppleInput(index: index))) }
        await fulfillment(of: [first], timeout: 15)
        guard estimates.count == 1 else {
            XCTFail("Apple did not produce its first result: \(failure ?? "no result")")
            return
        }
        // The old microsecond IDs produced the first result, then trapped in
        // CreateMLComponents when the next overlapping window was consumed.
        for index in 91...95 { XCTAssertTrue(engine.append(realAppleInput(index: index))) }
        await fulfillment(of: [second], timeout: 15)
        engine.finish()
        await fulfillment(of: [finished], timeout: 5)
        XCTAssertNil(failure)
        XCTAssertEqual(estimates.map(\.throughFrame), [90, 95])
        XCTAssertTrue(estimates.allSatisfy { $0.cumulativeCount.isFinite && $0.cumulativeCount >= 0 })
        XCTAssertEqual(estimates.last?.throughTimestamp, realAppleInput(index: 95).timestamp)
    }

    private func realAppleInput(index: Int) -> StationAppleInput {
        let keys: [JointKey] = [.leftShoulder, .leftElbow, .leftWrist, .rightShoulder, .rightElbow, .rightWrist,
                               .leftHip, .leftKnee, .leftAnkle, .rightHip, .rightKnee, .rightAnkle,
                               .nose, .neck, .root, .leftEye, .rightEye, .leftEar, .rightEar]
        var points = Dictionary(uniqueKeysWithValues: keys.map {
            ($0, JointPoint($0, location: CGPoint(x: 0.5, y: 0.5), confidence: 0.9))
        })
        let angle = (110 + 60 * cos(Double(index - 1) * 2 * .pi / 45)) * .pi / 180
        points[.leftShoulder] = JointPoint(.leftShoulder, location: CGPoint(x: 0.3, y: 0.8), confidence: 0.9)
        points[.leftElbow] = JointPoint(.leftElbow, location: CGPoint(x: 0.3, y: 0.5), confidence: 0.9)
        points[.leftWrist] = JointPoint(.leftWrist,
            location: CGPoint(x: 0.3 + 0.2 * sin(angle), y: 0.5 + 0.3 * cos(angle)), confidence: 0.9)
        let selected = JointsSelector(selectedJoints: [.leftShoulder, .leftElbow, .leftWrist]).applied(to: Pose(from: points))
        let timestamp = Double(index - 1) / 15 + Double(index / 30) * 0.002
        return StationAppleInput(pose: selected, timestamp: timestamp, frameIndex: index)
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

    func testStableReadinessDoesNotAdmitFleetingPoseAndRequiresSameVisibleLimb() {
        let engine = ControlledStationAppleEngine()
        let model = StationComparisonModel(appleEngineFactory: { engine })
        model.start(exercise: .curl)
        model.process(frame(sample(index: 0)))
        model.process(frame(StationPoseSample(timestamp: 1.0 / 15, joints: [:], personCount: 0)))
        for index in 2...6 { model.process(frame(sample(index: index))) }
        XCTAssertEqual(model.metrics.acceptedFrames, 0)
        XCTAssertEqual(engine.inputs.count, 0, "Readiness frames never enter either counter")
        model.process(frame(sample(index: 7)))
        XCTAssertEqual(model.metrics.acceptedFrames, 1)
        XCTAssertEqual(engine.inputs.first?.timestamp, 7.0 / 15)
        XCTAssertEqual(model.selectedJoints, [.leftShoulder, .leftElbow, .leftWrist])
        model.invalidate(reason: "Test complete")
    }

    func testLossReacquiresFreshSegmentAndPreservesPartialCumulativeCounts() {
        let firstEngine = ControlledStationAppleEngine()
        let secondEngine = ControlledStationAppleEngine()
        var engines = [firstEngine, secondEngine]
        let model = StationComparisonModel(appleEngineFactory: { engines.removeFirst() }, readinessDuration: 0)
        model.start(exercise: .curl)
        feed(0..<95, to: model)
        let firstCustom = model.customCount
        firstEngine.emit(.estimate(estimate(2.25, through: 90)))
        model.process(frame(StationPoseSample(timestamp: 95.0 / 15, joints: [:], personCount: 0)))
        assertReacquiring(model.state)
        XCTAssertEqual(model.customCount, firstCustom)
        XCTAssertEqual(model.appleCount, 2.25)
        XCTAssertEqual(model.metrics.windowProgress, 0)
        XCTAssertTrue(model.hasIncompleteCoverage)
        XCTAssertEqual(model.metrics.interruptedSegments, 1)

        firstEngine.emit(.estimate(estimate(99, through: 95)))
        firstEngine.emit(.failed("Late failure"))
        XCTAssertEqual(model.appleCount, 2.25)
        assertReacquiring(model.state)
        feed(96..<186, to: model)
        XCTAssertEqual(secondEngine.inputs.map(\.frameIndex), Array(1...90))
        XCTAssertEqual(model.state, .warmingUp, "Prior Apple totals do not bypass a new 90-pose warm-up")
        XCTAssertGreaterThan(model.customCount, firstCustom)
        secondEngine.emit(.estimate(StationAppleEstimate(cumulativeCount: 1.5, throughFrame: 90,
            throughTimestamp: 185.0 / 15, windowDuration: 89.0 / 15, processingMilliseconds: 12)))
        XCTAssertEqual(model.appleCount, 3.75)
        XCTAssertEqual(model.metrics.acceptedFrames, 185)
        XCTAssertEqual(model.metrics.appleCoveredFrames, 180)
        XCTAssertEqual(model.metrics.pendingFrames, 5, "Earlier uncovered tail stays visible")
        model.stop()
        secondEngine.emit(.finished)
        assertIncomplete(model.state)
    }

    func testReacquisitionCannotCompleteCycleStartedBeforeMissingMovement() {
        let old = ControlledStationAppleEngine()
        let new = ControlledStationAppleEngine()
        var engines = [old, new]
        let model = StationComparisonModel(appleEngineFactory: { engines.removeFirst() }, readinessDuration: 0)
        model.start(exercise: .curl)
        for index in 0..<7 { model.process(frame(sample(index: index, angle: 170))) }
        for index in 7..<15 { model.process(frame(sample(index: index, angle: 50))) }
        model.process(frame(StationPoseSample(timestamp: 1, joints: [:], personCount: 0)))
        for index in 16..<24 { model.process(frame(sample(index: index, angle: 170))) }
        XCTAssertEqual(model.customCount, 0, "Returning after a gap cannot finish the previous cycle")
        for index in 24..<34 { model.process(frame(sample(index: index, angle: 50))) }
        for index in 34..<43 { model.process(frame(sample(index: index, angle: 170))) }
        XCTAssertEqual(model.customCount, 1)
        XCTAssertEqual(new.inputs.first?.frameIndex, 1)
        model.invalidate(reason: "Test complete")
    }

    func testRecoveredReadinessNeedsStablePoseAndStopDoesNotWaitForMissingEngine() {
        let first = ControlledStationAppleEngine()
        let next = ControlledStationAppleEngine()
        var engines = [first, next]
        let model = StationComparisonModel(appleEngineFactory: { engines.removeFirst() })
        model.start(exercise: .curl)
        for index in 0..<10 { model.process(frame(sample(index: index))) }
        XCTAssertGreaterThan(model.metrics.acceptedFrames, 0)
        model.process(frame(StationPoseSample(timestamp: 10.0 / 15, joints: [:], personCount: 0)))
        for index in 11..<15 { model.process(frame(sample(index: index))) }
        assertReacquiring(model.state)
        XCTAssertEqual(next.inputs.count, 0)
        model.stop()
        assertIncomplete(model.state)
        XCTAssertFalse(model.state.isFinishing)
        XCTAssertEqual(first.finishCalls, 0, "The interrupted engine was cancelled, not left draining")
        XCTAssertEqual(next.finishCalls, 0)
    }

    func testStopDuringInitialReadinessFinishesImmediately() {
        let engine = ControlledStationAppleEngine()
        let model = StationComparisonModel(appleEngineFactory: { engine })
        model.start(exercise: .curl)
        model.process(frame(sample(index: 0)))
        model.stop()
        assertIncomplete(model.state)
        XCTAssertEqual(engine.finishCalls, 0)
        XCTAssertFalse(model.state.isFinishing)
    }

    private func assertReacquiring(_ state: StationComparisonState,
                                   file: StaticString = #filePath, line: UInt = #line) {
        guard case .reacquiring = state else {
            return XCTFail("Expected reacquisition, got \(state)", file: file, line: line)
        }
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
