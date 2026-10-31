import Foundation

/// A planned run's steps, as the coach wrote them into the plan
/// (`template_exercises.run_steps`; the server's src/runSteps.ts validates
/// the format). Paces are seconds per kilometer and distances are meters.
struct RunPlan: Equatable {
    /// The catalog's outdoor run, the only slot that carries steps.
    static let exerciseID = "ex_outdoor_run"

    enum Kind: String, Equatable {
        case warmup, work, recovery, cooldown
    }

    enum Target: Equatable {
        case pace(fastestSecondsPerKm: Int, slowestSecondsPerKm: Int)
        case heartRate(minBPM: Int, maxBPM: Int)
    }

    struct Step: Equatable {
        var kind: Kind
        var durationSeconds: Int?
        var distanceMeters: Double?
        var target: Target?
    }

    enum Item: Equatable {
        case step(Step)
        case repeated(times: Int, steps: [Step])
    }

    var items: [Item]

    init(items: [Item]) { self.items = items }

    /// Nil when the text isn't a step list this app can read, such as a
    /// format a newer server added. The slot then shows as a plain run.
    init?(json: String) {
        guard let data = json.data(using: .utf8),
              let array = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]],
              !array.isEmpty else { return nil }
        var items: [Item] = []
        for object in array {
            if let times = object["repeat"] as? Int {
                guard let raw = object["steps"] as? [[String: Any]], !raw.isEmpty else { return nil }
                let steps = raw.compactMap(Self.step)
                guard steps.count == raw.count else { return nil }
                items.append(.repeated(times: times, steps: steps))
            } else {
                guard let step = Self.step(object) else { return nil }
                items.append(.step(step))
            }
        }
        self.items = items
    }

    private static func step(_ object: [String: Any]) -> Step? {
        guard let kind = (object["kind"] as? String).flatMap(Kind.init(rawValue:)) else { return nil }
        let duration = object["duration_s"] as? Int
        let distance = (object["distance_m"] as? NSNumber)?.doubleValue
        guard (duration == nil) != (distance == nil) else { return nil }
        var target: Target?
        if let raw = object["target"] as? [String: Any] {
            switch raw["type"] as? String {
            case "pace":
                guard let fastest = raw["fastest_s_per_km"] as? Int,
                      let slowest = raw["slowest_s_per_km"] as? Int else { return nil }
                target = .pace(fastestSecondsPerKm: fastest, slowestSecondsPerKm: slowest)
            case "heart_rate":
                guard let low = raw["min_bpm"] as? Int, let high = raw["max_bpm"] as? Int else { return nil }
                target = .heartRate(minBPM: low, maxBPM: high)
            default:
                return nil
            }
        }
        return Step(kind: kind, durationSeconds: duration, distanceMeters: distance, target: target)
    }
}

/// How planned runs read in the app: paces and longer distances in the
/// recorder's miles or kilometers, track distances in meters.
enum RunPlanFormat {
    /// One line per step; a repeat group is a header line followed by its
    /// indented steps.
    struct Line: Equatable, Identifiable {
        var id: Int
        var text: String
        var indented: Bool
    }

    static func lines(_ plan: RunPlan, unit: RunDistanceUnit) -> [Line] {
        var lines: [Line] = []
        for item in plan.items {
            switch item {
            case .step(let step):
                lines.append(Line(id: lines.count, text: text(step, unit: unit), indented: false))
            case .repeated(let times, let steps):
                lines.append(Line(id: lines.count, text: "\(times) ×", indented: false))
                for step in steps {
                    lines.append(Line(id: lines.count, text: text(step, unit: unit), indented: true))
                }
            }
        }
        return lines
    }

    /// The whole plan on one line, for places with room for a single label.
    static func summary(_ plan: RunPlan, unit: RunDistanceUnit) -> String {
        plan.items.map { item in
            switch item {
            case .step(let step):
                return text(step, unit: unit)
            case .repeated(let times, let steps):
                let inner = steps.map { text($0, unit: unit) }.joined(separator: ", ")
                return steps.count == 1 ? "\(times) × \(inner)" : "\(times) × (\(inner))"
            }
        }
        .joined(separator: " · ")
    }

    /// "10 min warm-up", "800 m at 4:05–4:15 /km", "40 min at 130–145 bpm".
    static func text(_ step: RunPlan.Step, unit: RunDistanceUnit) -> String {
        let amount = step.distanceMeters.map { distance($0, unit: unit) }
            ?? duration(step.durationSeconds ?? 0)
        let kind: String
        switch step.kind {
        case .warmup: kind = " warm-up"
        case .work: kind = ""
        case .recovery: kind = " recovery"
        case .cooldown: kind = " cool-down"
        }
        return amount + kind + (step.target.map { " at " + target($0, unit: unit) } ?? "")
    }

    static func target(_ target: RunPlan.Target, unit: RunDistanceUnit) -> String {
        switch target {
        case .pace(let fastest, let slowest):
            let scale = unit.meters / 1_000
            let low = RunFormat.pace(Double(fastest) * scale)
            let high = RunFormat.pace(Double(slowest) * scale)
            return (low == high ? low : "\(low)–\(high)") + " /\(unit.abbreviation)"
        case .heartRate(let low, let high):
            return (low == high ? "\(low)" : "\(low)–\(high)") + " bpm"
        }
    }

    /// Under a kilometer reads in meters, as track intervals are planned.
    static func distance(_ meters: Double, unit: RunDistanceUnit) -> String {
        if meters < 1_000 { return "\(Int(meters.rounded())) m" }
        return "\(number(meters / unit.meters)) \(unit.abbreviation)"
    }

    /// "45 s", "10 min", "2 min 30 s", "1 h 15 min".
    static func duration(_ seconds: Int) -> String {
        let h = seconds / 3600, m = (seconds % 3600) / 60, s = seconds % 60
        var parts: [String] = []
        if h > 0 { parts.append("\(h) h") }
        if m > 0 { parts.append("\(m) min") }
        if s > 0 || parts.isEmpty { parts.append("\(s) s") }
        return parts.joined(separator: " ")
    }

    /// Up to two decimals without trailing zeros: "5", "5.5", "3.11".
    private static func number(_ value: Double) -> String {
        let rounded = (value * 100).rounded() / 100
        var text = String(format: "%.2f", rounded)
        while text.hasSuffix("0") { text.removeLast() }
        if text.hasSuffix(".") { text.removeLast() }
        return text
    }
}

extension RunDistanceUnit {
    /// The recorder's miles-or-kilometers choice, shared with plan views.
    static let preferenceKey = "runRecorder.distanceUnit"

    static func preferred(_ defaults: UserDefaults = .standard) -> RunDistanceUnit {
        defaults.string(forKey: preferenceKey).flatMap(RunDistanceUnit.init(rawValue:)) ?? .miles
    }
}

/// A plan slot the member starts in the run recorder.
struct PlannedRun: Equatable, Identifiable {
    /// The slot's id.
    let id: String
    /// The workout it belongs to, such as "Track Tuesday".
    let workoutName: String
    /// Nil for a run the coach planned without steps.
    let plan: RunPlan?
    let durationSeconds: Int?
}

extension TemplateExercise {
    /// An outdoor run slot, with or without planned steps.
    var isOutdoorRun: Bool { exercise_id == RunPlan.exerciseID }

    var runPlan: RunPlan? { run_steps.flatMap(RunPlan.init(json:)) }

    /// "Planned run · 10 min warm-up · 4 × (800 m at …)", or "Run · 30 min"
    /// without steps.
    func runPrescriptionLabel(in unit: RunDistanceUnit) -> String {
        if let plan = runPlan { return RunPlanFormat.summary(plan, unit: unit) }
        if let seconds = target_duration_s { return "Run · " + RunPlanFormat.duration(seconds) }
        return "Run at your own pace"
    }

    func plannedRun(in workoutName: String) -> PlannedRun {
        PlannedRun(id: id, workoutName: workoutName, plan: runPlan, durationSeconds: target_duration_s)
    }
}
