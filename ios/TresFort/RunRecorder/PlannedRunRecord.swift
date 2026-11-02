import SwiftUI
import CoreLocation

/// A finished run workout read against the run it planned
/// (docs/plans/planned-runs P7): what was run, and how it compares with the
/// plan's distance or time and its one pace or heart rate target. The run
/// itself comes from the day's activities (the recorder, Apple Health or
/// intervals.icu), not from logged sets.
struct PlannedRunRecord: Equatable {
    struct Row: Equatable, Identifiable {
        let id: String
        let label: String
        let value: String
        /// The plan's side: "Planned 3.5 mi", "In your 147–153 bpm target".
        var detail: String? = nil
        /// True when the run met the plan's target, false when it missed it,
        /// nil when there is no target to compare.
        var onTarget: Bool? = nil
    }

    let rows: [Row]

    /// The run that carried out a run workout on its date: the one named
    /// after the workout (the recorder uploads it under that name), else the
    /// longest run that day.
    static func matchingRun(workoutName: String?, among activities: [ExternalActivity]) -> ExternalActivity? {
        let runs = activities.filter { $0.kind == "run" && !$0.isDeleted }
        let wanted = workoutName?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() ?? ""
        if !wanted.isEmpty, let named = runs.first(where: {
            $0.name?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() == wanted
        }) {
            return named
        }
        return runs.max { ($0.moving_time_sec ?? 0) < ($1.moving_time_sec ?? 0) }
    }

    /// The planned distance in meters, when every step is a distance.
    static func plannedMeters(_ plan: RunPlan) -> Double? {
        let steps = plan.expandedSteps.map(\.step)
        guard !steps.isEmpty, steps.allSatisfy({ $0.distanceMeters != nil }) else { return nil }
        return steps.reduce(0) { $0 + ($1.distanceMeters ?? 0) }
    }

    /// The planned time in seconds, when every step is a time.
    static func plannedSeconds(_ plan: RunPlan) -> Int? {
        let steps = plan.expandedSteps.map(\.step)
        guard !steps.isEmpty, steps.allSatisfy({ $0.durationSeconds != nil }) else { return nil }
        return steps.reduce(0) { $0 + ($1.durationSeconds ?? 0) }
    }

    /// The plan's target when every step that has one shares it, so the whole
    /// run's average can stand against it. Intervals with different targets
    /// have none.
    static func sharedTarget(_ plan: RunPlan) -> RunPlan.Target? {
        let targets = plan.expandedSteps.compactMap(\.step.target)
        guard let first = targets.first, targets.allSatisfy({ $0 == first }) else { return nil }
        return first
    }

    /// "3.29 mi · 25:37 · 150 bpm average", leaving out what the run lacks.
    static func headline(_ run: ExternalActivity, unit: RunDistanceUnit) -> String {
        var parts: [String] = []
        if let meters = run.distance_m, meters > 0 { parts.append(distance(meters, unit: unit)) }
        if let seconds = run.moving_time_sec, seconds > 0 { parts.append(RunFormat.duration(Double(seconds))) }
        if let hr = run.average_hr, hr > 0 { parts.append("\(Int(hr.rounded())) bpm average") }
        return parts.joined(separator: " · ")
    }

    static func distance(_ meters: Double, unit: RunDistanceUnit) -> String {
        RunFormat.distance(meters, in: unit) + " " + unit.abbreviation
    }

    init(run: ExternalActivity, plan: RunPlan?, plannedSeconds slotSeconds: Int? = nil, unit: RunDistanceUnit) {
        var rows: [Row] = []
        let meters = run.distance_m.flatMap { $0 > 0 ? $0 : nil }
        let seconds = run.moving_time_sec.flatMap { $0 > 0 ? $0 : nil }
        let target = plan.flatMap(Self.sharedTarget)

        if let meters {
            rows.append(Row(
                id: "distance", label: "Distance", value: Self.distance(meters, unit: unit),
                detail: plan.flatMap(Self.plannedMeters).map { "Planned " + RunPlanFormat.distance($0, unit: unit) }))
        }
        if let seconds {
            let planned = plan.map(Self.plannedSeconds) ?? slotSeconds
            rows.append(Row(
                id: "time", label: "Moving time", value: RunFormat.duration(Double(seconds)),
                detail: planned.map { "Planned " + RunPlanFormat.duration($0) }))
        }
        if let meters, let seconds {
            let perKm = Double(seconds) / (meters / 1_000)
            var row = Row(id: "pace", label: "Average pace",
                          value: RunFormat.pace(perKm * unit.meters / 1_000) + " /\(unit.abbreviation)")
            if let target, case let .pace(fastest, slowest) = target {
                let actual = Int(perKm.rounded())
                let range = RunPlanFormat.target(target, unit: unit)
                if actual < fastest {
                    row.detail = "Faster than your \(range) target"
                    row.onTarget = false
                } else if actual > slowest {
                    row.detail = "Slower than your \(range) target"
                    row.onTarget = false
                } else {
                    row.detail = "In your \(range) target"
                    row.onTarget = true
                }
            }
            rows.append(row)
        }
        let average = run.average_hr.flatMap { $0 > 0 ? Int($0.rounded()) : nil }
        let highest = run.max_hr.flatMap { $0 > 0 ? $0 : nil }
        if average != nil || highest != nil {
            let value = [average.map { "\($0) avg" }, highest.map { "\($0) max" }]
                .compactMap { $0 }.joined(separator: " · ")
            var row = Row(id: "heartRate", label: "Heart rate", value: value)
            if let average, let target, case let .heartRate(low, high) = target {
                let range = RunPlanFormat.target(target, unit: unit)
                if average < low {
                    row.detail = "Below your \(range) target"
                    row.onTarget = false
                } else if average > high {
                    row.detail = "Above your \(range) target"
                    row.onTarget = false
                } else {
                    row.detail = "In your \(range) target"
                    row.onTarget = true
                }
            }
            rows.append(row)
        }
        if let load = run.shownLoad {
            rows.append(Row(id: "load", label: run.loadMethodLabel.map { "Load · \($0)" } ?? "Load",
                            value: "\(load)"))
        }
        self.rows = rows
    }
}

/// The run in a finished workout's record: the run's numbers against the
/// plan, then the planned steps.
struct PlannedRunRecordView: View {
    let slot: TemplateExercise
    let run: ExternalActivity?
    /// Reads the run's route, when it was recorded in the app.
    var routeAccess: ActivityRouteAccess? = nil
    @AppStorage(RunDistanceUnit.preferenceKey) private var unitRaw = RunDistanceUnit.miles.rawValue
    private var unit: RunDistanceUnit { RunDistanceUnit(rawValue: unitRaw) ?? .miles }

    var body: some View {
        WithActivityRoute(activity: run, access: routeAccess) { segments in
            record(routeSegments: segments)
        }
    }

    private func record(routeSegments: [[CLLocationCoordinate2D]]) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 8) {
                Image(systemName: "figure.run")
                    .font(.system(size: 14, weight: .bold))
                    .foregroundStyle(Theme.accent)
                Text((run?.displayTitle ?? "Run").uppercased())
                    .font(Theme.display(20))
                    .foregroundStyle(Theme.text)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if let run {
                SourceAttributionLabel(text: run.source_attribution)
                let record = PlannedRunRecord(run: run, plan: slot.runPlan,
                                              plannedSeconds: slot.target_duration_s, unit: unit)
                LazyVGrid(columns: [GridItem(.flexible(), alignment: .topLeading),
                                    GridItem(.flexible(), alignment: .topLeading)],
                          alignment: .leading, spacing: 14) {
                    ForEach(record.rows) { row in
                        VStack(alignment: .leading, spacing: 2) {
                            Text(row.label.uppercased())
                                .font(Theme.mono(9, .bold)).tracking(1)
                                .foregroundStyle(Theme.dim)
                            Text(row.value)
                                .font(Theme.mono(15, .bold))
                                .foregroundStyle(Theme.text)
                            if let detail = row.detail {
                                Text(detail)
                                    .font(.caption)
                                    .foregroundStyle(row.onTarget == true ? Theme.done : Theme.muted)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .accessibilityElement(children: .combine)
                        .accessibilityIdentifier("workoutRecord.run.\(row.id)")
                    }
                }
                if !routeSegments.isEmpty {
                    ActivityRouteThumbnail(segments: routeSegments)
                }
            } else {
                Text("The run shows here once it syncs from the recorder, Apple Health or intervals.icu.")
                    .font(.subheadline).foregroundStyle(Theme.muted)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if let plan = slot.runPlan {
                VStack(alignment: .leading, spacing: 8) {
                    Text("PLANNED")
                        .font(Theme.mono(11, .bold)).tracking(2)
                        .foregroundStyle(Theme.muted)
                    RunPlanStepsView(plan: plan, unit: unit, size: 12)
                }
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.surface)
        .clipShape(RoundedRectangle(cornerRadius: 14))
        .accessibilityIdentifier("workoutRecord.run")
    }
}
