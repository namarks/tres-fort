import CreateMLComponents
import Foundation

struct StationAppleInput: Sendable {
    let pose: Pose
    let timestamp: TimeInterval
    /// One-based position in this trial's shared, accepted pose stream.
    let frameIndex: Int
}

struct StationAppleEstimate: Sendable {
    let cumulativeCount: Float
    let throughFrame: Int
    let throughTimestamp: TimeInterval
    let windowDuration: TimeInterval
    /// Time from consuming a prepared window to receiving its result; excludes
    /// waiting for camera input. It is not camera-to-screen latency.
    let processingMilliseconds: Double
}

enum StationAppleCounterEvent {
    case estimate(StationAppleEstimate)
    case finished
    case failed(String)
}

/// A fresh engine belongs to one trial. Synchronous admission lets both counters
/// consume exactly the same prefix even if the model cannot keep up.
@MainActor
protocol StationAppleCountingEngine: AnyObject {
    func start(onEvent: @escaping @MainActor (StationAppleCounterEvent) -> Void)
    func append(_ input: StationAppleInput) -> Bool
    func finish()
    func cancel()
}

struct StationAppleWindow: Sendable {
    let poses: [Pose]
    let firstTimestamp: TimeInterval
    let lastTimestamp: TimeInterval
    let throughFrame: Int

    /// Match SlidingWindowTransformer: range values are pose indices, even
    /// when upstream timestamps use finer ticks. The model uses index overlap.
    /// This nominal sampling clock is not a capture-rate or latency measurement.
    func identifier(source: String) -> TemporalSegmentIdentifier {
        TemporalSegmentIdentifier(source: source,
                                  range: (throughFrame - StationAppleWindowBuilder.length)..<throughFrame,
                                  timescale: 15)
    }
}

/// Apple's sample uses 90 poses and a stride of five. An unfinished tail is
/// intentionally not padded: synthetic poses could change the estimated count.
struct StationAppleWindowBuilder {
    static let length = 90
    static let stride = 5
    private var inputs: [StationAppleInput] = []
    private var framesSinceWindow = 0
    private var hasWindow = false

    var bufferedPoseCount: Int { inputs.count }

    mutating func append(_ input: StationAppleInput) -> StationAppleWindow? {
        inputs.append(input)
        if inputs.count > Self.length { inputs.removeFirst() }
        framesSinceWindow += 1
        guard inputs.count == Self.length,
              !hasWindow || framesSinceWindow == Self.stride else { return nil }
        hasWindow = true
        framesSinceWindow = 0
        return StationAppleWindow(poses: inputs.map(\.pose), firstTimestamp: inputs[0].timestamp,
                                  lastTimestamp: input.timestamp, throughFrame: input.frameIndex)
    }
}

/// Uses the real system model. At most one window waits behind the in-flight
/// inference, plus the builder's 90 poses. No images enter or leave this type.
@MainActor
final class StationAppleCounter: StationAppleCountingEngine {
    private struct PendingWindow {
        let window: StationAppleWindow
        var startedAt: TimeInterval?
    }

    private var generation = UUID()
    private var continuation: AsyncStream<TemporalFeature<[Pose]>>.Continuation?
    private var task: Task<Void, Never>?
    private var handler: (@MainActor (StationAppleCounterEvent) -> Void)?
    private var builder = StationAppleWindowBuilder()
    private var pending: [TemporalSegmentIdentifier: PendingWindow] = [:]
    private var accepting = false

#if DEBUG
    private var diagnosticDroppedWindows = 0
    private var diagnosticTerminatedWindows = 0
    var diagnosticSnapshot: StationAppleDiagnosticSnapshot {
        StationAppleDiagnosticSnapshot(
            bufferedPoses: builder.bufferedPoseCount,
            queuedWindows: pending.values.filter { $0.startedAt == nil }.count,
            inFlightWindows: pending.values.filter { $0.startedAt != nil }.count,
            droppedWindows: diagnosticDroppedWindows, terminatedWindows: diagnosticTerminatedWindows)
    }
#endif

    func start(onEvent: @escaping @MainActor (StationAppleCounterEvent) -> Void) {
        cancel()
#if DEBUG
        diagnosticDroppedWindows = 0
        diagnosticTerminatedWindows = 0
#endif
        let generation = UUID()
        self.generation = generation
        handler = onEvent
        accepting = true
        builder = StationAppleWindowBuilder()
        let stream = AsyncStream<TemporalFeature<[Pose]>>(bufferingPolicy: .bufferingOldest(1)) {
            continuation = $0
        }
        task = Task.detached(priority: .userInitiated) { [weak self] in
            do {
                // Mark consumption rather than iterator.next(): next() can spend
                // seconds waiting for enough future camera poses to fill a window.
                let timedStream = stream.map { item in
                    let startedAt = ProcessInfo.processInfo.systemUptime
                    await self?.markStarted(item.id, at: startedAt, generation: generation)
                    return item
                }
                let sequence = AnyTemporalSequence<[Pose]>(timedStream, count: nil)
                let results = try await HumanBodyActionCounter().applied(to: sequence)
                for try await result in results {
                    guard !Task.isCancelled else { return }
                    await self?.receive(result, at: ProcessInfo.processInfo.systemUptime,
                                        generation: generation)
                }
                guard !Task.isCancelled else { return }
                await self?.complete(generation: generation)
            } catch {
                guard !Task.isCancelled else { return }
                await self?.fail(generation: generation)
            }
        }
    }

    func append(_ input: StationAppleInput) -> Bool {
        guard accepting, let continuation else { return false }
        // Match the official sample's body-joint selection, after the original
        // Vision observation has been converted to Pose in the capture worker.
        let selected = JointsSelector(ignoredJoints: [.nose, .leftEye, .leftEar, .rightEye, .rightEar])
            .applied(to: input.pose)
        let input = StationAppleInput(pose: selected, timestamp: input.timestamp, frameIndex: input.frameIndex)
        guard let window = builder.append(input) else { return true }
        // Capture timestamps stay on the window for measured history/lag. The
        // counter requires the same frame-index ranges as Apple's transformer;
        // microsecond ranges trap inside it on the second overlapping window.
        let id = window.identifier(source: generation.uuidString)
        pending[id] = PendingWindow(window: window)
        switch continuation.yield(TemporalFeature(id: id, feature: window.poses)) {
        case .enqueued:
            return true
        case .dropped:
#if DEBUG
            diagnosticDroppedWindows += 1
#endif
            pending.removeValue(forKey: id)
            return false
        case .terminated:
#if DEBUG
            diagnosticTerminatedWindows += 1
#endif
            pending.removeValue(forKey: id)
            return false
        @unknown default:
            pending.removeValue(forKey: id)
            return false
        }
    }

    func finish() {
        accepting = false
        continuation?.finish()
        continuation = nil
    }

    func cancel() {
        generation = UUID()
        accepting = false
        continuation?.finish()
        continuation = nil
        task?.cancel()
        task = nil
        handler = nil
        pending.removeAll()
        builder = StationAppleWindowBuilder()
    }

    private func markStarted(_ id: TemporalSegmentIdentifier, at time: TimeInterval, generation: UUID) {
        guard self.generation == generation else { return }
        pending[id]?.startedAt = time
    }

    private func receive(_ result: TemporalFeature<Float>, at time: TimeInterval, generation: UUID) {
        guard self.generation == generation else { return }
        guard let item = pending.removeValue(forKey: result.id), let startedAt = item.startedAt else {
            fail(generation: generation)
            return
        }
        handler?(.estimate(StationAppleEstimate(cumulativeCount: result.feature,
                                               throughFrame: item.window.throughFrame,
                                               throughTimestamp: item.window.lastTimestamp,
                                               windowDuration: item.window.lastTimestamp - item.window.firstTimestamp,
                                               processingMilliseconds: max(0, time - startedAt) * 1_000)))
    }

    private func complete(generation: UUID) {
        guard self.generation == generation else { return }
        accepting = false
        task = nil
        handler?(.finished)
        handler = nil
        pending.removeAll()
        builder = StationAppleWindowBuilder()
    }

    private func fail(generation: UUID) {
        guard self.generation == generation else { return }
        let handler = handler
        cancel()
        handler?(.failed("Apple's counter could not run. Start a new trial to retry on this device."))
    }

    deinit {
        continuation?.finish()
        task?.cancel()
    }
}
