import XCTest
@testable import TresFort

final class CoachingContextTests: XCTestCase {
    struct Fixture: Decodable {
        struct Conflict: Decodable {
            let name: String
            let lift_date: String
            let events: [ExternalEvent]
            let expected: String
        }
        let catalog: [ExerciseCatalog]
        let sets: [SetLog]
        let session: SessionRow
        let expected_session: CoachingContext.Session
        let meta: [String: JSONValue]
        let conflicts: [Conflict]
    }
    func fixture() throws -> Fixture {
        let url = try XCTUnwrap(Bundle(for: Self.self).url(forResource: "CoachingContext", withExtension: "json"))
        return try JSONDecoder().decode(Fixture.self, from: Data(contentsOf: url))
    }
    func testSharedSemanticProjectionAndAuthoredMetadata() throws {
        let f = try fixture()
        XCTAssertEqual(CoachingContext.session(f.session, sets: f.sets, catalog: f.catalog), f.expected_session)
        let meta = String(decoding: try JSONEncoder().encode(f.meta), as: UTF8.self)
        XCTAssertEqual(CoachingContext.planMeta(meta), f.meta)
        XCTAssertTrue(CoachingContext.planMeta("{invalid").values.allSatisfy { $0 == .null })
    }
    func testSharedSchedulingHeuristicUnknownAndThresholdFixtures() throws {
        for c in try fixture().conflicts {
            XCTAssertEqual(RideConflict.severity(forLiftDate: c.lift_date, hasLift: { $0 == c.lift_date },
                ridesOn: { date in c.events.filter { $0.date == date } }).rawValue, c.expected, c.name)
        }
    }
    func testRecentAndLastCompletedKeepSameSessionAndDoNotLetFutureOrDiscardedRowsHideIt() throws {
        let f = try fixture()
        var skipped = f.session
        skipped = SessionRow(id: "skip", date: "2026-09-10", status: "skipped", workout_id: nil)
        let future = SessionRow(id: "future", date: "2026-09-12", status: "planned", workout_id: nil)
        let discarded = SessionRow(id: "discard", date: "2026-09-11", status: "discarded", workout_id: nil)
        let rows = [future, discarded, f.session, skipped]
        XCTAssertEqual(CoachingContext.recent(rows, through: "2026-09-11").map(\.id), ["skip", "recent"])
        let last = try XCTUnwrap(CoachingContext.lastCompleted(rows, through: "2026-09-11"))
        XCTAssertEqual(CoachingContext.session(last, sets: f.sets, catalog: f.catalog), f.expected_session)
    }
    func testDeliveredBodyweightCohortsKeepTheirRecordedConditions() throws {
        for f in try BodyweightProgressFixture.load() {
            let row = SessionRow(id: f.name, date: "2026-09-09", status: "completed", workout_id: nil)
            let result = CoachingContext.session(row, sets: f.sets, catalog: f.catalog)
            let live = f.sets.filter { $0.deleted_at == nil && $0.is_warmup == 0 }
            XCTAssertEqual(result.sets.count, f.expected_cohorts.count, f.name)
            XCTAssertEqual(result.external_load_volume.first?.value, f.expected_tonnage, f.name)
            for set in result.sets {
                let original = try XCTUnwrap(live.first { $0.id == set.id })
                XCTAssertEqual(set.weight, original.weight, f.name)
                XCTAssertEqual(set.duration_s, set.is_timed ? original.duration_s ?? original.reps : nil, f.name)
            }
        }
    }
    func testKilogramSetsReadInKilogramsAndNeverJoinThePoundVolume() {
        let catalog = [ExerciseCatalog(id: "swing", name: "Kettlebell Swing", primary_muscle: "glutes",
            modality: "kettlebell", unit: "lb", laterality: "bilateral", load_mode: "total", demo_slug: nil)]
        func set(_ id: String, _ weight: Double, reps: Int, unit: String?, at time: Int) -> SetLog {
            SetLog(id: id, session_id: "session", exercise_id: "swing", template_exercise_id: nil,
                set_index: time, weight: weight, reps: reps, rpe: nil, is_warmup: 0, logged_at: time,
                duration_s: nil, is_timed: 0, deleted_at: nil, weight_unit: unit)
        }
        let row = SessionRow(id: "session", date: "2026-09-09", status: "completed", workout_id: nil)
        let sets = [set("kg", 24, reps: 15, unit: "kg", at: 1), set("lb", 24, reps: 15, unit: "lb", at: 2),
                    set("legacy", 53, reps: 12, unit: nil, at: 3)]
        let result = CoachingContext.session(row, sets: sets, catalog: catalog)
        XCTAssertEqual(result.sets.map(\.unit), ["kg", "lb", "lb"])
        XCTAssertEqual(result.key_sets, ["Kettlebell Swing: 15 reps · 24 kg", "Kettlebell Swing: 15 reps · 24 lb",
                                         "Kettlebell Swing: 12 reps · 53 lb"])
        XCTAssertEqual(result.external_load_volume, [
            CoachingContext.Volume(unit: "kg", value: 360, contributing_sets: 1),
            CoachingContext.Volume(unit: "lb", value: 996, contributing_sets: 2),
        ])
    }
    func testSetOwnedUnitReplacesOnlyTheCatalogDerivedUnit() throws {
        let f = try fixture()
        let tagged = f.sets.map { s in
            SetLog(id: s.id, session_id: s.session_id, exercise_id: s.exercise_id,
                template_exercise_id: s.template_exercise_id, set_index: s.set_index, weight: s.weight,
                reps: s.reps, rpe: s.rpe, is_warmup: s.is_warmup, logged_at: s.logged_at,
                duration_s: s.duration_s, is_timed: s.is_timed, deleted_at: s.deleted_at,
                updated_at: s.updated_at, weight_unit: "kg")
        }
        let result = CoachingContext.session(f.session, sets: tagged, catalog: f.catalog)
        // Same representatives and conditions; timed, unknown-exercise and lb
        // catalog rows now carry the set's unit, while cardio stays unitless.
        XCTAssertEqual(result.sets.map(\.id), f.expected_session.sets.map(\.id))
        XCTAssertEqual(result.sets.map(\.load_condition), f.expected_session.sets.map(\.load_condition))
        XCTAssertEqual(result.sets.map(\.unit), ["kg", "kg", "kg", "kg", "kg", nil, "kg"])
        XCTAssertEqual(result.key_sets, [
            "Plank: 45s · bodyweight",
            "Pull-Up: 8 reps · 30 kg assistance · RPE 7",
            "Pull-Up: 5 reps · 10 kg added",
            "Split Squat: 8 reps per side · 22.25 kg each hand · RPE 8.5",
            "Press: 5 reps · 20 kg",
            "Bike: 300s",
            "missing: 3 reps · 12 kg",
        ])
        XCTAssertEqual(result.external_load_volume, [CoachingContext.Volume(unit: "kg", value: 862, contributing_sets: 3)])
    }
}
