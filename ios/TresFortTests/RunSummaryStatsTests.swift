import Foundation
import XCTest
@testable import TresFort

/// The saved run's training load and barometer climb (docs/plans/run-recorder P7).
final class RunSummaryStatsTests: XCTestCase {
    private let start = Date(timeIntervalSince1970: 1_793_000_000)

    private func run(moving: Double = 1800) -> RecordedRun {
        var run = RecordedRun(startedAt: start, timeZone: TimeZone(identifier: "UTC")!)
        run.movingSeconds = moving
        run.endedAt = start.addingTimeInterval(moving)
        return run
    }

    private func readings(every step: Int, through last: Int, bpm: Double) -> [RecordedRun.HeartRateSample] {
        stride(from: 0, through: last, by: step).map {
            .init(timestamp: start.addingTimeInterval(TimeInterval($0)), beatsPerMinute: bpm)
        }
    }

    private func altitude(_ seconds: TimeInterval, _ meters: Double) -> RecordedRun.AltitudeSample {
        .init(timestamp: start.addingTimeInterval(seconds), meters: meters)
    }

    // MARK: - Training load

    func testHeartRateLoadIsOneHundredForAnHourAtThreshold() {
        var recorded = run()
        recorded.heartRates = readings(every: 5, through: 1795, bpm: 163)
        // 359 gaps of 5 s and the last reading's 1 s: 1,796 s at threshold.
        XCTAssertEqual(RunLoad.estimate(recorded, movingSeconds: 1800, thresholdHeartRate: 163, thresholdPacePerKm: 300),
                       RunLoad.Result(load: 50, method: .heartRate))
        recorded.heartRates = readings(every: 5, through: 1795, bpm: 163 * 1.1)
        XCTAssertEqual(RunLoad.estimate(recorded, movingSeconds: 1800, thresholdHeartRate: 163,
                                        thresholdPacePerKm: nil)?.load, 60)
    }

    func testReadingsWhilePausedNeverCount() {
        var recorded = run()
        recorded.endedAt = start.addingTimeInterval(2100)
        recorded.pauses = [.init(start: start.addingTimeInterval(600), end: start.addingTimeInterval(900))]
        recorded.heartRates = readings(every: 5, through: 2095, bpm: 163)
        recorded.heartRates += [.init(timestamp: start.addingTimeInterval(700), beatsPerMinute: 200)]
        let summary = RunLoad.heartRateSummary(recorded, movingSeconds: 1800)
        XCTAssertEqual(summary?.rms, 163)
        XCTAssertEqual(summary?.seconds, 1796, "The gap across the pause is 5 s of moving time")
        XCTAssertEqual(recorded.movingOffset(at: start.addingTimeInterval(1000)), 700)
    }

    func testPaceThenAverageHeartRateWhenTheReadingsCoverTooLittle() {
        var recorded = run(moving: 1500)
        recorded.distanceMeters = 5000
        // 5:00 /km against a 5:00 /km threshold for 25 minutes.
        XCTAssertEqual(RunLoad.estimate(recorded, movingSeconds: 1500, thresholdHeartRate: 163, thresholdPacePerKm: 300),
                       RunLoad.Result(load: 42, method: .pace))
        recorded.distanceMeters = 0
        recorded.heartRates = [.init(timestamp: start, beatsPerMinute: 150),
                               .init(timestamp: start.addingTimeInterval(1), beatsPerMinute: 166)]
        // 25 minutes at an average of 158 against 163.
        XCTAssertEqual(RunLoad.estimate(recorded, movingSeconds: 1500, thresholdHeartRate: 163, thresholdPacePerKm: 300),
                       RunLoad.Result(load: 39, method: .averageHeartRate))
        XCTAssertNil(RunLoad.estimate(recorded, movingSeconds: 1500, thresholdHeartRate: nil, thresholdPacePerKm: nil))
        XCTAssertNil(RunLoad.estimate(recorded, movingSeconds: 1500, thresholdHeartRate: 0, thresholdPacePerKm: .nan))
    }

    // MARK: - Climb

    func testClimbCountsARiseOnceItClearsThreeMeters() {
        XCTAssertEqual(RunAltitude.gain([0, 1, 2, 5, 4, 8, 2, 2.5]), 9)
        XCTAssertEqual(RunAltitude.gain([0, 1, 2, 1, 2.9]), 0, "Barometer wobble is not a climb")
        var recorded = run()
        XCTAssertNil(RunAltitude.climb(recorded))
        recorded.altitudes = [altitude(0, 0)]
        XCTAssertNil(RunAltitude.climb(recorded))
        recorded.altitudes = [altitude(0, 0), altitude(10, 4), altitude(20, 1)]
        XCTAssertEqual(RunAltitude.climb(recorded), 4)
    }

    func testAHillWalkedUpWhilePausedIsNotClimbed() {
        var recorded = run()
        recorded.pauses = [.init(start: start.addingTimeInterval(12), end: start.addingTimeInterval(20))]
        recorded.altitudes = [altitude(0, 0), altitude(10, 4), altitude(15, 20), altitude(20, 20), altitude(30, 24)]
        XCTAssertEqual(RunAltitude.movingSegments(recorded).map(\.count), [2, 2])
        XCTAssertEqual(RunAltitude.climb(recorded), 8)
    }

    func testReadingsBetweenTwoMomentsAreBlendedAndFarOnesIgnored() {
        let samples = [altitude(0, 0), altitude(10, 5), altitude(100, 9)]
        XCTAssertEqual(RunAltitude.relative(at: start.addingTimeInterval(4), in: samples) ?? .nan, 2, accuracy: 1e-9)
        XCTAssertEqual(RunAltitude.relative(at: start.addingTimeInterval(35), in: samples), 5)
        XCTAssertNil(RunAltitude.relative(at: start.addingTimeInterval(55), in: samples))
        XCTAssertEqual(RunAltitude.relative(at: start.addingTimeInterval(-20), in: samples), 0)
        XCTAssertNil(RunAltitude.relative(at: start.addingTimeInterval(200), in: samples))
        XCTAssertNil(RunAltitude.relative(at: start, in: []))
    }

    func testTheBarometerShapesElevationAtTheLevelGPSMeasured() {
        var recorded = run()
        let points: [RecordedRun.RoutePoint] = [
            .init(timestamp: start, latitude: 45.5, longitude: -122.6, altitude: 100, horizontalAccuracy: 5),
            .init(timestamp: start.addingTimeInterval(10), latitude: 45.5, longitude: -122.6,
                  altitude: 110, horizontalAccuracy: 5),
            .init(timestamp: start.addingTimeInterval(20), latitude: 45.5, longitude: -122.6,
                  altitude: nil, horizontalAccuracy: 5),
            .init(timestamp: start.addingTimeInterval(30), latitude: 45.5, longitude: -122.6,
                  altitude: 106, horizontalAccuracy: 5),
            .init(timestamp: start.addingTimeInterval(200), latitude: 45.5, longitude: -122.6,
                  altitude: 130, horizontalAccuracy: 5),
        ]
        XCTAssertNil(RunAltitude.fusedAltitudes(recorded, points: points), "No barometer: GPS altitude as before")
        recorded.altitudes = [altitude(0, 0), altitude(10, 2), altitude(20, 4), altitude(30, 6)]
        // GPS minus barometer: 100, 108 and 100, so the level is 100. The
        // last point has no reading near it and keeps its GPS altitude.
        XCTAssertEqual(RunAltitude.fusedAltitudes(recorded, points: points), [100, 102, 104, 106, 130])
        let noGPS = points.map { point -> RecordedRun.RoutePoint in
            var copy = point
            copy.altitude = nil
            return copy
        }
        XCTAssertNil(RunAltitude.fusedAltitudes(recorded, points: noGPS))
    }

    // MARK: - Upload

    private func uploadRun() -> RecordedRun {
        var recorded = RecordedRun(startedAt: start, timeZone: TimeZone(identifier: "UTC")!, name: "Run")
        recorded.points = [
            .init(timestamp: start, latitude: 45.5231, longitude: -122.6765, altitude: 15.24, horizontalAccuracy: 5),
            .init(timestamp: start.addingTimeInterval(10), latitude: 45.5232, longitude: -122.6766,
                  altitude: nil, horizontalAccuracy: 6),
            .init(timestamp: start.addingTimeInterval(20), latitude: 45.5233, longitude: -122.6767,
                  altitude: 16, horizontalAccuracy: 5),
        ]
        recorded.movingSeconds = 20
        recorded.distanceMeters = 28
        recorded.endedAt = start.addingTimeInterval(20)
        return recorded
    }

    func testTheUploadedRunCarriesBarometerElevationAndItsClimb() throws {
        var recorded = uploadRun()
        let plain = try XCTUnwrap(String(data: RecordedRunTCX.encode(recorded), encoding: .utf8))
        XCTAssertTrue(plain.contains("<AltitudeMeters>15.2</AltitudeMeters>"))
        let plainBody = try XCTUnwrap(String(
            data: APIClient.recordingMultipartBody(recorded, tcx: Data(), boundary: "B"), encoding: .utf8))
        XCTAssertFalse(plainBody.contains("elevation_gain_m"))

        recorded.altitudes = [altitude(0, 0), altitude(10, 1), altitude(20, 4.25)]
        let tcx = try XCTUnwrap(String(data: RecordedRunTCX.encode(recorded), encoding: .utf8))
        // GPS minus barometer: 15.24 and 11.75, so the level is 13.495.
        XCTAssertEqual(tcx.components(separatedBy: "<AltitudeMeters>").count - 1, 3)
        XCTAssertTrue(tcx.contains("<AltitudeMeters>13.5</AltitudeMeters><DistanceMeters>0.0</DistanceMeters>"))
        XCTAssertTrue(tcx.contains("<AltitudeMeters>14.5</AltitudeMeters><DistanceMeters>14.0</DistanceMeters>"))
        XCTAssertTrue(tcx.contains("<AltitudeMeters>17.7</AltitudeMeters><DistanceMeters>28.0</DistanceMeters>"))
        let body = try XCTUnwrap(String(
            data: APIClient.recordingMultipartBody(recorded, tcx: Data(), boundary: "B"), encoding: .utf8))
        XCTAssertTrue(body.contains("name=\"elevation_gain_m\"\r\n\r\n4.2\r\n")
                      || body.contains("name=\"elevation_gain_m\"\r\n\r\n4.3\r\n"))
    }

    func testARunSavedBeforeTheBarometerStillLoads() throws {
        let data = try JSONEncoder().encode(uploadRun())
        var json = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        json.removeValue(forKey: "altitudes")
        let decoded = try JSONDecoder().decode(RecordedRun.self, from: JSONSerialization.data(withJSONObject: json))
        XCTAssertNil(decoded.altitudes)
        XCTAssertNil(RunAltitude.climb(decoded))
    }
}
