import Foundation

/// Comparable work shares an exercise/variation, execution mode, exact logged
/// external load, unit and implement/side convention. Never infer body mass.
struct ExerciseMetricCohort: Identifiable {
    struct Key: Hashable {
        let exerciseID: String
        let timed: Bool
        let weight: Double
        let unit: String
        let laterality: String
        let loadMode: String
    }
    var id: Key { key }
    let key: Key
    let modality: String
    let top: SetLog
    let setCount: Int
    let totalReps: Int
    let externalLoadVolume: Double?
    /// The unit this cohort's load (and so its estimate and volume) is in.
    var weightUnit: WeightUnit { WeightUnit(rawValue: key.unit) ?? .lb }
    var bestReps: Int? { key.timed ? nil : top.reps }
    var bestHoldSeconds: Int? { key.timed ? (top.duration_s ?? top.reps) : nil }
    var estimatedOneRepMax: Double? {
        ExerciseMetrics.estimatedOneRepMax(top, modality: modality, timed: key.timed)
    }
    var conditionLabel: String {
        let load = SetValueFormatter.number(abs(key.weight))
        let unit = key.unit == "sec" ? "lb" : key.unit
        let signed = modality == "bw" || modality == "timed"
        let base: String
        if signed && key.weight == 0 { base = "Strict BW" }
        else if signed && key.weight < 0 { base = "BW−\(load) \(unit) assist" }
        else if signed { base = "BW+\(load) \(unit)" }
        else { base = "\(SetValueFormatter.number(key.weight)) \(unit)" }
        return base + (key.loadMode == "per_hand" ? " each hand" : "")
    }
    var valueLabel: String {
        let value = key.timed ? "\(bestHoldSeconds ?? 0)s" : "\(top.reps) reps"
        return "\(conditionLabel) · \(value)"
            + (key.laterality == "unilateral" ? " per side" : "")
    }
}

enum ExerciseMetrics {
    static func estimatedOneRepMax(_ set: SetLog, modality: String, timed: Bool) -> Double? {
        guard !timed, set.weight > 0,
              ["barbell", "dumbbell", "machine"].contains(modality) else { return nil }
        return (set.weight * (1 + Double(set.reps) / 30) * 10).rounded() / 10
    }

    static func cohorts(_ sets: [SetLog], catalog: [ExerciseCatalog]) -> [ExerciseMetricCohort] {
        let live = sets.filter { $0.is_warmup == 0 && $0.deleted_at == nil }
        func exercise(_ id: String) -> ExerciseCatalog? { catalog.first { $0.id == id } }
        let grouped = Dictionary(grouping: live) { set in
            let ex = exercise(set.exercise_id)
            // Zero load is the same in either unit, so strict bodyweight and
            // unloaded holds stay one cohort whichever slot unit logged them.
            return ExerciseMetricCohort.Key(
                exerciseID: set.exercise_id,
                timed: set.is_timed.map { $0 == 1 } ?? (ex?.modality == "timed"),
                weight: set.weight,
                unit: set.weight == 0 ? WeightUnit.lb.rawValue : set.weightUnit.rawValue,
                laterality: ex?.laterality ?? "bilateral", loadMode: ex?.load_mode ?? "total")
        }
        return grouped.map { key, rows in
            func score(_ set: SetLog) -> Int { key.timed ? (set.duration_s ?? set.reps) : set.reps }
            let top = rows.dropFirst().reduce(rows[0]) { best, row in
                score(row) > score(best) ? row : best
            }
            let reps = key.timed ? 0 : rows.reduce(0) { $0 + $1.reps }
                * (key.laterality == "unilateral" ? 2 : 1)
            return ExerciseMetricCohort(
                key: key, modality: exercise(key.exerciseID)?.modality ?? "unknown",
                top: top, setCount: rows.count, totalReps: reps,
                externalLoadVolume: !key.timed && key.weight > 0
                    ? key.weight * Double(reps) * (key.loadMode == "per_hand" ? 2 : 1) : nil)
        }.sorted {
            if $0.key.exerciseID != $1.key.exerciseID { return $0.key.exerciseID < $1.key.exerciseID }
            if $0.key.timed != $1.key.timed { return !$0.key.timed }
            // Order loads physically (20 kg is heavier than 25 lb); physically
            // equal loads in different units list lb first, deterministically.
            let lhs = $0.weightUnit.convert($0.key.weight, to: .lb)
            let rhs = $1.weightUnit.convert($1.key.weight, to: .lb)
            return lhs == rhs ? $0.key.unit > $1.key.unit : lhs < rhs
        }
    }
}
