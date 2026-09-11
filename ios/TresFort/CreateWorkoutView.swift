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
                                    createdID = await sync.addWorkoutDay(name: authority.name,
                                        expectedPlanID: authority.planID, expectedVersion: authority.version)
                                }
                            }
                            .disabled(creating || sync.isRoutineMutationInFlight
                                      || name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                                      || (sync.plan == nil && !sync.canCreateRoutine))
                            .accessibilityIdentifier("createWorkout.create")
                        }
                        if let error = sync.loadError {
                            Text(error).foregroundStyle(Theme.danger)
                            if authority != nil {
                                Text("If the library changed, close this screen and review it before creating another workout.")
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
