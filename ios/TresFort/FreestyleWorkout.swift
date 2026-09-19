import Foundation

struct FreestyleSlot: Codable, Equatable {
    let exercise_id: String
    var target_sets: Int
    var target_reps: Int
    var target_duration_s: Int?
    var target_weight: Double
    var rest_seconds: Int
    var source_set_ids: [String]? = nil

    enum CodingKeys: String, CodingKey {
        case exercise_id, target_sets, target_reps, target_duration_s, target_weight, rest_seconds, source_set_ids
    }
    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(exercise_id, forKey: .exercise_id)
        try c.encode(target_sets, forKey: .target_sets)
        try c.encode(target_reps, forKey: .target_reps)
        try c.encode(target_duration_s, forKey: .target_duration_s)
        try c.encode(target_weight, forKey: .target_weight)
        try c.encode(rest_seconds, forKey: .rest_seconds)
        try c.encodeIfPresent(source_set_ids, forKey: .source_set_ids)
    }
}

struct FreestyleWorkoutDraft: Decodable {
    let session: SessionRow
    let source_signature: String
    var slots: [FreestyleSlot]
}

struct SaveFreestyleRequest: Codable {
    let workout_id: String
    let name: String
    let expected_plan_id: String
    let expected_version: Int
    let expected_attempt: Int
    let source_signature: String
    let slots: [FreestyleSlot]
}

struct SaveFreestyleResult: Decodable {
    let workout_id: String
    let plan_id: String
    let version: Int
    let session: SessionRow
}

@MainActor protocol FreestyleAPI {
    func startFreestyle(date: String, expectedAttempt: Int, jwt: String) async throws -> SessionRow
    func freestyleDraft(sessionID: String, jwt: String) async throws -> FreestyleWorkoutDraft
    func saveFreestyle(sessionID: String, request: SaveFreestyleRequest, jwt: String) async throws -> SaveFreestyleResult
}

extension APIClient: FreestyleAPI {
    func startFreestyle(date: String, expectedAttempt: Int, jwt: String) async throws -> SessionRow {
        try await post("api/sessions", body: ["date": date, "kind": "freestyle", "expected_attempt": expectedAttempt],
                       jwt: jwt, headers: Self.attemptProtocolHeaders(expectedAttempt: expectedAttempt))
    }
    func freestyleDraft(sessionID: String, jwt: String) async throws -> FreestyleWorkoutDraft {
        try await get("api/sessions/\(sessionID)/workout-draft", jwt: jwt)
    }
    func saveFreestyle(sessionID: String, request: SaveFreestyleRequest, jwt: String) async throws -> SaveFreestyleResult {
        try await post("api/sessions/\(sessionID)/save-workout", body: request, jwt: jwt)
    }
}

/// Local runner presentation, never a library template or a write target.
/// Logged sets always carry a null template_exercise_id.
enum FreestyleRunner {
    static func exercise(_ exercise: ExerciseCatalog, previous: SetLog? = nil, order: Int) -> TemplateExercise {
        let timed = exercise.modality == "timed" || exercise.modality == "cardio"
        let comparable = previous.flatMap { ($0.is_timed == 1) == timed ? $0 : nil }
        return TemplateExercise(id: exercise.id, exercise_id: exercise.id, exercise_name: exercise.name,
            exercise_unit: exercise.unit, order_index: order, target_sets: 1,
            target_reps: timed ? 1 : max(1, comparable?.reps ?? 8), target_reps_max: nil, target_rpe: nil,
            rest_seconds: 120, target_weight: comparable?.weight ?? 0, cues: nil,
            exercise_modality: exercise.modality, exercise_laterality: exercise.laterality,
            exercise_load_mode: exercise.load_mode, exercise_demo_slug: exercise.demo_slug,
            target_duration_s: timed ? max(1, comparable?.duration_s ?? comparable?.reps ?? (exercise.modality == "cardio" ? 300 : 30)) : nil,
            is_warmup: 0)
    }
}
