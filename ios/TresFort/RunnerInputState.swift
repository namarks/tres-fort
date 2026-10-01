import Foundation

/// A draft is reusable only for this slot and this prescription. A changed
/// target wins over an old draft; ordinary recovery keeps intentional edits.
struct RunnerPrescription: Codable, Equatable {
    let slotID: String
    let exerciseID: String
    let warmup: Bool
    let timed: Bool
    let weight: Double?
    let reps: Int
    let duration: Int?
    let rpe: Double?
    private(set) var unit: String?

    init(_ exercise: TemplateExercise) {
        slotID = exercise.id
        exerciseID = exercise.exercise_id
        warmup = exercise.isWarmup
        timed = exercise.isTimed
        weight = exercise.target_weight
        reps = exercise.target_reps
        duration = exercise.target_duration_s
        rpe = exercise.target_rpe
        unit = exercise.targetWeightUnit.rawValue
    }

    /// `unit` is the unit the draft weight is held in. Older checkpoints
    /// recorded the catalog unit ("lb", or "sec"/"min" for timed moves, both
    /// held as lb) or nothing at all; compare the load unit each one implies,
    /// so an lb-held draft never survives as a kg slot's load.
    func matches(current: Self) -> Bool {
        var comparable = self, expected = current
        comparable.unit = (WeightUnit(rawValue: unit ?? "") ?? .lb).rawValue
        expected.unit = (WeightUnit(rawValue: current.unit ?? "") ?? .lb).rawValue
        return comparable == expected
    }
}

struct RunnerInputState: Codable, Equatable {
    let prescription: RunnerPrescription
    let weight: Double
    let reps: Int
    let rpe: Double?
    let durationSeconds: Int
}

enum RunnerInputPolicy {
    /// Exact slot context prevents a working set or duplicate movement slot
    /// from becoming a warm-up/history default. Legacy unbound history is
    /// usable only when this exercise has one slot of the requested class.
    static func comparableSets(_ exercise: TemplateExercise, sets: [SetLog],
                               sessions: [SessionRow], currentSessionID: String?,
                               dayExercises: [TemplateExercise], dayID: String? = nil) -> [SetLog] {
        let completed = Set(sessions.filter { $0.status == "completed" && $0.id != currentSessionID }.map(\.id))
        let classSlots = dayExercises.filter {
            $0.exercise_id == exercise.exercise_id && $0.isWarmup == exercise.isWarmup
                && $0.isTimed == exercise.isTimed
        }
        let sameDaySessions = Set(sessions.filter { dayID != nil && $0.workout_id == dayID }.map(\.id))
        return sets.filter {
            completed.contains($0.session_id) && $0.deleted_at == nil
                && $0.exercise_id == exercise.exercise_id
                && ($0.is_warmup == 1) == exercise.isWarmup
                && ($0.is_timed.map { $0 == 1 } ?? (exercise.exercise_modality == "timed")) == exercise.isTimed
                && ($0.template_exercise_id == exercise.id
                    || ($0.template_exercise_id == nil && classSlots.count == 1 && sameDaySessions.contains($0.session_id)))
        }.sorted { $0.logged_at < $1.logged_at }
    }

    static func seed(_ exercise: TemplateExercise, previous: SetLog?, draft: RunnerInputState?, defaultWeight: Double = 45) -> RunnerInputState {
        let prescription = RunnerPrescription(exercise)
        if let draft, draft.prescription.matches(current: prescription) {
            return RunnerInputState(prescription: prescription, weight: draft.weight,
                reps: draft.reps, rpe: draft.rpe, durationSeconds: draft.durationSeconds)
        }
        // Every candidate is expressed in the slot's unit: the target already
        // is, a previous set is converted from its own unit, and the default
        // bar is 45 lb.
        let unit = exercise.targetWeightUnit
        let previousWeight = previous.map { $0.weightUnit.convert($0.weight, to: unit) }
        return RunnerInputState(
            prescription: prescription,
            weight: exercise.exercise_modality == "cardio" ? 0
                : exercise.target_weight ?? previousWeight
                    ?? (exercise.isTimed || exercise.isBodyweight ? 0 : WeightUnit.lb.convert(defaultWeight, to: unit)),
            reps: exercise.target_reps,
            rpe: exercise.target_rpe,
            durationSeconds: exercise.holdSeconds)
    }
}
