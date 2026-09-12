import Foundation

struct SessionExerciseSwaps: Codable {
    var attempt: Int = 0
    let revision: Int
    let entries: [SessionExerciseSwap]
}

struct SessionExerciseSwap: Codable {
    let original: TemplateExercise
    let replacement: TemplateExercise
    let exercise_ids: [String]
}

extension SessionRow {
    var exerciseSwaps: SessionExerciseSwaps {
        guard let data = exercise_swaps?.data(using: .utf8),
              let swaps = try? JSONDecoder().decode(SessionExerciseSwaps.self, from: data),
              swaps.attempt == (attempt ?? 0)
        else { return SessionExerciseSwaps(revision: 0, entries: []) }
        return swaps
    }

    func exerciseSwap(for original: TemplateExercise) -> SessionExerciseSwap? {
        exerciseSwaps.entries.first { $0.original == original }
    }

    func applyingExerciseSwaps(to workout: Workout) -> Workout {
        guard status != "discarded" else { return workout }
        let swaps = exerciseSwaps.entries
        guard !swaps.isEmpty else { return workout }
        return Workout(id: workout.id, name: workout.name, day_label: workout.day_label,
            order_index: workout.order_index, exercises: workout.exercises.map { original in
                swaps.first { $0.original == original }?.replacement ?? original
            })
    }
}

struct WorkoutSwapTarget: Identifiable {
    let session: WorkoutTerminalActionTarget
    let exercise: TemplateExercise
    let planVersion: Int
    let revision: Int
    var id: String { exercise.id }
}

@MainActor
protocol SessionExerciseSwapAPI {
    func swapSessionExercise(sessionID: String, slotID: String, exerciseID: String,
        expectedAttempt: Int, expectedVersion: Int, expectedRevision: Int, jwt: String) async throws -> SessionRow
}

extension APIClient: SessionExerciseSwapAPI {
    func swapSessionExercise(sessionID: String, slotID: String, exerciseID: String,
        expectedAttempt: Int, expectedVersion: Int, expectedRevision: Int, jwt: String) async throws -> SessionRow {
        try await post("api/sessions/\(sessionID)/exercises/\(slotID)/swap", body: [
            "to_exercise": exerciseID, "expected_attempt": expectedAttempt,
            "expected_version": expectedVersion, "expected_revision": expectedRevision,
        ], jwt: jwt)
    }
}
