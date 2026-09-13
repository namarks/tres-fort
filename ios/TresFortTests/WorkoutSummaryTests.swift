import XCTest
@testable import TresFort

final class WorkoutSummaryTests: XCTestCase {
    func testServerCompletionFixtureDecodesWithoutRecalculatingRecords() throws {
        let url = try XCTUnwrap(Bundle(for: Self.self).url(forResource: "WorkoutCompletion", withExtension: "json"))
        let summary = try JSONDecoder().decode(WorkoutSummary.self, from: Data(contentsOf: url))
        XCTAssertTrue(summary.final)
        XCTAssertEqual(summary.working_sets, 4)
        XCTAssertEqual(summary.external_load_volume, 225)
        XCTAssertEqual(summary.records.count, 1)
        XCTAssertEqual(summary.records.first?.label, "BW−30 lb assist · 12 reps")
        XCTAssertEqual(summary.records.first?.previous, 10)
        XCTAssertFalse(summary.targets_available)
        XCTAssertEqual(summary.cohorts.last?.label, "Strict BW · 45s")
    }
}

extension WorkoutSummaryTests {
    private struct PresentationFixture: Decodable {
        let summary: WorkoutSummary
        let session: SessionRow
        let sets: [SetLog]
    }
    private func presentationFixture() throws -> PresentationFixture {
        let url = try XCTUnwrap(Bundle(for: Self.self).url(forResource: "WorkoutSummaryPresentation", withExtension: "json"))
        return try JSONDecoder().decode(PresentationFixture.self, from: Data(contentsOf: url))
    }
    private func modifiedSummary(_ update: (inout [String: Any]) -> Void) throws -> WorkoutSummary {
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(presentationFixture().summary)) as? [String: Any])
        update(&object)
        return try JSONDecoder().decode(WorkoutSummary.self, from: JSONSerialization.data(withJSONObject: object))
    }

    func testMixedWorkoutUsesRecordedDurationAndServerVolume() throws {
        let fixture = try presentationFixture()
        let stats = WorkoutSummaryStats.make(summary: fixture.summary, session: fixture.session, timedWorkSeconds: 75)
        XCTAssertEqual(stats.map(\.id), ["duration", "volume", "sets", "reps"])
        XCTAssertEqual(stats.first?.value, "45 min")
        XCTAssertEqual(stats[1].value, "990 lb")
        let restored = try JSONDecoder().decode(SessionRow.self, from: JSONEncoder().encode(fixture.session))
        XCTAssertEqual(restored.started_at, fixture.session.started_at)
        XCTAssertEqual(restored.completed_at, fixture.session.completed_at)
    }

    func testBodyweightAndTimedWorkDoNotInventWeightLifted() throws {
        let fixture = try presentationFixture()
        let bodyweight = try modifiedSummary { $0["external_load_volume"] = NSNull() }
        XCTAssertEqual(WorkoutSummaryStats.make(summary: bodyweight, session: fixture.session,
            timedWorkSeconds: 75).map(\.id), ["duration", "reps", "sets", "timed"])
        let timed = try modifiedSummary { $0["external_load_volume"] = NSNull(); $0["total_reps"] = 0 }
        let stats = WorkoutSummaryStats.make(summary: timed, session: fixture.session, timedWorkSeconds: 75)
        XCTAssertEqual(stats.map(\.id), ["duration", "timed", "sets"])
        XCTAssertEqual(stats[1].value, "1m 15s")
    }

    func testMissingOrReversedSessionTimesAreOmitted() throws {
        let fixture = try presentationFixture()
        var session = fixture.session
        session.started_at = nil
        XCTAssertFalse(WorkoutSummaryStats.make(summary: fixture.summary, session: session, timedWorkSeconds: 0).contains { $0.id == "duration" })
        session.started_at = (session.completed_at ?? 0) + 1
        XCTAssertFalse(WorkoutSummaryStats.make(summary: fixture.summary, session: session, timedWorkSeconds: 0).contains { $0.id == "duration" })
        let legacy = try JSONDecoder().decode(SessionRow.self,
            from: Data(#"{"id":"old","date":"2026-09-08","status":"completed"}"#.utf8))
        XCTAssertNil(legacy.started_at)
        XCTAssertNil(legacy.completed_at)
    }

    func testVolumeRequiresOneKnownUnit() throws {
        let fixture = try presentationFixture()
        let mixed = try modifiedSummary { object in
            var cohorts = object["cohorts"] as! [[String: Any]]
            var kg = cohorts[0]; kg["unit"] = "kg"; cohorts.append(kg)
            object["cohorts"] = cohorts
        }
        XCTAssertFalse(WorkoutSummaryStats.make(summary: mixed, session: fixture.session,
            timedWorkSeconds: 0).contains { $0.id == "volume" })
    }

    func testTimedWorkSumsActualIntervalsAndExcludesWarmupsAndDeletedSets() throws {
        let fixture = try presentationFixture()
        var rows = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(fixture.sets)) as? [[String: Any]])
        var warmup = rows.last!; warmup["id"] = "warmup"; warmup["is_warmup"] = 1
        var deleted = rows.last!; deleted["id"] = "deleted"; deleted["deleted_at"] = 10
        var legacy = rows.last!; legacy["id"] = "legacy"; legacy["duration_s"] = NSNull(); legacy["reps"] = 20
        rows += [warmup, deleted, legacy]
        let sets = try JSONDecoder().decode([SetLog].self, from: JSONSerialization.data(withJSONObject: rows))
        XCTAssertEqual(WorkoutSummaryStats.timedWorkSeconds(sets: sets, isTimed: { $0.is_timed == 1 }), 95)
    }
}
