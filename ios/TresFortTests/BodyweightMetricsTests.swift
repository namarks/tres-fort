import XCTest
@testable import TresFort

final class BodyweightMetricsTests: XCTestCase {
    private struct LegacyTopSet: Decodable {
        let est_1rm: Double
    }

    func testSetValueFormatterCoversAddedAssistedStrictAndTimedWork() {
        XCTAssertEqual(
            SetValueFormatter.value(
                weight: 45, reps: 5, durationSeconds: nil,
                timed: false, bodyweight: true),
            "BW+45 × 5")
        XCTAssertEqual(
            SetValueFormatter.value(
                weight: -30, reps: 8, durationSeconds: nil,
                timed: false, bodyweight: true),
            "BW−30 × 8")
        XCTAssertEqual(
            SetValueFormatter.value(
                weight: 0, reps: 8, durationSeconds: nil,
                timed: false, bodyweight: true),
            "BW × 8")
        XCTAssertEqual(
            SetValueFormatter.value(
                weight: -20, reps: 45, durationSeconds: 45,
                timed: true, bodyweight: false),
            "45s")
    }

    func testFeedTopSetDecodesMetricContextAndUsesSharedFormatter() throws {
        let data = Data(
            """
            {
              "exercise": "Pull-Up",
              "weight": -30,
              "reps": 12,
              "unit": "lb",
              "modality": "bw",
              "duration_s": null,
              "is_timed": false,
              "est_1rm": 0
            }
            """.utf8)
        let top = try JSONDecoder().decode(FeedSessionItem.TopSet.self, from: data)

        XCTAssertEqual(top.valueLabel, "BW−30 × 12")
        XCTAssertEqual(top.est_1rm, 0)
        XCTAssertNil(top.estimatedOneRepMax)
        XCTAssertEqual(
            try JSONDecoder().decode(LegacyTopSet.self, from: data).est_1rm,
            0)
    }
}
