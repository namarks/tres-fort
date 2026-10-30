import XCTest
@testable import TresFort

/// Runs in the beta smoke shard and both App Store shards.
@MainActor
final class RunRecorderPackagingTests: XCTestCase {
    func testLocationAudioBluetoothAndHealthWriteKeysShipOnlyOutsideTheAppStoreBuild() {
        let modes = Bundle.main.object(forInfoDictionaryKey: "UIBackgroundModes") as? [String]
        let location = Bundle.main.object(forInfoDictionaryKey: "NSLocationWhenInUseUsageDescription") as? String
        let bluetooth = Bundle.main.object(forInfoDictionaryKey: "NSBluetoothAlwaysUsageDescription") as? String
        let healthUpdate = Bundle.main.object(forInfoDictionaryKey: "NSHealthUpdateUsageDescription") as? String
#if APP_STORE_BUILD
        XCTAssertNil(modes)
        XCTAssertNil(location)
        XCTAssertNil(bluetooth)
        XCTAssertEqual(healthUpdate?.contains("does not write to Apple Health"), true)
        XCTAssertFalse(RunRecorderModel.isSupported)
#else
        XCTAssertEqual(modes, ["location", "audio", "bluetooth-central"])
        XCTAssertEqual(location?.contains("records your route"), true)
        XCTAssertEqual(bluetooth?.contains("heart rate monitor"), true)
        XCTAssertEqual(healthUpdate?.contains("saves runs you record"), true)
        XCTAssertTrue(CoreLocationRunSource.hasBackgroundLocationMode)
#endif
    }
}
