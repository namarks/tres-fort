import SwiftUI

/// A planned run's lap as `GET /api/activities/:id/route` serves it with the
/// run recorded in the app (src/runLaps.ts, docs/plans/planned-runs P9).
struct ActivityLap: Decodable, Equatable {
    struct Target: Decodable, Equatable {
        let type: String
        var fastest_s_per_km: Int? = nil
        var slowest_s_per_km: Int? = nil
        var min_bpm: Int? = nil
        var max_bpm: Int? = nil
    }

    /// 1-based position of the step in the plan with repeats unrolled; nil
    /// for what was run after the plan finished.
    let step: Int?
    let kind: String?
    let round: Int?
    let rounds: Int?
    let planned_duration_s: Int?
    let planned_distance_m: Double?
    let target: Target?
    let start_s: Double
    let moving_s: Double
    let distance_m: Double
    let avg_hr: Int?
    let max_hr: Int?
    /// "completed", "skipped" or "stopped" (the run ended in it).
    let end: String

    var planKind: RunPlan.Kind? { kind.flatMap(RunPlan.Kind.init(rawValue:)) }

    var planTarget: RunPlan.Target? {
        guard let target else { return nil }
        switch target.type {
        case "pace":
            guard let fastest = target.fastest_s_per_km, let slowest = target.slowest_s_per_km else { return nil }
            return .pace(fastestSecondsPerKm: fastest, slowestSecondsPerKm: slowest)
        case "heart_rate":
            guard let low = target.min_bpm, let high = target.max_bpm else { return nil }
            return .heartRate(minBPM: low, maxBPM: high)
        default:
            return nil
        }
    }
}

/// How a lap reads on a run's detail: "RUN 2/4", "400 m · 1:33 · 6:14 /mi ·
/// 168 bpm", and how it went against the step's target.
struct RunLapRow: Equatable, Identifiable {
    enum Verdict: Equatable {
        case onTarget, fast, slow, high, low
    }

    let id: Int
    let kind: RunPlan.Kind?
    let title: String
    /// "Skipped" or "Ended early"; nil for a step run in full.
    let note: String?
    let figures: String
    /// "Pace 6:20–6:36 /mi · faster"; nil without a target.
    let target: String?
    let verdict: Verdict?

    static func rows(_ laps: [ActivityLap], unit: RunDistanceUnit) -> [RunLapRow] {
        laps.enumerated().map { index, lap in row(lap, id: index, unit: unit) }
    }

    static func row(_ lap: ActivityLap, id: Int, unit: RunDistanceUnit) -> RunLapRow {
        let kind = lap.planKind
        var title = kind.map(RunPlanFormat.kindTitle) ?? "After the plan"
        if let round = lap.round, let rounds = lap.rounds { title += " \(round)/\(rounds)" }
        let note: String?
        switch lap.end {
        case "skipped": note = "Skipped"
        case "stopped" where lap.step != nil: note = "Ended early"
        default: note = nil
        }
        let pace = RunPace.average(movingSeconds: lap.moving_s, meters: lap.distance_m, unit: unit)
        var figures = [distance(lap.distance_m, unit: unit), RunFormat.duration(lap.moving_s)]
        if let pace { figures.append(RunFormat.pace(pace) + " /\(unit.abbreviation)") }
        if let bpm = lap.avg_hr { figures.append("\(bpm) bpm") }

        var targetText: String?
        var verdict: Verdict?
        if let target = lap.planTarget {
            let judged = Self.verdict(lap, target: target)
            verdict = judged
            targetText = RunPlanFormat.targetTitle(target, unit: unit) + (judged.map { " · " + Self.words($0) } ?? "")
        }
        return RunLapRow(id: id, kind: kind, title: title, note: note, figures: figures.joined(separator: " · "),
                         target: targetText, verdict: verdict)
    }

    /// The lap's average pace or heart rate against the step's range. Nil
    /// when the lap has no pace (under 10 m) or no heart rate.
    static func verdict(_ lap: ActivityLap, target: RunPlan.Target) -> Verdict? {
        switch target {
        case .pace(let fastest, let slowest):
            guard let perKm = RunPace.average(movingSeconds: lap.moving_s, meters: lap.distance_m,
                                              unit: .kilometers) else { return nil }
            // Paces compare to the whole second the target is written in.
            let seconds = perKm.rounded()
            if seconds < Double(fastest) { return .fast }
            if seconds > Double(slowest) { return .slow }
            return .onTarget
        case .heartRate(let low, let high):
            guard let bpm = lap.avg_hr else { return nil }
            if bpm > high { return .high }
            if bpm < low { return .low }
            return .onTarget
        }
    }

    static func words(_ verdict: Verdict) -> String {
        switch verdict {
        case .onTarget: return "on target"
        case .fast: return "faster"
        case .slow: return "slower"
        case .high: return "above"
        case .low: return "below"
        }
    }

    /// Track distances in meters, longer laps in the member's unit.
    static func distance(_ meters: Double, unit: RunDistanceUnit) -> String {
        if meters < 1_000 { return "\(Int(meters.rounded())) m" }
        return RunFormat.distance(meters, in: unit) + " " + unit.abbreviation
    }
}

/// A planned run's laps on its detail, each step on its own line, so an
/// interval session reads like a watch's lap list instead of one average.
struct RunLapsView: View {
    let laps: [ActivityLap]
    let unit: RunDistanceUnit

    var body: some View {
        let rows = RunLapRow.rows(laps, unit: unit)
        VStack(alignment: .leading, spacing: 10) {
            Text("LAPS")
                .font(Theme.mono(11, .bold)).tracking(2)
                .foregroundStyle(Theme.muted)
            ForEach(rows) { row in
                HStack(alignment: .top, spacing: 10) {
                    RoundedRectangle(cornerRadius: 2)
                        .fill(color(row.kind))
                        .frame(width: 4)
                        .accessibilityHidden(true)
                    VStack(alignment: .leading, spacing: 2) {
                        HStack(spacing: 6) {
                            Text(row.title.uppercased())
                                .font(Theme.mono(11, .bold)).tracking(1)
                                .foregroundStyle(color(row.kind))
                            if let note = row.note {
                                Text(note)
                                    .font(.caption)
                                    .foregroundStyle(Theme.muted)
                            }
                        }
                        Text(row.figures)
                            .font(Theme.mono(13, .bold))
                            .foregroundStyle(Theme.text)
                            .monospacedDigit()
                        if let target = row.target {
                            Text(target)
                                .font(.caption)
                                .foregroundStyle(row.verdict == .onTarget ? Theme.done : Theme.muted)
                        }
                    }
                    .fixedSize(horizontal: false, vertical: true)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .accessibilityElement(children: .combine)
                .accessibilityIdentifier("activity.lap.\(row.id)")
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("activity.laps")
    }

    private func color(_ kind: RunPlan.Kind?) -> Color {
        switch kind {
        case .work: return Theme.accent
        case .recovery: return Theme.done
        case .warmup, .cooldown: return Theme.muted
        case nil: return Theme.dim
        }
    }
}
