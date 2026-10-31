import Foundation
import XCTest
@testable import TresFort

/// Moving through a planned run's steps while it records (planned-runs P2).
final class RunPlanProgressTests: XCTestCase {
    /// 10 min warm-up, 3 × (400 m, 90 s recovery), 5 min cool-down.
    private let plan = RunPlan(items: [
        .step(.init(kind: .warmup, durationSeconds: 600, distanceMeters: nil, target: nil)),
        .repeated(times: 3, steps: [
            .init(kind: .work, durationSeconds: nil, distanceMeters: 400,
                  target: .pace(fastestSecondsPerKm: 240, slowestSecondsPerKm: 250)),
            .init(kind: .recovery, durationSeconds: 90, distanceMeters: nil, target: nil),
        ]),
        .step(.init(kind: .cooldown, durationSeconds: 300, distanceMeters: nil, target: nil)),
    ])

    func testRepeatsUnrollWithTheirRound() {
        let steps = plan.expandedSteps
        XCTAssertEqual(steps.count, 8)
        XCTAssertEqual(steps.map(\.step.kind), [.warmup, .work, .recovery, .work, .recovery, .work, .recovery, .cooldown])
        XCTAssertEqual(steps.map(\.round), [nil, 1, 1, 2, 2, 3, 3, nil])
        XCTAssertEqual(steps[3].rounds, 3)
    }

    func testTimedAndDistanceStepsEndOnTheirOwnMeasure() {
        let steps = plan.expandedSteps
        var progress = RunPlanProgress()
        XCTAssertFalse(progress.advance(steps, movingSeconds: 599, meters: 1_900))
        XCTAssertEqual(progress.remaining(steps, movingSeconds: 599, meters: 1_900, unit: .miles), "0:01 left")

        XCTAssertTrue(progress.advance(steps, movingSeconds: 601, meters: 1_910))
        XCTAssertEqual(progress.stepIndex, 1)
        // The warm-up's exact end starts the interval, so a late update
        // doesn't shorten the next step's time.
        XCTAssertEqual(progress.stepStartSeconds, 600)
        XCTAssertEqual(progress.stepStartMeters, 1_910)
        XCTAssertEqual(progress.remaining(steps, movingSeconds: 640, meters: 2_100, unit: .kilometers), "210 m left")

        XCTAssertFalse(progress.advance(steps, movingSeconds: 680, meters: 2_309))
        XCTAssertTrue(progress.advance(steps, movingSeconds: 690, meters: 2_315))
        XCTAssertEqual(progress.stepIndex, 2)
        XCTAssertEqual(progress.stepStartMeters, 2_310)
        XCTAssertEqual(progress.stepStartSeconds, 690)
        XCTAssertEqual(progress.remaining(steps, movingSeconds: 700, meters: 2_340, unit: .miles), "1:20 left")
    }

    func testALateUpdateCanFinishSeveralSteps() {
        let steps = plan.expandedSteps
        var progress = RunPlanProgress()
        // Warm-up done at 600 s; the first 400 m ends at 400 m past the warm-up.
        XCTAssertTrue(progress.advance(steps, movingSeconds: 700, meters: 500))
        XCTAssertEqual(progress.stepIndex, 1)
        XCTAssertTrue(progress.advance(steps, movingSeconds: 800, meters: 900))
        XCTAssertEqual(progress.stepIndex, 2)
        XCTAssertEqual(progress.stepStartMeters, 900)
    }

    func testSkipStartsTheNextStepNowAndThePlanEnds() {
        let steps = plan.expandedSteps
        var progress = RunPlanProgress()
        progress.skip(steps, movingSeconds: 120, meters: 300)
        XCTAssertEqual(progress.stepIndex, 1)
        XCTAssertEqual(progress.stepStartSeconds, 120)
        XCTAssertEqual(progress.stepStartMeters, 300)
        for _ in 1..<steps.count { progress.skip(steps, movingSeconds: 200, meters: 400) }
        XCTAssertTrue(progress.isComplete(steps))
        XCTAssertNil(progress.remaining(steps, movingSeconds: 200, meters: 400, unit: .miles))
        // Skipping past the end does nothing.
        progress.skip(steps, movingSeconds: 300, meters: 500)
        XCTAssertEqual(progress.stepIndex, steps.count)
        XCTAssertFalse(progress.advance(steps, movingSeconds: 5_000, meters: 9_000))
    }

    func testLongerDistancesLeftReadInTheRunUnit() {
        let steps = RunPlan(items: [
            .step(.init(kind: .work, durationSeconds: nil, distanceMeters: 5_000, target: nil)),
        ]).expandedSteps
        let progress = RunPlanProgress()
        XCTAssertEqual(progress.remaining(steps, movingSeconds: 0, meters: 0, unit: .kilometers), "5 km left")
        XCTAssertEqual(progress.remaining(steps, movingSeconds: 0, meters: 2_988.3, unit: .miles), "1.25 mi left")
    }

    func testTheCheckpointKeepsTheStep() throws {
        var run = RecordedRun(startedAt: Date(timeIntervalSince1970: 1_793_000_000))
        run.plan = RunPlanFollowing(runSteps: "[{\"kind\":\"work\",\"duration_s\":600}]",
                                    progress: RunPlanProgress(stepIndex: 1, stepStartSeconds: 600, stepStartMeters: 1_500))
        let decoded = try JSONDecoder().decode(RecordedRun.self, from: JSONEncoder().encode(run))
        XCTAssertEqual(decoded.plan, run.plan)

        // A run saved before planned runs has no plan.
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(run)) as? [String: Any])
        object["plan"] = nil
        let old = try JSONDecoder().decode(RecordedRun.self, from: JSONSerialization.data(withJSONObject: object))
        XCTAssertNil(old.plan)
    }
}
