import SwiftUI

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
            "target_weight": "Target load", "target_duration_s": "Target duration",
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

struct PlanHistoryView: View {
    @ObservedObject var sync: SyncModel
    var onCorrect: (() -> Void)? = nil
    @Environment(\.dismiss) private var dismiss
    @State private var history: PlanHistoryResponse?
    @State private var comparison: PlanComparisonResponse?
    @State private var selected: PlanHistoryItem?
    @State private var restoring = false
    @State private var loadingHistory = true
    @State private var loadingComparison = false
    @State private var loadingMore = false
    @State private var errorMessage: String?
    @State private var showEditor = false
    @State private var historyRequest = UUID()

    var body: some View {
        NavigationStack {
            ScrollViewReader { proxy in
                List {
                    Section {
                        Text("All plan changes, including dismissed changes, stay here. Compare a saved version with your current plan before restoring it.")
                            .font(.caption).foregroundStyle(Theme.muted)
                        Button("Correct current workouts") {
                            Task {
                                await sync.load()
                                if let error = sync.loadError { errorMessage = error }
                                else if let onCorrect { onCorrect() }
                                else { showEditor = true }
                            }
                        }
                        .disabled(sync.isLoading || sync.isRoutineMutationInFlight)
                        .accessibilityIdentifier("planHistory.correct")
                    }
                    comparisonContent.id("comparison")
                    capturedVersionsContent
                    errorContent
                }
                .onChange(of: comparison) { _, value in
                    if value != nil { withAnimation { proxy.scrollTo("comparison", anchor: .top) } }
                }
            }
            .navigationTitle("Plan changes")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .topBarLeading) { Button("Done") { dismiss() } } }
            .task { await loadInitialHistory() }
            .sheet(isPresented: $showEditor, onDismiss: { Task { await loadInitialHistory() } }) {
                WorkoutsView(sync: sync)
            }
            .confirmationDialog(
                "Restore version \(selected?.version ?? 0)?",
                isPresented: $restoring,
                titleVisibility: .visible
            ) {
                Button("Restore as a new version", role: .destructive) {
                    guard let selected, let reviewedComparison = comparison, let history,
                          reviewedComparison.from_version == selected.version,
                          reviewedComparison.plan_id == history.plan_id,
                          reviewedComparison.to_version == history.current_version else { return }
                    Task {
                        if await sync.restorePlanVersion(
                            selected.version,
                            expectedPlanID: history.plan_id,
                            reviewedCurrentVersion: reviewedComparison.to_version,
                            reason: "Restored from Workout history") {
                            await loadInitialHistory()
                            comparison = nil
                            self.selected = nil
                        } else {
                            let conflictNotice = sync.loadError
                                ?? "The routine changed. Review the latest comparison before restoring."
                            comparison = nil
                            self.selected = nil
                            restoring = false
                            await loadInitialHistory(preservingError: conflictNotice)
                        }
                    }
                }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("The selected version is shown on the left of the comparison arrow. Your current routine stays in history, and the restored routine becomes a new version.")
            }
        }
        .preferredColorScheme(.dark)
    }

    @ViewBuilder private var comparisonContent: some View {
        if let comparison, let selected,
           comparison.from_version == selected.version,
           comparison.plan_id == history?.plan_id {
            Section("Version \(selected.version) → current version \(comparison.to_version)") {
                if comparison.changes.isEmpty {
                    Text("This version matches the current routine.")
                } else {
                    ForEach(PlanHistoryPresentation.indexedChanges(comparison.changes), id: \.offset) { entry in
                        let change = entry.change
                        VStack(alignment: .leading, spacing: 3) {
                            Text(PlanHistoryPresentation.fieldName(for: change)).font(Theme.mono(12, .bold))
                            Text("\(PlanHistoryPresentation.value(change.before)) → \(PlanHistoryPresentation.value(change.after))")
                                .font(Theme.mono(11)).foregroundStyle(Theme.muted)
                        }
                    }
                    Button("Restore version \(selected.version)", role: .destructive) { restoring = true }
                        .disabled(sync.running || sync.isRoutineMutationInFlight)
                    if sync.running {
                        Text("Finish or discard the active workout before restoring a routine.")
                            .font(Theme.mono(10)).foregroundStyle(Theme.muted)
                    }
                }
            }
        } else if loadingComparison {
            Section { ProgressView("Comparing routines…") }
        }
    }

    @ViewBuilder private var capturedVersionsContent: some View {
        Section("Captured versions") {
            if loadingHistory {
                ProgressView("Loading routine history…")
            } else if history?.items.isEmpty != false {
                Text("No captured routine changes yet.").foregroundStyle(Theme.muted)
            }
            ForEach(history?.items ?? []) { item in
                VStack(alignment: .leading, spacing: 10) {
                    PlanChangeRow(item: item)
                    if let previous = item.previous_version {
                        Button("Review before this change") { selectVersion(previous) }
                            .accessibilityIdentifier("planHistory.before.\(item.version)")
                    }
                    Button("Compare version \(item.version) with current") { select(item) }
                        .accessibilityIdentifier("planHistory.compare.\(item.version)")
                }
                .buttonStyle(.borderless)
            }
            if history?.next_before_version != nil {
                Button(loadingMore ? "Loading…" : "Load earlier changes") { Task { await loadMore() } }
                    .disabled(loadingMore)
            }
        }
    }

    @ViewBuilder private var errorContent: some View {
        if let errorMessage {
            Section {
                Text(errorMessage).foregroundStyle(Theme.danger)
                Button("Try again") { Task { await loadInitialHistory() } }
            }
        }
    }

    private func selectVersion(_ version: Int) {
        select(PlanHistoryItem(version: version, actor: "", operation: "", reason: nil,
                               created_at: 0, summary: nil))
    }

    private func select(_ item: PlanHistoryItem) {
        guard let history else { return }
        selected = item
        comparison = nil
        loadingComparison = true
        errorMessage = nil
        let planID = history.plan_id
        let currentVersion = history.current_version
        Task {
            let loaded = await sync.comparePlanVersion(item.version, toVersion: currentVersion)
            guard selected?.version == item.version,
                  self.history?.plan_id == planID,
                  self.history?.current_version == currentVersion else { return }
            comparison = loaded?.plan_id == planID && loaded?.from_version == item.version
                && loaded?.to_version == currentVersion ? loaded : nil
            loadingComparison = false
            if comparison == nil { errorMessage = sync.loadError ?? "Could not compare this routine version." }
        }
    }

    private func loadInitialHistory(preservingError: String? = nil) async {
        comparison = nil
        selected = nil
        loadingComparison = false
        let request = UUID()
        historyRequest = request
        history = nil
        loadingMore = false
        loadingHistory = true
        errorMessage = preservingError
        let loaded = await sync.loadPlanHistory()
        guard historyRequest == request else { return }
        history = loaded
        loadingHistory = false
        if history == nil {
            errorMessage = sync.loadError ?? preservingError ?? "Could not load routine history."
        }
    }

    private func loadMore() async {
        guard let current = history, let before = current.next_before_version else { return }
        loadingMore = true
        let request = historyRequest
        defer { if historyRequest == request { loadingMore = false } }
        let loaded = await sync.loadPlanHistory(beforeVersion: before)
        guard historyRequest == request, history == current else { return }
        guard let page = loaded, page.plan_id == current.plan_id else {
            errorMessage = sync.loadError ?? "Could not load earlier changes."
            return
        }
        history = PlanHistoryResponse(
            plan_id: current.plan_id, current_version: current.current_version,
            items: current.items + page.items, next_before_version: page.next_before_version)
    }
}
