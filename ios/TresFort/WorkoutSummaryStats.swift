import Foundation

/// Select a small set of meaningful metrics without recalculating the server's
/// volume, rep totals or records. Elapsed time uses the recorded session bounds;
/// timed work is the sum of logged working intervals, never a cohort best × sets.
struct WorkoutSummaryStat: Identifiable, Equatable {
    let id: String
    let value: String
    let label: String
}

enum WorkoutSummaryStats {
    static func make(summary: WorkoutSummary, session: SessionRow,
                     timedWorkSeconds: Int) -> [WorkoutSummaryStat] {
        var stats: [WorkoutSummaryStat] = []
        if session.status == "completed", let start = session.started_at,
           let end = session.completed_at, start > 0, end > start {
            stats.append(.init(id: "duration", value: duration((end - start) / 1_000), label: "Duration"))
        }

        // The older summary wire format has one volume total. Do not assign a
        // unit to an aggregate across different units or unsupported work.
        let units = Set(summary.cohorts.filter { $0.metric == "reps" && $0.weight > 0 }.map(\.unit))
        let hasVolume = summary.external_load_volume.map { $0.isFinite && $0 > 0 } == true
            && units.count == 1 && units.isSubset(of: ["lb", "kg"])
        if hasVolume, let volume = summary.external_load_volume, let unit = units.first {
            stats.append(.init(id: "volume", value: "\(number(volume)) \(unit)", label: "Weight lifted"))
        } else if summary.total_reps > 0 {
            stats.append(.init(id: "reps", value: number(Double(summary.total_reps)), label: "Reps"))
        } else if timedWorkSeconds > 0 {
            stats.append(.init(id: "timed", value: duration(timedWorkSeconds), label: "Timed work"))
        }

        stats.append(.init(id: "sets", value: number(Double(summary.working_sets)), label: "Working sets"))
        if hasVolume && summary.total_reps > 0 {
            stats.append(.init(id: "reps", value: number(Double(summary.total_reps)), label: "Reps"))
        } else if timedWorkSeconds > 0 && !stats.contains(where: { $0.id == "timed" }) {
            stats.append(.init(id: "timed", value: duration(timedWorkSeconds), label: "Timed work"))
        }
        return Array(stats.prefix(4))
    }

    static func timedWorkSeconds(sets: [SetLog], isTimed: (SetLog) -> Bool) -> Int {
        sets.filter { $0.deleted_at == nil && $0.is_warmup == 0 && isTimed($0) }
            .reduce(0) { $0 + max(0, $1.duration_s ?? $1.reps) }
    }

    static func duration(_ seconds: Int) -> String {
        if seconds < 60 { return "\(seconds)s" }
        if seconds < 3_600 {
            return seconds % 60 == 0 ? "\(seconds / 60) min" : "\(seconds / 60)m \(seconds % 60)s"
        }
        return "\(seconds / 3_600)h \((seconds % 3_600) / 60)m"
    }

    private static func number(_ value: Double) -> String {
        value.formatted(.number.precision(.fractionLength(0...1)))
    }
}
