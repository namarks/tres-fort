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

    private func target(timed: Bool = false) -> TemplateExercise {
        TemplateExercise(id: "slot", exercise_id: "original", exercise_name: "Squat",
            exercise_unit: "lb", order_index: 0, target_sets: 3, target_reps: 5,
            target_reps_max: nil, target_rpe: nil, rest_seconds: 60,
            target_weight: 45, cues: nil, exercise_modality: "barbell",
            exercise_laterality: nil, exercise_load_mode: nil, exercise_demo_slug: nil,
            target_duration_s: timed ? 30 : nil, is_warmup: 0)
    }

    func testSwapSharesAliasSearchAndRegionComposition() {
        let rows = [exercise("original", "Squat", "legs"),
                    exercise("replacement", "Goblet Squat", "legs", "dumbbell", aliases: #"["front loaded squat"]"#),
                    exercise("upper", "Overhead Press", "shoulders", "dumbbell")]
        XCTAssertEqual(ExerciseSearchPolicy.results(rows, query: "FRÓNT loaded", region: .lower,
            replacing: target()).map(\.id), ["replacement"])
        XCTAssertTrue(ExerciseSearchPolicy.results(rows, query: "front loaded", region: .upper,
            replacing: target()).isEmpty)
        XCTAssertEqual(ExerciseSearchPolicy.results(rows, query: "dumbbell", region: .upper,
            replacing: target()).map(\.id), ["upper"])
    }

    func testSwapKeepsMatchingMuscleFirstWithoutHidingOtherOrUnknownMuscles() {
        let rows = [exercise("original", "Squat", "legs"),
                    exercise("other", "A Press", "chest"),
                    exercise("same", "Z Squat", "LÉGS"),
                    exercise("unknown", "B Movement", "unknown")]
        XCTAssertEqual(ExerciseSearchPolicy.results(rows, query: "", region: .all,
            replacing: target()).map(\.id), ["same", "other", "unknown"])
        XCTAssertEqual(ExerciseSearchPolicy.results(rows, query: "", region: .all).map(\.id),
                       ["other", "unknown", "original", "same"])
    }

    func testClearingSwapFiltersCannotReintroduceOriginalOrIncompatibleModes() {
        let rows = [exercise("original", "Squat", "legs"),
                    exercise("reps", "Push-Up", "chest", "bw"),
                    exercise("hold", "Plank", "core", "timed"),
                    exercise("cardio", "Bike", "legs", "cardio")]
        XCTAssertEqual(ExerciseSearchPolicy.results(rows, query: "", region: .all,
            replacing: target()).map(\.id), ["reps"])
        // A duration override determines the target's execution mode, not its catalog modality.
        XCTAssertEqual(ExerciseSearchPolicy.results(rows, query: "", region: .all,
            replacing: target(timed: true)).map(\.id), ["cardio", "hold"])
    }

    func testMissingOriginalCatalogAndMalformedAliasesKeepCompatibleChoicesDiscoverable() {
        let rows = [exercise("z", "Z Squat", "legs", aliases: "invalid"),
                    exercise("a", "A Press", "chest", aliases: #"["press"]"#),
                    exercise("hold", "Plank", "core", "timed")]
        XCTAssertEqual(ExerciseSearchPolicy.results(rows, query: "", region: .all,
            replacing: target()).map(\.id), ["a", "z"])
        XCTAssertEqual(ExerciseSearchPolicy.results(rows, query: "squat", region: .lower,
            replacing: target()).map(\.id), ["z"])
    }
}
