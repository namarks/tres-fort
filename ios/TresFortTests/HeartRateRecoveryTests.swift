import Foundation
import XCTest
@testable import TresFort

/// The cool-down rules after a recorded run (docs/plans/run-recorder P7).
final class HeartRateRecoveryTests: XCTestCase {
    private let stop = Date(timeIntervalSince1970: 1_793_000_000)

    private func sample(_ seconds: TimeInterval, _ bpm: Double) -> RecordedRun.HeartRateSample {
        .init(timestamp: stop.addingTimeInterval(seconds), beatsPerMinute: bpm)
    }

    private func run(lastReadingAt seconds: TimeInterval?, bpm: Double = 165) -> RecordedRun {
        var run = RecordedRun(startedAt: stop.addingTimeInterval(-1800))
        if let seconds { run.heartRates = [sample(seconds - 30, 150), sample(seconds, bpm)] }
        return run
    }

    func testItNeedsAReadingAtTheStop() {
        XCTAssertNil(HeartRateRecoveryMeasurement(run: run(lastReadingAt: nil), stoppedAt: stop))
        XCTAssertNil(HeartRateRecoveryMeasurement(run: run(lastReadingAt: -6), stoppedAt: stop),
                     "A reading 6 s before the stop isn't the heart rate at the stop")
        XCTAssertNil(HeartRateRecoveryMeasurement(run: run(lastReadingAt: -1, bpm: 255), stoppedAt: stop))
        let measurement = HeartRateRecoveryMeasurement(run: run(lastReadingAt: -2), stoppedAt: stop)
        XCTAssertEqual(measurement?.atStop, 165)
        XCTAssertEqual(measurement?.isComplete, false)
        XCTAssertNil(measurement?.result)
    }

    func testEachMarkTakesTheNearestReading() throws {
        var measurement = try XCTUnwrap(HeartRateRecoveryMeasurement(run: run(lastReadingAt: 0), stoppedAt: stop))
        measurement.add(sample(30, 150))
        measurement.add(sample(58, 140))
        XCTAssertNil(measurement.result, "Nothing counts before the mark is reached")
        measurement.add(sample(61, 137))
        XCTAssertEqual(measurement.result, HeartRateRecovery(atStop: 165, after60s: 137, after120s: nil))
        measurement.add(sample(117, 122))
        measurement.add(sample(124, 119))
        XCTAssertEqual(measurement.result, HeartRateRecovery(atStop: 165, after60s: 137, after120s: 122),
                       "117 s is nearer two minutes than 124 s")
        XCTAssertTrue(measurement.isComplete)
    }

    func testAMarkWithNoReadingNearItStaysEmpty() throws {
        var measurement = try XCTUnwrap(HeartRateRecoveryMeasurement(run: run(lastReadingAt: 0), stoppedAt: stop))
        measurement.add(sample(50, 140))
        measurement.add(sample(70, 132))
        XCTAssertNil(measurement.result, "Neither reading is within 5 s of a minute")
        measurement.add(sample(121, 120))
        XCTAssertEqual(measurement.result, HeartRateRecovery(atStop: 165, after60s: nil, after120s: 120))
    }

    func testAQuietStrapSettlesMarksAsTheClockPasses() throws {
        var measurement = try XCTUnwrap(HeartRateRecoveryMeasurement(run: run(lastReadingAt: 0), stoppedAt: stop))
        measurement.add(sample(57, 140))
        measurement.expire(at: stop.addingTimeInterval(64))
        XCTAssertNil(measurement.result, "Still inside the tolerance")
        measurement.expire(at: stop.addingTimeInterval(66))
        XCTAssertEqual(measurement.result?.after60s, 140)
        XCTAssertFalse(measurement.isComplete)
        measurement.expire(at: stop.addingTimeInterval(126))
        XCTAssertTrue(measurement.isComplete)
        XCTAssertNil(measurement.result?.after120s)
    }

    func testImplausibleOrOutOfOrderReadingsAreIgnored() throws {
        var measurement = try XCTUnwrap(HeartRateRecoveryMeasurement(run: run(lastReadingAt: 0), stoppedAt: stop))
        measurement.add(sample(-1, 170))
        measurement.add(sample(60, 0))
        measurement.add(sample(60, 300))
        XCTAssertNil(measurement.result)
        measurement.add(sample(61, 138))
        measurement.add(sample(60.5, 120))
        XCTAssertEqual(measurement.result?.after60s, 138)
    }

    func testTheSummarySaysHowFarHeartRateFell() {
        XCTAssertEqual(HeartRateRecovery(atStop: 165, after60s: 137, after120s: 121).summary,
                       "28 bpm in 1 min · 44 in 2 min")
        XCTAssertEqual(HeartRateRecovery(atStop: 165, after60s: 137, after120s: nil).summary, "28 bpm in 1 min")
        XCTAssertEqual(HeartRateRecovery(atStop: 150, after60s: nil, after120s: 130).summary, "20 bpm in 2 min")
        XCTAssertEqual(HeartRateRecovery(atStop: 120, after60s: 124, after120s: nil).summary, "+4 bpm in 1 min")
        XCTAssertNil(HeartRateRecovery(atStop: 120, after60s: nil, after120s: nil).summary)
    }

    func testItUsesTheServersFieldNames() throws {
        let json = #"{"at_stop":165,"after_60s":137,"after_120s":null}"#
        let decoded = try JSONDecoder().decode(HeartRateRecovery.self, from: Data(json.utf8))
        XCTAssertEqual(decoded, HeartRateRecovery(atStop: 165, after60s: 137, after120s: nil))
    }

    func testTheRunsAverageAndMaximumHeartRate() {
        var run = RecordedRun(startedAt: stop)
        XCTAssertNil(run.averageHeartRate)
        run.heartRates = [sample(0, 140), sample(1, 150), sample(2, 166)]
        XCTAssertEqual(run.averageHeartRate ?? 0, 152, accuracy: 0.001)
        XCTAssertEqual(run.maximumHeartRate, 166)
    }
}
