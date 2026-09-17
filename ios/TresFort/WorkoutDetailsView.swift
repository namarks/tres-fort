import SwiftUI

/// A saved workout is always opened by its explicit identity. A stale selection
/// must never fall through to the runner's last workout or the first library row.
struct WorkoutDetailsView: View {
    @ObservedObject var sync: SyncModel
    let workoutID: String
    var date: String? = nil
    var onStart: ((String) -> Void)? = nil
    @Environment(\.dismiss) private var dismiss
    @State private var editing = false
    @State private var saving = false
    @State private var refreshing = false

    private var workout: Workout? { sync.workout(id: workoutID) }
    private var canResume: Bool { sync.hasResumableWorkout && sync.resumableCheckpoint?.selectedDayID == workoutID }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    if let workout {
                        Text(date.map { "For \($0)" } ?? "Saved workout")
                            .font(Theme.mono(12)).foregroundStyle(Theme.muted)
                        WorkoutExercisePreview(sync: sync, exercises: workout.exercises)
                        if workout.exercises.isEmpty {
                            Text("No exercises yet. Edit this workout to add exercises and targets.")
                                .foregroundStyle(Theme.muted)
                        }
                        Button("Edit \(workout.name)") { editing = true }
                            .frame(maxWidth: .infinity, minHeight: 44)
                            .accessibilityIdentifier("workoutDetails.edit")
                        Text("Changes apply whenever you use this saved workout. Completed records stay unchanged.")
                            .font(.footnote).foregroundStyle(Theme.muted)
                    } else {
                        Text("This workout is not loaded. Refresh to check for it, or choose another workout from the library.")
                            .foregroundStyle(Theme.muted)
                        Button(refreshing ? "Refreshing…" : "Refresh workout") {
                            refreshing = true
                            Task { await sync.load(); refreshing = false }
                        }
                        .disabled(refreshing)
                        .frame(minHeight: 44)
                    }
                    if let error = sync.loadError {
                        Text(error).font(.footnote).foregroundStyle(Theme.danger)
                    }
                }
                .padding(20)
            }
            .safeAreaInset(edge: .bottom, spacing: 0) {
                if let workout, onStart != nil || date != nil {
                    primaryAction(for: workout)
                        .padding(.horizontal, 20)
                        .padding(.vertical, 12)
                        .background(Theme.background)
                        .overlay(alignment: .top) { Divider() }
                }
            }
            .background(Theme.background)
            .foregroundStyle(Theme.text)
            .navigationTitle(workout?.name ?? "Workout unavailable")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Done") { dismiss() } } }
            .sheet(isPresented: $editing) { EditWorkoutSheet(sync: sync, dayID: workoutID) }
        }
        .preferredColorScheme(.dark)
    }

    @ViewBuilder
    private func primaryAction(for workout: Workout) -> some View {
        VStack(spacing: 8) {
            if let onStart {
                Button(canResume ? "Continue workout" : "Start this workout") { onStart(workout.id) }
                    .buttonStyle(WorkoutPrimaryButtonStyle())
                    .disabled(workout.exercises.isEmpty || (sync.blocksNewWorkoutStart && !canResume)
                        || sync.todayIsCompleted || sync.isRoutineMutationInFlight)
                    .accessibilityIdentifier("workoutDetails.start")
                Text("Today only. Weekly schedule unchanged.")
                    .font(.footnote).foregroundStyle(Theme.muted)
            } else if let date {
                Button(saving ? "Saving…" : "Schedule for \(date)") {
                    saving = true
                    Task {
                        let accepted = await sync.setCalendarOverride(date: date, dayID: workout.id)
                        saving = false
                        if accepted { dismiss() }
                    }
                }
                .buttonStyle(WorkoutPrimaryButtonStyle())
                .disabled(saving || sync.isRoutineMutationInFlight
                    || sync.calendarAssignmentUnavailableReason(date: date) != nil)
                .accessibilityIdentifier("workoutDetails.schedule")
                Text("This date only. Weekly schedule unchanged.")
                    .font(.footnote).foregroundStyle(Theme.muted)
            }
        }
    }
}

struct WorkoutPrimaryButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) private var isEnabled
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.headline)
            .frame(maxWidth: .infinity, minHeight: 48)
            .foregroundStyle(isEnabled ? Theme.bg : Theme.muted)
            .background(isEnabled ? Theme.accent : Theme.surface2)
            .clipShape(RoundedRectangle(cornerRadius: 12))
            .opacity(configuration.isPressed ? 0.8 : 1)
    }
}

struct WeeklyScheduleView: View {
    @ObservedObject var sync: SyncModel
    @Environment(\.dismiss) private var dismiss
    @State private var draft: [String: String] = [:]
    @State private var savedDraft: [String: String] = [:]
    @State private var loadedPlanID = ""
    @State private var loadedVersion = 0
    @State private var saving = false
    @State private var confirmDiscard = false
    @State private var scheduleChanged = false
    private let names = ["mon": "Monday", "tue": "Tuesday", "wed": "Wednesday",
                         "thu": "Thursday", "fri": "Friday", "sat": "Saturday", "sun": "Sunday"]

    private var hasChanges: Bool { draft != savedDraft }
    private var planWasReplaced: Bool { !loadedPlanID.isEmpty && sync.plan?.id != loadedPlanID }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    ForEach(PlanSchedule.weekdayKeys, id: \.self) { key in
                        Picker(names[key] ?? key, selection: Binding(
                            get: { draft[key] ?? "" }, set: { draft[key] = $0 })) {
                            Text("Rest").tag("")
                            ForEach(sync.plan?.workouts ?? []) { workout in
                                Text(workout.name).tag(workout.id)
                            }
                        }
                        .accessibilityIdentifier("weeklySchedule.\(key)")
                    }
                } footer: {
                    Text("Repeats each week. Workouts assigned to specific dates stay in place.")
                }
                .disabled(saving || sync.isRoutineMutationInFlight || sync.plan == nil || planWasReplaced)
                if planWasReplaced {
                    Text("The active plan changed. Reopen this schedule to review it.")
                        .foregroundStyle(Theme.danger)
                } else if scheduleChanged {
                    Text("The schedule changed elsewhere. Your choices are still here. Review them before saving to replace the current weekly schedule.")
                        .foregroundStyle(Theme.danger)
                        .accessibilityIdentifier("weeklySchedule.conflict")
                }
                if let error = sync.loadError {
                    Text(error).foregroundStyle(Theme.danger)
                        .accessibilityIdentifier("weeklySchedule.error")
                }
            }
            .navigationTitle("Weekly schedule")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") {
                        if hasChanges { confirmDiscard = true } else { dismiss() }
                    }
                    .disabled(saving)
                    .accessibilityIdentifier("weeklySchedule.cancel")
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(saving ? "Saving…" : "Save") { save() }
                        .disabled(!hasChanges || saving || sync.isRoutineMutationInFlight
                            || sync.plan == nil || planWasReplaced)
                        .accessibilityIdentifier("weeklySchedule.save")
                }
            }
            .alert("Discard schedule changes?", isPresented: $confirmDiscard) {
                Button("Keep editing", role: .cancel) {}
                Button("Discard changes", role: .destructive) { dismiss() }
            } message: {
                Text("Your weekly schedule has not been saved.")
            }
            .task(id: [sync.plan?.id ?? "", String(sync.plan?.version ?? 0)]) {
                // An external refresh must not replace an unsaved draft. Saving
                // uses its loaded version so concurrent edits still conflict.
                guard !saving, !hasChanges else { return }
                savedDraft = RoutineScheduleDraftPolicy.persistedDraft(for: sync.plan)
                draft = savedDraft
                loadedPlanID = sync.plan?.id ?? ""
                loadedVersion = sync.plan?.version ?? 0
            }
        }
        .interactiveDismissDisabled(hasChanges || saving)
        .preferredColorScheme(.dark)
    }

    private func save() {
        saving = true
        Task {
            let accepted = await sync.saveRecurringSchedule(draft,
                expectedPlanID: loadedPlanID, expectedVersion: loadedVersion)
            if accepted {
                dismiss()
            } else if let plan = sync.plan, plan.id == loadedPlanID {
                let latest = RoutineScheduleDraftPolicy.persistedDraft(for: plan)
                scheduleChanged = scheduleChanged || plan.version != loadedVersion || latest != savedDraft
                savedDraft = latest
                loadedVersion = plan.version
            }
            saving = false
        }
    }
}
