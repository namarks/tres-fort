import Foundation

/// Server-owned completion projection, shared by Today, history and the MCP
/// coach. No PR/target-comparison arithmetic lives in the presentation layer.
struct WorkoutSummary: Codable {
    let version: Int
    let session_id: String
    let date: String
    let attempt: Int
    let final: Bool
    let working_sets: Int
    let total_reps: Int
    let external_load_volume: Double?
    let cohorts: [Cohort]
    let records: [Record]
    let targets_available: Bool
    let targets: [Target]

    struct Cohort: Codable, Identifiable {
        let exercise_id: String
        let name: String
        let weight: Double
        let unit: String
        let modality: String
        let laterality: String
        let load_mode: String
        let metric: String
        let value: Int
        let set_count: Int
        var id: String { "\(exercise_id):\(weight):\(metric)" }
        var label: String { Self.label(weight: weight, unit: unit, modality: modality,
            loadMode: load_mode, laterality: laterality, metric: metric, value: value) }

        static func label(weight: Double, unit: String, modality: String, loadMode: String,
                          laterality: String, metric: String, value: Int) -> String {
            let displayUnit = unit == "sec" ? "lb" : unit
            let load: String
            if ["bw", "timed"].contains(modality) {
                load = weight == 0 ? "Strict BW" : weight < 0
                    ? "BW−\(SetValueFormatter.number(-weight)) \(displayUnit) assist"
                    : "BW+\(SetValueFormatter.number(weight)) \(displayUnit)"
            } else { load = "\(SetValueFormatter.number(weight)) \(displayUnit)" }
            return load + (loadMode == "per_hand" ? " each hand" : "")
                + " · \(value)\(metric == "duration" ? "s" : " reps")"
                + (laterality == "unilateral" ? " per side" : "")
        }
    }
    struct Record: Codable, Identifiable {
        let exercise_id: String
        let name: String
        let weight: Double
        let unit: String
        let modality: String
        let laterality: String
        let load_mode: String
        let metric: String
        let value: Int
        let previous: Int
        /// The previous best's own load, which can be the same implement in
        /// the other unit (53 lb for 24 kg). Older summaries omit it.
        let previous_weight: Double?
        let previous_unit: String?
        var id: String { "\(exercise_id):\(weight):\(metric)" }
        var label: String { Cohort.label(weight: weight, unit: unit, modality: modality,
            loadMode: load_mode, laterality: laterality, metric: metric, value: value) }
        var previousLabel: String {
            let text = "Previous: \(previous)\(metric == "duration" ? "s" : " reps")"
            guard let previousWeight = previous_weight, previousWeight != 0,
                  let previousUnit = previous_unit, previousUnit != unit else { return text }
            return text + " at \(SetValueFormatter.number(previousWeight)) \(previousUnit)"
        }
    }
    struct Target: Codable, Identifiable {
        let slot_id: String
        let name: String
        let sets: Int
        let actual_sets: Int
        let missed_sets: Int
        let changed_sets: Int
        let below_target_sets: Int
        let comparison_available: Bool?
        var id: String { slot_id }
        var differs: Bool { comparison_available != false &&
            (actual_sets != sets || missed_sets > 0 || changed_sets > 0 || below_target_sets > 0) }
    }
}
