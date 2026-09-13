import XCTest
@testable import TresFort

final class ExerciseSearchTests: XCTestCase {
    private func exercise(_ id: String, _ name: String, _ muscle: String, _ modality: String = "barbell", aliases: String? = nil) -> ExerciseCatalog {
        ExerciseCatalog(id: id, name: name, primary_muscle: muscle, modality: modality, unit: "lb",
                        laterality: nil, load_mode: nil, demo_slug: nil, aliases: aliases)
    }

    func testSearchComposesWithRegionAndHandlesAliasesEquipmentAndPunctuation() {
        let rows = [exercise("squat", "Back Squat", "quads"),
                    exercise("bench", "Bench Press", "chest", aliases: #"["bp","flat bench"]"#),
                    exercise("pull", "Pull-Up", "back", "bw"),
                    exercise("core", "Plank", "core", "timed")]
        XCTAssertEqual(ExerciseSearchPolicy.results(rows, query: "  FLÁT bench\n", region: .upper).map(\.id), ["bench"])
        XCTAssertEqual(ExerciseSearchPolicy.results(rows, query: "bp", region: .upper).map(\.id), ["bench"])
        XCTAssertTrue(ExerciseSearchPolicy.results(rows, query: "bench", region: .lower).isEmpty)
        XCTAssertEqual(ExerciseSearchPolicy.results(rows, query: "pull up bodyweight", region: .upper).map(\.id), ["pull"])
        XCTAssertEqual(ExerciseSearchPolicy.results(rows, query: "timed", region: .core).map(\.id), ["core"])
    }

    func testAllKeepsFullBodyAndUnknownMusclesDiscoverableAndNameFillsAGap() {
        let rows = [exercise("full", "Thruster", "full body"), exercise("other", "Other", "unknown")]
        XCTAssertEqual(ExerciseSearchPolicy.results(rows, query: "", region: .all).count, 2)
        XCTAssertEqual(ExerciseSearchPolicy.defaultName(existingNames: ["Workout 1", " workout 3 ", "WORKOUT 2"]), "Workout 4")
        XCTAssertEqual(ExerciseSearchPolicy.defaultName(existingNames: ["Workout 2"]), "Workout 1")
    }

    func testAllSeedMusclesHaveTheExpectedRegion() {
        for muscle in ["quads", "hamstrings", "glutes", "calves", "legs"] {
            XCTAssertTrue(ExerciseRegion.lower.includes(exercise(muscle, muscle, muscle)))
        }
        for muscle in ["chest", "back", "shoulders", "traps", "biceps", "triceps", "forearms"] {
            XCTAssertTrue(ExerciseRegion.upper.includes(exercise(muscle, muscle, muscle)))
        }
        XCTAssertTrue(ExerciseRegion.core.includes(exercise("core", "Plank", "core")))
    }
}
