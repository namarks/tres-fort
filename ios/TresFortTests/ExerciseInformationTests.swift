import XCTest
@testable import TresFort

final class ExerciseInformationTests: XCTestCase {
    private func prescription(weight: Double? = 20, timed: Bool = false) -> TemplateExercise {
        TemplateExercise(id: "slot", exercise_id: "exercise", exercise_name: "Pull-Up",
            exercise_unit: "lb", order_index: 0, target_sets: 3, target_reps: 8,
            target_reps_max: nil, target_rpe: nil, rest_seconds: 60,
            target_weight: weight, cues: "Stay controlled", exercise_modality: "bw",
            exercise_laterality: "unilateral", exercise_load_mode: "per_hand",
            exercise_demo_slug: nil, target_duration_s: timed ? 30 : nil, is_warmup: 0)
    }

    private func set(_ id: String, session: String, weight: Double = 20, timed: Bool = false,
                     warmup: Bool = false, deleted: Bool = false, exercise: String = "exercise") -> SetLog {
        SetLog(id: id, session_id: session, exercise_id: exercise, template_exercise_id: "slot",
            set_index: 1, weight: weight, reps: 8, rpe: nil, is_warmup: warmup ? 1 : 0,
            logged_at: 1, duration_s: timed ? 30 : nil, is_timed: timed ? 1 : 0,
            deleted_at: deleted ? 2 : nil)
    }

    private let sessions = [
        SessionRow(id: "older", date: "2026-09-01", status: "completed", workout_id: nil),
        SessionRow(id: "newer", date: "2026-09-02", status: "completed", workout_id: nil),
        SessionRow(id: "current", date: "2026-09-03", status: "in_progress", workout_id: nil),
        SessionRow(id: "discarded", date: "2026-09-04", status: "discarded", workout_id: nil)
    ]

    private func summary(_ sets: [SetLog], target: TemplateExercise? = nil) -> ExerciseInformationHistory.Summary? {
        let catalog = ExerciseInformation(prescription: prescription(), catalog: nil).exercise
        let history = TrainingHistoryIndex(sessions: sessions, sets: sets, catalog: [catalog]).history(for: "exercise")
        return ExerciseInformationHistory.latest(history, sessions: sessions, prescription: target)
    }

    func testMatchingPerformanceUsesCompletedSessionWithSameLoadAndMode() {
        let result = summary([
            set("matching", session: "older"),
            set("other-load", session: "newer", weight: -20),
            set("other-mode", session: "newer", timed: true),
            set("current", session: "current"), set("discarded", session: "discarded")
        ], target: prescription())
        XCTAssertEqual(result?.date, "2026-09-01")
        XCTAssertEqual(result?.cohorts.first?.top.id, "matching")
        XCTAssertEqual(result?.cohorts.first?.valueLabel, "BW+20 lb each hand · 8 reps per side")
    }

    func testAssistedHoldRetainsSignedLoadAndDuration() {
        let result = summary([set("hold", session: "older", weight: -20, timed: true),
                              set("reps", session: "newer", weight: -20)],
                             target: prescription(weight: -20, timed: true))
        XCTAssertEqual(result?.cohorts.first?.key.weight, -20)
        XCTAssertEqual(result?.cohorts.first?.bestHoldSeconds, 30)
        XCTAssertEqual(result?.cohorts.first?.valueLabel, "BW−20 lb assist each hand · 30s per side")
    }

    func testCatalogHistoryKeepsDistinctCohortsAndIgnoresDeletedWarmupAndOtherExercises() {
        let result = summary([set("working", session: "older"),
            set("assisted", session: "older", weight: -10),
            set("hold", session: "older", weight: 0, timed: true),
            set("warmup", session: "newer", warmup: true),
            set("deleted", session: "newer", deleted: true),
            set("original", session: "newer", exercise: "original-exercise")])
        XCTAssertEqual(result?.date, "2026-09-01")
        XCTAssertEqual(result?.cohorts.count, 3)
        XCTAssertEqual(Set(result?.cohorts.map(\.top.id) ?? []), ["working", "assisted", "hold"])
    }

    func testNoMatchingPerformanceIsNotSubstitutedWithDifferentLoad() {
        XCTAssertNil(summary([set("other", session: "older", weight: -20)], target: prescription()))
        XCTAssertNotNil(summary([set("other", session: "older", weight: -20)], target: prescription(weight: nil)))
    }

    func testLoadingUnavailableAndVerifiedEmptyAreDistinctAndCachedHistoryIsReadable() {
        typealias History = ExerciseInformationHistory
        XCTAssertEqual(History.availability(hasHistory: false, loading: true, verified: false, cached: false, failed: false), .loading)
        XCTAssertEqual(History.availability(hasHistory: false, loading: false, verified: false, cached: false, failed: false), .unavailable)
        XCTAssertEqual(History.availability(hasHistory: false, loading: false, verified: true, cached: true, failed: false), .unavailable)
        XCTAssertEqual(History.availability(hasHistory: false, loading: false, verified: true, cached: false, failed: true), .unavailable)
        XCTAssertEqual(History.availability(hasHistory: false, loading: false, verified: true, cached: false, failed: false), .empty)
        XCTAssertEqual(History.availability(hasHistory: true, loading: true, verified: false, cached: true, failed: true), .history)
    }

    func testTemplateIdentityAndHoldOverrideSurviveMissingCatalog() {
        let info = ExerciseInformation(prescription: prescription(timed: true), catalog: nil)
        XCTAssertEqual(info.id, "exercise")
        XCTAssertEqual(info.exercise.laterality, "unilateral")
        XCTAssertEqual(info.exercise.load_mode, "per_hand")
        XCTAssertEqual(info.prescription?.isTimed, true)
        XCTAssertEqual(info.prescription?.cues, "Stay controlled")
    }
}
