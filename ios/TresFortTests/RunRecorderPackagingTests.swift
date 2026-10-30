import XCTest
@testable import TresFort

/// Runs in the beta smoke shard and both App Store shards.
@MainActor
final class RunRecorderPackagingTests: XCTestCase {
    func testLocationAndHealthWriteKeysShipOnlyOutsideTheAppStoreBuild() {
        let modes = Bundle.main.object(forInfoDictionaryKey: "UIBackgroundModes") as? [String]
        let location = Bundle.main.object(forInfoDictionaryKey: "NSLocationWhenInUseUsageDescription") as? String
        let healthUpdate = Bundle.main.object(forInfoDictionaryKey: "NSHealthUpdateUsageDescription") as? String
#if APP_STORE_BUILD
        XCTAssertNil(modes)
        XCTAssertNil(location)
        XCTAssertEqual(healthUpdate?.contains("does not write to Apple Health"), true)
        XCTAssertFalse(RunRecorderModel.isSupported)
#else
        XCTAssertEqual(modes, ["location"])
        XCTAssertEqual(location?.contains("records your route"), true)
        XCTAssertEqual(healthUpdate?.contains("saves runs you record"), true)
        XCTAssertTrue(CoreLocationRunSource.hasBackgroundLocationMode)
#endif
    }
}
