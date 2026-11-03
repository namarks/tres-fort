import HealthKit
import XCTest
@testable import TresFort

/// The sport vocabulary (docs/plans/sport-activities P0). `Sports.json` is the
/// contract `src/sports.ts` is tested against too.
final class SportsTests: XCTestCase {
    private struct Fixture: Decodable {
        struct Entry: Decodable { let id: String; let label: String }
        let sports: [Entry]
        let healthkit: [String: String]
    }

    private func fixture() throws -> Fixture {
        let url = try XCTUnwrap(Bundle(for: Self.self).url(forResource: "Sports", withExtension: "json"))
        return try JSONDecoder().decode(Fixture.self, from: Data(contentsOf: url))
    }

    func testListMatchesTheWorker() throws {
        let f = try fixture()
        XCTAssertEqual(Sports.all.map(\.id), f.sports.map(\.id))
        XCTAssertEqual(Sports.all.map(\.label), f.sports.map(\.label))
        XCTAssertFalse(Sports.all.contains { $0.glyph.isEmpty })
    }

    func testHealthKitTypesMatchTheWorker() throws {
        let f = try fixture()
        for (raw, sport) in f.healthkit {
            let type = try XCTUnwrap(HKWorkoutActivityType(rawValue: try XCTUnwrap(UInt(raw))))
            XCTAssertEqual(Sports.sport(for: type), sport, "HKWorkoutActivityType \(raw)")
        }
        // Every type the Worker doesn't list is "other" on both sides.
        for raw in UInt(1)...UInt(90) where f.healthkit[String(raw)] == nil {
            guard let type = HKWorkoutActivityType(rawValue: raw) else { continue }
            XCTAssertEqual(Sports.sport(for: type), "other", "HKWorkoutActivityType \(raw)")
        }
        XCTAssertEqual(Sports.sport(for: .soccer), "soccer")
        XCTAssertEqual(Sports.sport(for: .other), "other")
    }

    func testTitlesNameTheSport() {
        XCTAssertEqual(Sports.title(name: "Workout", sport: "soccer", kind: "other"), "Soccer")
        XCTAssertEqual(Sports.title(name: nil, sport: "tennis", kind: "other"), "Tennis")
        XCTAssertEqual(Sports.title(name: "Evening Soccer", sport: "soccer", kind: "other"), "Evening Soccer")
        XCTAssertEqual(Sports.title(name: "Workout", sport: "other", kind: "other"), "Workout")
        XCTAssertEqual(Sports.title(name: nil, sport: nil, kind: "ride"), "Ride")
        XCTAssertEqual(Sports.matching(name: " table tennis ")?.id, "table_tennis")
        XCTAssertNil(Sports.matching(name: "Other"))
        XCTAssertNil(Sports.matching(name: "Board games"))
    }

    func testActivityShowsItsSport() throws {
        let json = """
        {"id":"healthkit:activity:u:1","source":"healthkit","external_id":"1","date":"2026-11-02",
         "kind":"other","name":"Workout","moving_time_sec":5400,"elapsed_time_sec":5400,"distance_m":null,
         "average_watts":null,"weighted_avg_watts":null,"average_hr":151,"max_hr":182,"training_load":null,
         "intensity":null,"calories":900,"elevation_gain_m":null,"synced_at":1,"deleted_at":null,
         "sport":"soccer"}
        """
        let a = try JSONDecoder().decode(ExternalActivity.self, from: Data(json.utf8))
        XCTAssertEqual(a.displayTitle, "Soccer")
        XCTAssertEqual(a.glyph, "figure.soccer")
        // An older Worker sends no sport: the kind still decides.
        let old = try JSONDecoder().decode(ExternalActivity.self,
                                           from: Data(json.replacingOccurrences(of: ",\n \"sport\":\"soccer\"", with: "").utf8))
        XCTAssertNil(old.sport)
        XCTAssertEqual(old.displayTitle, "Workout")
    }

    func testPlannedSportCountsAWatchRecording() throws {
        func synced(_ name: String?, sport: String?) -> ExternalActivity {
            var a = ExternalActivity(
                id: UUID().uuidString, source: "healthkit", external_id: "x", date: "2026-11-02", kind: "other",
                name: name, moving_time_sec: 5400, elapsed_time_sec: nil, distance_m: nil, average_watts: nil,
                weighted_avg_watts: nil, average_hr: nil, max_hr: nil, training_load: nil, intensity: nil,
                calories: nil, elevation_gain_m: nil, synced_at: 1, deleted_at: nil)
            a.sport = sport
            return a
        }
        XCTAssertTrue(PlannedActivity.isLogged("Soccer", manual: [], synced: [synced("Evening Soccer", sport: "soccer")]))
        XCTAssertTrue(PlannedActivity.isLogged("Soccer", manual: [], synced: [synced("Workout", sport: "soccer")]))
        XCTAssertFalse(PlannedActivity.isLogged("Soccer", manual: [], synced: [synced("Workout", sport: "tennis")]))
        // A name that isn't a sport still needs the name.
        XCTAssertFalse(PlannedActivity.isLogged("Team practice", manual: [], synced: [synced("Workout", sport: "soccer")]))
        let logged = ActivityRow(id: "a", user_id: "u", date: "2026-11-02", type: "soccer", title: nil,
                                 duration_minutes: 90, notes: nil, logged_at: 1, source: "ios", deleted_at: nil)
        XCTAssertTrue(PlannedActivity.isLogged("Soccer", manual: [logged], synced: []))
    }

    func testPickerOffersEverySportOnce() {
        let kinds = PendingActivity.kinds
        XCTAssertEqual(Set(kinds).count, kinds.count)
        XCTAssertEqual(kinds.first, "pilates")
        XCTAssertEqual(kinds.last, "other")
        XCTAssertTrue(kinds.contains("soccer"))
        XCTAssertEqual(PendingActivity.label(for: "soccer"), "Soccer")
        XCTAssertEqual(PendingActivity.label(for: "lift"), "Lift (other)")
        XCTAssertEqual(PendingActivity.glyph(for: "tennis"), "figure.tennis")
    }
}
