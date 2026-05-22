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
    /// "bilateral" (default) | "unilateral". Optional so older payloads
    /// (pre-0011 migration) still decode — defaults to bilateral.
    let exercise_laterality: String?
    /// "total" (default) | "per_hand". per_hand → weight is ONE dumbbell;
    /// display "X each hand". Optional so pre-0014 payloads still decode.
    let exercise_load_mode: String?
    /// Planned hold seconds for timed slots (planks, holds). Optional;
    /// when null, fall back to target_reps (the legacy timed convention).
    let target_duration_s: Int?

    var isTimed: Bool { exercise_modality == "timed" }
    // Key off MODALITY, not unit: bw exercises (Pull-Up, Dead Bug) are
    // seeded with unit "lb" in the catalog, so checking the unit left the
    // weight field showing for them (bug #2). Modality is the truth.
    var isBodyweight: Bool { exercise_modality == "bw" }
    var isUnilateral: Bool { exercise_laterality == "unilateral" }
    var isPerHand: Bool { exercise_load_mode == "per_hand" }
    /// Prescribed hold for a timed set, in seconds. Uses target_duration_s
    /// (the real field) and falls back to target_reps for older slots that
    /// stored the hold there. Min 1s so the timer is never zero-length.
    var holdSeconds: Int { max(1, target_duration_s ?? target_reps) }

    /// "3×5" / "3×5–8" / "3×45s" (timed).
    var targetLabel: String {
        if isTimed { return "\(target_sets)×\(holdSeconds)s" }
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
    /// "bilateral" | "unilateral". Unilateral exercises log reps per-side;
    /// rollups (set count, total reps, volume) double for unilateral so the
    /// 45×8 Bulgarian split squat reads as 16 reps / 720 lb of work, not
    /// 8 reps / 360 lb. Optional for older payloads (pre-0011 migration)
    /// — defaults to bilateral.
    let laterality: String?
    /// "total" | "per_hand". per_hand two-dumbbell lifts log one dumbbell's
    /// weight; display "X each hand". Optional (pre-0014 payloads).
    let load_mode: String?
}

/// An externally-sourced training event (e.g. an intervals.icu planned
/// ride) surfaced read-only in the lift calendar. FROZEN CONTRACT — wire
/// shape mirrors the backend exactly; the app NEVER writes these.
///
/// Wire shape (a NEW array alongside `sessions`/`sets` in `/api/state`):
///   { "id": "intervals:{event_id}", "source": "intervals",
///     "external_id": "{event_id}", "date": "YYYY-MM-DD",
///     "kind": "ride|run|swim|other", "title": "...",
///     "description": "...", "planned_duration_sec": 5400,
///     "training_load": 95, "intensity": 0.78,
///     "synced_at": 1716000000000, "deleted_at": null }
///
/// `deleted_at` non-null ⇒ the event is tombstoned and must be hidden.
/// All optional fields are tolerant: a thin/older payload still decodes.
struct ExternalEvent: Decodable, Identifiable, Equatable {
    let id: String
    let source: String
    let external_id: String
    let date: String                 // YYYY-MM-DD (device-local civil date)
    let kind: String                 // ride / run / swim / other
    let title: String?
    let description: String?
    let planned_duration_sec: Int?
    let training_load: Int?          // TSS
    let intensity: Double?           // IF
    let synced_at: Int?
    let deleted_at: Int?             // non-null ⇒ hidden

    /// A tombstoned event must never be shown or counted in conflicts.
    var isDeleted: Bool { deleted_at != nil }

    /// "1h 30m" / "45m" from `planned_duration_sec` (nil → nil).
    var durationLabel: String? {
        guard let s = planned_duration_sec, s > 0 else { return nil }
        let h = s / 3600
        let m = (s % 3600) / 60
        if h > 0 { return m > 0 ? "\(h)h \(m)m" : "\(h)h" }
        return "\(m)m"
    }

    /// Display title, falling back to a humanised kind when absent.
    var displayTitle: String {
        if let t = title, !t.isEmpty { return t }
        return kind.capitalized
    }
}

struct StateResponse: Decodable {
    let plan: PlanTree?
    let plan_version: Int
    let sessions: [SessionRow]
    let sets: [SetLog]
    /// NEW (FROZEN CONTRACT): external training events (read-only ride
    /// overlay). Absent or empty in older/thin payloads → `[]`, never a
    /// decode failure.
    let external_events: [ExternalEvent]
    let server_time: Int

    private enum CodingKeys: String, CodingKey {
        case plan, plan_version, sessions, sets, external_events, server_time
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        plan = try c.decodeIfPresent(PlanTree.self, forKey: .plan)
        plan_version = try c.decode(Int.self, forKey: .plan_version)
        sessions = try c.decode([SessionRow].self, forKey: .sessions)
        sets = try c.decode([SetLog].self, forKey: .sets)
        // Absent key OR JSON null → no rides (defensive, never throws).
        external_events =
            (try? c.decodeIfPresent([ExternalEvent].self, forKey: .external_events))
            .flatMap { $0 } ?? []
        server_time = try c.decode(Int.self, forKey: .server_time)
    }
}
