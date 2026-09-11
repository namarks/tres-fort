import SwiftUI

/// Creates a named entry in the shared library, then opens its prescription.
/// Keep the observed version on an uncertain retry so a lost response cannot
/// quietly append a second workout after the first creation committed.
struct CreateWorkoutView: View {
    @ObservedObject var sync: SyncModel
    var onStart: ((String) -> Void)? = nil
    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
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
    }

    var body: some View {
        Group {
            if let createdID, editing {
                EditWorkoutSheet(sync: sync, dayID: createdID, onDone: { editing = false })
            } else if let createdID {
                WorkoutDetailsView(sync: sync, workoutID: createdID, onStart: onStart)
            } else {
                NavigationStack {
                    Form {
                        Section {
                            TextField("Workout name", text: $name)
                                .accessibilityIdentifier("createWorkout.name")
                                .disabled(creating || authority != nil)
                        } footer: {
                            Text("Saved to your workout library. Next, choose exercises and targets. You can use it on any date; a weekly schedule is optional.")
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
                                                                      name: name.trimmingCharacters(in: .whitespacesAndNewlines))
                                    }
                                    guard let authority else { return }
                                    switch await sync.createLibraryWorkout(name: authority.name,
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
                                      || name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
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
                    .navigationTitle("Create a workout")
                    .navigationBarTitleDisplayMode(.inline)
                    .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() }.disabled(creating) } }
                }
            }
        }
        .preferredColorScheme(.dark)
        .interactiveDismissDisabled(creating)
    }
}
