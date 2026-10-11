import CoreImage
import XCTest
@testable import TresFort

@MainActor
final class StationConnectionSetupTests: XCTestCase {
    func testSetupShortcutRejectsCredentialsParametersAndOtherDestinations() {
        XCTAssertTrue(StationLink.isSetupURL(StationLink.setupURL))
        for value in ["https://ipad-display", "tresfort://ipad-display/",
                      "tresfort://ipad-display?connect=1", "tresfort://ipad-display#connect",
                      "tresfort://ipad-display:123", "tresfort://user@ipad-display",
                      "tresfort://ipad-display.evil", "tresfort://other"] {
            XCTAssertFalse(StationLink.isSetupURL(URL(string: value)!), value)
        }
    }

    func testRenderedSetupCodeDecodesToTheNavigationShortcut() throws {
        let image = try XCTUnwrap(StationSetupCode.image()?.cgImage)
        let detector = try XCTUnwrap(CIDetector(ofType: CIDetectorTypeQRCode,
            context: CIContext(options: [.useSoftwareRenderer: true]),
            options: [CIDetectorAccuracy: CIDetectorAccuracyHigh]))
        let codes = detector.features(in: CIImage(cgImage: image)).compactMap { ($0 as? CIQRCodeFeature)?.messageString }
        XCTAssertEqual(codes, [StationLink.setupURL.absoluteString])
    }

    func testSetupCodeIncludesFourWhiteModulesOnEverySide() throws {
        let image = try XCTUnwrap(StationSetupCode.image()?.cgImage)
        let width = image.width, height = image.height
        var pixels = [UInt8](repeating: 255, count: width * height)
        try pixels.withUnsafeMutableBytes { buffer in
            let context = try XCTUnwrap(CGContext(data: buffer.baseAddress,
                width: width, height: height, bitsPerComponent: 8, bytesPerRow: width,
                space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue))
            context.interpolationQuality = .none
            context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        }
        var minX = width, minY = height, maxX = 0, maxY = 0
        for y in 0..<height {
            for x in 0..<width where pixels[y * width + x] < 128 {
                minX = min(minX, x); minY = min(minY, y)
                maxX = max(maxX, x); maxY = max(maxY, y)
            }
        }
        guard minX < width else { return XCTFail("The code must contain a symbol") }
        // A QR finder pattern's outer edge is seven modules wide. Measure it
        // from the pixels rather than assuming the generator's raster scale.
        let finderWidth = (minX...maxX).prefix { pixels[minY * width + $0] < 128 }.count
        XCTAssertEqual(finderWidth % 7, 0)
        let module = finderWidth / 7
        XCTAssertGreaterThan(module, 0)
        for margin in [minX, minY, width - 1 - maxX, height - 1 - maxY] {
            XCTAssertGreaterThanOrEqual(margin, 4 * module, "Keep the required four-module quiet zone")
        }
    }

    func testRememberedConnectionNeverFollowsAnotherAccountOrSignedOutSession() {
        XCTAssertTrue(StationLink.isEnabled(storedAccount: "member-a", accountID: "member-a"))
        for account in [nil, "", "member-b"] {
            XCTAssertFalse(StationLink.isEnabled(storedAccount: "member-a", accountID: account))
        }
        XCTAssertFalse(StationLink.isEnabled(storedAccount: "", accountID: "member-a"))
    }
}
