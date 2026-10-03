import Foundation

/// Disposable presentation from the same synced logs and catalog the coach reads.
/// Missing catalog data is unknown, and never creates a load or progress claim.
enum CoachingContext {
    static func number(_ value: Double) -> String {
        let text = String(value)
        return text.hasSuffix(".0") ? String(text.dropLast(2)) : text
    }

    struct KeySet: Codable, Identifiable, Equatable {
        let id: String
        let exercise_id: String
        let name: String?
        let unit: String?
        let modality: String?
        let laterality: String?
        let load_mode: String?
        let weight: Double?
        let load_condition: String
        let reps: Int?
        let duration_s: Int?
        let is_timed: Bool
        let rpe: Double?
        let label: String
    }
    struct Muscle: Codable, Equatable {
        let muscle: String
        let logged_working_sets: Int
    }
    struct Volume: Codable, Equatable {
        let unit: String
        let value: Double
        let contributing_sets: Int
    }
    struct Session: Codable, Identifiable, Equatable {
        let id: String
        let date: String
        let status: String
        let notes: String?
        let perceived_fatigue: Int?
        let logged_working_sets: Int
        let sets_with_effort: Int
        let primary_muscle_sets: [Muscle]
        let external_load_volume: [Volume]
        let key_sets: [String]
        let sets: [KeySet]
    }

    static func session(_ row: SessionRow, sets: [SetLog], catalog: [ExerciseCatalog]) -> Session {
        let live = sets.filter { $0.session_id == row.id && $0.is_warmup == 0 && $0.deleted_at == nil }
            .sorted { $0.logged_at == $1.logged_at ? $0.id < $1.id : $0.logged_at < $1.logged_at }
        func exercise(_ id: String) -> ExerciseCatalog? { catalog.first { $0.id == id } }
        let representativeIDs = Set(ExerciseMetrics.cohorts(live, catalog: catalog).map { $0.top.id })
        let keySets = live.filter { representativeIDs.contains($0.id) || exercise($0.exercise_id) == nil }.map { s -> KeySet in
            let ex = exercise(s.exercise_id)
            let timed = s.is_timed.map { $0 == 1 } ?? (ex?.modality == "timed" || ex?.modality == "cardio")
            let signed = ex?.modality == "bw" || ex?.modality == "timed"
            // A set's own weight_unit decides its load unit (labels and volume
            // buckets); rows without one keep the server's catalog-derived unit.
            let unit: String?
            if ex?.modality == "cardio" { unit = nil }
            else if s.weight_unit != nil { unit = s.weightUnit.rawValue }
            else { unit = ex?.unit == "sec" ? "lb" : ex?.unit }
            let load: Double? = ex?.modality == "cardio" ? nil : s.weight
            let condition = load == nil ? "unavailable" : ex == nil ? "unknown"
                : signed ? s.weight < 0 ? "assistance" : s.weight > 0 ? "added" : "bodyweight" : "external"
            let reps = timed ? nil : s.reps
            let duration = timed ? s.duration_s ?? s.reps : nil
            let loadLabel: String
            if let load {
                loadLabel = condition == "bodyweight" ? "bodyweight"
                    : "\(number(condition == "assistance" ? abs(load) : load)) \(unit ?? "unit unknown")"
                        + (condition == "assistance" ? " assistance" : condition == "added" ? " added" : "")
            } else { loadLabel = "" }
            let value = timed ? "\(duration ?? 0)s" : "\(reps ?? 0) reps"
            let label = "\(ex?.name ?? s.exercise_id): \(value)"
                + (ex?.laterality == "unilateral" ? " per side" : "")
                + (loadLabel.isEmpty ? "" : " · \(loadLabel)")
                + (ex?.load_mode == "per_hand" ? " each hand" : "")
                + (s.rpe.map { " · RPE \(number($0))" } ?? "")
            return KeySet(id: s.id, exercise_id: s.exercise_id, name: ex?.name,
                          unit: unit, modality: ex?.modality, laterality: ex?.laterality ?? (ex == nil ? nil : "bilateral"),
                          load_mode: ex?.load_mode ?? (ex == nil ? nil : "total"), weight: load,
                          load_condition: condition, reps: reps, duration_s: duration,
                          is_timed: timed, rpe: s.rpe, label: label)
        }
        let muscles = Dictionary(grouping: live) { exercise($0.exercise_id)?.primary_muscle ?? "unknown" }
        var volumes: [String: Volume] = [:]
        for s in live {
            guard let ex = exercise(s.exercise_id), ex.modality != "cardio", ex.unit != "sec",
                  !(s.is_timed.map { $0 == 1 } ?? (ex.modality == "timed")), s.weight > 0 else { continue }
            let value = s.weight * Double(s.reps) * (ex.laterality == "unilateral" ? 2 : 1)
                * (ex.load_mode == "per_hand" ? 2 : 1)
            let unit = s.weight_unit == nil ? ex.unit : s.weightUnit.rawValue
            let old = volumes[unit]
            volumes[unit] = Volume(unit: unit, value: (old?.value ?? 0) + value,
                                   contributing_sets: (old?.contributing_sets ?? 0) + 1)
        }
        return Session(id: row.id, date: row.date, status: row.status, notes: row.notes,
                       perceived_fatigue: row.perceived_fatigue, logged_working_sets: live.count,
                       sets_with_effort: live.filter { $0.rpe != nil }.count,
                       primary_muscle_sets: muscles.keys.sorted().map { Muscle(muscle: $0, logged_working_sets: muscles[$0]!.count) },
                       external_load_volume: volumes.keys.sorted().compactMap { volumes[$0] },
                       key_sets: keySets.map(\.label), sets: keySets)
    }

    static func recent(_ sessions: [SessionRow], through today: String) -> [SessionRow] {
        Array(sessions.filter { $0.status != "discarded" && $0.date <= today }
            .sorted { $0.date == $1.date ? $0.id < $1.id : $0.date > $1.date }.prefix(7))
    }
    static func lastCompleted(_ sessions: [SessionRow], through today: String) -> SessionRow? {
        sessions.filter { $0.status == "completed" && $0.date <= today }
            .sorted { $0.date == $1.date ? $0.id < $1.id : $0.date > $1.date }.first
    }
    static func planMeta(_ raw: String?) -> [String: JSONValue] {
        let parsed = raw.flatMap { $0.data(using: .utf8) }
            .flatMap { try? JSONDecoder().decode([String: JSONValue].self, from: $0) } ?? [:]
        return Dictionary(uniqueKeysWithValues: ["schedule", "race", "periodization", "trips", "stress_model"]
            .map { ($0, parsed[$0] ?? .null) })
    }
}
