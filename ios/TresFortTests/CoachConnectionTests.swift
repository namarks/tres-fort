import XCTest
@testable import TresFort

final class CoachConnectionTests: XCTestCase {
    private func profile(_ fields: String) throws -> MeProfile {
        let data = Data("""
        {"intervals":{"connected":false},\(fields)}
        """.utf8)
        return try JSONDecoder().decode(MeProfile.self, from: data)
    }

    func testNewAppReadsLegacyServerCoachStatus() throws {
        let result = try profile("\"claude\":{\"is_owner\":false,\"connected\":true,\"last_active\":123}")
        XCTAssertTrue(result.coach.connected)
        XCTAssertFalse(result.coach.is_owner)
        XCTAssertEqual(result.coach.last_active, 123)
    }

    func testNeutralStatusTakesPrecedenceOverLegacyAlias() throws {
        let result = try profile("""
        "coach":{"is_owner":true,"connected":false},
        "claude":{"is_owner":true,"connected":true,"last_active":123}
        """)
        XCTAssertFalse(result.coach.connected)
        XCTAssertNil(result.coach.last_active)
    }

    func testNeutralOnlyServerCanDecodeWithoutLegacyField() throws {
        let result = try profile("\"coach\":{\"is_owner\":false,\"connected\":true}")
        XCTAssertTrue(result.coach.connected)
    }

    func testMissingOrMalformedConnectionIsAReadFailure() {
        XCTAssertThrowsError(try profile("\"display_name\":\"Example\""))
        XCTAssertThrowsError(try profile("""
        "coach":{"connected":"yes"},
        "claude":{"is_owner":false,"connected":true}
        """))
    }
}
