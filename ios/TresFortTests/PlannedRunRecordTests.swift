import XCTest
@testable import TresFort

final class PlannedRunRecordTests: XCTestCase {
    private func activity(
        id: String = UUID().uuidString, kind: String = "run", name: String? = nil,
        seconds: Int? = 1_537, meters: Double? = 5_296, averageHR: Double? = 150, maxHR: Int? = 160,
        load: Int? = 31, deleted: Bool = false
    ) -> ExternalActivity {
        ExternalActivity(
            id: id, source: "intervals", external_id: id, date: "2026-11-01", kind: kind, name: name,
            moving_time_sec: seconds, elapsed_time_sec: nil, distance_m: meters, average_watts: nil,
            weighted_avg_watts: nil, average_hr: averageHR, max_hr: maxHR, training_load: load,
            intensity: nil, calories: nil, elevation_gain_m: nil, synced_at: 1, deleted_at: deleted ? 2 : nil)
    }

    /// Tonight's run: a half-mile warm-up, then 3 miles at 147–153 bpm.
    private let zoneThree = RunPlan(json: """
    [{"kind":"warmup","distance_m":805},
     {"kind":"work","distance_m":4828,"target":{"type":"heart_rate","min_bpm":147,"max_bpm":153}}]
    """)!

    func testTheWorkoutsRunIsTheOneNamedForItElseTheLongest() {
        let named = activity(id: "named", name: "Zone 3 Run 3.5 mi", seconds: 900)
        let longer = activity(id: "longer", name: "Run", seconds: 2_000)
        let ride = activity(id: "ride", kind: "ride", seconds: 5_000)
        let gone = activity(id: "gone", name: "zone 3 run 3.5 mi", deleted: true)

        XCTAssertEqual(PlannedRunRecord.matchingRun(
            workoutName: " zone 3 run 3.5 MI", among: [gone, longer, named, ride])?.id, "named")
        XCTAssertEqual(PlannedRunRecord.matchingRun(workoutName: "Tempo", among: [named, longer, ride])?.id, "longer")
        XCTAssertNil(PlannedRunRecord.matchingRun(workoutName: "Tempo", among: [ride, gone]))
    }

    func testARunReadsAgainstItsPlannedDistanceAndHeartRateTarget() {
        let record = PlannedRunRecord(run: activity(), plan: zoneThree, unit: .miles)
        let rows = Dictionary(uniqueKeysWithValues: record.rows.map { ($0.id, $0) })

        XCTAssertEqual(record.rows.map(\.id), ["distance", "time", "pace", "heartRate", "load"])
        XCTAssertEqual(rows["distance"]?.value, "3.29 mi")
        XCTAssertEqual(rows["distance"]?.detail, "Planned 3.5 mi")
        XCTAssertEqual(rows["time"]?.value, "25:37")
        XCTAssertNil(rows["time"]?.detail, "A distance plan has no planned time")
        XCTAssertEqual(rows["pace"]?.value, "7:47 /mi")
        XCTAssertNil(rows["pace"]?.onTarget, "A heart rate plan sets no pace")
        XCTAssertEqual(rows["heartRate"]?.value, "150 avg · 160 max")
        XCTAssertEqual(rows["heartRate"]?.detail, "In your 147–153 bpm target")
        XCTAssertEqual(rows["heartRate"]?.onTarget, true)
        XCTAssertEqual(rows["load"]?.value, "31")

        let hot = PlannedRunRecord(run: activity(averageHR: 158), plan: zoneThree, unit: .miles)
        XCTAssertEqual(hot.rows.first { $0.id == "heartRate" }?.detail, "Above your 147–153 bpm target")
        XCTAssertEqual(hot.rows.first { $0.id == "heartRate" }?.onTarget, false)
    }

    func testPaceTargetsAndTimedPlans() throws {
        // 30 minutes at 5:00–5:30 /km.
        let steady = try XCTUnwrap(RunPlan(json: """
        [{"kind":"work","duration_s":1800,"target":{"type":"pace","fastest_s_per_km":300,"slowest_s_per_km":330}}]
        """))
        let inRange = PlannedRunRecord(run: activity(seconds: 1_800, meters: 5_800, averageHR: nil, maxHR: nil, load: nil),
                                       plan: steady, unit: .kilometers)
        XCTAssertEqual(inRange.rows.map(\.id), ["distance", "time", "pace"])
        XCTAssertEqual(inRange.rows[1].detail, "Planned 30 min")
        XCTAssertEqual(inRange.rows[2].value, "5:10 /km")
        XCTAssertEqual(inRange.rows[2].detail, "In your 5:00–5:30 /km target")

        let fast = PlannedRunRecord(run: activity(seconds: 1_800, meters: 6_500), plan: steady, unit: .kilometers)
        XCTAssertEqual(fast.rows.first { $0.id == "pace" }?.detail, "Faster than your 5:00–5:30 /km target")
        let slow = PlannedRunRecord(run: activity(seconds: 1_800, meters: 5_000), plan: steady, unit: .kilometers)
        XCTAssertEqual(slow.rows.first { $0.id == "pace" }?.detail, "Slower than your 5:00–5:30 /km target")

        // A run without steps compares with the slot's time.
        let plain = PlannedRunRecord(run: activity(), plan: nil, plannedSeconds: 2_400, unit: .miles)
        XCTAssertEqual(plain.rows.first { $0.id == "time" }?.detail, "Planned 40 min")
        XCTAssertNil(plain.rows.first { $0.id == "distance" }?.detail)
    }

    func testIntervalsWithDifferentTargetsHaveNoSharedTarget() throws {
        let intervals = try XCTUnwrap(RunPlan(json: """
        [{"kind":"warmup","duration_s":600},
         {"repeat":4,"steps":[
           {"kind":"work","distance_m":800,"target":{"type":"pace","fastest_s_per_km":245,"slowest_s_per_km":255}},
           {"kind":"recovery","duration_s":120,"target":{"type":"heart_rate","min_bpm":110,"max_bpm":130}}]}]
        """))
        XCTAssertNil(PlannedRunRecord.sharedTarget(intervals))
        XCTAssertNil(PlannedRunRecord.plannedMeters(intervals))
        XCTAssertNil(PlannedRunRecord.plannedSeconds(intervals))
        XCTAssertEqual(PlannedRunRecord.plannedMeters(zoneThree), 5_633)
        XCTAssertEqual(PlannedRunRecord.sharedTarget(zoneThree), .heartRate(minBPM: 147, maxBPM: 153))

        let record = PlannedRunRecord(run: activity(), plan: intervals, unit: .miles)
        XCTAssertTrue(record.rows.allSatisfy { $0.onTarget == nil })
    }

    func testHeadlineLeavesOutWhatTheRunLacks() {
        XCTAssertEqual(PlannedRunRecord.headline(activity(), unit: .miles), "3.29 mi · 25:37 · 150 bpm average")
        XCTAssertEqual(PlannedRunRecord.headline(activity(meters: nil, averageHR: nil), unit: .miles), "25:37")
    }
}
