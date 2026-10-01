import XCTest
@testable import TresFort

/// One exercise history can hold lb and kg sets. Client aggregates keep each
/// unit's totals apart, compare loads physically, or report a mixed scalar as
/// unavailable; they never add or max raw numbers across units.
final class MixedUnitHistoryTests: XCTestCase {
    private func exercise(modality: String = "barbell", laterality: String? = nil,
                          loadMode: String? = nil) -> ExerciseCatalog {
        ExerciseCatalog(id: "exercise", name: "Exercise", primary_muscle: "legs",
            modality: modality, unit: "lb", laterality: laterality, load_mode: loadMode, demo_slug: nil)
    }

    private func set(_ id: String, session: String, weight: Double, reps: Int = 5,
                     unit: String? = nil, timed: Bool = false) -> SetLog {
        SetLog(id: id, session_id: session, exercise_id: "exercise", template_exercise_id: nil,
            set_index: 1, weight: weight, reps: reps, rpe: nil, is_warmup: 0, logged_at: 1,
            duration_s: timed ? reps : nil, is_timed: timed ? 1 : 0, deleted_at: nil, weight_unit: unit)
    }

    private func history(_ sets: [SetLog], dates: [String: String],
                         catalog: ExerciseCatalog? = nil) -> [TrainingHistoryIndex.SessionStat] {
        let sessions = dates.map { SessionRow(id: $0.key, date: $0.value, status: "completed", workout_id: nil) }
        return TrainingHistoryIndex(sessions: sessions, sets: sets, catalog: [catalog ?? exercise()])
            .history(for: "exercise")
    }

    func testSessionVolumeKeepsUnitsApartAndHasNoSingleScalarWhenMixed() {
        let stats = history([
            set("lb-legacy", session: "mixed", weight: 100),
            set("lb", session: "mixed", weight: 100, unit: "lb"),
            set("kg", session: "mixed", weight: 50, unit: "kg"),
            set("kg-1", session: "kilograms", weight: 60, unit: "kg"),
            set("kg-2", session: "kilograms", weight: 60, unit: "kg"),
            set("legacy", session: "pounds", weight: 135)
        ], dates: ["mixed": "2026-09-01", "kilograms": "2026-09-02", "pounds": "2026-09-03"])
        XCTAssertEqual(stats.map(\.id), ["mixed", "kilograms", "pounds"])

        // Not 1250 "lb": 1000 lb and 250 kg stay separate.
        XCTAssertEqual(stats[0].volumeByUnit, [.lb: 1000, .kg: 250])
        XCTAssertNil(stats[0].volume)
        XCTAssertEqual(WeightUnit.totals(stats[0].volumeByUnit, number: SetValueFormatter.number),
                       "1000 lb · 250 kg")
        XCTAssertEqual(stats[1].volumeByUnit, [.kg: 600])
        XCTAssertEqual(stats[1].volume, 600)
        XCTAssertEqual(WeightUnit.totals(stats[1].volumeByUnit, number: SetValueFormatter.number), "600 kg")
        XCTAssertEqual(stats[2].volume, 675)
        XCTAssertEqual(WeightUnit.totals(stats[2].volumeByUnit, number: SetValueFormatter.number), "675 lb")
        XCTAssertEqual(WeightUnit.totals([:], number: SetValueFormatter.number), "")
    }

    func testSessionEstimateComparesPhysicallyAndKeepsItsOwnUnit() throws {
        // 200 lb × 5 estimates 233.3 lb; 100 kg × 5 estimates 116.7 kg (257.3 lb).
        let stat = try XCTUnwrap(history([
            set("pounds", session: "session", weight: 200),
            set("kilograms", session: "session", weight: 100, unit: "kg")
        ], dates: ["session": "2026-09-01"]).first)
        XCTAssertEqual(stat.est1RM, 116.7)
        XCTAssertEqual(stat.loadUnit, .kg)
        XCTAssertEqual(stat.topWeight, 100)
        XCTAssertEqual(stat.topReps, 5)
        XCTAssertEqual(stat.cohorts.map(\.conditionLabel), ["200 lb", "100 kg"])
    }

    func testEstimateTrendIsShownInTheLatestUnit() throws {
        let switchedToKilograms = ExerciseHistoryProgress.options(history([
            set("pounds", session: "june", weight: 200),
            set("kilograms", session: "july", weight: 100, unit: "kg")
        ], dates: ["june": "2026-06-01", "july": "2026-07-01"]))
        let estimate = try XCTUnwrap(switchedToKilograms.first)
        XCTAssertEqual(estimate.id, .estimatedOneRepMax)
        XCTAssertEqual(estimate.unit, "kg")
        XCTAssertEqual(estimate.points.map(\.value), [105.8, 116.7])
        // Each load keeps its own comparison panel and label.
        XCTAssertEqual(Set(switchedToKilograms.dropFirst().map(\.title)),
                       ["200 lb · Best reps", "100 kg · Best reps"])

        let switchedToPounds = try XCTUnwrap(ExerciseHistoryProgress.options(history([
            set("kilograms", session: "june", weight: 100, unit: "kg"),
            set("pounds", session: "july", weight: 200, unit: "lb")
        ], dates: ["june": "2026-06-01", "july": "2026-07-01"])).first)
        XCTAssertEqual(switchedToPounds.unit, "lb")
        XCTAssertEqual(switchedToPounds.points.map(\.value), [257.3, 233.3])
    }

    func testZeroLoadIsOneCohortWhicheverUnitLoggedIt() throws {
        let stats = history([
            set("legacy", session: "s1", weight: 0, reps: 8),
            set("kg-slot", session: "s2", weight: 0, reps: 10, unit: "kg"),
            set("added-kg", session: "s3", weight: 10, unit: "kg"),
            set("added-lb", session: "s3", weight: 10, reps: 6),
            set("mixed-kg", session: "s4", weight: 0, reps: 9, unit: "kg"),
            set("mixed-lb", session: "s4", weight: 0, reps: 7, unit: "lb")
        ], dates: ["s1": "2026-06-01", "s2": "2026-07-01", "s3": "2026-07-02", "s4": "2026-07-03"],
           catalog: exercise(modality: "bw"))
        XCTAssertEqual(stats.map(\.id), ["s1", "s2", "s3", "s4"])
        XCTAssertNil(stats[2].bestReps)
        XCTAssertEqual(stats[3].cohorts.count, 1)
        XCTAssertEqual(stats[3].bestReps, 9)

        let options = ExerciseHistoryProgress.options(stats)
        XCTAssertEqual(options.count, 3)
        let strict = try XCTUnwrap(options.first { $0.title == "Strict BW · Best reps" })
        XCTAssertEqual(strict.points.map(\.value), [8, 10, 9])
        XCTAssertEqual(try XCTUnwrap(options.first { $0.title == "BW+10 kg · Best reps" }).points.map(\.value), [5])
        XCTAssertEqual(try XCTUnwrap(options.first { $0.title == "BW+10 lb · Best reps" }).points.map(\.value), [6])

        // A strict-bodyweight kg slot still finds strict work logged before units.
        let slot = TemplateExercise(id: "slot", exercise_id: "exercise", exercise_name: "Pull-Up",
            exercise_unit: "lb", order_index: 0, target_sets: 3, target_reps: 8,
            target_reps_max: nil, target_rpe: nil, rest_seconds: 60,
            target_weight: 0, cues: nil, exercise_modality: "bw",
            exercise_laterality: nil, exercise_load_mode: nil,
            exercise_demo_slug: nil, target_duration_s: nil, is_warmup: 0,
            target_weight_unit: "kg")
        let sessions = [SessionRow(id: "s1", date: "2026-06-01", status: "completed", workout_id: nil)]
        let latest = ExerciseInformationHistory.latest(Array(stats.prefix(1)), sessions: sessions, prescription: slot)
        XCTAssertEqual(latest?.cohorts.map(\.top.id), ["legacy"])
    }

    func testCohortsOrderLoadsPhysically() {
        let cohorts = ExerciseMetrics.cohorts([
            set("light", session: "session", weight: 25),
            set("kilograms", session: "session", weight: 20, unit: "kg"),
            set("heavier", session: "session", weight: 30)
        ], catalog: [exercise()])
        XCTAssertEqual(cohorts.map(\.conditionLabel), ["25 lb", "30 lb", "20 kg"])
    }

    func testPoundHistoryIsTheSameWithOrWithoutAnExplicitUnit() throws {
        func results(_ unit: String?) -> [TrainingHistoryIndex.SessionStat] {
            history([set("a", session: "may", weight: 35, reps: 8, unit: unit),
                     set("b", session: "june", weight: 33, reps: 8, unit: unit)],
                    dates: ["may": "2026-05-26", "june": "2026-06-14"])
        }
        for stats in [results(nil), results("lb")] {
            XCTAssertEqual(stats.map(\.est1RM), [44.3, 41.8])
            XCTAssertEqual(stats.map(\.loadUnit), [.lb, .lb])
            XCTAssertEqual(stats.map(\.volume), [280, 264])
            let estimate = try XCTUnwrap(ExerciseHistoryProgress.options(stats).first)
            XCTAssertEqual(estimate.unit, "lb")
            XCTAssertEqual(estimate.points.map(\.value), [44.3, 41.8])
        }
        let perHand = try XCTUnwrap(history([set("row", session: "s", weight: 20, reps: 10)],
            dates: ["s": "2026-06-01"],
            catalog: exercise(modality: "dumbbell", laterality: "unilateral", loadMode: "per_hand")).first)
        XCTAssertEqual(perHand.volume, 800)
        XCTAssertEqual(WeightUnit.totals(perHand.volumeByUnit, number: SetValueFormatter.number), "800 lb")
    }

    func testLoggedHoldLabelNamesItsOwnUnit() {
        let kilograms = set("hold", session: "s", weight: 10, reps: 30, unit: "kg", timed: true)
        XCTAssertEqual(kilograms.valueLabel(timed: true, bodyweight: false, unilateral: false), "30s · +10 kg")
        let assisted = set("hold", session: "s", weight: -5, reps: 30, unit: "kg", timed: true)
        XCTAssertEqual(assisted.valueLabel(timed: true, bodyweight: false, unilateral: false), "30s · 5 kg assist")
        let legacy = set("hold", session: "s", weight: 10, reps: 30, timed: true)
        XCTAssertEqual(legacy.valueLabel(timed: true, bodyweight: false, unilateral: false), "30s · +10 lb")
    }
}

/// The in-workout review totals the same per-unit way as history.
@MainActor
final class MixedUnitTonnageTests: XCTestCase {
    private final class Tokens: AppTokenStore {
        func load() -> String? { nil }
        func save(_ token: String) {}
        func clear() {}
    }

    /// SyncModel holds AuthModel unowned; keep it for the test's lifetime.
    private var auth: AuthModel?

    func testTonnageTotalsPerLoggedUnit() {
        let suite = "MixedUnitTonnageTests.\(UUID().uuidString)"
        let defaults = LocalPersistence(suiteName: suite)!
        addTeardownBlock { [preferences = defaults.preferences, directory = defaults.trainingStore.directory] in
            preferences.removePersistentDomain(forName: suite)
            try? FileManager.default.removeItem(at: directory)
        }
        let auth = AuthModel(tokenStore: Tokens(), defaults: defaults)
        self.auth = auth
        let model = SyncModel(auth: auth, defaults: defaults)
        model.catalog = [
            ExerciseCatalog(id: "row", name: "One-Arm Row", primary_muscle: "back", modality: "dumbbell",
                unit: "lb", laterality: "unilateral", load_mode: "per_hand", demo_slug: nil),
            ExerciseCatalog(id: "squat", name: "Squat", primary_muscle: "legs", modality: "barbell",
                unit: "lb", laterality: "bilateral", load_mode: "total", demo_slug: nil)
        ]
        func set(_ id: String, _ exercise: String, weight: Double, reps: Int, unit: String?,
                 timed: Bool = false) -> SetLog {
            SetLog(id: id, session_id: "session", exercise_id: exercise, template_exercise_id: nil,
                set_index: 1, weight: weight, reps: reps, rpe: nil, is_warmup: 0, logged_at: 1,
                duration_s: timed ? reps : nil, is_timed: timed ? 1 : 0, deleted_at: nil, weight_unit: unit)
        }
        let pounds = [set("row-lb", "row", weight: 20, reps: 10, unit: nil)]
        let sets = pounds + [
            set("row-kg", "row", weight: 10, reps: 8, unit: "kg"),
            set("squat-kg", "squat", weight: 100, reps: 5, unit: "kg"),
            set("hold-kg", "squat", weight: 10, reps: 30, unit: "kg", timed: true),
            set("unloaded", "squat", weight: 0, reps: 5, unit: "kg")
        ]

        // 20 lb × 10 per side, each hand = 800 lb; 10 kg row = 320 kg plus 500 kg of squats.
        let mixed = model.tonnageByUnit(for: sets)
        XCTAssertEqual(mixed, [.lb: 800, .kg: 820])
        XCTAssertEqual(WeightUnit.totals(mixed) { "\(Int($0))" }, "800 lb · 820 kg")
        // An all-lb workout reads exactly as before.
        XCTAssertEqual(WeightUnit.totals(model.tonnageByUnit(for: pounds)) { "\(Int($0))" }, "800 lb")
        XCTAssertTrue(model.tonnageByUnit(for: [sets[3], sets[4]]).isEmpty)
    }
}
