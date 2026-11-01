import XCTest
@testable import TresFort

final class EnduranceEntryTests: XCTestCase {
    func testTimeAcceptsMinutesMinutesSecondsAndHours() {
        XCTAssertEqual(EnduranceEntry.seconds(from: "45"), 2_700)
        XCTAssertEqual(EnduranceEntry.seconds(from: " 25:00 "), 1_500)
        XCTAssertEqual(EnduranceEntry.seconds(from: "45:30"), 2_730)
        XCTAssertEqual(EnduranceEntry.seconds(from: "1:05:30"), 3_930)
    }

    func testUnreadableOrZeroTimeIsRejected() {
        for text in ["", "0", "0:00", "1:60", "1:05:60", "abc", "-5", "1:2:3:4", "12:"] {
            XCTAssertNil(EnduranceEntry.seconds(from: text), text)
        }
    }

    func testTimeOverSevenDaysOrHugeIsRejectedWithoutOverflow() {
        XCTAssertEqual(EnduranceEntry.seconds(from: "168:00:00"), 604_800)
        for text in ["168:00:01", "10081", "153722867280912931", "153722867280912931:00",
                     "2562047788015215:00:00", "9223372036854775807"] {
            XCTAssertNil(EnduranceEntry.seconds(from: text), text)
        }
    }

    func testDistanceConvertsToMetersAndAcceptsADecimalComma() throws {
        XCTAssertEqual(try XCTUnwrap(EnduranceEntry.meters(from: "3.1", unit: .mi)), 4_988.966, accuracy: 0.001)
        XCTAssertEqual(EnduranceEntry.meters(from: "5,5", unit: .km), 5_500)
        XCTAssertEqual(EnduranceEntry.meters(from: "1500", unit: .m), 1_500)
        XCTAssertNil(EnduranceEntry.meters(from: "-1", unit: .km))
        XCTAssertNil(EnduranceEntry.meters(from: "", unit: .km))
        XCTAssertTrue(EnduranceEntry.isReadableDistance(" ", unit: .km))
        XCTAssertFalse(EnduranceEntry.isReadableDistance("far", unit: .km))
    }

    func testPaceForRunsSpeedForRidesAndPer100ForSwims() {
        XCTAssertEqual(EnduranceEntry.paceLabel(seconds: 1_447, meters: 4_844.1, unit: .mi, kind: "run"), "8:01 /mi")
        XCTAssertEqual(EnduranceEntry.paceLabel(seconds: 3_600, meters: 30_000, unit: .km, kind: "ride"), "30.0 km/h")
        XCTAssertEqual(EnduranceEntry.paceLabel(seconds: 1_800, meters: 1_500, unit: .m, kind: "swim"), "2:00 /100m")
        XCTAssertNil(EnduranceEntry.paceLabel(seconds: 1_800, meters: 0, unit: .mi, kind: "run"))
    }

    func testSwimsUsePoolUnits() {
        XCTAssertEqual(EnduranceEntry.DistanceUnit.choices(for: "swim"), [.m, .yd])
        XCTAssertEqual(EnduranceEntry.DistanceUnit.choices(for: "run"), [.mi, .km])
    }

    func testBodyCarriesOnlyWhatWasEntered() {
        let swim = EnduranceEntry(id: "id-1", date: "2026-11-01", kind: "swim", durationS: 1_800,
                                  distanceM: nil, indoor: true, startTime: "06:30", title: nil, notes: nil)
        XCTAssertEqual(Set(swim.body.keys), ["id", "date", "type", "duration_s", "start_time"])

        let run = EnduranceEntry(id: "id-2", date: "2026-11-01", kind: "run", durationS: 1_447,
                                 distanceM: 4_844.1, indoor: false, startTime: "07:30",
                                 title: "Lunch loop", notes: "Easy")
        XCTAssertEqual(run.body["type"] as? String, "run")
        XCTAssertEqual(run.body["distance_m"] as? Double, 4_844.1)
        XCTAssertEqual(run.body["indoor"] as? Bool, false)
        XCTAssertEqual(run.body["title"] as? String, "Lunch loop")
        XCTAssertEqual(run.body["notes"] as? String, "Easy")
    }

    func testFailureShowsTheServerMessage() {
        let error = APIError.http(409, #"{"error":"intervals_write_forbidden","message":"Reconnect intervals.icu."}"#)
        XCTAssertEqual(EnduranceEntry.failureMessage(error), "Reconnect intervals.icu.")
        XCTAssertTrue(EnduranceEntry.failureMessage(URLError(.notConnectedToInternet)).contains("Nothing was saved"))
        XCTAssertTrue(EnduranceEntry.failureMessage(APIError.http(400, "{}")).contains("Nothing was saved"))
    }
}

final class EnduranceProgressTests: XCTestCase {
    // Wednesday; the week starts Monday 2026-11-02.
    private let today = "2026-11-04"

    private func activity(_ id: String, date: String, kind: String = "run", seconds: Int? = 1_800,
                          meters: Double? = nil, deleted: Bool = false) -> ExternalActivity {
        ExternalActivity(
            attribution_version: 1, id: id, source: "intervals", external_id: id, date: date,
            kind: kind, name: nil, moving_time_sec: seconds, elapsed_time_sec: nil,
            distance_m: meters, average_watts: nil, weighted_avg_watts: nil, average_hr: nil,
            max_hr: nil, training_load: nil, intensity: nil, calories: nil,
            elevation_gain_m: nil, synced_at: 1, deleted_at: deleted ? 2 : nil)
    }

    func testWeeksTotalsAndRecentActivities() {
        let summary = EnduranceProgress(activities: [
            activity("run", date: "2026-11-03", meters: 5_000),
            activity("ride", date: "2026-11-02", kind: "ride", seconds: 3_600, meters: 30_000),
            activity("lift", date: "2026-11-03", kind: "strength", seconds: 3_600),
            activity("yoga", date: "2026-11-03", kind: "yoga", seconds: 3_600),
            activity("pilates", date: "2026-11-03", kind: "other", seconds: 3_600),
            activity("last-week", date: "2026-10-27", seconds: 1_200),
            activity("too-old", date: "2026-10-10"),
            activity("tomorrow", date: "2026-11-05"),
            activity("deleted", date: "2026-11-03", deleted: true),
        ], today: today, weekCount: 3)

        XCTAssertEqual(summary.weeks.map(\.start), ["2026-10-19", "2026-10-26", "2026-11-02"])
        XCTAssertEqual(summary.weeks.map(\.seconds), [0, 1_200, 5_400])
        XCTAssertEqual(summary.weeks.last?.end, today)
        XCTAssertEqual(summary.thisWeekSeconds, 5_400)
        XCTAssertEqual(summary.thisWeekCount, 2)
        XCTAssertEqual(summary.averageWeekSeconds, 600)
        XCTAssertEqual(summary.thisWeek.map(\.kind), ["ride", "run"])
        XCTAssertEqual(summary.thisWeek.first?.meters, 30_000)
        XCTAssertEqual(summary.recent.map(\.id), ["run", "ride", "last-week"])
    }

    func testNoEnduranceMeansNoCard() {
        let summary = EnduranceProgress(activities: [
            activity("lift", date: "2026-11-03", kind: "strength"),
            activity("pilates", date: "2026-11-03", kind: "other"),
            activity("too-old", date: "2025-01-01"),
        ], today: today)
        XCTAssertTrue(summary.isEmpty)
        XCTAssertEqual(summary.weeks.count, 12)
    }

    func testFormatting() throws {
        XCTAssertEqual(EnduranceProgress.duration(5_400), "1h 30m")
        XCTAssertEqual(EnduranceProgress.duration(3_600), "1h")
        XCTAssertEqual(EnduranceProgress.duration(1_500), "25m")
        XCTAssertEqual(EnduranceProgress.distance(5_000, kind: "run", unit: .miles), "3.1 mi")
        XCTAssertEqual(EnduranceProgress.distance(5_000, kind: "run", unit: .kilometers), "5.0 km")
        XCTAssertEqual(EnduranceProgress.distance(500, kind: "swim", unit: .miles), "547 yd")
        XCTAssertEqual(EnduranceProgress.distance(500, kind: "swim", unit: .kilometers), "500 m")
        XCTAssertNil(EnduranceProgress.distance(0, kind: "run", unit: .miles))

        let run = activity("run", date: today, meters: 5_000)
        XCTAssertEqual(EnduranceProgress.pace(run, unit: .miles), "9:39 /mi")
        let ride = activity("ride", date: today, kind: "ride", seconds: 3_600, meters: 30_000)
        XCTAssertEqual(EnduranceProgress.pace(ride, unit: .miles), "18.6 mph")
        XCTAssertNil(EnduranceProgress.pace(activity("no-distance", date: today), unit: .miles))
    }
}
