import Foundation

// Codable mirrors of the REST DTOs (server is source of truth).

struct AuthResponse: Decodable {
    let jwt: String
    let user: UserDTO
}

struct SessionRenewalResponse: Decodable {
    let jwt: String
}

enum AppleRevocationOutcome: String, Decodable, Equatable {
    case revoked
    case manualRequired = "manual_required"
}

struct AccountDeletionResponse: Decodable {
    let ok: Bool
    let owner_tombstoned: Bool
    /// Optional for compatibility with a previous Worker during app/server
    /// version skew. A missing outcome cannot prove provider revocation and
    /// therefore takes the same safe UI path as `manual_required`.
    let apple_revocation: AppleRevocationOutcome?
}

struct UserDTO: Decodable {
    let id: String
    let display_name: String?
    let email: String?
}

struct TemplateExercise: Codable, Identifiable, Equatable {
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
    /// free-exercise-db slug (e.g. "Barbell_Squat"). Optional: null when the
    /// catalog row has no upstream demo (planks/holds/band primitives), or
    /// when the payload is pre-0020. Drives the demo sheet lookup against
    /// the bundled asset catalog and the Worker /api/exercises/:id/demo
    /// route — falls back to cue text when nil.
    let exercise_demo_slug: String?
    /// Planned hold seconds for timed slots (planks, holds). Optional;
    /// when null, fall back to target_reps (the legacy timed convention).
    let target_duration_s: Int?
    /// 1 = this slot is a PRESCRIBED warm-up (erg, mobility, ramp-up). Its
    /// logged sets stay out of working-set rollups / session RPE. Optional so
    /// pre-0026 payloads decode → defaults to a working slot. (Migration 0026.)
    let is_warmup: Int?

    /// A prescribed warm-up slot (erg, mobility). Renders in a warm-up style
    /// and its logged sets are flagged is_warmup.
    var isWarmup: Bool { is_warmup == 1 }

    // Timed when the catalog modality is "timed"/"cardio" OR the slot pins an
    // explicit target_duration_s. Cardio ergs (rowing/bike/ski, treadmill) are
    // duration-driven like holds, so they use the same countdown runner.
    // Safe to honor target_duration_s now that LOGGED sets carry an
    // authoritative per-set is_timed flag (backend migration 0024): the runner
    // declares is_timed when logging (= this property), and history/agenda
    // render off set.is_timed (SyncModel.isTimedSet), so a duration-pinned hold
    // reads as "Ns" everywhere — no longer the cross-view "0 × 45"
    // inconsistency (Codex P2 on #58) that forced modality-only.
    var isTimed: Bool {
        exercise_modality == "timed" || exercise_modality == "cardio"
            || target_duration_s != nil
    }
    // Key off MODALITY, not unit: bw exercises (Pull-Up, Dead Bug) are
    // seeded with unit "lb" in the catalog, so checking the unit left the
    // weight field showing for them (bug #2). Modality is the truth.
    var isBodyweight: Bool { exercise_modality == "bw" }
    var isUnilateral: Bool { exercise_laterality == "unilateral" }
    var isPerHand: Bool { exercise_load_mode == "per_hand" }
    /// Prescribed hold/effort for a timed or cardio set, in seconds. Uses
    /// target_duration_s (the real field) and falls back to target_reps for
    /// older slots that stored the hold there. Min 1s so the timer is never
    /// zero-length.
    var holdSeconds: Int { max(1, target_duration_s ?? target_reps) }

    /// Human duration for a timed/cardio slot: "45s" for short holds, "5 min"
    /// for a whole-minute effort, "1:30" otherwise. Keeps a 5-min erg from
    /// reading "300s".
    var holdLabel: String {
        let s = holdSeconds
        if s >= 60 && s % 60 == 0 { return "\(s / 60) min" }
        if s >= 60 { return String(format: "%d:%02d", s / 60, s % 60) }
        return "\(s)s"
    }

    /// "3×5" / "3×5–8" / "3×45s" (hold) / "5 min" (single-set warm-up erg).
    var targetLabel: String {
        if isTimed {
            // A single-set timed effort (a warm-up erg, one plank) reads
            // cleaner as just the duration than "1×5 min".
            return target_sets <= 1 ? holdLabel : "\(target_sets)×\(holdLabel)"
        }
        if let hi = target_reps_max, hi != target_reps {
            return "\(target_sets)×\(target_reps)–\(hi)"
        }
        return "\(target_sets)×\(target_reps)"
    }
}

struct DayTemplate: Codable, Identifiable, Equatable {
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

struct PlanTree: Codable {
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

    /// Parsed availability/blackout ranges from `meta.trips` (M4), or [] when
    /// absent/malformed. Mirrors the backend `Trip` → `CalendarProjection.TripRange`
    /// so the composite projection can mark trip days `.unavailable`/`.light`.
    /// The backend already validates these (normalizeTrips), so defaults rarely
    /// fire; `can_train_light` defaults to true (only an explicit false blacks out).
    var trips: [TripRange] {
        guard let meta, let data = meta.data(using: .utf8) else { return [] }
        struct WireTrip: Decodable {
            let id: String
            let start: String
            let end: String
            let type: String?
            let can_train_light: Bool?
        }
        struct MetaEnvelope: Decodable { let trips: [WireTrip]? }
        guard let wire = try? JSONDecoder().decode(MetaEnvelope.self, from: data).trips else { return [] }
        return wire.map {
            TripRange(id: $0.id, start: $0.start, end: $0.end,
                      type: $0.type ?? "other",
                      canTrainLight: $0.can_train_light ?? true)
        }
    }
}

struct SessionRow: Codable, Identifiable {
    let id: String
    let date: String
    let status: String
    /// Present in `/api/state` (backend `SELECT * FROM sessions`); lets a
    /// real planned/in-progress session resolve to its template in the
    /// agenda. Optional so older payloads still decode.
    let day_template_id: String?
    /// Server mutation ordering for this canonical session. Optional for
    /// rolling compatibility, but new Workers return it on state, set, finish,
    /// and discard responses so delayed callbacks cannot outrank later state.
    var updated_at: Int? = nil
    /// Monotonic generation of the single (user,date) row. Discard retains the
    /// current attempt; explicit same-day revival increments it.
    var attempt: Int? = nil
    /// Present on compatibility Workers. Optional so the app can still decode
    /// the pre-attempt Worker during the required Worker-first rollout.
    var write_protocol: String? = nil
}

struct SetLog: Codable, Identifiable {
    let id: String
    let session_id: String
    let exercise_id: String
    /// The plan slot this set was logged against, when known. Completion and
    /// the "completed sets" chips key on THIS (the slot) rather than
    /// exercise_id, so the same movement appearing in two slots — or sets
    /// logged out of order — never cross-attribute completion (#3). Null for
    /// sets logged by Claude/MCP or before this build → callers fall back to
    /// exercise_id matching.
    let template_exercise_id: String?
    let set_index: Int
    let weight: Double
    let reps: Int
    let rpe: Double?
    let is_warmup: Int
    let logged_at: Int
    let duration_s: Int?
    /// 1 = a deliberate timed hold (render as "Ns"); 0/absent = a rep set.
    /// Backend migration 0024. Optional so sets from a pre-0024 server still
    /// decode — callers fall back to catalog modality when nil (see
    /// SyncModel.isTimedSet).
    let is_timed: Int?
    let deleted_at: Int?
}

extension SetLog {
    /// One-line value for a logged set: a timed hold reads "45s"; a bodyweight
    /// rep set reads "BW × 6"; a weighted set reads "85 × 5". A SetLog carries
    /// no modality, so the caller resolves both flags from the exercise's
    /// catalog row (see SyncModel.isTimedExercise / isBodyweightExercise) —
    /// "BW" keys off modality == "bw", NOT weight == 0, so a weighted lift
    /// logged at 0 load (unloaded warmup, machine/cable at zero) still reads
    /// "0 × reps", not "BW × reps". #30
    func valueLabel(timed: Bool, bodyweight: Bool) -> String {
        if timed, let d = duration_s, d > 0 { return "\(d)s" }
        if bodyweight { return "BW × \(reps)" }
        let w = weight.rounded() == weight ? String(Int(weight)) : String(format: "%.1f", weight)
        return "\(w) × \(reps)"
    }
}

struct ExerciseCatalog: Codable, Identifiable {
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
    /// Demo slug — see TemplateExercise.exercise_demo_slug. Optional
    /// (pre-0020 payloads).
    let demo_slug: String?
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
struct ExternalEvent: Codable, Identifiable, Equatable {
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

/// A COMPLETED endurance activity (e.g. an intervals.icu recorded ride or
/// run) surfaced read-only in the lift calendar as a "workout completed".
/// FROZEN CONTRACT — wire shape mirrors the backend exactly (see
/// migrations/0015); the app NEVER writes these.
///
/// Wire shape (a NEW array alongside `external_events` in `/api/state`):
///   { "id": "intervals:activity:{id}", "source": "intervals",
///     "external_id": "{id}", "date": "YYYY-MM-DD",
///     "kind": "ride|run|swim|other", "name": "...",
///     "moving_time_sec": 5400, "elapsed_time_sec": 5700,
///     "distance_m": 42000, "average_watts": 185,
///     "weighted_avg_watts": 205, "average_hr": 142, "max_hr": 171,
///     "training_load": 88, "intensity": 0.74, "calories": 760,
///     "elevation_gain_m": 430, "synced_at": ..., "deleted_at": null }
///
/// `deleted_at` non-null ⇒ tombstoned and must be hidden. All actuals are
/// optional: a thin/older payload still decodes.
struct ExternalActivity: Codable, Identifiable, Equatable {
    let id: String
    let source: String
    let external_id: String
    let date: String                 // YYYY-MM-DD (device-local civil date)
    let kind: String                 // ride / run / swim / other
    let name: String?
    let moving_time_sec: Int?
    let elapsed_time_sec: Int?
    let distance_m: Double?
    let average_watts: Double?
    let weighted_avg_watts: Double?  // normalized power
    let average_hr: Double?
    let max_hr: Int?
    let training_load: Int?          // TSS
    let intensity: Double?           // IF
    let calories: Int?
    let elevation_gain_m: Double?
    let synced_at: Int?
    let deleted_at: Int?             // non-null ⇒ hidden

    /// A tombstoned activity must never be shown.
    var isDeleted: Bool { deleted_at != nil }

    /// Display title, falling back to a humanised kind when absent.
    var displayTitle: String {
        if let n = name, !n.isEmpty { return n }
        return kind.capitalized
    }

    /// SF Symbol per activity kind (calendar glyph + agenda header).
    /// Mirrors the kinds emitted by `kindOf` in the backend's
    /// src/intervals.ts and FeedItemRow.rideGlyph — keep them in sync.
    var glyph: String {
        switch kind {
        case "ride":       return "bicycle"
        case "run":        return "figure.run"
        case "swim":       return "figure.pool.swim"
        case "walk":       return "figure.walk"
        case "hike":       return "figure.hiking"
        case "row":        return "figure.rower"
        case "ski":        return "figure.skiing.downhill"
        case "yoga":       return "figure.mind.and.body"
        case "elliptical": return "figure.elliptical"
        case "strength":   return "dumbbell.fill"
        default:           return "figure.mixed.cardio"
        }
    }

    /// "1h 30m" / "45m" from `moving_time_sec` (nil → nil).
    var durationLabel: String? {
        guard let s = moving_time_sec, s > 0 else { return nil }
        let h = s / 3600
        let m = (s % 3600) / 60
        if h > 0 { return m > 0 ? "\(h)h \(m)m" : "\(h)h" }
        return "\(m)m"
    }

    /// Distance in miles ("26.1 mi") — the athlete is US-based.
    var distanceLabel: String? {
        guard let m = distance_m, m > 0 else { return nil }
        return String(format: "%.1f mi", m / 1609.344)
    }

    var avgPowerLabel: String? {
        guard let w = average_watts, w > 0 else { return nil }
        return "\(Int(w.rounded())) W"
    }

    var normPowerLabel: String? {
        guard let w = weighted_avg_watts, w > 0 else { return nil }
        return "\(Int(w.rounded())) W"
    }

    /// "142 / 171 bpm" — omits max when absent; nil when no HR at all.
    var hrLabel: String? {
        let avg = (average_hr ?? 0) > 0 ? Int(average_hr!.rounded()) : nil
        let mx = (max_hr ?? 0) > 0 ? max_hr! : nil
        if let a = avg, let x = mx { return "\(a) / \(x) bpm" }
        if let a = avg { return "\(a) bpm" }
        if let x = mx { return "\(x) bpm" }
        return nil
    }

    /// Elevation in feet ("1,410 ft").
    var elevationLabel: String? {
        guard let m = elevation_gain_m, m > 0 else { return nil }
        let ft = Int((m * 3.28084).rounded())
        return "\(ft) ft"
    }

    var tssLabel: String? {
        guard let t = training_load, t > 0 else { return nil }
        return "\(t) TSS"
    }

    var caloriesLabel: String? {
        guard let c = calories, c > 0 else { return nil }
        return "\(c) cal"
    }
}

struct StateResponse: Codable {
    let plan: PlanTree?
    let plan_version: Int
    let sessions: [SessionRow]
    let sets: [SetLog]
    /// NEW (FROZEN CONTRACT): external training events (read-only ride
    /// overlay). Absent or empty in older/thin payloads → `[]`, never a
    /// decode failure.
    let external_events: [ExternalEvent]
    /// NEW (FROZEN CONTRACT): completed endurance activities (read-only
    /// "workouts completed"). Same defensive decode as external_events.
    let external_activities: [ExternalActivity]
    /// User-authored manual activities (Pilates / walk / yoga / "lift
    /// elsewhere" …) logged from the app or MCP. Keyed on user_id, NOT a
    /// group — these render on the personal calendar regardless of group
    /// membership. `/api/state` returns the full current non-deleted set
    /// under `activities`. Same defensive decode: absent/null → [].
    let activities: [ActivityRow]
    let server_time: Int

    private enum CodingKeys: String, CodingKey {
        case plan, plan_version, sessions, sets
        case external_events, external_activities, activities, server_time
    }

    init(
        plan: PlanTree?,
        plan_version: Int,
        sessions: [SessionRow],
        sets: [SetLog],
        external_events: [ExternalEvent],
        external_activities: [ExternalActivity],
        activities: [ActivityRow],
        server_time: Int
    ) {
        self.plan = plan
        self.plan_version = plan_version
        self.sessions = sessions
        self.sets = sets
        self.external_events = external_events
        self.external_activities = external_activities
        self.activities = activities
        self.server_time = server_time
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
        external_activities =
            (try? c.decodeIfPresent([ExternalActivity].self, forKey: .external_activities))
            .flatMap { $0 } ?? []
        activities =
            (try? c.decodeIfPresent([ActivityRow].self, forKey: .activities))
            .flatMap { $0 } ?? []
        server_time = try c.decode(Int.self, forKey: .server_time)
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encodeIfPresent(plan, forKey: .plan)
        try c.encode(plan_version, forKey: .plan_version)
        try c.encode(sessions, forKey: .sessions)
        try c.encode(sets, forKey: .sets)
        try c.encode(external_events, forKey: .external_events)
        try c.encode(external_activities, forKey: .external_activities)
        try c.encode(activities, forKey: .activities)
        try c.encode(server_time, forKey: .server_time)
    }
}
