import Foundation
import XCTest
@testable import TresFort

/// A planned run's laps (docs/plans/planned-runs P9): the step marks the
/// plan keeps while recording, the laps the upload and the TCX file carry,
/// and how a run's detail shows them.
final class RunLapsTests: XCTestCase {
    private let start = Date(timeIntervalSince1970: 1_793_000_000)

    /// A 60 s warm-up, then twice 200 m at 3:50–4:00 /km with 30 s to recover.
    private let steps = """
    [{"kind":"warmup","duration_s":60},{"repeat":2,"steps":[\
    {"kind":"work","distance_m":200,"target":{"type":"pace","fastest_s_per_km":230,"slowest_s_per_km":240}},\
    {"kind":"recovery","duration_s":30}]}]
    """

    /// The plan run through: the warm-up ends at 60 s and 150 m, the first
    /// 200 m at 110 s, the first recovery is skipped at 120 s, the second
    /// 200 m ends at 170 s and its recovery at 200 s. The run then walks on
    /// to 260 s and 700 m. A point and a heart rate reading every 10 s.
    private func plannedRun() -> RecordedRun {
        let expanded = RunPlan(json: steps)!.expandedSteps
        var progress = RunPlanProgress()
        XCTAssertTrue(progress.advance(expanded, movingSeconds: 60, meters: 150))
        XCTAssertTrue(progress.advance(expanded, movingSeconds: 110, meters: 350))
        progress.skip(expanded, movingSeconds: 120, meters: 370)
        XCTAssertTrue(progress.advance(expanded, movingSeconds: 170, meters: 570))
        XCTAssertTrue(progress.advance(expanded, movingSeconds: 200, meters: 640))
        XCTAssertTrue(progress.isComplete(expanded))

        var run = RecordedRun(startedAt: start, timeZone: TimeZone(identifier: "UTC")!, name: "Intervals")
        run.plan = RunPlanFollowing(runSteps: steps, progress: progress)
        run.points = stride(from: 0, through: 260, by: 10).map { second -> RecordedRun.RoutePoint in
            RecordedRun.RoutePoint(timestamp: start.addingTimeInterval(TimeInterval(second)),
                  latitude: 45.5 + Double(second) * 0.00002, longitude: -122.6, altitude: nil,
                  horizontalAccuracy: 5)
        }
        run.heartRates = stride(from: 5, through: 255, by: 10).map { second -> RecordedRun.HeartRateSample in
            let bpm: Double
            switch second {
            case ..<60: bpm = 130
            case ..<110: bpm = 170
            case ..<120: bpm = 150
            case ..<170: bpm = 172
            case ..<200: bpm = 140
            default: bpm = 110
            }
            return RecordedRun.HeartRateSample(timestamp: start.addingTimeInterval(TimeInterval(second)),
                                               beatsPerMinute: bpm)
        }
        run.movingSeconds = 260
        run.distanceMeters = 700
        run.endedAt = start.addingTimeInterval(260)
        return run
    }

    // MARK: - Recording

    func testThePlanMarksEachStepItLeaves() {
        let marks = plannedRun().plan?.progress.laps
        XCTAssertEqual(marks, [
            RunLapMark(stepIndex: 0, startSeconds: 0, startMeters: 0, endSeconds: 60, endMeters: 150, skipped: false),
            RunLapMark(stepIndex: 1, startSeconds: 60, startMeters: 150, endSeconds: 110, endMeters: 350,
                       skipped: false),
            RunLapMark(stepIndex: 2, startSeconds: 110, startMeters: 350, endSeconds: 120, endMeters: 370,
                       skipped: true),
            RunLapMark(stepIndex: 3, startSeconds: 120, startMeters: 370, endSeconds: 170, endMeters: 570,
                       skipped: false),
            RunLapMark(stepIndex: 4, startSeconds: 170, startMeters: 570, endSeconds: 200, endMeters: 640,
                       skipped: false),
        ])
    }

    func testLapsCarryEachStepAndTheStretchAfterThePlan() {
        let laps = RunLaps.summaries(plannedRun())
        XCTAssertEqual(laps.map(\.stepIndex), [0, 1, 2, 3, 4, nil])
        XCTAssertEqual(laps.map(\.end), [.completed, .completed, .skipped, .completed, .completed, .stopped])
        XCTAssertEqual(laps.map(\.movingSeconds), [60, 50, 10, 50, 30, 60])
        XCTAssertEqual(laps.map(\.meters), [150, 200, 20, 200, 70, 60])
        // Each lap's heart rate is its own: the walk after the plan doesn't
        // pull the intervals down.
        XCTAssertEqual(laps.map(\.averageHeartRate), [130, 170, 150, 172, 140, 110])
        XCTAssertEqual(laps[3].step?.round, 2)
        // The laps add up to the run.
        XCTAssertEqual(laps.map(\.movingSeconds).reduce(0, +), 260)
        XCTAssertEqual(laps.map(\.meters).reduce(0, +), 700)
    }

    func testARunStoppedMidStepEndsWithThatStep() {
        var run = plannedRun()
        let expanded = RunPlan(json: steps)!.expandedSteps
        var progress = RunPlanProgress()
        _ = progress.advance(expanded, movingSeconds: 60, meters: 150)
        run.plan?.progress = progress
        run.movingSeconds = 90
        run.distanceMeters = 260
        run.endedAt = start.addingTimeInterval(90)
        let laps = RunLaps.summaries(run)
        XCTAssertEqual(laps.map(\.stepIndex), [0, 1])
        XCTAssertEqual(laps.last?.end, .stopped)
        XCTAssertEqual(laps.last?.movingSeconds, 30)
        XCTAssertEqual(laps.last?.meters, 110)
    }

    func testNoLapsWithoutAPlanOrFromARunSavedBeforeLaps() throws {
        var plain = plannedRun()
        plain.plan = nil
        XCTAssertEqual(RunLaps.summaries(plain), [])
        XCTAssertNil(RunLaps.uploadJSON([]))

        // A checkpoint saved before laps were kept has no marks for the steps
        // it already left, so it has no laps rather than a partial list.
        var old = plannedRun()
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(old)) as? [String: Any])
        var plan = try XCTUnwrap(object["plan"] as? [String: Any])
        var progress = try XCTUnwrap(plan["progress"] as? [String: Any])
        progress["laps"] = nil
        plan["progress"] = progress
        object["plan"] = plan
        old = try JSONDecoder().decode(RecordedRun.self, from: JSONSerialization.data(withJSONObject: object))
        XCTAssertNil(old.plan?.progress.laps)
        XCTAssertEqual(RunLaps.summaries(old), [])
        // The marks round-trip through a checkpoint.
        let saved = plannedRun()
        XCTAssertEqual(try JSONDecoder().decode(RecordedRun.self, from: JSONEncoder().encode(saved)).plan, saved.plan)
    }

    func testMovingTimeAndClockTimeAroundAPause() {
        var run = RecordedRun(startedAt: start)
        run.pauses = [.init(start: start.addingTimeInterval(30), end: start.addingTimeInterval(50))]
        XCTAssertEqual(RunLaps.movingSeconds(run, at: start.addingTimeInterval(60)), 40)
        XCTAssertEqual(RunLaps.movingSeconds(run, at: start.addingTimeInterval(40)), 30)
        XCTAssertEqual(RunLaps.date(run, atMoving: 40), start.addingTimeInterval(60))
        XCTAssertEqual(RunLaps.date(run, atMoving: 20), start.addingTimeInterval(20))
        XCTAssertTrue(RunLaps.isPaused(run, at: start.addingTimeInterval(40)))
        XCTAssertFalse(RunLaps.isPaused(run, at: start.addingTimeInterval(50)))
    }

    // MARK: - Upload

    func testTheUploadCarriesTheLapsAsTheServerReadsThem() throws {
        let run = plannedRun()
        let json = try XCTUnwrap(RunLaps.uploadJSON(RunLaps.summaries(run)))
        let laps = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(json.utf8)) as? [[String: Any]])
        XCTAssertEqual(laps.count, 6)
        XCTAssertEqual(laps[1]["step"] as? Int, 2)
        XCTAssertEqual(laps[1]["kind"] as? String, "work")
        XCTAssertEqual(laps[1]["round"] as? Int, 1)
        XCTAssertEqual(laps[1]["rounds"] as? Int, 2)
        XCTAssertEqual(laps[1]["planned_distance_m"] as? Double, 200)
        XCTAssertNil(laps[1]["planned_duration_s"])
        let target = try XCTUnwrap(laps[1]["target"] as? [String: Any])
        XCTAssertEqual(target["type"] as? String, "pace")
        XCTAssertEqual(target["fastest_s_per_km"] as? Int, 230)
        XCTAssertEqual(target["slowest_s_per_km"] as? Int, 240)
        XCTAssertEqual(laps[1]["start_s"] as? Double, 60)
        XCTAssertEqual(laps[1]["moving_s"] as? Double, 50)
        XCTAssertEqual(laps[1]["distance_m"] as? Double, 200)
        XCTAssertEqual(laps[1]["avg_hr"] as? Int, 170)
        XCTAssertEqual(laps[1]["max_hr"] as? Int, 170)
        XCTAssertEqual(laps[1]["end"] as? String, "completed")
        XCTAssertEqual(laps[0]["planned_duration_s"] as? Int, 60)
        XCTAssertNil(laps[0]["round"])
        XCTAssertEqual(laps[2]["end"] as? String, "skipped")
        // After the plan: no step, nothing planned.
        XCTAssertNil(laps[5]["step"])
        XCTAssertNil(laps[5]["kind"])
        XCTAssertNil(laps[5]["target"])
        XCTAssertEqual(laps[5]["end"] as? String, "stopped")

        let body = try XCTUnwrap(String(
            data: APIClient.recordingMultipartBody(run, tcx: Data(), boundary: "B"), encoding: .utf8))
        XCTAssertTrue(body.contains("name=\"laps\"\r\n\r\n\(json)\r\n"))
        var plain = run
        plain.plan = nil
        let plainBody = try XCTUnwrap(String(
            data: APIClient.recordingMultipartBody(plain, tcx: Data(), boundary: "B"), encoding: .utf8))
        XCTAssertFalse(plainBody.contains("name=\"laps\""))
    }

    func testTheTCXHasALapPerStepAndSplitsTracksOnASharedPoint() throws {
        let tcx = try XCTUnwrap(String(data: RecordedRunTCX.encode(plannedRun()), encoding: .utf8))
        XCTAssertEqual(tcx.components(separatedBy: "<Lap ").count - 1, 6)
        XCTAssertEqual(tcx.components(separatedBy: "<Track>").count - 1, 6)
        // 27 points, five of them repeated where a step ended mid-track.
        XCTAssertEqual(tcx.components(separatedBy: "<Trackpoint>").count - 1, 32)
        XCTAssertTrue(tcx.contains("<Lap StartTime=\"2026-10-26T07:34:20Z\">\n"
            + "        <TotalTimeSeconds>50.0</TotalTimeSeconds>\n"
            + "        <DistanceMeters>200.0</DistanceMeters>\n"
            + "        <Calories>0</Calories>\n"
            + "        <AverageHeartRateBpm><Value>170</Value></AverageHeartRateBpm>\n"
            + "        <MaximumHeartRateBpm><Value>170</Value></MaximumHeartRateBpm>\n"
            + "        <Intensity>Active</Intensity>\n"
            + "        <TriggerMethod>Distance</TriggerMethod>\n"
            + "        <Track>\n"
            + "          <Trackpoint><Time>2026-10-26T07:34:10Z</Time>"))
        XCTAssertEqual(tcx.components(separatedBy: "<Intensity>Resting</Intensity>").count - 1, 2)
        XCTAssertEqual(tcx.components(separatedBy: "<TriggerMethod>Time</TriggerMethod>").count - 1, 2)
        XCTAssertEqual(tcx.components(separatedBy: "<TriggerMethod>Manual</TriggerMethod>").count - 1, 2)
        XCTAssertTrue(tcx.hasSuffix("</Lap>\n    </Activity>\n  </Activities>\n</TrainingCenterDatabase>\n"))

        // A run without a plan keeps one lap.
        var plain = plannedRun()
        plain.plan = nil
        let single = try XCTUnwrap(String(data: RecordedRunTCX.encode(plain), encoding: .utf8))
        XCTAssertEqual(single.components(separatedBy: "<Lap ").count - 1, 1)
        XCTAssertFalse(single.contains("AverageHeartRateBpm"))
    }

    // MARK: - On the run's detail

    private let served = """
    {"activity_id":"recording:activity:u:r","source":"recording","recording_id":"r","route":null,
     "heart_rate_recovery":null,"laps":[
      {"step":2,"kind":"work","round":1,"rounds":4,"planned_duration_s":null,"planned_distance_m":200,
       "target":{"type":"pace","fastest_s_per_km":230,"slowest_s_per_km":240},
       "start_s":60,"moving_s":50,"distance_m":200,"avg_hr":170,"max_hr":176,"end":"completed"},
      {"step":3,"kind":"recovery","round":1,"rounds":4,"planned_duration_s":30,"planned_distance_m":null,
       "target":{"type":"heart_rate","min_bpm":140,"max_bpm":150},
       "start_s":110,"moving_s":30,"distance_m":60,"avg_hr":152,"max_hr":160,"end":"skipped"},
      {"step":9,"kind":"cooldown","round":null,"rounds":null,"planned_duration_s":null,"planned_distance_m":1609.3,
       "target":null,"start_s":140,"moving_s":420,"distance_m":1200,"avg_hr":null,"max_hr":null,"end":"stopped"},
      {"step":null,"kind":null,"round":null,"rounds":null,"planned_duration_s":null,"planned_distance_m":null,
       "target":null,"start_s":560,"moving_s":60,"distance_m":60,"avg_hr":110,"max_hr":118,"end":"stopped"}]}
    """

    func testTheRunsDetailListsEachLapAgainstItsTarget() throws {
        let response = try JSONDecoder().decode(ActivityRouteResponse.self, from: Data(served.utf8))
        let laps = try XCTUnwrap(response.laps)
        let rows = RunLapRow.rows(laps, unit: .miles)
        XCTAssertEqual(rows.map(\.title), ["Run 1/4", "Recover 1/4", "Cool down", "After the plan"])
        XCTAssertEqual(rows.map(\.note), [nil, "Skipped", "Ended early", nil])
        // 200 m in 50 s is 6:42 a mile, slower than 6:10–6:26.
        XCTAssertEqual(rows[0].figures, "200 m · 0:50 · 6:42 /mi · 170 bpm")
        XCTAssertEqual(rows[0].target, "Pace 6:10–6:26 /mi · slower")
        XCTAssertEqual(rows[0].verdict, .slow)
        XCTAssertEqual(rows[1].target, "Heart rate 140–150 bpm · above")
        XCTAssertEqual(rows[1].verdict, .high)
        XCTAssertEqual(rows[2].figures, "0.75 mi · 7:00 · 9:23 /mi")
        XCTAssertNil(rows[2].target)
        XCTAssertEqual(rows[3].figures, "60 m · 1:00 · 26:49 /mi · 110 bpm")
        XCTAssertEqual(RunLapRow.rows(laps, unit: .kilometers)[2].figures, "1.20 km · 7:00 · 5:50 /km")

        // On target, and the edges of a pace range.
        let onPace = ActivityLap(step: 2, kind: "work", round: nil, rounds: nil, planned_duration_s: nil,
                                 planned_distance_m: 400,
                                 target: .init(type: "pace", fastest_s_per_km: 230, slowest_s_per_km: 240),
                                 start_s: 0, moving_s: 94, distance_m: 400, avg_hr: nil, max_hr: nil,
                                 end: "completed")
        XCTAssertEqual(RunLapRow.row(onPace, id: 0, unit: .kilometers).verdict, .onTarget)
        XCTAssertEqual(RunLapRow.row(onPace, id: 0, unit: .kilometers).target, "Pace 3:50–4:00 /km · on target")
        let fast = ActivityLap(step: 2, kind: "work", round: nil, rounds: nil, planned_duration_s: nil,
                           planned_distance_m: 400, target: onPace.target, start_s: 0, moving_s: 88,
                           distance_m: 400, avg_hr: nil, max_hr: nil, end: "completed")
        XCTAssertEqual(RunLapRow.row(fast, id: 0, unit: .kilometers).verdict, .fast)

        // An older server sends no laps.
        let older = try JSONDecoder().decode(ActivityRouteResponse.self, from: Data("""
        {"activity_id":"a","source":"recording","recording_id":"r","route":null}
        """.utf8))
        XCTAssertNil(older.laps)
    }
}
