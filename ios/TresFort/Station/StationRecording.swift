import AVFoundation
import CryptoKit
import Foundation
import ImageIO

enum StationRecordingState: Equatable {
    case idle
    case recording(elapsed: TimeInterval)
    case finishing
    case saved
    case failed(String)

    var isBusy: Bool {
        switch self {
        case .recording, .finishing: return true
        default: return false
        }
    }
}

enum StationRecordingFinishReason: String, Codable {
    case userStopped, durationLimit, cameraStopped, orientationChanged
}

/// A completed local package. Coordinates in its measurements use the same
/// upright, bottom-left, height-normalized system as StationPoseSample.
struct StationRecording: Codable, Identifiable, Equatable {
    let schemaVersion: Int
    let id: UUID
    let createdAt: Date
    let exerciseRawValue: String
    let durationSeconds: Double
    let frameCount: Int
    let droppedFrameCount: Int
    let orientation: UInt32
    let width: Int
    let height: Int
    let imageAspectRatio: Double
    let finishReason: StationRecordingFinishReason
    let appBuild: String
    var actualReps: Int?
    var detector: StationPoseDetector? = nil

    var exercise: StationExercise { StationExercise(rawValue: exerciseRawValue) ?? .squat }
    var imageOrientation: CGImagePropertyOrientation { CGImagePropertyOrientation(rawValue: orientation) ?? .up }
}

struct StationRecordingMeasurement: Codable, Equatable {
    struct Joint: Codable, Equatable {
        let x: Double?
        let y: Double?
        let confidence: Float?

        private enum CodingKeys: String, CodingKey { case x, y, confidence }

        func encode(to encoder: Encoder) throws {
            var container = encoder.container(keyedBy: CodingKeys.self)
            try container.encode(x, forKey: .x)
            try container.encode(y, forKey: .y)
            try container.encode(confidence, forKey: .confidence)
        }
    }

    let timestampSeconds: Double
    let sourceTimestampSeconds: Double
    let personCount: Int
    let visionMilliseconds: Double?
    var detector: StationPoseDetector?
    var inferenceMilliseconds: Double?
    let imageAspectRatio: Double
    let joints: [String: Joint]

    init(frame: StationComparisonFrame, timestampSeconds: Double) {
        self.timestampSeconds = timestampSeconds
        sourceTimestampSeconds = frame.sample.timestamp
        personCount = frame.sample.personCount
        detector = frame.detector
        inferenceMilliseconds = frame.inferenceMilliseconds
        visionMilliseconds = frame.detector == .appleVision ? frame.inferenceMilliseconds : nil
        imageAspectRatio = frame.imageAspectRatio
        // Include every joint, even when tracking returned no usable coordinate.
        // Missing points stay null rather than appearing as a confident origin.
        joints = Dictionary(uniqueKeysWithValues: StationJoint.allCases.map { joint in
            let point = frame.sample.joints[joint]
            return (joint.rawValue, Joint(
                x: point?.x.isFinite == true ? point?.x : nil,
                y: point?.y.isFinite == true ? point?.y : nil,
                confidence: point?.confidence.isFinite == true ? point?.confidence : nil))
        })
    }
}

enum StationRecordingError: LocalizedError {
    case storageFull, invalidReps, missingRecording, invalidManifest, damagedRecording(UUID), noFrames, encodingFailed

    var errorDescription: String? {
        switch self {
        case .storageFull: return "There are 20 saved tests. Delete a test before recording another."
        case .invalidReps: return "Enter an actual rep count between 0 and 1,000."
        case .missingRecording: return "This test is no longer available on this iPad."
        case .invalidManifest: return "This test could not be read."
        case .damagedRecording: return "A saved test is damaged. Delete damaged tests to restore the recording list."
        case .noFrames: return "No video frames were saved. Keep the camera on and try again."
        case .encodingFailed: return "The test could not be saved. Free some storage and try again."
        }
    }
}

/// Video is never added to Photos, synced with workouts, or backed up to iCloud.
/// A final manifest is published only after both local data files are complete.
final class StationRecordingStore: @unchecked Sendable {
    static let maximumDuration: TimeInterval = 45
    static let maximumSavedRecordings = 20
    private static let initializationLock = NSLock()
    private static var initializedRoots: Set<String> = []

    let rootURL: URL
    let session: StationSessionGate

    init(session: StationSessionGate, baseURL: URL? = nil) throws {
        self.session = session
        rootURL = try Self.accountDirectory(accountID: session.accountID, baseURL: baseURL)
        try session.withAccess {
        try FileManager.default.createDirectory(at: self.rootURL, withIntermediateDirectories: true,
                                               attributes: [.protectionKey: FileProtectionType.complete])
        var localRoot = self.rootURL
        var resources = URLResourceValues()
        resources.isExcludedFromBackup = true
        try localRoot.setResourceValues(resources)

        Self.initializationLock.lock()
        defer { Self.initializationLock.unlock() }
        if !Self.initializedRoots.contains(self.rootURL.path) {
            // No recorder exists before the first store in this process. Remove
            // incomplete files left by a killed process, without touching saved tests.
            for url in try FileManager.default.contentsOfDirectory(at: self.rootURL, includingPropertiesForKeys: nil)
            where url.lastPathComponent.hasPrefix(".pending-")
                && UUID(uuidString: String(url.lastPathComponent.dropFirst(".pending-".count))) != nil {
                try FileManager.default.removeItem(at: url)
            }
            Self.initializedRoots.insert(self.rootURL.path)
        }
        }
    }

    /// Unscoped prototype clips remain untouched and are never attributed to
    /// whichever account happens to sign in first after this upgrade.
    static func accountDirectory(accountID: String, baseURL: URL? = nil) throws -> URL {
        guard let base = baseURL ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)
            .first?.appendingPathComponent("StationRecordings", isDirectory: true) else {
            throw CocoaError(.fileNoSuchFile)
        }
        let digest = SHA256.hash(data: Data(accountID.utf8)).map { String(format: "%02x", $0) }.joined()
        return base.appendingPathComponent("accounts", isDirectory: true).appendingPathComponent(digest, isDirectory: true)
    }

    @MainActor
    static func deleteAccountRecordings(accountID: String, baseURL: URL? = nil) throws {
        StationAccess.invalidateAccount(accountID)
        try StationSessionGate.revokeAccount(accountID) {
            let root = try accountDirectory(accountID: accountID, baseURL: baseURL)
            if FileManager.default.fileExists(atPath: root.path) { try FileManager.default.removeItem(at: root) }
        }
    }

    func list() throws -> [StationRecording] {
        try session.withAccess {
        try FileManager.default.contentsOfDirectory(at: rootURL, includingPropertiesForKeys: nil)
            .compactMap { url -> StationRecording? in
                guard let id = UUID(uuidString: url.lastPathComponent) else { return nil }
                // Surface damage instead of quietly creating an undeletable item
                // which still occupies one of the bounded storage slots.
                do { return try load(id: id) }
                catch { throw StationRecordingError.damagedRecording(id) }
            }
            .sorted { $0.createdAt > $1.createdAt }
        }
    }

    func load(id: UUID) throws -> StationRecording {
        try session.withAccess {
        let url = try manifestURL(for: id)
        guard FileManager.default.fileExists(atPath: url.path) else { throw StationRecordingError.missingRecording }
        let recording = try JSONDecoder().decode(StationRecording.self, from: Data(contentsOf: url))
        guard recording.schemaVersion == 1, recording.id == id,
              recording.frameCount > 0, recording.durationSeconds.isFinite,
              recording.frameCount <= Int(Self.maximumDuration * 15), recording.droppedFrameCount >= 0,
              recording.durationSeconds >= 0, recording.durationSeconds <= Self.maximumDuration,
              (1...1920).contains(recording.width), (1...1440).contains(recording.height),
              [.up, .down, .left, .right].contains(recording.imageOrientation),
              CGImagePropertyOrientation(rawValue: recording.orientation) != nil,
              StationExercise(rawValue: recording.exerciseRawValue) != nil,
              recording.actualReps == nil || (0...1_000).contains(recording.actualReps!),
              recording.imageAspectRatio.isFinite, recording.imageAspectRatio > 0,
              FileManager.default.fileExists(atPath: try videoURL(for: id).path),
              FileManager.default.fileExists(atPath: try measurementsURL(for: id).path) else {
            throw StationRecordingError.invalidManifest
        }
        let rotates = recording.imageOrientation == .left || recording.imageOrientation == .right
        let expectedAspect = rotates ? Double(recording.height) / Double(recording.width) : Double(recording.width) / Double(recording.height)
        guard abs(recording.imageAspectRatio - expectedAspect) < 0.000001 else { throw StationRecordingError.invalidManifest }
        return recording
        }
    }

    func delete(id: UUID) throws {
        try session.withAccess {
        let url = try directoryURL(for: id)
        if FileManager.default.fileExists(atPath: url.path) { try FileManager.default.removeItem(at: url) }
        }
    }

    @discardableResult
    func updateActualReps(_ reps: Int?, for id: UUID) throws -> StationRecording {
        try session.withAccess {
        guard reps == nil || (0...1_000).contains(reps!) else { throw StationRecordingError.invalidReps }
        var recording = try load(id: id)
        recording.actualReps = reps
        try JSONEncoder().encode(recording).write(to: manifestURL(for: id), options: [.atomic, .completeFileProtection])
        return recording
        }
    }

    func directoryURL(for id: UUID) throws -> URL { try session.withAccess { rootURL.appendingPathComponent(id.uuidString, isDirectory: true) } }
    func videoURL(for id: UUID) throws -> URL { try directoryURL(for: id).appendingPathComponent("clip.mov") }
    func measurementsURL(for id: UUID) throws -> URL { try directoryURL(for: id).appendingPathComponent("measurements.jsonl") }
    func manifestURL(for id: UUID) throws -> URL { try directoryURL(for: id).appendingPathComponent("manifest.json") }

    func shareURLs(for id: UUID) throws -> [URL] {
        try session.withAccess {
            _ = try load(id: id)
            var urls = try [videoURL(for: id), measurementsURL(for: id), manifestURL(for: id)]
            let comparison = try directoryURL(for: id).appendingPathComponent("comparison.json")
            if FileManager.default.fileExists(atPath: comparison.path) { urls.append(comparison) }
            return urls
        }
    }

    func saveComparison(_ report: StationReplayReport, for id: UUID) throws {
        try session.withAccess {
            _ = try load(id: id)
            guard report.recordingID == id else { throw StationRecordingError.invalidManifest }
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys]
            try encoder.encode(report).write(to: directoryURL(for: id).appendingPathComponent("comparison.json"),
                                             options: [.atomic, .completeFileProtection])
        }
    }

    func prepare(id: UUID) throws -> URL {
        try session.withAccess {
        Self.initializationLock.lock()
        defer { Self.initializationLock.unlock() }
        let reservedCount = try FileManager.default.contentsOfDirectory(at: rootURL, includingPropertiesForKeys: nil)
            .filter {
                UUID(uuidString: $0.lastPathComponent) != nil
                    || ($0.lastPathComponent.hasPrefix(".pending-")
                        && UUID(uuidString: String($0.lastPathComponent.dropFirst(".pending-".count))) != nil)
            }.count
        guard reservedCount < Self.maximumSavedRecordings else { throw StationRecordingError.storageFull }
        let url = pendingURL(for: id)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: false,
                                               attributes: [.protectionKey: FileProtectionType.complete])
        do {
            var excluded = url
            var resources = URLResourceValues()
            resources.isExcludedFromBackup = true
            try excluded.setResourceValues(resources)
        } catch {
            try? FileManager.default.removeItem(at: url)
            throw error
        }
        return url
        }
    }

    func publish(_ recording: StationRecording) throws {
        try session.withAccess {
        let pending = pendingURL(for: recording.id)
        try JSONEncoder().encode(recording).write(to: pending.appendingPathComponent("manifest.json"),
                                                  options: [.atomic, .completeFileProtection])
        try FileManager.default.moveItem(at: pending, to: directoryURL(for: recording.id))
        }
    }

    func discardPending(id: UUID) {
        session.cleanup { try? FileManager.default.removeItem(at: pendingURL(for: id)) }
    }

    private func pendingURL(for id: UUID) -> URL { rootURL.appendingPathComponent(".pending-\(id.uuidString)", isDirectory: true) }
}

/// Only accepted frames advance this timeline. In particular, encoder
/// backpressure cannot create JSON rows for video frames that do not exist.
struct StationRecordingTimeline {
    private(set) var firstTimestamp: CMTime?
    private(set) var lastTimestamp: CMTime?
    private(set) var frameCount = 0

    func presentationTime(for timestamp: CMTime) -> CMTime? {
        guard timestamp.isNumeric, CMTimeGetSeconds(timestamp).isFinite else { return nil }
        if let lastTimestamp, CMTimeCompare(timestamp, lastTimestamp) <= 0 { return nil }
        let relative = firstTimestamp.map { CMTimeSubtract(timestamp, $0) } ?? .zero
        guard CMTimeGetSeconds(relative) < StationRecordingStore.maximumDuration else { return nil }
        return relative
    }

    mutating func accept(_ timestamp: CMTime) {
        if firstTimestamp == nil { firstTimestamp = timestamp }
        lastTimestamp = timestamp
        frameCount += 1
    }

    var duration: TimeInterval {
        guard let firstTimestamp, let lastTimestamp else { return 0 }
        return CMTimeGetSeconds(CMTimeSubtract(lastTimestamp, firstTimestamp))
    }
}

/// Accessed only on StationCaptureWorker's serial queue, including the writer
/// completion. AVAssetWriter owns encoder buffering; no frame array is retained.
final class StationRecordingWriter {
    let id: UUID
    let exercise: StationExercise
    private let store: StationRecordingStore
    private let createdAt = Date()
    private let directory: URL
    private let measurements: FileHandle
    private var writer: AVAssetWriter?
    private var input: AVAssetWriterInput?
    private var adaptor: AVAssetWriterInputPixelBufferAdaptor?
    private(set) var timeline = StationRecordingTimeline()
    private var droppedFrames = 0
    private var detector: StationPoseDetector?
    private var orientation: CGImagePropertyOrientation = .up
    private var width = 0
    private var height = 0
    private var aspect: Double = 1
    private var finishing = false
    private var terminal = false

    init(exercise: StationExercise, store: StationRecordingStore) throws {
        let id = UUID()
        self.id = id
        self.exercise = exercise
        self.store = store
        let directory = try store.prepare(id: id)
        self.directory = directory
        let url = directory.appendingPathComponent("measurements.jsonl")
        do {
            guard FileManager.default.createFile(atPath: url.path, contents: nil,
                                                attributes: [.protectionKey: FileProtectionType.complete]) else {
                throw StationRecordingError.encodingFailed
            }
            measurements = try FileHandle(forWritingTo: url)
        } catch {
            store.discardPending(id: id)
            throw error
        }
    }

    @discardableResult
    func append(pixelBuffer: CVPixelBuffer, time: CMTime, orientation: CGImagePropertyOrientation,
                frame: StationComparisonFrame) throws -> Bool {
        try store.session.withAccess {
        guard !finishing, !terminal else { return false }
        if writer == nil { try configure(pixelBuffer: pixelBuffer, orientation: orientation, aspect: frame.imageAspectRatio) }
        guard let writer, let input, let adaptor, writer.status == .writing else {
            throw StationRecordingError.encodingFailed
        }
        guard input.isReadyForMoreMediaData, let presentationTime = timeline.presentationTime(for: time) else {
            droppedFrames += 1
            return false
        }
        var row = try JSONEncoder().encode(StationRecordingMeasurement(
            frame: frame, timestampSeconds: CMTimeGetSeconds(presentationTime)))
        row.append(0x0a)
        guard adaptor.append(pixelBuffer, withPresentationTime: presentationTime) else {
            throw StationRecordingError.encodingFailed
        }
        // Any measurement write failure discards the entire package, so a saved
        // package never contains a video/measurement count mismatch.
        try measurements.write(contentsOf: row)
        detector = detector ?? frame.detector
        timeline.accept(time)
        return true
        }
    }

    func finish(reason: StationRecordingFinishReason, queue: DispatchQueue,
                completion: @escaping (Result<StationRecording, Error>) -> Void) {
        guard !finishing, !terminal else { return }
        finishing = true
        guard store.session.isActive else {
            cancel()
            completion(.failure(StationAccessError.sessionEnded))
            return
        }
        guard let writer, let input, timeline.frameCount > 0 else {
            cancel()
            completion(.failure(StationRecordingError.noFrames))
            return
        }
        input.markAsFinished()
        writer.finishWriting { [self] in
            queue.async { [self] in
                guard !terminal else { return }
                do {
                    guard writer.status == .completed else { throw StationRecordingError.encodingFailed }
                    try measurements.close()
                    let recording = StationRecording(
                        schemaVersion: 1, id: id, createdAt: createdAt, exerciseRawValue: exercise.rawValue,
                        durationSeconds: timeline.duration, frameCount: timeline.frameCount,
                        droppedFrameCount: droppedFrames, orientation: orientation.rawValue,
                        width: width, height: height, imageAspectRatio: aspect, finishReason: reason,
                        appBuild: Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "unknown", actualReps: nil, detector: detector)
                    try store.publish(recording)
                    terminal = true
                    completion(.success(recording))
                } catch {
                    cancel()
                    completion(.failure(error))
                }
            }
        }
    }

    func cancel() {
        guard !terminal else { return }
        terminal = true
        if let writer, writer.status == .writing || writer.status == .unknown { writer.cancelWriting() }
        try? measurements.close()
        store.discardPending(id: id)
    }

    private func configure(pixelBuffer: CVPixelBuffer, orientation: CGImagePropertyOrientation, aspect: Double) throws {
        width = CVPixelBufferGetWidth(pixelBuffer)
        height = CVPixelBufferGetHeight(pixelBuffer)
        self.orientation = orientation
        self.aspect = aspect
        let writer = try AVAssetWriter(outputURL: directory.appendingPathComponent("clip.mov"), fileType: .mov)
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.h264,
            AVVideoWidthKey: width, AVVideoHeightKey: height,
            AVVideoCompressionPropertiesKey: [AVVideoAverageBitRateKey: 3_000_000]
        ])
        input.expectsMediaDataInRealTime = true
        input.transform = Self.playbackTransform(orientation: orientation, width: width, height: height)
        guard writer.canAdd(input) else { throw StationRecordingError.encodingFailed }
        writer.add(input)
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input, sourcePixelBufferAttributes: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferWidthKey as String: width, kCVPixelBufferHeightKey as String: height
        ])
        guard writer.startWriting() else { throw StationRecordingError.encodingFailed }
        writer.startSession(atSourceTime: .zero)
        self.writer = writer
        self.input = input
        self.adaptor = adaptor
    }

    static func playbackTransform(orientation: CGImagePropertyOrientation, width: Int, height: Int) -> CGAffineTransform {
        switch orientation {
        case .right: return CGAffineTransform(a: 0, b: 1, c: -1, d: 0, tx: CGFloat(height), ty: 0)
        case .down: return CGAffineTransform(a: -1, b: 0, c: 0, d: -1, tx: CGFloat(width), ty: CGFloat(height))
        case .left: return CGAffineTransform(a: 0, b: -1, c: 1, d: 0, tx: 0, ty: CGFloat(width))
        default: return .identity
        }
    }
}
