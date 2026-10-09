import XCTest
@testable import TresFort

@MainActor
final class PublicStationTests: XCTestCase {
    #if APP_STORE_BUILD
    func testSavedBetaOptInAllowsPartnerLinkButCannotArmOrAcceptCameraCounts() {
        XCTAssertTrue(StationLink.isEnabled(storedAccount: "host", accountID: "host"))
        XCTAssertFalse(StationLink.isEnabled(storedAccount: "host", accountID: "other"))
        XCTAssertFalse(StationLink.cameraCountingAvailable)
        let controller = StationLinkController()
        controller.request(.init(slotID: "slot", setNumber: 1, exercise: .squat,
                                 exerciseName: "Squat", targetReps: 8))
        XCTAssertNil(controller.arm)
        XCTAssertNil(controller.armToResend)
        let armID = UUID()
        controller.receive(.progress(.init(armID: armID, count: 8, leftCount: nil, rightCount: nil, status: "Counting")))
        controller.receive(.completion(.init(armID: armID, eventID: UUID(), reps: 8,
                                             leftCount: nil, rightCount: nil, partial: false)))
        controller.receive(.station(.cameraOff, armID: nil))
        XCTAssertNil(controller.progress)
        XCTAssertNil(controller.proposal)
        XCTAssertNil(controller.lastLogged)
        XCTAssertNil(controller.stationState)
        var received: PartnerPacket?
        controller.onPartnerMessage = { received = $0 }
        let packet = PartnerPacket(id: UUID(), message: .requestSetup)
        controller.receive(.partner(packet))
        XCTAssertEqual(received, packet, "Public camera exclusion must retain partner setup")
    }

    func testPublicIPadRejectsCameraArmWhileDeliveringPartnerPackets() {
        let station = StationLinkStation()
        station.receive(.arm(.init(armID: UUID(), slotID: "slot", setNumber: 1,
                                  exercise: .squat, exerciseName: "Squat", targetReps: 8)))
        station.beginCounting()
        XCTAssertNil(station.arm)
        XCTAssertNil(station.armToCount)
        XCTAssertFalse(station.isCounting)
        var received: PartnerPacket?
        station.onPartnerMessage = { received = $0 }
        let packet = PartnerPacket(id: UUID(), message: .cancel)
        station.receive(.partner(packet))
        XCTAssertEqual(received, packet)
    }
    #else
    func testBetaRetainsCameraCapability() {
        XCTAssertTrue(StationLink.cameraCountingAvailable)
    }
    #endif
}
