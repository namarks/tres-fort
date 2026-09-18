import SwiftUI

/// Captures the exercise being inspected without changing a picker or runner.
struct ExerciseInformation: Identifiable {
    let exercise: ExerciseCatalog
    let prescription: TemplateExercise?
    var id: String { exercise.id }

    init(exercise: ExerciseCatalog) {
        self.exercise = exercise
        prescription = nil
    }

    init(prescription: TemplateExercise, catalog: ExerciseCatalog?) {
        self.prescription = prescription
        exercise = ExerciseCatalog(id: prescription.exercise_id, name: prescription.exercise_name,
            primary_muscle: catalog?.primary_muscle ?? prescription.exercise_modality,
            modality: prescription.exercise_modality, unit: prescription.exercise_unit,
            laterality: prescription.exercise_laterality ?? catalog?.laterality,
            load_mode: prescription.exercise_load_mode ?? catalog?.load_mode,
            demo_slug: prescription.exercise_demo_slug ?? catalog?.demo_slug)
    }
}

enum ExerciseInformationHistory {
    struct Summary {
        let date: String
        let cohorts: [ExerciseMetricCohort]
    }

    /// Reuse the history cohorts; never combine loads or rep/hold modes into
    /// an invented performance. Current and discarded workouts are excluded.
    static func latest(_ history: [TrainingHistoryIndex.SessionStat], sessions: [SessionRow],
                       prescription: TemplateExercise?) -> Summary? {
        let completed = Set(sessions.filter { $0.status == "completed" }.map(\.id))
        for session in history.sorted(by: { ($0.date, $0.id) > ($1.date, $1.id) })
            where completed.contains(session.id) {
            let cohorts = session.cohorts.filter { cohort in
                guard let prescription else { return true }
                return cohort.key.timed == prescription.isTimed
                    && (prescription.target_weight == nil || cohort.key.weight == prescription.target_weight)
            }
            if !cohorts.isEmpty { return Summary(date: session.date, cohorts: cohorts) }
        }
        return nil
    }

    enum Availability { case loading, unavailable, empty, history }

    static func availability(hasHistory: Bool, loading: Bool, verified: Bool,
                             cached: Bool, failed: Bool) -> Availability {
        if hasHistory { return .history }
        if loading { return .loading }
        if !verified || cached || failed { return .unavailable }
        return .empty
    }
}

struct ExerciseInformationSheet: View {
    @ObservedObject var sync: SyncModel
    let information: ExerciseInformation
    @Environment(\.dismiss) private var dismiss
    @State private var tab = Tab.technique

    private enum Tab: String, CaseIterable { case technique = "Technique", history = "History" }
    private var exercise: ExerciseCatalog { information.exercise }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                Picker("Exercise information", selection: $tab) {
                    ForEach(Tab.allCases, id: \.self) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.segmented)
                .fixedSize(horizontal: false, vertical: true)
                .padding()
                .accessibilityIdentifier("exerciseInfo.tabs")
                if tab == .technique {
                    ExerciseDemoSheet(exerciseID: exercise.id, name: exercise.name,
                        primaryMuscle: exercise.primary_muscle, secondaryMuscles: [],
                        modality: exercise.modality, laterality: exercise.laterality ?? "bilateral",
                        loadMode: exercise.load_mode ?? "total", demoSlug: exercise.demo_slug,
                        jwt: sync.exerciseDemoJWT, timed: information.prescription?.isTimed,
                        cues: information.prescription?.cues)
                } else {
                    history
                }
            }
            .background(Theme.background)
            .navigationTitle(exercise.name)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }.accessibilityIdentifier("exerciseInfo.done")
                }
            }
            .toolbarColorScheme(.dark, for: .navigationBar)
        }
        .tint(Theme.accent)
        .preferredColorScheme(.dark)
    }

    private var history: some View {
        let records = sync.history(for: exercise.id)
        let latest = ExerciseInformationHistory.latest(records, sessions: sync.sessions,
                                                         prescription: information.prescription)
        let availability = ExerciseInformationHistory.availability(hasHistory: !records.isEmpty,
            loading: sync.isLoading, verified: sync.hasVerifiedPlanState,
            cached: sync.isUsingCachedState, failed: sync.loadError != nil)
        return ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                switch availability {
                case .loading:
                    ProgressView("Loading history…")
                        .accessibilityIdentifier("exerciseInfo.history.loading")
                case .unavailable:
                    Text("History unavailable").font(.headline)
                        .accessibilityIdentifier("exerciseInfo.history.unavailable")
                    Text("Connect and refresh to check this exercise’s history.")
                        .foregroundStyle(Theme.muted)
                    refreshButton
                case .empty:
                    Text("No history yet").font(.headline)
                        .accessibilityIdentifier("exerciseInfo.history.empty")
                    Text("Your recorded working sets will appear here.")
                        .foregroundStyle(Theme.muted)
                case .history:
                    if sync.isUsingCachedState || sync.loadError != nil || !sync.hasVerifiedPlanState {
                        Text("Showing saved history. Refresh to check for changes.")
                            .font(.subheadline).foregroundStyle(Theme.muted)
                        refreshButton
                    }
                    if sync.isLoading { ProgressView("Refreshing history…") }
                    if let latest {
                        VStack(alignment: .leading, spacing: 12) {
                            Text(information.prescription == nil ? "Last session" : "Last comparable session")
                                .font(.headline)
                            Text(latest.date).font(.subheadline).foregroundStyle(Theme.muted)
                                .accessibilityIdentifier("exerciseInfo.history.date")
                            ForEach(latest.cohorts) { cohort in
                                VStack(alignment: .leading, spacing: 4) {
                                    Text(cohort.valueLabel).font(.body.weight(.semibold))
                                    Text("Best of \(cohort.setCount) working \(cohort.setCount == 1 ? "set" : "sets")")
                                        .font(.caption).foregroundStyle(Theme.muted)
                                }
                            }
                            if let prescription = information.prescription {
                                Text(prescription.target_weight == nil
                                    ? "Same exercise and rep or hold mode."
                                    : "Same exercise, rep or hold mode, and prescribed load.")
                                    .font(.caption).foregroundStyle(Theme.muted)
                            }
                        }
                        .padding(16).frame(maxWidth: .infinity, alignment: .leading)
                        .background(Theme.surface).clipShape(RoundedRectangle(cornerRadius: 14))
                    } else {
                        Text("No comparable completed session yet").font(.headline)
                        Text("Full history includes your other loads, rep or hold modes, and current workout.")
                            .foregroundStyle(Theme.muted)
                    }
                    NavigationLink {
                        ExerciseDetailView(sync: sync, exerciseID: exercise.id)
                    } label: {
                        Label("Full history", systemImage: "chart.xyaxis.line")
                            .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
                    }
                    .accessibilityIdentifier("exerciseInfo.history.full")
                }
            }
            .foregroundStyle(Theme.text)
            .frame(maxWidth: .infinity, alignment: .leading).padding(20)
        }
    }

    private var refreshButton: some View {
        Button("Refresh history") { Task { await sync.load() } }
            .disabled(sync.isLoading).frame(minHeight: 44)
    }
}
