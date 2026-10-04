import XCTest
@testable import TresFort

final class StationCameraConfigurationTests: XCTestCase {
    private typealias Format = StationCameraConfiguration.Format

    private func format(_ index: Int, width: Int = 1280, height: Int = 960,
                        fieldOfView: Double = 100, frameRate: Int32 = 30) -> Format {
        Format(index: index, width: width, height: height,
               horizontalFieldOfView: fieldOfView, frameRate: frameRate)
    }

    func testFullHeightVideoWinsOverThe720PresetCrop() {
        let cropped = format(0, height: 720)
        let fullHeight = format(1)
        XCTAssertEqual(StationCameraConfiguration.preferredFormat(in: [cropped, fullHeight])?.index, 1)
    }

    func testWiderRealCoverageWinsOverAspectRatioAlone() {
        let narrowFourByThree = format(0, fieldOfView: 55)
        let widerVideo = format(1, height: 720, fieldOfView: 110)
        XCTAssertEqual(StationCameraConfiguration.preferredFormat(in: [narrowFourByThree, widerVideo])?.index, 1)
    }

    func testPhotoResolutionCannotWinByHavingTheLargestFieldOfView() {
        let photo = format(0, width: 4032, height: 3024, fieldOfView: 122)
        let video = format(1)
        XCTAssertEqual(StationCameraConfiguration.preferredFormat(in: [photo, video])?.index, 1)
    }

    func testEquivalentCoverageUsesModerateResolutionForPoseLatency() {
        let large = format(0, width: 1920, height: 1440)
        let moderate = format(1)
        XCTAssertEqual(StationCameraConfiguration.preferredFormat(in: [large, moderate])?.index, 1)
    }

    func testLowResolutionIsOnlyAFallbackWhenClearerVideoIsUnavailable() {
        let low = format(0, width: 640, height: 480, fieldOfView: 122)
        let video = format(1, height: 720)
        XCTAssertEqual(StationCameraConfiguration.preferredFormat(in: [low, video])?.index, 1)
        XCTAssertEqual(StationCameraConfiguration.preferredFormat(in: [low])?.index, 0)
    }

    func testUnsupportedCadenceAndDimensionsHaveNoSelection() {
        XCTAssertNil(StationCameraConfiguration.preferredFormat(in: [
            format(0, frameRate: 60), format(1, width: 0), format(2, height: 0)
        ]))
        XCTAssertEqual(StationCameraConfiguration.preferredFormat(in: [format(3, frameRate: 15)])?.index, 3)
    }

    func testUnknownFieldOfViewStillChoosesFullHeightWithoutNonfiniteMath() {
        let cropped = format(0, height: 720, fieldOfView: 0)
        let fullHeight = format(1, fieldOfView: .nan)
        XCTAssertEqual(StationCameraConfiguration.preferredFormat(in: [cropped, fullHeight])?.index, 1)
    }
}
