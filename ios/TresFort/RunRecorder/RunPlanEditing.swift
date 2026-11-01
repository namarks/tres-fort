import Foundation

/// Limits the server enforces on planned run steps (src/runSteps.ts), so the
/// editor can stop a member before a save is rejected.
enum RunPlanLimits {
    static let items = 50
    static let repeatSteps = 10
    static let repeats = 1...50
    static let expandedSteps = 200
    static let durationSeconds = 1...(6 * 60 * 60)
    static let distanceMeters = 100_000.0
    static let paceSecondsPerKm = 120...1200
    static let heartRate = 40...230
}

extension RunPlan {
    /// The step list in the plan's JSON format, as the slot routes accept it.
    var jsonObject: [[String: Any]] {
        items.map { item in
            switch item {
            case .step(let step):
                return Self.object(step)
            case .repeated(let times, let steps):
                return ["repeat": times, "steps": steps.map(Self.object)]
            }
        }
    }

    /// How many steps the runner meets, with repeats unrolled.
    var expandedCount: Int {
        items.reduce(0) { total, item in
            switch item {
            case .step: return total + 1
            case .repeated(let times, let steps): return total + times * steps.count
            }
        }
    }

    private static func object(_ step: Step) -> [String: Any] {
        var object: [String: Any] = ["kind": step.kind.rawValue]
        if let distance = step.distanceMeters {
            object["distance_m"] = distance
        } else {
            object["duration_s"] = step.durationSeconds ?? 0
        }
        switch step.target {
        case .pace(let fastest, let slowest)?:
            object["target"] = ["type": "pace", "fastest_s_per_km": fastest, "slowest_s_per_km": slowest]
        case .heartRate(let low, let high)?:
            object["target"] = ["type": "heart_rate", "min_bpm": low, "max_bpm": high]
        case nil:
            break
        }
        return object
    }
}

extension RunPlan.Step {
    /// Why the server would reject this step, in words for the editor, or nil.
    var problem: String? {
        if let distance = distanceMeters {
            if !(distance > 0) { return "Enter a distance." }
            if distance > RunPlanLimits.distanceMeters { return "A step can be at most 100 km." }
        } else {
            guard let seconds = durationSeconds, seconds >= 1 else { return "Enter a time." }
            if seconds > RunPlanLimits.durationSeconds.upperBound { return "A step can be at most 6 hours." }
        }
        switch target {
        case .pace(let fastest, let slowest)?:
            guard RunPlanLimits.paceSecondsPerKm.contains(fastest),
                  RunPlanLimits.paceSecondsPerKm.contains(slowest) else {
                return "Pace must be between 2:00 and 20:00 per kilometer."
            }
            if fastest > slowest { return "The fast end of the pace range must be quicker than the slow end." }
        case .heartRate(let low, let high)?:
            guard RunPlanLimits.heartRate.contains(low), RunPlanLimits.heartRate.contains(high) else {
                return "Heart rate must be between 40 and 230 bpm."
            }
            if low > high { return "The low end of the heart rate range must be below the high end." }
        case nil:
            break
        }
        return nil
    }
}

/// A planned run while the member edits it. Each item is one step or a
/// repeat group, with ids so lists can track them.
struct RunPlanDraft: Equatable {
    struct Step: Identifiable, Equatable {
        var id = UUID()
        var step: RunPlan.Step
    }

    struct Item: Identifiable, Equatable {
        var id = UUID()
        /// Nil for a single step; otherwise how many times the steps repeat.
        var repeats: Int?
        var steps: [Step]
    }

    var items: [Item]

    static let newStep = RunPlan.Step(kind: .work, durationSeconds: 600, distanceMeters: nil, target: nil)

    init(plan: RunPlan?) {
        items = (plan?.items ?? []).map { item in
            switch item {
            case .step(let step):
                return Item(repeats: nil, steps: [Step(step: step)])
            case .repeated(let times, let steps):
                return Item(repeats: times, steps: steps.map { Step(step: $0) })
            }
        }
    }

    /// The plan to save; nil when there are no steps, which saves the run
    /// without steps.
    var plan: RunPlan? {
        let planItems: [RunPlan.Item] = items.compactMap { item -> RunPlan.Item? in
            if let repeats = item.repeats {
                return item.steps.isEmpty ? nil : .repeated(times: repeats, steps: item.steps.map(\.step))
            }
            return item.steps.first.map { .step($0.step) }
        }
        return planItems.isEmpty ? nil : RunPlan(items: planItems)
    }

    var canAddItem: Bool { items.count < RunPlanLimits.items }

    func canAddStep(toRepeat id: UUID) -> Bool {
        (items.first { $0.id == id }?.steps.count ?? RunPlanLimits.repeatSteps) < RunPlanLimits.repeatSteps
    }

    /// Why the plan can't be saved yet, or nil.
    var problem: String? {
        if items.count > RunPlanLimits.items { return "A plan can have at most 50 parts." }
        for (index, item) in items.enumerated() {
            if let repeats = item.repeats {
                if item.steps.isEmpty { return "Repeat \(index + 1) needs at least one step." }
                if item.steps.count > RunPlanLimits.repeatSteps { return "A repeat can hold at most 10 steps." }
                if !RunPlanLimits.repeats.contains(repeats) { return "A repeat runs 1 to 50 times." }
            }
            if let problem = item.steps.lazy.compactMap(\.step.problem).first { return problem }
        }
        if let plan, plan.expandedCount > RunPlanLimits.expandedSteps {
            return "With repeats, a plan can have at most 200 steps."
        }
        return nil
    }

    mutating func addStep(_ step: RunPlan.Step = RunPlanDraft.newStep) {
        guard canAddItem else { return }
        items.append(Item(repeats: nil, steps: [Step(step: step)]))
    }

    /// Adds "4 × (work, recovery)", the usual interval shape.
    mutating func addRepeat() {
        guard canAddItem else { return }
        items.append(Item(repeats: 4, steps: [
            Step(step: RunPlan.Step(kind: .work, durationSeconds: 180, distanceMeters: nil, target: nil)),
            Step(step: RunPlan.Step(kind: .recovery, durationSeconds: 90, distanceMeters: nil, target: nil)),
        ]))
    }

    mutating func addStep(toRepeat id: UUID) {
        guard canAddStep(toRepeat: id), let index = items.firstIndex(where: { $0.id == id }) else { return }
        items[index].steps.append(Step(step: Self.newStep))
    }

    /// Moves a part up (-1) or down (+1); does nothing at either end.
    mutating func move(_ id: UUID, by offset: Int) {
        guard let index = items.firstIndex(where: { $0.id == id }) else { return }
        let destination = index + offset
        guard items.indices.contains(destination) else { return }
        items.swapAt(index, destination)
    }

    /// Moves a step within its repeat.
    mutating func moveStep(_ stepID: UUID, inRepeat id: UUID, by offset: Int) {
        guard let index = items.firstIndex(where: { $0.id == id }),
              let stepIndex = items[index].steps.firstIndex(where: { $0.id == stepID }) else { return }
        let destination = stepIndex + offset
        guard items[index].steps.indices.contains(destination) else { return }
        items[index].steps.swapAt(stepIndex, destination)
    }

    mutating func remove(_ id: UUID) {
        items.removeAll { $0.id == id }
    }

    /// Removes a step from a repeat; the last step removes the repeat.
    mutating func removeStep(_ stepID: UUID, inRepeat id: UUID) {
        guard let index = items.firstIndex(where: { $0.id == id }) else { return }
        items[index].steps.removeAll { $0.id == stepID }
        if items[index].steps.isEmpty { items.remove(at: index) }
    }

    mutating func update(_ stepID: UUID, to step: RunPlan.Step) {
        for index in items.indices {
            if let stepIndex = items[index].steps.firstIndex(where: { $0.id == stepID }) {
                items[index].steps[stepIndex].step = step
                return
            }
        }
    }
}

/// Paces as the member types them, "4:05", in the recorder's unit, and as
/// the plan stores them, whole seconds per kilometer.
enum RunPaceInput {
    /// Seconds from "m:ss", or nil when the text isn't a pace.
    static func seconds(_ text: String) -> Int? {
        let parts = text.trimmingCharacters(in: .whitespaces).split(separator: ":", omittingEmptySubsequences: false)
        guard parts.count == 2, let minutes = Int(parts[0]), let seconds = Int(parts[1]),
              parts[1].count == 2, minutes >= 0, (0..<60).contains(seconds) else { return nil }
        return minutes * 60 + seconds
    }

    /// A pace per mile or kilometer as seconds per kilometer.
    static func secondsPerKm(_ secondsPerUnit: Int, unit: RunDistanceUnit) -> Int {
        Int((Double(secondsPerUnit) * 1_000 / unit.meters).rounded())
    }

    /// "4:05" for a stored pace, shown per mile or kilometer.
    static func text(secondsPerKm: Int, unit: RunDistanceUnit) -> String {
        let perUnit = Int((Double(secondsPerKm) * unit.meters / 1_000).rounded())
        return "\(perUnit / 60):" + String(format: "%02d", perUnit % 60)
    }
}

/// Distances as the member types them, in meters, kilometers or miles.
enum RunDistanceInput: String, CaseIterable, Identifiable {
    case meters = "m", kilometers = "km", miles = "mi"

    var id: String { rawValue }

    var meters: Double {
        switch self {
        case .meters: return 1
        case .kilometers: return 1_000
        case .miles: return RunDistanceUnit.miles.meters
        }
    }

    /// Meters from typed text such as "800" or "1.5", or nil.
    func meters(_ text: String) -> Double? {
        guard let value = Double(text.trimmingCharacters(in: .whitespaces).replacingOccurrences(of: ",", with: ".")),
              value.isFinite, value > 0 else { return nil }
        return value * meters
    }

    /// The unit a stored distance reads best in, and its value as text.
    static func display(_ meters: Double, preferred: RunDistanceUnit) -> (RunDistanceInput, String) {
        if meters < 1_000 { return (.meters, String(Int(meters.rounded()))) }
        let unit: RunDistanceInput = preferred == .miles ? .miles : .kilometers
        let value = ((meters / unit.meters) * 100).rounded() / 100
        var text = String(format: "%.2f", value)
        while text.hasSuffix("0") { text.removeLast() }
        if text.hasSuffix(".") { text.removeLast() }
        return (unit, text)
    }
}

/// A step's distance while the member edits it. The text shows a rounded
/// value, so until the member changes the text or unit, the step keeps the
/// exact distance it had.
struct RunDistanceEntry {
    var text: String
    var unit: RunDistanceInput
    private let original: (meters: Double, text: String, unit: RunDistanceInput)?

    init(meters: Double?, preferred: RunDistanceUnit) {
        if let meters {
            let shown = RunDistanceInput.display(meters, preferred: preferred)
            unit = shown.0
            text = shown.1
            original = (meters, shown.1, shown.0)
        } else {
            unit = preferred == .miles ? .miles : .kilometers
            text = "1"
            original = nil
        }
    }

    /// Meters for the step, or nil when the text isn't a distance.
    var meters: Double? {
        if let original, text == original.text, unit == original.unit { return original.meters }
        return unit.meters(text)
    }
}
