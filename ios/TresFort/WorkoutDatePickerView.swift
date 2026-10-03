import SwiftUI

/// A date assignment is a small selection task. Saved-workout editing and
/// library management stay in WorkoutsView; previews here are read-only.
struct WorkoutDatePickerView: View {
    @ObservedObject var sync: SyncModel
    let date: String
    @Environment(\.dismiss) private var dismiss
    @State private var selectedID: String?
    @State private var saving = false
    @State private var refreshing = false

    init(sync: SyncModel, date: String) {
        self.sync = sync
        self.date = date
        _selectedID = State(initialValue: sync.previewWorkout(forDateString: date)?.id)
    }

    private var workouts: [Workout] {
        WorkoutLibraryPolicy.choices(plan: sync.plan, date: date)
    }
    private var selectedWorkout: Workout? { workouts.first { $0.id == selectedID } }
    private var unavailableReason: String? {
        sync.calendarAssignmentUnavailableReason(date: date)
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    Text("For \(date)").font(.subheadline).foregroundStyle(Theme.muted)
                        .accessibilityIdentifier("workoutPicker.date")
                    if let reason = unavailableReason {
                        Text(reason).font(.subheadline).foregroundStyle(Theme.muted)
                    }
                    if workouts.isEmpty {
                        Text(sync.plan == nil ? "Your workouts are not loaded." : "No saved workouts are available.")
                            .font(.body).foregroundStyle(Theme.muted)
                    }
                    ForEach(workouts) { workout in
                        VStack(alignment: .leading, spacing: 0) {
                            Button { selectedID = workout.id } label: {
                                HStack(spacing: 12) {
                                    VStack(alignment: .leading, spacing: 5) {
                                        Text(workout.name).font(.headline).foregroundStyle(Theme.text)
                                        Text(prescriptionSummary(workout))
                                            .font(.subheadline).foregroundStyle(Theme.muted)
                                    }
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                    Image(systemName: selectedID == workout.id ? "checkmark.circle.fill" : "circle")
                                        .foregroundStyle(selectedID == workout.id ? Theme.accent : Theme.dim)
                                        .accessibilityHidden(true)
                                }
                                .padding(16).frame(minHeight: 64).contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                            .accessibilityIdentifier("workoutPicker.workout.\(workout.id)")
                            .accessibilityAddTraits(selectedID == workout.id ? .isSelected : [])
                            .disabled(saving || sync.isRoutineMutationInFlight)
                            if selectedID == workout.id, !workout.exercises.isEmpty {
                                DisclosureGroup {
                                    WorkoutExercisePreview(sync: sync, exercises: workout.exercises)
                                        .padding(.top, 12)
                                } label: {
                                    Text("Preview exercises").font(.subheadline)
                                        .frame(minHeight: 44)
                                }
                                .tint(Theme.accent)
                                .padding(.horizontal, 16).padding(.bottom, 12)
                                .accessibilityIdentifier("workoutPicker.preview")
                            }
                        }
                        .background(Theme.surface)
                        .clipShape(RoundedRectangle(cornerRadius: 14))
                    }
                    if let error = sync.loadError {
                        Text(error).font(.subheadline).foregroundStyle(Theme.danger)
                            .accessibilityIdentifier("workoutPicker.error")
                    }
                    if sync.plan == nil || sync.loadError != nil || sync.isUsingCachedState {
                        Button(refreshing ? "Refreshing…" : "Refresh workouts") {
                            refreshing = true
                            Task { await sync.load(); refreshing = false }
                        }
                        .frame(minHeight: 44)
                        .disabled(saving || refreshing || sync.isRoutineMutationInFlight)
                        .accessibilityIdentifier("workoutPicker.refresh")
                    }
                }
                .padding(20)
            }
            .safeAreaInset(edge: .bottom, spacing: 0) {
                VStack(spacing: 8) {
                    Button(saving ? "Saving…" : "Schedule workout") { assign() }
                        .buttonStyle(WorkoutPrimaryButtonStyle())
                        .disabled(selectedWorkout == nil || saving || refreshing
                            || sync.isRoutineMutationInFlight || unavailableReason != nil)
                        .accessibilityIdentifier("workoutPicker.schedule")
                    Text("This date only. Weekly schedule unchanged.")
                        .font(.caption).foregroundStyle(Theme.muted)
                }
                .padding(.horizontal, 20).padding(.vertical, 12)
                .background(Theme.background)
            }
            .background(Theme.background)
            .navigationTitle("Choose a workout")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }.disabled(saving)
                }
            }
        }
        .preferredColorScheme(.dark)
        .interactiveDismissDisabled(saving)
        .onChange(of: workouts.map(\.id)) { _, ids in
            if let selectedID, !ids.contains(selectedID) { self.selectedID = nil }
        }
    }

    private func prescriptionSummary(_ workout: Workout) -> String {
        let count = workout.exercises.count
        guard count > 0 else { return "No exercises yet" }
        let sets = workout.exercises.reduce(0) { $0 + $1.target_sets }
        return "\(count) \(count == 1 ? "exercise" : "exercises") · \(sets) \(sets == 1 ? "set" : "sets")"
    }

    private func assign() {
        guard let selectedWorkout, !saving else { return }
        saving = true
        Task {
            // The shared mutation rechecks the date, active session, blackout,
            // workout availability and assignment attempt at the write boundary.
            let accepted = await sync.setCalendarOverride(date: date, dayID: selectedWorkout.id)
            saving = false
            if accepted { dismiss() }
        }
    }
}
