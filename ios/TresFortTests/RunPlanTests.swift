import Foundation
import XCTest
@testable import TresFort

/// Planned runs as the plan stores them (`template_exercises.run_steps`,
/// canonical JSON from src/runSteps.ts) and as the app reads them.
final class RunPlanTests: XCTestCase {
    private let intervals = """
    [{"kind":"warmup","duration_s":600},\
    {"repeat":4,"steps":[\
    {"kind":"work","distance_m":800,"target":{"type":"pace","fastest_s_per_km":245,"slowest_s_per_km":255}},\
    {"kind":"recovery","duration_s":90}]},\
    {"kind":"cooldown","duration_s":600}]
    """

    func testReadsStepsAndRepeats() throws {
        let plan = try XCTUnwrap(RunPlan(json: intervals))
        XCTAssertEqual(plan.items, [
            .step(.init(kind: .warmup, durationSeconds: 600, distanceMeters: nil, target: nil)),
            .repeated(times: 4, steps: [
                .init(kind: .work, durationSeconds: nil, distanceMeters: 800,
                      target: .pace(fastestSecondsPerKm: 245, slowestSecondsPerKm: 255)),
                .init(kind: .recovery, durationSeconds: 90, distanceMeters: nil, target: nil),
            ]),
            .step(.init(kind: .cooldown, durationSeconds: 600, distanceMeters: nil, target: nil)),
        ])
    }

    func testReadsHeartRateTarget() throws {
        let plan = try XCTUnwrap(RunPlan(json: """
        [{"kind":"work","duration_s":2400,"target":{"type":"heart_rate","min_bpm":130,"max_bpm":145}}]
        """))
        XCTAssertEqual(plan.items, [
            .step(.init(kind: .work, durationSeconds: 2400, distanceMeters: nil,
                        target: .heartRate(minBPM: 130, maxBPM: 145))),
        ])
    }

    func testUnreadableStepsAreNil() {
        XCTAssertNil(RunPlan(json: ""))
        XCTAssertNil(RunPlan(json: "[]"))
        XCTAssertNil(RunPlan(json: "{\"kind\":\"work\",\"duration_s\":60}"))
        // A kind, target type or step shape this app doesn't know.
        XCTAssertNil(RunPlan(json: "[{\"kind\":\"strides\",\"duration_s\":60}]"))
        XCTAssertNil(RunPlan(json: "[{\"kind\":\"work\",\"duration_s\":60,\"target\":{\"type\":\"power\"}}]"))
        // Both or neither of duration and distance.
        XCTAssertNil(RunPlan(json: "[{\"kind\":\"work\",\"duration_s\":60,\"distance_m\":400}]"))
        XCTAssertNil(RunPlan(json: "[{\"kind\":\"work\"}]"))
        // A repeat with no steps, or one bad step inside it.
        XCTAssertNil(RunPlan(json: "[{\"repeat\":3,\"steps\":[]}]"))
        XCTAssertNil(RunPlan(json: "[{\"repeat\":3,\"steps\":[{\"kind\":\"work\",\"duration_s\":60},{\"kind\":\"x\"}]}]"))
    }

    func testLinesIndentRepeatedSteps() throws {
        let plan = try XCTUnwrap(RunPlan(json: intervals))
        let lines = RunPlanFormat.lines(plan, unit: .kilometers)
        XCTAssertEqual(lines.map(\.text), [
            "10 min warm-up",
            "4 ×",
            "800 m at 4:05–4:15 /km",
            "1 min 30 s recovery",
            "10 min cool-down",
        ])
        XCTAssertEqual(lines.map(\.indented), [false, false, true, true, false])
        XCTAssertEqual(lines.map(\.id), [0, 1, 2, 3, 4])
    }

    func testSummaryIsOneLine() throws {
        let plan = try XCTUnwrap(RunPlan(json: intervals))
        XCTAssertEqual(RunPlanFormat.summary(plan, unit: .kilometers),
                       "10 min warm-up · 4 × (800 m at 4:05–4:15 /km, 1 min 30 s recovery) · 10 min cool-down")
        let single = RunPlan(items: [.repeated(times: 6, steps: [
            .init(kind: .work, durationSeconds: 20, distanceMeters: nil, target: nil),
        ])])
        XCTAssertEqual(RunPlanFormat.summary(single, unit: .miles), "6 × 20 s")
    }

    func testPaceTargetsReadInTheRecordersUnit() {
        let pace = RunPlan.Target.pace(fastestSecondsPerKm: 300, slowestSecondsPerKm: 330)
        XCTAssertEqual(RunPlanFormat.target(pace, unit: .kilometers), "5:00–5:30 /km")
        // 300 s/km × 1.609344 = 482.8 s/mi; 330 s/km = 531.1 s/mi.
        XCTAssertEqual(RunPlanFormat.target(pace, unit: .miles), "8:03–8:51 /mi")
        let exact = RunPlan.Target.pace(fastestSecondsPerKm: 300, slowestSecondsPerKm: 300)
        XCTAssertEqual(RunPlanFormat.target(exact, unit: .kilometers), "5:00 /km")
        XCTAssertEqual(RunPlanFormat.target(.heartRate(minBPM: 130, maxBPM: 145), unit: .miles), "130–145 bpm")
        XCTAssertEqual(RunPlanFormat.target(.heartRate(minBPM: 150, maxBPM: 150), unit: .miles), "150 bpm")
    }

    func testDistances() {
        XCTAssertEqual(RunPlanFormat.distance(400, unit: .miles), "400 m")
        XCTAssertEqual(RunPlanFormat.distance(5_000, unit: .kilometers), "5 km")
        XCTAssertEqual(RunPlanFormat.distance(5_500, unit: .kilometers), "5.5 km")
        XCTAssertEqual(RunPlanFormat.distance(5_000, unit: .miles), "3.11 mi")
        XCTAssertEqual(RunPlanFormat.distance(1_609.344, unit: .miles), "1 mi")
    }

    func testDurations() {
        XCTAssertEqual(RunPlanFormat.duration(45), "45 s")
        XCTAssertEqual(RunPlanFormat.duration(600), "10 min")
        XCTAssertEqual(RunPlanFormat.duration(150), "2 min 30 s")
        XCTAssertEqual(RunPlanFormat.duration(4_500), "1 h 15 min")
        XCTAssertEqual(RunPlanFormat.duration(0), "0 s")
    }

    func testOutdoorRunSlotLabels() throws {
        let timed = try decodeSlot(exerciseID: RunPlan.exerciseID, durationSeconds: 1_800)
        XCTAssertTrue(timed.isOutdoorRun)
        XCTAssertNil(timed.runPlan)
        XCTAssertEqual(timed.runPrescriptionLabel(in: .miles), "Run · 30 min")

        var slot = try decodeSlot(exerciseID: RunPlan.exerciseID, durationSeconds: nil)
        XCTAssertEqual(slot.runPrescriptionLabel(in: .miles), "Run at your own pace")

        slot.run_steps = "[{\"kind\":\"work\",\"distance_m\":5000,\"target\":{\"type\":\"pace\",\"fastest_s_per_km\":300,\"slowest_s_per_km\":330}}]"
        XCTAssertEqual(slot.runPrescriptionLabel(in: .kilometers), "5 km at 5:00–5:30 /km")

        let run = slot.plannedRun(in: "Tempo Thursday")
        XCTAssertEqual(run.id, slot.id)
        XCTAssertEqual(run.workoutName, "Tempo Thursday")
        XCTAssertEqual(run.plan, slot.runPlan)
    }

    func testOtherSlotsAreNotRuns() throws {
        let slot = try decodeSlot(exerciseID: "ex_treadmill", durationSeconds: 600)
        XCTAssertFalse(slot.isOutdoorRun)
    }

    func testDecodesRunStepsFromState() throws {
        let slot = try decodeSlot(exerciseID: RunPlan.exerciseID, durationSeconds: nil,
                                  runSteps: "[{\"kind\":\"work\",\"duration_s\":1200}]")
        XCTAssertEqual(slot.runPlan?.items, [.step(.init(kind: .work, durationSeconds: 1_200, distanceMeters: nil, target: nil))])
    }

    func testPreferredUnitFollowsTheRecorder() throws {
        let defaults = try XCTUnwrap(UserDefaults(suiteName: "RunPlanTests.\(UUID().uuidString)"))
        XCTAssertEqual(RunDistanceUnit.preferred(defaults), .miles)
        defaults.set(RunDistanceUnit.kilometers.rawValue, forKey: RunDistanceUnit.preferenceKey)
        XCTAssertEqual(RunDistanceUnit.preferred(defaults), .kilometers)
    }

    private func decodeSlot(exerciseID: String, durationSeconds: Int?, runSteps: String? = nil) throws -> TemplateExercise {
        var object: [String: Any] = [
            "id": UUID().uuidString,
            "exercise_id": exerciseID,
            "exercise_name": "Outdoor Run",
            "exercise_unit": "lb",
            "order_index": 0,
            "target_sets": 1,
            "target_reps": 1,
            "rest_seconds": 0,
            "exercise_modality": "cardio",
        ]
        if let durationSeconds { object["target_duration_s"] = durationSeconds }
        if let runSteps { object["run_steps"] = runSteps }
        let data = try JSONSerialization.data(withJSONObject: object)
        return try JSONDecoder().decode(TemplateExercise.self, from: data)
    }
}
