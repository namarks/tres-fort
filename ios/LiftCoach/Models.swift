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
    let exercise_modality: String

    var isTimed: Bool { exercise_modality == "timed" }
    var isBodyweight: Bool { exercise_unit == "bw" }

    /// "3×5" / "3×5–8" / "3×45s" (timed).
    var targetLabel: String {
        if isTimed { return "\(target_sets)×\(target_reps)s" }
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

/// `meta.schedule` — the weekly recurrence map (FROZEN CONTRACT).
///
/// Wire shape (inside the plan's `meta` JSON string):
///   "schedule": { "version": 1,
///     "week": { "mon": "<day_template_id|null>", "tue": …, … "sun": … } }
///
/// Keyed by weekday; null / absent = rest day; values are `day_template_id`.
/// The app is READ-ONLY here — Claude owns schedule edits via MCP.
struct PlanSchedule: Decodable, Equatable {
    let version: Int
    let week: [String: String?]

    /// Lowercase 3-letter keys, in the contract's order.
    static let weekdayKeys = ["mon", "tue", "wed", "thu", "fri", "sat", "sun"]

    /// day_template_id scheduled for a weekday key, or nil (rest / absent).
    func templateID(forWeekdayKey key: String) -> String? {
        // `week[key]` is `String??`: outer = key present, inner = JSON null.
        guard let inner = week[key] else { return nil }
        return inner
    }
}

struct PlanTree: Decodable {
    let id: String
    let name: String
    let version: Int
    let days: [DayTemplate]
    /// Raw plan `meta` JSON, delivered by the backend as a JSON-encoded
    /// *string* (`plans.meta TEXT`). Schedule lives inside it; decoded
    /// lazily via `schedule` so a malformed/absent meta never breaks sync.
    let meta: String?

    /// Parsed weekly schedule, or nil if meta is absent/!schedule/malformed.
    var schedule: PlanSchedule? {
        guard let meta, let data = meta.data(using: .utf8) else { return nil }
        struct MetaEnvelope: Decodable { let schedule: PlanSchedule? }
        return try? JSONDecoder().decode(MetaEnvelope.self, from: data).schedule
    }
}

struct SessionRow: Decodable, Identifiable {
    let id: String
    let date: String
    let status: String
    /// Present in `/api/state` (backend `SELECT * FROM sessions`); lets a
    /// real planned/in-progress session resolve to its template in the
    /// agenda. Optional so older payloads still decode.
    let day_template_id: String?
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
    let duration_s: Int?
    let deleted_at: Int?
}

struct ExerciseCatalog: Decodable, Identifiable {
    let id: String
    let name: String
    let primary_muscle: String
    let modality: String
    let unit: String
}

struct StateResponse: Decodable {
    let plan: PlanTree?
    let plan_version: Int
    let sessions: [SessionRow]
    let sets: [SetLog]
    let server_time: Int
}
