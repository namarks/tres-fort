import XCTest
@testable import TresFort

final class CalendarProjectionTests: XCTestCase {
    private let today = "2026-05-18"
    private let blackout = TripRange(
        id: "trip-blackout",
        start: "2026-05-20",
        end: "2026-05-20",
        type: "travel",
        canTrainLight: false)
    private let schedule = PlanSchedule(
        version: 1,
        week: ["wed": "d_pull"])

    private func session(status: String) -> SessionRow {
        SessionRow(
            id: "session-\(status)",
            date: "2026-05-20",
            status: status,
            // The schedule projects d_pull. A real d_push session proves the
            // result came from the session rather than schedule projection.
            day_template_id: "d_push")
    }

    func testBlackoutKeepsOnlyRealLoggedSessionsVisible() {
        for status in ["in_progress", "completed"] {
            let real = session(status: status)
            let projection = CalendarProjection.project(
                dateString: real.date,
                today: today,
                sessionByDate: [real.date: real],
                schedule: schedule,
                templateIDs: ["d_push", "d_pull"],
                trips: [blackout])

            XCTAssertEqual(
                projection,
                .session(
                    status: status,
                    hardBlackoutTripType: "travel"),
                "\(status) is evidence that training happened and must survive the blackout")
            XCTAssertTrue(projection.suppressesScheduleAndEndurance)
        }
    }

    func testBlackoutSuppressesPlannedSkippedDiscardedAndUnknownSessions() {
        for status in ["planned", "skipped", "discarded", "unknown_non_training"] {
            let real = session(status: status)

            XCTAssertEqual(
                CalendarProjection.project(
                    dateString: real.date,
                    today: today,
                    sessionByDate: [real.date: real],
                    schedule: schedule,
                    templateIDs: ["d_push", "d_pull"],
                    trips: [blackout]),
                .unavailable(tripType: "travel"),
                "\(status) must not defeat a hard blackout")
        }
    }

    func testBlackoutSuppressesScheduleWhenThereIsNoRealSession() {
        XCTAssertEqual(
            CalendarProjection.project(
                dateString: "2026-05-20",
                today: today,
                sessionByDate: [:],
                schedule: schedule,
                templateIDs: ["d_pull"],
                trips: [blackout]),
            .unavailable(tripType: "travel"))
    }

    func testBlackoutSessionRetainsNullTemplateWithoutEnablingScheduleFallback() {
        let real = SessionRow(
            id: "session-null-template",
            date: "2026-05-20",
            status: "in_progress",
            day_template_id: nil)

        let projection = CalendarProjection.project(
            dateString: real.date,
            today: today,
            sessionByDate: [real.date: real],
            schedule: schedule,
            templateIDs: ["d_pull"],
            trips: [blackout])

        XCTAssertEqual(
            projection,
            .session(
                status: "in_progress",
                hardBlackoutTripType: "travel"))
        XCTAssertTrue(projection.suppressesScheduleAndEndurance)
    }

    func testOrdinarySessionDoesNotSuppressEndurance() {
        let real = session(status: "completed")
        let projection = CalendarProjection.project(
            dateString: real.date,
            today: today,
            sessionByDate: [real.date: real],
            schedule: schedule,
            templateIDs: ["d_push", "d_pull"])

        XCTAssertEqual(projection, .session(status: "completed"))
        XCTAssertFalse(projection.suppressesScheduleAndEndurance)
    }

    func testHardBlackoutSurvivingLiftDoesNotCreateRideConflict() {
        let real = session(status: "completed")
        let blackoutProjection = CalendarProjection.project(
            dateString: real.date,
            today: today,
            sessionByDate: [real.date: real],
            schedule: schedule,
            templateIDs: ["d_push", "d_pull"],
            trips: [blackout])
        let ordinaryProjection = CalendarProjection.project(
            dateString: real.date,
            today: today,
            sessionByDate: [real.date: real],
            schedule: schedule,
            templateIDs: ["d_push", "d_pull"])

        XCTAssertFalse(RideConflict.dateHasLift(blackoutProjection))
        XCTAssertTrue(RideConflict.dateHasLift(ordinaryProjection))
    }
}
