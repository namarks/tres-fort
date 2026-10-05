import XCTest
@testable import TresFort

final class StationTrackingCatalogTests: XCTestCase {
    func testBundledAuditLoadsAndResolvesCandidatesAndFallbacks() {
        let catalog = StationTrackingCatalog.bundled
        XCTAssertEqual(catalog.exerciseIDs.count, 280)
        XCTAssertEqual(catalog.entry(for: "ex_db_curl").trial, .curl)
        XCTAssertEqual(catalog.entry(for: "ex_plank").trial, .plank)
        XCTAssertEqual(catalog.entry(for: "ex_wall_sit").trial, .wallSit)
        XCTAssertEqual(catalog.entry(for: "ex_side_plank").profile?.measurement, .hold)
        XCTAssertNil(catalog.entry(for: "ex_side_plank").trial)
        XCTAssertNil(catalog.entry(for: "ex_sa_db_bench").trial)
        XCTAssertNotNil(catalog.entry(for: "ex_clean_jerk").reason)
        XCTAssertNil(catalog.entry(for: "new-exercise").trial)
        XCTAssertNotNil(catalog.entry(for: "new-exercise").reason)
    }

    func testRejectsDuplicateUnknownAndIncompatibleCatalogMetadata() throws {
        let url = try XCTUnwrap(Bundle.main.url(forResource: "StationTrackingCatalog", withExtension: "json"))
        let original = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
        var newer = original
        newer["schemaVersion"] = 2
        XCTAssertThrowsError(try StationTrackingCatalog(data: JSONSerialization.data(withJSONObject: newer)))
        var groups = try XCTUnwrap(original["groups"] as? [[String: Any]])
        groups.append(groups[0])
        var duplicate = original
        duplicate["groups"] = groups
        XCTAssertThrowsError(try StationTrackingCatalog(data: JSONSerialization.data(withJSONObject: duplicate)))
        for (key, value) in [("profile", "unimplemented"), ("trial", "plank")] {
            var invalid = original
            var altered = try XCTUnwrap(original["groups"] as? [[String: Any]])
            altered[0][key] = value
            invalid["groups"] = altered
            XCTAssertThrowsError(try StationTrackingCatalog(data: JSONSerialization.data(withJSONObject: invalid)))
        }
    }

    func testTimedPrescriptionDoesNotBecomeARepCounterOrAnUnrelatedHold() throws {
        func option(id: String, modality: String, seconds: Int?) throws -> StationExerciseOption {
            var json: [String: Any] = ["id": "slot", "exercise_id": id, "exercise_name": id,
                "exercise_unit": "lb", "order_index": 0, "target_sets": 3, "target_reps": 45,
                "rest_seconds": 60, "exercise_modality": modality]
            if let seconds { json["target_duration_s"] = seconds }
            let slot = try JSONDecoder().decode(TemplateExercise.self, from: JSONSerialization.data(withJSONObject: json))
            return StationExerciseOption(prescription: slot)
        }
        XCTAssertEqual(try option(id: "ex_plank", modality: "timed", seconds: nil).targetSeconds, 45)
        XCTAssertEqual(try option(id: "ex_plank", modality: "timed", seconds: 60).trial(), .plank)
        XCTAssertNil(try option(id: "ex_plank", modality: "timed", seconds: 0).trial())
        XCTAssertNil(try option(id: "ex_plank", modality: "timed", seconds: 3601).trial())
        XCTAssertEqual(try option(id: "ex_back_squat", modality: "barbell", seconds: nil).trial(), .squat)
        XCTAssertNil(try option(id: "ex_back_squat", modality: "barbell", seconds: 30).trial())
    }
}
