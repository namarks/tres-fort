import Foundation

/// Disposable read model. No persistence, account authority, or write state:
/// SyncModel invalidates it whenever its published source arrays change.
struct TrainingHistoryIndex {
    struct SessionStat: Identifiable {
        let id: String
        let date: String
        let est1RM: Double?
        let topWeight: Double
        let topReps: Int
        /// Unit of `est1RM` and `topWeight`: the top set's own logged unit.
        let loadUnit: WeightUnit
        let bestReps: Int?
        let totalReps: Int
        /// External-load volume per logged unit; lb and kg are never summed.
        let volumeByUnit: [WeightUnit: Double]
        let setCount: Int
        let bestHoldSeconds: Int?
        let hasTimedSets: Bool
        let avgDuration: Int
        let cohorts: [ExerciseMetricCohort]

        /// The single-unit volume; nil when absent or when units are mixed.
        var volume: Double? { volumeByUnit.count == 1 ? volumeByUnit.values.first : nil }
    }

    let sessionsByDate: [String: SessionRow]
    private let datesBySession: [String: String]
    let setsBySession: [String: [SetLog]]
    let workingSetsByExercise: [String: [SetLog]]
    let catalogByID: [String: ExerciseCatalog]
    let loggedExerciseIDs: [String]

    init(sessions: [SessionRow], sets: [SetLog], catalog: [ExerciseCatalog]) {
        func rank(_ status: String) -> Int {
            switch status {
            case "completed": return 4
            case "in_progress": return 3
            case "planned": return 2
            case "skipped": return 1
            default: return 0
            }
        }
        var byDate: [String: SessionRow] = [:]
        var dates: [String: String] = [:]
        for session in sessions {
            dates[session.id] = session.date
            if let current = byDate[session.date], rank(current.status) >= rank(session.status) { continue }
            byDate[session.date] = session
        }
        sessionsByDate = byDate
        datesBySession = dates
        let live = sets.filter { $0.deleted_at == nil }
        setsBySession = Dictionary(grouping: live, by: \.session_id)
        let working = live.filter { $0.is_warmup == 0 }
        workingSetsByExercise = Dictionary(grouping: working, by: \.exercise_id)
        var recent: [String: Int] = [:]
        for set in working { recent[set.exercise_id] = max(recent[set.exercise_id] ?? Int.min, set.logged_at) }
        loggedExerciseIDs = recent.keys.sorted {
            recent[$0] == recent[$1] ? $0 < $1 : recent[$0]! > recent[$1]!
        }
        catalogByID = Dictionary(catalog.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
    }

    func history(for exerciseID: String, latestOnly: Bool = false) -> [SessionStat] {
        let grouped = Dictionary(grouping: workingSetsByExercise[exerciseID] ?? [], by: \.session_id)
        let sessionIDs = grouped.keys.filter { datesBySession[$0] != nil }
            .sorted { datesBySession[$0]! < datesBySession[$1]! }
        let selected = latestOnly ? Array(sessionIDs.suffix(1)) : sessionIDs
        let exercise = catalogByID[exerciseID]
        let sides = exercise?.laterality == "unilateral" ? 2 : 1
        let implements = exercise?.load_mode == "per_hand" ? 2 : 1
        func timed(_ set: SetLog) -> Bool {
            set.is_timed.map { $0 == 1 } ?? (exercise?.modality == "timed")
        }
        // Estimates compare physically across units; the best keeps its own
        // number and unit (`loadUnit`).
        func estimateInPounds(_ cohort: ExerciseMetricCohort) -> Double {
            cohort.estimatedOneRepMax.map { cohort.weightUnit.convert($0, to: .lb) } ?? 0
        }
        return selected.compactMap { sid in
            guard let rows = grouped[sid], let date = datesBySession[sid], !rows.isEmpty else { return nil }
            let timedRows = rows.filter(timed)
            let repRows = rows.filter { !timed($0) }
            let cohorts = ExerciseMetrics.cohorts(rows, catalog: exercise.map { [$0] } ?? [])
            let repCohorts = cohorts.filter { !$0.key.timed }
            let holdCohorts = cohorts.filter { $0.key.timed }
            let best = cohorts.max { estimateInPounds($0) < estimateInPounds($1) }
            let top = best?.top ?? rows[0]
            let durations = timedRows.map { $0.duration_s ?? $0.reps }
            var volumeByUnit: [WeightUnit: Double] = [:]
            for row in repRows where row.weight > 0 {
                volumeByUnit[row.weightUnit, default: 0] +=
                    row.weight * Double(row.reps * sides) * Double(implements)
            }
            return SessionStat(id: sid, date: date,
                est1RM: best?.estimatedOneRepMax,
                topWeight: top.weight, topReps: top.reps, loadUnit: top.weightUnit,
                bestReps: exercise?.modality == "bw" && repCohorts.count == 1 ? repCohorts[0].bestReps : nil,
                totalReps: repRows.reduce(0) { $0 + $1.reps * sides },
                volumeByUnit: volumeByUnit, setCount: rows.count,
                bestHoldSeconds: holdCohorts.count == 1 ? holdCohorts[0].bestHoldSeconds : nil,
                hasTimedSets: !timedRows.isEmpty,
                avgDuration: holdCohorts.count == 1 && !durations.isEmpty ? durations.reduce(0, +) / durations.count : 0,
                cohorts: cohorts)
        }
    }
}
