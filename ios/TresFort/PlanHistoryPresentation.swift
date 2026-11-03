import Foundation

/// Readable labels for plan history. The app no longer shows plan history to
/// members (owner's call, 2026-11-03): the change log stays on the server and
/// the coach reads it over MCP. The client data layer and these labels stay,
/// tested, in case a simpler view returns.
enum PlanHistoryPresentation {
    static func actor(_ actor: String) -> String {
        switch actor {
        case "mcp": return "Coach"
        case "ios": return "You"
        case "system": return "System"
        default: return actor.capitalized
        }
    }

    static func operation(_ operation: String) -> String {
        let names = ["update_plan": "Training plan updated", "update_exercise": "Exercise updated",
                     "restore_plan": "Training plan restored", "set_schedule": "Weekly schedule updated",
                     "adjust_today": "Training targets adjusted", "create_plan": "Training plan created",
                     "ensure_active_plan": "Training plan created", "baseline": "First captured version",
                     "add_day": "Workout added", "add_workout": "Workout added",
                     "update_day": "Workout updated", "update_workout": "Workout updated",
                     "delete_day": "Workout removed", "delete_workout": "Workout removed"]
        return names[operation] ?? operation.replacingOccurrences(of: "_", with: " ").capitalized
    }

    static func rationale(_ item: PlanHistoryItem) -> String {
        guard let reason = item.reason?.trimmingCharacters(in: .whitespacesAndNewlines), !reason.isEmpty else {
            return "No reason recorded."
        }
        return reason
    }

    static func indexedChanges(_ changes: [PlanVersionChange])
        -> [(offset: Int, change: PlanVersionChange)] {
        changes.enumerated().map { (offset: $0.offset, change: $0.element) }
    }

    static func fieldName(for change: PlanVersionChange) -> String {
        if change.path.contains(" · ") { return change.path }
        let field = change.path.split(separator: ".").last.map(String.init) ?? change.kind
        let names = [
            "target_sets": "Target sets", "target_reps": "Target reps",
            "target_reps_max": "Maximum reps", "target_rpe": "Target effort",
            "target_weight": "Target load", "target_weight_unit": "Target load unit",
            "target_duration_s": "Target duration",
            "rest_seconds": "Rest time", "schedule": "Weekly schedule",
            "name": change.kind == "day" ? "Workout name" : "Training plan name",
            "cues": "Coaching cues", "order_index": "Order",
        ]
        if let name = names[field] { return name }
        // Older comparison responses used storage UUIDs as their last path
        // component. Never expose those implementation identifiers in UI.
        if UUID(uuidString: field) != nil || field.hasPrefix("slot-") || field.hasPrefix("day-") {
            return change.kind == "day" ? "Workout" : "Exercise prescription"
        }
        return field.replacingOccurrences(of: "_", with: " ").capitalized
    }

    static func value(_ value: JSONValue?) -> String {
        value?.displayText ?? "Not set"
    }
}
