import CoreImage
import CoreVideo
import CryptoKit
import Foundation
import ImageIO
import MediaPipeTasksVision

/// Coordinates use the upright image, top-left origin. Depth uses the model's
/// approximate image-width scale; it is not a measured distance in metres.
struct StationMediaPipeLandmark: Codable, Equatable, Sendable {
    let x: Float
    let y: Float
    let z: Float
    let visibility: Float?
    let presence: Float?
}

/// Hip-centred model estimates in metres, not depth-sensor measurements.
struct StationMediaPipeWorldLandmark: Codable, Equatable, Sendable {
    let x: Float
    let y: Float
    let z: Float
    let visibility: Float?
    let presence: Float?
}

struct StationMediaPipeDetection: Sendable {
    let poses: [[StationMediaPipeLandmark]]
    let worldPoses: [[StationMediaPipeWorldLandmark]]
    /// Includes input orientation and model inference, excluding model loading.
    let inferenceMilliseconds: Double
}

/// One instance per replay. Use a background serial context and strictly
/// increasing clip timestamps. A lock also prevents concurrent SDK invocations.
/// No source frames or SDK result objects escape this synchronous adapter.
final class StationMediaPipeDetector {
    static let runtimeVersion = "0.10.21"
    static let modelIdentifier = "pose_landmarker_full/float16/1"
    static let modelSHA256 = "5134a3aad27a58b93da0088d431f366da362b44e3ccfbe3462b3827a839011b1"

    enum DetectionError: LocalizedError {
        case missingModel, incorrectModel, unsupportedPixelFormat, invalidTimestamp, bufferAllocation

        var errorDescription: String? {
            switch self {
            case .missingModel: return "The MediaPipe Full model is missing from this build."
            case .incorrectModel: return "The MediaPipe Full model does not match the pinned version."
            case .unsupportedPixelFormat: return "MediaPipe replay requires BGRA video frames."
            case .invalidTimestamp: return "Replay frame timestamps must increase. Start a new detector for each replay."
            case .bufferAllocation: return "A video frame could not be prepared for MediaPipe."
            }
        }
    }

    private let landmarker: PoseLandmarker
    private let lock = NSLock()
    private let imageContext = CIContext(options: [.cacheIntermediates: false,
                                                  .workingColorSpace: NSNull(),
                                                  .outputColorSpace: NSNull()])
    private var previousTimestamp: Int?

    init(modelURL: URL? = Bundle.main.url(forResource: "pose_landmarker_full", withExtension: "task")) throws {
        guard let modelURL else { throw DetectionError.missingModel }
        let bytes = try Data(contentsOf: modelURL, options: .mappedIfSafe)
        let digest = SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined()
        guard digest == Self.modelSHA256 else { throw DetectionError.incorrectModel }
        let options = PoseLandmarkerOptions()
        options.baseOptions.modelAssetPath = modelURL.path
        options.baseOptions.delegate = .CPU
        options.runningMode = .video
        // Detect ambiguity rather than silently reducing a crowded clip to one person.
        options.numPoses = 2
        options.minPoseDetectionConfidence = 0.5
        options.minPosePresenceConfidence = 0.5
        options.minTrackingConfidence = 0.5
        options.shouldOutputSegmentationMasks = false
        landmarker = try PoseLandmarker(options: options)
    }

    func detect(pixelBuffer: CVPixelBuffer, timestampMilliseconds: Int,
                orientation: CGImagePropertyOrientation) throws -> StationMediaPipeDetection {
        lock.lock()
        defer { lock.unlock() }
        guard timestampMilliseconds >= 0,
              previousTimestamp.map({ timestampMilliseconds > $0 }) ?? true else {
            throw DetectionError.invalidTimestamp
        }
        let started = ProcessInfo.processInfo.systemUptime
        return try autoreleasepool {
            let upright = try uprightPixelBuffer(pixelBuffer, orientation: orientation)
            let image = try MPImage(pixelBuffer: upright)
            // A failed SDK invocation may still consume the timestamp internally.
            previousTimestamp = timestampMilliseconds
            let result = try landmarker.detect(videoFrame: image, timestampInMilliseconds: timestampMilliseconds)
            let poses = result.landmarks.map { pose in
                pose.map {
                    StationMediaPipeLandmark(x: $0.x, y: $0.y, z: $0.z,
                                             visibility: $0.visibility?.floatValue,
                                             presence: $0.presence?.floatValue)
                }
            }
            let worldPoses = result.worldLandmarks.map { pose in
                pose.map {
                    StationMediaPipeWorldLandmark(x: $0.x, y: $0.y, z: $0.z,
                                                  visibility: $0.visibility?.floatValue,
                                                  presence: $0.presence?.floatValue)
                }
            }
            return StationMediaPipeDetection(
                poses: poses, worldPoses: worldPoses,
                inferenceMilliseconds: (ProcessInfo.processInfo.systemUptime - started) * 1_000
            )
        }
    }

    /// Physically apply EXIF orientation before calling MediaPipe with `.up`.
    /// This makes returned landmarks share Vision's upright image basis, without
    /// depending on MediaPipe's projection back into an oriented input image.
    func uprightPixelBuffer(_ source: CVPixelBuffer,
                            orientation: CGImagePropertyOrientation) throws -> CVPixelBuffer {
        guard CVPixelBufferGetPixelFormatType(source) == kCVPixelFormatType_32BGRA else {
            throw DetectionError.unsupportedPixelFormat
        }
        if orientation == .up { return source }
        let rotated = CIImage(cvPixelBuffer: source).oriented(forExifOrientation: Int32(orientation.rawValue))
        let extent = rotated.extent
        var output: CVPixelBuffer?
        let status = CVPixelBufferCreate(kCFAllocatorDefault, Int(extent.width), Int(extent.height),
                                        kCVPixelFormatType_32BGRA,
                                        [kCVPixelBufferIOSurfacePropertiesKey: [:]] as CFDictionary, &output)
        guard status == kCVReturnSuccess, let output else { throw DetectionError.bufferAllocation }
        let translated = rotated.transformed(by: CGAffineTransform(translationX: -extent.minX, y: -extent.minY))
        imageContext.render(translated, to: output)
        return output
    }
}
