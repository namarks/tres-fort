import AVFoundation
import Combine
import Foundation
import ImageIO
import Vision

struct StationReplayPoint: Codable, Equatable {
    let x: Double
    let y: Double
    let score: Float
}

struct StationReplayPose: Codable, Equatable {
    let personCount: Int
    let joints: [String: StationReplayPoint]
    let milliseconds: Double

    func sample(at timestamp: Double) -> StationPoseSample {
        StationPoseSample(timestamp: timestamp, joints: Dictionary(uniqueKeysWithValues:
            joints.compactMap { name, point in
                StationJoint(rawValue: name).map {
                    ($0, StationJointPoint(x: point.x, y: point.y, confidence: point.score))
                }
            }), personCount: personCount)
    }
}

struct StationReplayFrame: Codable, Equatable {
    let timestamp: Double
    let apple: StationReplayPose
    let mediaPipe: StationReplayPose
    let mediaPipeLandmarks: [[StationMediaPipeLandmark]]
    let mediaPipeWorldLandmarks: [[StationMediaPipeWorldLandmark]]
    let appleCycles: Int
    // For curls these legacy scalar fields contain max(left, right), never
    // their sum. New displays use the explicit per-arm fields below.
    let mediaPipeCycles: Int
    var appleLeftCycles: Int? = nil
    var appleRightCycles: Int? = nil
    var mediaPipeLeftCycles: Int? = nil
    var mediaPipeRightCycles: Int? = nil
}

struct StationReplayReport: Codable {
    let schemaVersion: Int
    let recordingID: UUID
    let createdAt: Date
    let appleRevision: Int
    let mediaPipeModel: String
    let mediaPipeRuntime: String
    let mediaPipeModelSHA256: String
    let osVersion: String
    let appBuild: String
    let frames: [StationReplayFrame]
    var counterVersion: String? = nil
}

enum StationReplayError: LocalizedError {
    case invalidRecording, readFailed, noFrames, multiplePeople
    var errorDescription: String? {
        switch self {
        case .invalidRecording: return "This recording cannot be compared. Try a new test."
        case .readFailed: return "The video could not be read completely. Try again."
        case .noFrames: return "This recording has no video frames."
        case .multiplePeople: return "More than one person was detected. Counts are unavailable for this test. Record a new test with only one person visible."
        }
    }
}

/// Both detectors see each decoded, unrotated frame with the same orientation
/// and source time. Offline speed is deliberately not presented as live FPS.
enum StationReplayWorker {
    static func run(recording: StationRecording, videoURL: URL, session: StationSessionGate,
                    appleDetection: ((CVPixelBuffer, CGImagePropertyOrientation) throws -> StationReplayPose)? = nil,
                    progress: @escaping @Sendable (Int) -> Void) async throws -> StationReplayReport {
        try session.requireActive()
        guard let orientation = CGImagePropertyOrientation(rawValue: recording.orientation),
              recording.durationSeconds <= 46, recording.frameCount <= 1_400,
              recording.width > 0, recording.height > 0 else { throw StationReplayError.invalidRecording }
        let asset = AVURLAsset(url: videoURL)
        guard let track = try await asset.loadTracks(withMediaType: .video).first else {
            throw StationReplayError.noFrames
        }
        try Task.checkCancellation()
        try session.requireActive()
        let reader = try AVAssetReader(asset: asset)
        let output = AVAssetReaderTrackOutput(track: track, outputSettings: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA
        ])
        output.alwaysCopiesSampleData = false
        guard reader.canAdd(output) else { throw StationReplayError.readFailed }
        reader.add(output)
        guard try session.withAccess({ reader.startReading() }) else { throw reader.error ?? StationReplayError.readFailed }
        defer { reader.cancelReading() }
        let vision = VNDetectHumanBodyPoseRequest()
        let mediaPipe = try StationMediaPipeDetector()
        var frames: [StationReplayFrame] = []
        var appleCounter = StationMovementCounter(exercise: recording.exercise)
        var mediaPipeCounter = StationMovementCounter(exercise: recording.exercise)
        var previousTimestamp = -Double.infinity
        var previousMilliseconds = -1
        while let buffer = try session.withAccess({ output.copyNextSampleBuffer() }) {
            try Task.checkCancellation()
            try session.requireActive()
            guard frames.count < 1_400 else { throw StationReplayError.invalidRecording }
            let frame: StationReplayFrame = try autoreleasepool {
                let timestamp = CMTimeGetSeconds(CMSampleBufferGetPresentationTimeStamp(buffer))
                let milliseconds = try validatedMilliseconds(timestamp, after: previousTimestamp,
                                                              previousMilliseconds: previousMilliseconds)
                guard
                      let pixels = CMSampleBufferGetImageBuffer(buffer),
                      CVPixelBufferGetWidth(pixels) == recording.width,
                      CVPixelBufferGetHeight(pixels) == recording.height else {
                    throw StationReplayError.invalidRecording
                }
                previousTimestamp = timestamp
                previousMilliseconds = milliseconds
                let apple = try appleDetection?(pixels, orientation)
                    ?? detectApple(pixels: pixels, orientation: orientation, request: vision, aspect: recording.imageAspectRatio)
                let result = try mediaPipe.detect(pixelBuffer: pixels, timestampMilliseconds: milliseconds,
                                                  orientation: orientation)
                let mp = adaptMediaPipe(result, aspect: recording.imageAspectRatio)
                // Identity ambiguity is terminal for the whole comparison,
                // just as it is for live tracking. Never join different people
                // across a reset or publish a partial stream as a full total.
                try validateIdentity(applePersonCount: apple.personCount, mediaPipePersonCount: mp.personCount)
                appleCounter.process(apple.sample(at: timestamp))
                mediaPipeCounter.process(mp.sample(at: timestamp))
                return StationReplayFrame(timestamp: timestamp, apple: apple, mediaPipe: mp,
                                          mediaPipeLandmarks: result.poses, mediaPipeWorldLandmarks: result.worldPoses,
                                          appleCycles: appleCounter.count, mediaPipeCycles: mediaPipeCounter.count,
                                          appleLeftCycles: appleCounter.leftCount, appleRightCycles: appleCounter.rightCount,
                                          mediaPipeLeftCycles: mediaPipeCounter.leftCount, mediaPipeRightCycles: mediaPipeCounter.rightCount)
            }
            try session.requireActive()
            frames.append(frame)
            if frames.count.isMultiple(of: 15) { progress(frames.count) }
        }
        try Task.checkCancellation()
        try session.requireActive()
        guard reader.status == .completed else { throw reader.error ?? StationReplayError.readFailed }
        guard !frames.isEmpty, frames.count == recording.frameCount else { throw StationReplayError.readFailed }
        return StationReplayReport(schemaVersion: 1, recordingID: recording.id, createdAt: Date(),
                                   appleRevision: vision.revision, mediaPipeModel: StationMediaPipeDetector.modelIdentifier,
                                   mediaPipeRuntime: StationMediaPipeDetector.runtimeVersion,
                                   mediaPipeModelSHA256: StationMediaPipeDetector.modelSHA256,
                                   osVersion: ProcessInfo.processInfo.operatingSystemVersionString,
                                   appBuild: Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "unknown",
                                   frames: frames, counterVersion: "independent-curl-arms-v1")
    }

    static func validateIdentity(applePersonCount: Int, mediaPipePersonCount: Int) throws {
        guard applePersonCount <= 1, mediaPipePersonCount <= 1 else { throw StationReplayError.multiplePeople }
    }

    static func validatedMilliseconds(_ timestamp: Double, after previous: Double,
                                      previousMilliseconds: Int) throws -> Int {
        guard timestamp.isFinite, timestamp >= 0, timestamp <= 46, timestamp > previous else {
            throw StationReplayError.invalidRecording
        }
        let milliseconds = Int((timestamp * 1_000).rounded())
        guard milliseconds > previousMilliseconds else { throw StationReplayError.invalidRecording }
        return milliseconds
    }

    private static func detectApple(pixels: CVPixelBuffer, orientation: CGImagePropertyOrientation,
                                    request: VNDetectHumanBodyPoseRequest, aspect: Double) throws -> StationReplayPose {
        let started = ProcessInfo.processInfo.systemUptime
        try VNImageRequestHandler(cvPixelBuffer: pixels, orientation: orientation).perform([request])
        let milliseconds = (ProcessInfo.processInfo.systemUptime - started) * 1_000
        let observations = request.results ?? []
        var joints: [String: StationReplayPoint] = [:]
        if observations.count == 1, let observation = observations.first {
            let points = try observation.recognizedPoints(.all)
            for (joint, name) in jointNames {
                guard let point = points[name], point.x.isFinite, point.y.isFinite,
                      point.confidence.isFinite else { continue }
                joints[joint.rawValue] = StationReplayPoint(x: Double(point.x) * aspect,
                                                           y: Double(point.y), score: point.confidence)
            }
        }
        return StationReplayPose(personCount: observations.count, joints: joints, milliseconds: milliseconds)
    }

    static func adaptMediaPipe(_ detection: StationMediaPipeDetection, aspect: Double) -> StationReplayPose {
        var joints: [String: StationReplayPoint] = [:]
        if detection.poses.count == 1, let pose = detection.poses.first {
            for (joint, index) in mediaPipeIndices where index < pose.count {
                let p = pose[index]
                let score = min(p.visibility ?? 0, p.presence ?? 0)
                guard p.x.isFinite, p.y.isFinite, score.isFinite else { continue }
                joints[joint.rawValue] = StationReplayPoint(x: Double(p.x) * aspect, y: 1 - Double(p.y), score: score)
            }
        }
        return StationReplayPose(personCount: detection.poses.count, joints: joints,
                                 milliseconds: detection.inferenceMilliseconds)
    }

    private static let mediaPipeIndices: [(StationJoint, Int)] = [
        (.leftShoulder, 11), (.rightShoulder, 12), (.leftElbow, 13), (.rightElbow, 14),
        (.leftWrist, 15), (.rightWrist, 16), (.leftHip, 23), (.rightHip, 24),
        (.leftKnee, 25), (.rightKnee, 26), (.leftAnkle, 27), (.rightAnkle, 28)
    ]
    private static let jointNames: [(StationJoint, VNHumanBodyPoseObservation.JointName)] = [
        (.leftShoulder, .leftShoulder), (.rightShoulder, .rightShoulder),
        (.leftElbow, .leftElbow), (.rightElbow, .rightElbow), (.leftWrist, .leftWrist), (.rightWrist, .rightWrist),
        (.leftHip, .leftHip), (.rightHip, .rightHip), (.leftKnee, .leftKnee), (.rightKnee, .rightKnee),
        (.leftAnkle, .leftAnkle), (.rightAnkle, .rightAnkle)
    ]
}

@MainActor
final class StationReplayModel: ObservableObject {
    typealias Runner = @Sendable (StationRecording, URL, StationSessionGate, @escaping @Sendable (Int) -> Void) async throws -> StationReplayReport
    @Published private(set) var report: StationReplayReport?
    @Published private(set) var completedFrames = 0
    @Published private(set) var isRunning = false
    @Published private(set) var error: String?
    private var task: Task<Void, Never>?
    private var generation = UUID()
    private let access: StationAccess
    private let runner: Runner

    init(access: StationAccess, runner: @escaping Runner = { recording, url, session, progress in
        try await StationReplayWorker.run(recording: recording, videoURL: url, session: session, progress: progress)
    }) {
        self.access = access
        self.runner = runner
        access.observeInvalidation { [weak self] in
            guard let self else { return false }
            self.clear()
            return true
        }
    }

    @discardableResult
    func start(recording: StationRecording, store: StationRecordingStore) -> Task<Void, Never>? {
        cancel()
        report = nil
        error = nil
        completedFrames = 0
        guard access.validate(), store.session === access.session else { return nil }
        let url: URL
        do {
            _ = try store.load(id: recording.id)
            url = try store.videoURL(for: recording.id)
            // Reruns replace derived evidence. If a rerun fails or discovers an
            // ambiguous identity, sharing must not revive an older total.
            try store.removeComparison(for: recording.id)
        }
        catch { self.error = error.localizedDescription; return nil }
        isRunning = true
        let token = generation
        let session = access.session
        let runner = self.runner
        let progress: @Sendable (Int) -> Void = { [weak self] count in
            guard let model = self else { return }
            Task { @MainActor in
                guard model.access.validate(), model.generation == token else { return }
                model.completedFrames = count
            }
        }
        task = Task { [weak self] in
            let worker = Task.detached(priority: .userInitiated) {
                try session.requireActive()
                return try await runner(recording, url, session, progress)
            }
            do {
                let report = try await withTaskCancellationHandler { try await worker.value }
                    onCancel: { worker.cancel() }
                try Task.checkCancellation()
                guard let self, self.access.validate(), self.generation == token else { return }
                try store.saveComparison(report, for: recording.id)
                self.report = report
                self.completedFrames = report.frames.count
                self.isRunning = false
            } catch is CancellationError { }
            catch {
                guard let self, self.access.validate(), self.generation == token else { return }
                self.error = error.localizedDescription
                self.isRunning = false
            }
        }
        return task
    }

    func cancel() {
        generation = UUID()
        task?.cancel()
        task = nil
        isRunning = false
    }

    func clear() {
        cancel()
        report = nil
        error = nil
        completedFrames = 0
    }

    deinit { task?.cancel() }
}
