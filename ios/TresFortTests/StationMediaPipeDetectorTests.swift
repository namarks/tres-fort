import CoreVideo
import ImageIO
import XCTest
@testable import TresFort

final class StationMediaPipeDetectorTests: XCTestCase {
    #if APP_STORE_IPHONE_ONLY
    func testAppStoreBuildHasNoModelAndExplicitlyRejectsStationInference() {
        XCTAssertNil(Bundle.main.url(forResource: "pose_landmarker_full", withExtension: "task"))
        XCTAssertFalse(StationLink.isAvailable)
        XCTAssertThrowsError(try StationMediaPipeDetector()) { error in
            guard case StationMediaPipeDetector.DetectionError.unavailableInThisBuild = error else {
                return XCTFail("Expected the explicit unavailable-build error, got \(error)")
            }
        }
    }
    #else
    func testBundledFullModelExecutesAndRejectsTimestampReuse() throws {
        let detector = try StationMediaPipeDetector()
        let frame = try buffer(width: 192, height: 256, blue: Array(repeating: 0, count: 192 * 256))
        let first = try detector.detect(pixelBuffer: frame, timestampMilliseconds: 0, orientation: .up)
        XCTAssertTrue(first.poses.isEmpty)
        XCTAssertTrue(first.worldPoses.isEmpty)
        XCTAssertTrue(first.inferenceMilliseconds.isFinite)
        XCTAssertGreaterThan(first.inferenceMilliseconds, 0)
        XCTAssertThrowsError(try detector.detect(pixelBuffer: frame, timestampMilliseconds: 0, orientation: .up))
        XCTAssertThrowsError(try detector.detect(pixelBuffer: frame, timestampMilliseconds: -1, orientation: .up))
        XCTAssertTrue(try detector.detect(pixelBuffer: frame, timestampMilliseconds: 100, orientation: .right).poses.isEmpty)
    }

    func testMissingOrWrongModelFailsClosed() throws {
        XCTAssertThrowsError(try StationMediaPipeDetector(modelURL: nil))
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("wrong.task")
        try Data("not the pinned model".utf8).write(to: url)
        XCTAssertThrowsError(try StationMediaPipeDetector(modelURL: url))
    }

    func testFramePreparationPreservesPixelsForQuarterTurns() throws {
        let detector = try StationMediaPipeDetector()
        let original = try buffer(width: 2, height: 3, blue: [20, 40, 60, 80, 100, 120])
        let cases: [(CGImagePropertyOrientation, Int, Int, [UInt8])] = [
            (.up, 2, 3, [20, 40, 60, 80, 100, 120]),
            (.right, 3, 2, [100, 60, 20, 120, 80, 40]),
            (.down, 2, 3, [120, 100, 80, 60, 40, 20]),
            (.left, 3, 2, [40, 80, 120, 20, 60, 100]),
            (.upMirrored, 2, 3, [40, 20, 80, 60, 120, 100])
        ]
        for (orientation, width, height, expected) in cases {
            let rotated = try detector.uprightPixelBuffer(original, orientation: orientation)
            XCTAssertEqual(CVPixelBufferGetWidth(rotated), width)
            XCTAssertEqual(CVPixelBufferGetHeight(rotated), height)
            XCTAssertEqual(blueValues(rotated), expected, "EXIF orientation \(orientation.rawValue)")
        }
    }

    private func buffer(width: Int, height: Int, blue: [UInt8]) throws -> CVPixelBuffer {
        var output: CVPixelBuffer?
        XCTAssertEqual(CVPixelBufferCreate(kCFAllocatorDefault, width, height, kCVPixelFormatType_32BGRA,
                                          [kCVPixelBufferIOSurfacePropertiesKey: [:]] as CFDictionary,
                                          &output), kCVReturnSuccess)
        let result = try XCTUnwrap(output)
        CVPixelBufferLockBaseAddress(result, [])
        defer { CVPixelBufferUnlockBaseAddress(result, []) }
        let address = try XCTUnwrap(CVPixelBufferGetBaseAddress(result)).assumingMemoryBound(to: UInt8.self)
        let stride = CVPixelBufferGetBytesPerRow(result)
        for y in 0..<height {
            for x in 0..<width {
                let offset = y * stride + x * 4
                address[offset] = blue[y * width + x]
                address[offset + 1] = 0
                address[offset + 2] = 0
                address[offset + 3] = 255
            }
        }
        return result
    }

    private func blueValues(_ buffer: CVPixelBuffer) -> [UInt8] {
        CVPixelBufferLockBaseAddress(buffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(buffer, .readOnly) }
        guard let address = CVPixelBufferGetBaseAddress(buffer)?.assumingMemoryBound(to: UInt8.self) else { return [] }
        let stride = CVPixelBufferGetBytesPerRow(buffer)
        return (0..<CVPixelBufferGetHeight(buffer)).flatMap { y in
            (0..<CVPixelBufferGetWidth(buffer)).map { x in address[y * stride + x * 4] }
        }
    }
    #endif
}
