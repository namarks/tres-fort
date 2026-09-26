import SwiftUI

/// Select exercises locally, then save one complete library workout.
/// Keep the observed version on an uncertain retry so a lost response cannot
/// quietly append a second workout after the first creation committed.
struct CreateWorkoutView: View {
    @ObservedObject var sync: SyncModel
    var onStart: ((String) -> Void)? = nil
    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    @State private var selectedExercises: [ExerciseCatalog] = []
    @State private var reviewing = false
    @State private var creating = false
    @State private var refreshing = false
    @State private var createdID: String?
    @State private var editing = true
    @State private var authority: CreationAuthority?
    @State private var hadUncertainAttempt = false
    @State private var needsLibraryReview = false

    private struct CreationAuthority {
        let planID: String
        let version: Int
        let name: String
        let exerciseIDs: [String]
    }

    var body: some View {
        Group {
            if let createdID, editing {
                EditWorkoutSheet(sync: sync, dayID: createdID, onDone: { editing = false })
            } else if let createdID {
                WorkoutDetailsView(sync: sync, workoutID: createdID, onStart: onStart)
            } else {
                NavigationStack {
                    ExercisePickerList(sync: sync) { exercise in
                        let selectedIndex = selectedExercises.firstIndex { $0.id == exercise.id }
                        Button {
                            if let selectedIndex { selectedExercises.remove(at: selectedIndex) }
                            else { selectedExercises.append(exercise) }
                        } label: {
                            HStack(spacing: 12) {
                                ExerciseCatalogLabel(exercise: exercise)
                                Spacer()
                                if let selectedIndex {
                                    Text("\(selectedIndex + 1)")
                                        .font(.subheadline.bold()).foregroundStyle(Theme.bg)
                                        .frame(width: 28, height: 28).background(Theme.accent).clipShape(Circle())
                                } else {
                                    Image(systemName: "plus.circle").foregroundStyle(Theme.accent)
                                }
                            }.frame(minHeight: 44).contentShape(Rectangle())
                        }
                        .disabled(selectedIndex == nil && selectedExercises.count >= 50)
                        .accessibilityAddTraits(selectedIndex == nil ? [] : [.isSelected])
                        .accessibilityIdentifier("exercisePicker.exercise.\(exercise.id)")
                    }
                    .navigationTitle("Add exercises")
                    .navigationBarTitleDisplayMode(.inline)
                    .safeAreaInset(edge: .bottom) {
                        Button { reviewing = true } label: {
                            Text("Review workout (\(selectedExercises.count))")
                                .font(.headline).foregroundStyle(Theme.bg)
                                .frame(maxWidth: .infinity, minHeight: 48)
                        }
                            .buttonStyle(.borderedProminent).tint(Theme.accent)
                            .disabled(selectedExercises.isEmpty)
                            .accessibilityIdentifier("createWorkout.review")
                            .padding().background(Theme.background)
                    }
                    .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } } }
                    .navigationDestination(isPresented: $reviewing) { reviewForm }
                }
            }
        }
        .preferredColorScheme(.dark)
        .interactiveDismissDisabled(creating)
    }

    private var suggestedName: String {
        ExerciseSearchPolicy.defaultName(existingNames: sync.plan?.workouts.map(\.name) ?? [])
    }

    private var reviewForm: some View {
        Form {
            Section("Workout name · optional") {
                TextField(suggestedName, text: $name)
                    .accessibilityIdentifier("createWorkout.name")
                    .disabled(creating || authority != nil)
            }
            Section {
                ForEach(selectedExercises) { exercise in
                    HStack {
                        ExerciseCatalogLabel(exercise: exercise)
                        Spacer()
                        Text(ExerciseSearchPolicy.initialTargets(for: exercise))
                            .font(.caption).foregroundStyle(Theme.muted)
                    }
                }
                .onDelete { selectedExercises.remove(atOffsets: $0) }
                .deleteDisabled(creating || authority != nil)
            } header: { Text("Exercises") } footer: {
                Text("Start with these targets, then adjust sets, reps, and weights in the workout editor. No weight is preselected. You can rename the workout anytime.")
            }
            Section {
                Button(creating ? "Creating…" : authority == nil ? "Create workout" : "Retry creation") {
                    creating = true
                    Task {
                        defer { creating = false }
                        if authority == nil {
                            let planID: String
                            let version: Int
                            if let plan = sync.plan {
                                planID = plan.id; version = plan.version
                            } else if let result = await sync.ensureRoutinePlan(name: "My Training") {
                                planID = result.plan.id; version = result.plan.version
                            } else { return }
                            authority = CreationAuthority(planID: planID, version: version,
                                                          name: name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? suggestedName : name.trimmingCharacters(in: .whitespacesAndNewlines),
                                                          exerciseIDs: selectedExercises.map(\.id))
                        }
                        guard let authority else { return }
                        switch await sync.createLibraryWorkout(name: authority.name, exerciseIDs: authority.exerciseIDs,
                            expectedPlanID: authority.planID, expectedVersion: authority.version) {
                        case let .created(id): createdID = id
                        case .needsReview:
                            // A first-attempt conflict proves no creation. A
                            // conflict after a lost reply cannot disprove that
                            // earlier commit, so require library inspection.
                            if hadUncertainAttempt { needsLibraryReview = true }
                            else { self.authority = nil }
                        case .retrySameRequest: hadUncertainAttempt = true
                        }
                    }
                }
                .disabled(creating || needsLibraryReview || sync.isRoutineMutationInFlight
                          || selectedExercises.isEmpty
                          || (sync.plan == nil && !sync.canCreateRoutine))
                .accessibilityIdentifier("createWorkout.create")
            }
            if let error = sync.loadError {
                Text(error).foregroundStyle(Theme.danger)
                if authority != nil {
                    Text(needsLibraryReview
                         ? "The earlier request may have saved. Close this screen and check your workout library before creating another workout."
                         : "Retry uses the same request to avoid saving a duplicate workout.")
                        .font(.footnote).foregroundStyle(Theme.muted)
                }
            }
            if sync.plan == nil && !sync.canCreateRoutine {
                Button(refreshing ? "Refreshing…" : "Refresh training plan") {
                    refreshing = true
                    Task { await sync.load(); refreshing = false }
                }
                .disabled(creating || refreshing)
                .accessibilityIdentifier("createWorkout.refreshPlan")
            }
        }
        .scrollContentBackground(.hidden)
        .background(Theme.background)
        .navigationTitle("Review workout")
        .navigationBarTitleDisplayMode(.inline)
        .navigationBarBackButtonHidden(creating || authority != nil)
        .toolbar { ToolbarItem(placement: .topBarTrailing) { Button("Cancel") { dismiss() }.disabled(creating) } }
    }
}
