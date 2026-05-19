import Foundation

// Codable mirrors of the REST DTOs (server is source of truth).

struct AuthResponse: Decodable {
    let jwt: String
    let user: UserDTO
}

struct UserDTO: Decodable {
    let id: String
    let display_name: String?
    let email: String?
}

struct TemplateExercise: Decodable, Identifiable, Equatable {
    let id: String
    let exercise_id: String
    let exercise_name: String
    let exercise_unit: String
    let order_index: Int
    let target_sets: Int
    let target_reps: Int
    let target_reps_max: Int?
    let target_rpe: Double?
    let rest_seconds: Int
    let target_weight: Double?
    let cues: String?

    /// "3×5" or "3×5–8".
    var targetLabel: String {
        if let hi = target_reps_max, hi != target_reps {
            return "\(target_sets)×\(target_reps)–\(hi)"
        }
        return "\(target_sets)×\(target_reps)"
    }
}

struct DayTemplate: Decodable, Identifiable, Equatable {
    let id: String
    let name: String
    let day_label: String?
    let order_index: Int
    let exercises: [TemplateExercise]

    var title: String { day_label.map { "\($0) · \(name)" } ?? name }
}

struct PlanTree: Decodable {
    let id: String
    let name: String
    let version: Int
    let days: [DayTemplate]
}

struct SessionRow: Decodable, Identifiable {
    let id: String
    let date: String
    let status: String
}

struct SetLog: Decodable, Identifiable {
    let id: String
    let session_id: String
    let exercise_id: String
    let set_index: Int
    let weight: Double
    let reps: Int
    let rpe: Double?
    let is_warmup: Int
    let logged_at: Int
}

struct StateResponse: Decodable {
    let plan: PlanTree?
    let plan_version: Int
    let sessions: [SessionRow]
    let sets: [SetLog]
    let server_time: Int
}
