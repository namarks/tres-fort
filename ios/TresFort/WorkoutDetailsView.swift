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
    @State private var demoFor: TemplateExercise?

    private var workout: Workout? { sync.workout(id: workoutID) }
    private var canResume: Bool { sync.hasResumableWorkout && sync.resumableCheckpoint?.selectedDayID == workoutID }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    if let workout {
                        Text(date.map { "For \($0)" } ?? "Saved workout")
                            .font(Theme.mono(12)).foregroundStyle(Theme.muted)
                        ForEach(ExerciseGroupBlock.blocks(workout.exercises)) { block in
                            VStack(alignment: .leading, spacing: 12) {
                                if block.isGroup {
                                    Text(block.title).font(.headline).foregroundStyle(Theme.accent)
                                    Text("\(block.rounds) rounds · \(block.roundRest)s round rest")
                                        .font(.caption).foregroundStyle(Theme.muted)
                                }
                                ForEach(block.members) { exercise in
                                    VStack(alignment: .leading, spacing: 5) {
                                        HStack {
                                            Text(exercise.exercise_name).font(.headline)
                                            DemoInfoButton(exerciseName: exercise.exercise_name) { demoFor = exercise }
                                            if exercise.isWarmup { WarmupTag() }
                                        }
                                        Text(exercise.targetLabel)
                                            .font(Theme.mono(13)).foregroundStyle(Theme.muted)
                                    }
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                }
                            }
                            .padding(16).background(Theme.surface)
                            .clipShape(RoundedRectangle(cornerRadius: 14))
                        }
                        if workout.exercises.isEmpty {
                            Text("No exercises yet. Edit this workout to add exercises and targets.")
                                .foregroundStyle(Theme.muted)
                        }
                        if let onStart {
                            Button(canResume ? "Continue workout" : "Start this workout") { onStart(workout.id) }
                                .buttonStyle(WorkoutPrimaryButtonStyle())
                                .disabled(workout.exercises.isEmpty || (sync.blocksNewWorkoutStart && !canResume)
                                    || sync.todayIsCompleted || sync.isRoutineMutationInFlight)
                                .accessibilityIdentifier("workoutDetails.start")
                            Text("For today only. Your weekly schedule stays the same.")
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
                            Text("This date only. Your weekly schedule stays the same.")
                                .font(.footnote).foregroundStyle(Theme.muted)
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
            .background(Theme.background)
            .foregroundStyle(Theme.text)
            .navigationTitle(workout?.name ?? "Workout unavailable")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Done") { dismiss() } } }
            .sheet(isPresented: $editing) { EditWorkoutSheet(sync: sync, dayID: workoutID) }
            .sheet(item: $demoFor) { exercise in
                ExerciseDemoSheet(
                    exerciseID: exercise.exercise_id, name: exercise.exercise_name,
                    primaryMuscle: sync.catalogRow(exercise.exercise_id)?.primary_muscle ?? exercise.exercise_modality,
                    secondaryMuscles: [], modality: exercise.exercise_modality,
                    laterality: exercise.exercise_laterality ?? "bilateral",
                    loadMode: exercise.exercise_load_mode ?? "total",
                    demoSlug: exercise.exercise_demo_slug, jwt: sync.exerciseDemoJWT)
            }
        }
        .preferredColorScheme(.dark)
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
    @State private var identity: [String] = []
    private let names = ["mon": "Monday", "tue": "Tuesday", "wed": "Wednesday",
                         "thu": "Thursday", "fri": "Friday", "sat": "Saturday", "sun": "Sunday"]

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
                    }
                    Button("Save weekly schedule") {
                        Task { await sync.saveRecurringSchedule(draft) }
                    }
                } footer: {
                    Text("Repeats each week. Workouts assigned to specific dates stay in place.")
                }
                .disabled(sync.isRoutineMutationInFlight || sync.plan == nil)
                if let error = sync.loadError { Text(error).foregroundStyle(Theme.danger) }
            }
            .navigationTitle("Weekly schedule")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Done") { dismiss() } } }
            .task(id: [sync.plan?.id ?? "", String(sync.plan?.version ?? 0)]) {
                let state = RoutineScheduleDraftPolicy.reconcile(
                    currentDraft: draft, loadedIdentity: identity, plan: sync.plan)
                draft = state.draft
                identity = state.identity
            }
        }
        .preferredColorScheme(.dark)
    }
}
