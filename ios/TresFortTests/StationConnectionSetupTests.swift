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

    func testRememberedConnectionNeverFollowsAnotherAccountOrSignedOutSession() {
        XCTAssertTrue(StationLink.isEnabled(storedAccount: "member-a", accountID: "member-a"))
        for account in [nil, "", "member-b"] {
            XCTAssertFalse(StationLink.isEnabled(storedAccount: "member-a", accountID: account))
        }
        XCTAssertFalse(StationLink.isEnabled(storedAccount: "", accountID: "member-a"))
    }
}
