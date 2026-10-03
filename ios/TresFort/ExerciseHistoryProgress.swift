import Foundation

/// Options for one progress panel. Load/mode comparisons stay separate even
/// though the screen only presents the selected series.
struct ExerciseHistoryProgress: Identifiable {
    enum ID: Hashable {
        case estimatedOneRepMax
        case condition(ExerciseMetricCohort.Key)
    }

    struct Point: Identifiable {
        var id: String { date }
        let date: String
        let value: Double
    }

    let id: ID
    let title: String
    let unit: String
    let points: [Point]
    var hasTrend: Bool { points.count > 1 }

    static func options(_ history: [TrainingHistoryIndex.SessionStat]) -> [Self] {
        // A civil day has one best value, including when multiple sessions
        // were logged that day. One day is a summary, never a trend.
        func dailyBest(_ points: [Point]) -> [Point] {
            Dictionary(grouping: points, by: \.date).map { date, values in
                Point(date: date, value: values.map(\.value).max() ?? 0)
            }.sorted { $0.date < $1.date }
        }

        let grouped = Dictionary(grouping: history.flatMap { session in
            session.cohorts.map { (date: session.date, cohort: $0) }
        }, by: { $0.cohort.key })
        var options = grouped.values.compactMap { rows -> Self? in
            guard let cohort = rows.first?.cohort else { return nil }
            let metric = cohort.key.timed ? "Best hold" : "Best reps"
            let side = cohort.key.laterality == "unilateral" ? " per side" : ""
            return Self(id: .condition(cohort.key),
                title: "\(cohort.conditionLabel) · \(metric)\(side)",
                unit: cohort.key.timed ? "s" : "reps",
                points: dailyBest(rows.map {
                    Point(date: $0.date,
                        value: Double($0.cohort.bestHoldSeconds ?? $0.cohort.bestReps ?? 0))
                }))
        }.sorted { lhs, rhs in
            // Most recently used conditions come first; label breaks ties
            // deterministically without depending on dictionary iteration.
            let a = lhs.points.last?.date ?? "", b = rhs.points.last?.date ?? ""
            return a == b ? lhs.title.localizedStandardCompare(rhs.title) == .orderedAscending : a > b
        }

        // An estimate is a physical quantity, so a history that switched
        // units is still one trend: every estimate is shown in the unit of
        // the latest one. Estimates already in that unit keep their value.
        let estimated = history.filter { $0.est1RM != nil }
        if let unit = estimated.max(by: { ($0.date, $0.id) < ($1.date, $1.id) })?.loadUnit {
            let estimates = estimated.compactMap { session -> Point? in
                guard let value = session.est1RM else { return nil }
                if session.loadUnit == unit { return Point(date: session.date, value: value) }
                let converted: Double = session.loadUnit.convert(value, to: unit)
                return Point(date: session.date, value: (converted * 10).rounded() / 10)
            }
            options.insert(Self(id: .estimatedOneRepMax, title: "Estimated 1RM",
                unit: unit.rawValue, points: dailyBest(estimates)), at: 0)
        }
        return options
    }

    static func selected(_ id: ID?, from options: [Self]) -> Self? {
        options.first { $0.id == id } ?? options.first
    }
}
