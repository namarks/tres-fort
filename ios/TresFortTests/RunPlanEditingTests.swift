import Foundation
import XCTest
@testable import TresFort

/// Planning a run's steps in the app (docs/plans/planned-runs P5): the draft
/// the editor works on, its checks against the server's limits, and pace and
/// distance entry.
final class RunPlanEditingTests: XCTestCase {
    private let intervals = RunPlan(items: [
        .step(.init(kind: .warmup, durationSeconds: 600, distanceMeters: nil, target: nil)),
        .repeated(times: 4, steps: [
            .init(kind: .work, durationSeconds: nil, distanceMeters: 800,
                  target: .pace(fastestSecondsPerKm: 245, slowestSecondsPerKm: 255)),
            .init(kind: .recovery, durationSeconds: 90, distanceMeters: nil, target: nil),
        ]),
        .step(.init(kind: .cooldown, durationSeconds: 600, distanceMeters: nil,
                    target: .heartRate(minBPM: 120, maxBPM: 140))),
    ])

    func testStepsSaveInThePlansFormatAndReadBack() throws {
        let data = try JSONSerialization.data(withJSONObject: intervals.jsonObject)
        let text = try XCTUnwrap(String(data: data, encoding: .utf8))
        XCTAssertEqual(RunPlan(json: text), intervals)
        let first = try XCTUnwrap(intervals.jsonObject.first)
        XCTAssertEqual(first["kind"] as? String, "warmup")
        XCTAssertEqual(first["duration_s"] as? Int, 600)
        XCTAssertNil(first["distance_m"])
        XCTAssertNil(first["target"])
        XCTAssertEqual(intervals.jsonObject[1]["repeat"] as? Int, 4)
    }

    func testDraftKeepsThePlanUntilEdited() {
        let draft = RunPlanDraft(plan: intervals)
        XCTAssertEqual(draft.plan, intervals)
        XCTAssertNil(draft.problem)
        XCTAssertEqual(draft.items.map(\.repeats), [nil, 4, nil])
        XCTAssertEqual(intervals.expandedCount, 10)
    }

    func testAnEmptyDraftSavesAsARunWithoutSteps() {
        var draft = RunPlanDraft(plan: nil)
        XCTAssertNil(draft.plan)
        draft.addStep()
        XCTAssertEqual(draft.plan?.items, [.step(RunPlanDraft.newStep)])
        draft.remove(draft.items[0].id)
        XCTAssertNil(draft.plan)
    }

    func testAddingARepeatGivesWorkAndRecovery() {
        var draft = RunPlanDraft(plan: nil)
        draft.addRepeat()
        XCTAssertEqual(draft.plan?.items, [.repeated(times: 4, steps: [
            .init(kind: .work, durationSeconds: 180, distanceMeters: nil, target: nil),
            .init(kind: .recovery, durationSeconds: 90, distanceMeters: nil, target: nil),
        ])])
        let id = draft.items[0].id
        draft.addStep(toRepeat: id)
        XCTAssertEqual(draft.items[0].steps.count, 3)
    }

    func testMovingAndRemovingParts() throws {
        var draft = RunPlanDraft(plan: intervals)
        let warmup = draft.items[0].id
        draft.move(warmup, by: -1)
        XCTAssertEqual(draft.items[0].id, warmup, "The first part can't move up")
        draft.move(warmup, by: 1)
        XCTAssertEqual(draft.items[1].id, warmup)

        let group = draft.items[0]
        XCTAssertEqual(group.repeats, 4)
        let work = group.steps[0].id
        draft.moveStep(work, inRepeat: group.id, by: 1)
        XCTAssertEqual(draft.items[0].steps[1].id, work)

        draft.removeStep(work, inRepeat: group.id)
        XCTAssertEqual(draft.items[0].steps.count, 1)
        draft.removeStep(draft.items[0].steps[0].id, inRepeat: group.id)
        XCTAssertFalse(draft.items.contains { $0.id == group.id }, "Removing a repeat's last step removes the repeat")
    }

    func testEditingAStepReplacesItWherever() throws {
        var draft = RunPlanDraft(plan: intervals)
        let recovery = draft.items[1].steps[1].id
        let jog = RunPlan.Step(kind: .recovery, durationSeconds: 120, distanceMeters: nil,
                               target: .heartRate(minBPM: 100, maxBPM: 130))
        draft.update(recovery, to: jog)
        guard case .repeated(_, let steps)? = draft.plan?.items[1] else { return XCTFail("Expected a repeat") }
        XCTAssertEqual(steps[1], jog)
    }

    func testLimitsMatchTheServer() {
        var draft = RunPlanDraft(plan: nil)
        for _ in 0..<RunPlanLimits.items { draft.addStep() }
        XCTAssertFalse(draft.canAddItem)
        draft.addStep()
        XCTAssertEqual(draft.items.count, 50)

        var group = RunPlanDraft(plan: nil)
        group.addRepeat()
        let id = group.items[0].id
        for _ in 0..<20 { group.addStep(toRepeat: id) }
        XCTAssertEqual(group.items[0].steps.count, 10)
        XCTAssertFalse(group.canAddStep(toRepeat: id))

        // 50 × 5 steps unrolls past 200.
        let long = RunPlan(items: [.repeated(times: 50, steps: Array(repeating: RunPlanDraft.newStep, count: 5))])
        XCTAssertEqual(RunPlanDraft(plan: long).problem, "With repeats, a plan can have at most 200 steps.")
    }

    func testStepProblems() {
        func step(duration: Int? = 60, distance: Double? = nil, target: RunPlan.Target? = nil) -> RunPlan.Step {
            RunPlan.Step(kind: .work, durationSeconds: distance == nil ? duration : nil,
                         distanceMeters: distance, target: target)
        }
        XCTAssertNil(step().problem)
        XCTAssertEqual(step(duration: 0).problem, "Enter a time.")
        XCTAssertEqual(step(duration: 6 * 3600 + 1).problem, "A step can be at most 6 hours.")
        XCTAssertNil(step(distance: 100_000).problem)
        XCTAssertEqual(step(distance: 100_001).problem, "A step can be at most 100 km.")
        XCTAssertEqual(step(target: .pace(fastestSecondsPerKm: 119, slowestSecondsPerKm: 300)).problem,
                       "Pace must be between 2:00 and 20:00 per kilometer.")
        XCTAssertEqual(step(target: .pace(fastestSecondsPerKm: 300, slowestSecondsPerKm: 290)).problem,
                       "The fast end of the pace range must be quicker than the slow end.")
        XCTAssertNil(step(target: .pace(fastestSecondsPerKm: 300, slowestSecondsPerKm: 300)).problem)
        XCTAssertEqual(step(target: .heartRate(minBPM: 150, maxBPM: 140)).problem,
                       "The low end of the heart rate range must be below the high end.")
        XCTAssertEqual(step(target: .heartRate(minBPM: 30, maxBPM: 140)).problem,
                       "Heart rate must be between 40 and 230 bpm.")
    }

    func testPaceEntry() {
        XCTAssertEqual(RunPaceInput.seconds("4:05"), 245)
        XCTAssertEqual(RunPaceInput.seconds(" 10:00 "), 600)
        XCTAssertNil(RunPaceInput.seconds("4:5"))
        XCTAssertNil(RunPaceInput.seconds("4:60"))
        XCTAssertNil(RunPaceInput.seconds("405"))
        XCTAssertNil(RunPaceInput.seconds("fast"))
        XCTAssertEqual(RunPaceInput.secondsPerKm(245, unit: .kilometers), 245)
        // 6:34 /mi = 394 s per 1.609344 km = 244.8 s/km.
        XCTAssertEqual(RunPaceInput.secondsPerKm(394, unit: .miles), 245)
        XCTAssertEqual(RunPaceInput.text(secondsPerKm: 245, unit: .kilometers), "4:05")
        XCTAssertEqual(RunPaceInput.text(secondsPerKm: 245, unit: .miles), "6:34")
    }

    func testDistanceEntry() {
        XCTAssertEqual(RunDistanceInput.meters.meters("800"), 800)
        XCTAssertEqual(RunDistanceInput.kilometers.meters("1,5"), 1_500)
        XCTAssertEqual(RunDistanceInput.miles.meters("1"), 1_609.344)
        XCTAssertNil(RunDistanceInput.kilometers.meters("0"))
        XCTAssertNil(RunDistanceInput.kilometers.meters("far"))
        XCTAssertEqual(RunDistanceInput.display(800, preferred: .miles).0, .meters)
        XCTAssertEqual(RunDistanceInput.display(800, preferred: .miles).1, "800")
        XCTAssertEqual(RunDistanceInput.display(5_000, preferred: .kilometers).1, "5")
        XCTAssertEqual(RunDistanceInput.display(1_609.344, preferred: .miles).0, .miles)
        XCTAssertEqual(RunDistanceInput.display(1_609.344, preferred: .miles).1, "1")
    }

    func testAnUntouchedDistanceKeepsItsExactMeters() {
        // 5 km reads as 3.11 mi; reading that back would give 5,005 m.
        var entry = RunDistanceEntry(meters: 5_000, preferred: .miles)
        XCTAssertEqual(entry.unit, .miles)
        XCTAssertEqual(entry.text, "3.11")
        XCTAssertEqual(entry.meters, 5_000)
        let longest = RunDistanceEntry(meters: RunPlanLimits.distanceMeters, preferred: .miles)
        XCTAssertEqual(longest.meters, RunPlanLimits.distanceMeters)

        entry.text = "3"
        XCTAssertEqual(entry.meters ?? 0, 3 * 1_609.344, accuracy: 0.001)
        entry.text = "3.11"
        XCTAssertEqual(entry.meters, 5_000, "Typing the shown value back keeps the exact distance")
        entry.unit = .kilometers
        XCTAssertEqual(entry.meters ?? 0, 3_110, accuracy: 0.001)

        let fresh = RunDistanceEntry(meters: nil, preferred: .kilometers)
        XCTAssertEqual(fresh.unit, .kilometers)
        XCTAssertEqual(fresh.meters, 1_000)
    }
}
