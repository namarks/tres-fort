import SwiftUI

/// Names a run, puts it on a weekday and opens its step editor, all from the
/// weekday sheet (docs/plans/planned-runs P8). It is saved as a workout with
/// one outdoor run, the same thing the coach writes, so Today, the recorder
/// and the calendar treat it like any planned run.
struct NewPlannedRunView: View {
    @ObservedObject var sync: SyncModel
    let weekdayKey: String
    /// Closes the weekday sheet once the run is on the weekday and planned,
    /// or the member chose to plan its steps later.
    var onFinished: () -> Void
    @State private var name = ""
    @State private var saving = false
    /// The run saved by an earlier attempt whose weekday write failed.
    @State private var createdID: String?
    @State private var authority: Authority?
    @State private var hadUncertainAttempt = false
    @State private var needsLibraryReview = false
    @State private var planning: Planning?
    @FocusState private var nameFocused: Bool

    private struct Authority { let planID: String; let version: Int; let name: String }
    /// The run's slot and the plan version the step editor saves against,
    /// fixed when it opens so a newer plan is a conflict, not overwritten.
    private struct Planning { let workoutID: String; let slot: TemplateExercise; let version: Int }

    private var dayName: String { WorkoutLibraryPolicy.weekdayNames[weekdayKey] ?? weekdayKey }
    private var runName: String { PlannedRunCreation.name(name) }
    private var match: PlannedRunCreation.Match {
        createdID == nil ? PlannedRunCreation.match(named: runName, in: sync.plan) : .available
    }

    var body: some View {
        Group {
            if let planning {
                RunPlanEditorView(sync: sync, dayID: planning.workoutID, slot: planning.slot,
                                  expectedVersion: planning.version, onFinished: onFinished)
                    .navigationBarBackButtonHidden(true)
            } else {
                form
            }
        }
    }

    private var form: some View {
        Form {
            Section {
                TextField(PlannedRunCreation.defaultName, text: $name)
                    .textInputAutocapitalization(.words)
                    .submitLabel(.done)
                    .focused($nameFocused)
                    .disabled(saving || authority != nil)
                    .accessibilityIdentifier("newRun.name")
            } header: {
                Text("Which run on \(dayName)s?")
            } footer: {
                Text("Next you plan its steps: a warm-up, intervals or a steady run, each with an optional pace or heart rate range.")
            }
            if authority == nil {
                Section("Ideas") {
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 8) {
                            ForEach(PlannedRunCreation.suggestions, id: \.self) { idea in
                                Button(idea) { name = idea }
                                    .font(Theme.mono(13, .bold))
                                    .padding(.horizontal, 12).frame(minHeight: 36)
                                    .background(runName == idea ? Theme.accent.opacity(0.18) : Theme.surface2)
                                    .clipShape(Capsule())
                                    .buttonStyle(.plain)
                                    .accessibilityIdentifier("newRun.idea.\(idea)")
                            }
                        }
                        .padding(.vertical, 4)
                    }
                    .listRowInsets(EdgeInsets(top: 4, leading: 12, bottom: 4, trailing: 12))
                }
            }
            Section {
                Button(buttonTitle) { save() }
                    .buttonStyle(WorkoutPrimaryButtonStyle())
                    .disabled(saving || needsLibraryReview || isTaken
                              || sync.isRoutineMutationInFlight || sync.plan == nil)
                    .listRowBackground(Color.clear)
                    .listRowInsets(EdgeInsets(top: 4, leading: 0, bottom: 4, trailing: 0))
                    .accessibilityIdentifier("newRun.save")
            } footer: {
                switch match {
                case let .run(existing):
                    Text("You already have \(existing.name), so this uses it and opens its steps.")
                case let .taken(existing):
                    Text("\(existing.name) is already a workout that isn't a run. Pick another name.")
                        .foregroundStyle(Theme.danger)
                case .available:
                    EmptyView()
                }
            }
            if let error = sync.loadError {
                Section {
                    Text(error).foregroundStyle(Theme.danger)
                    if needsLibraryReview {
                        Text("The first try may have saved. Check the Workouts side before making it again.")
                            .font(.footnote).foregroundStyle(Theme.muted)
                    }
                }
            }
        }
        .scrollContentBackground(.hidden)
        .background(Theme.background)
        .navigationTitle("New run")
        .navigationBarTitleDisplayMode(.inline)
        .navigationBarBackButtonHidden(saving || authority != nil)
        .onAppear { nameFocused = true }
    }

    private var isTaken: Bool {
        if case .taken = match { return true }
        return false
    }

    private var buttonTitle: String {
        if saving { return "Saving…" }
        if createdID != nil || authority != nil { return "Try again" }
        return "Plan it every \(dayName)"
    }

    private func save() {
        guard !saving, !isTaken, let plan = sync.plan else { return }
        nameFocused = false
        saving = true
        Task {
            defer { saving = false }
            if createdID == nil, case let .run(existing) = match {
                if await sync.setWeekday(weekdayKey, to: existing.id) { openSteps(existing.id) }
                return
            }
            if createdID == nil {
                // Keep the first request's version on a retry, so a reply lost
                // after the save can't quietly make a second run.
                let request = authority ?? Authority(planID: plan.id, version: plan.version, name: runName)
                authority = request
                switch await sync.createLibraryWorkout(name: request.name, exerciseIDs: [RunPlan.exerciseID],
                    expectedPlanID: request.planID, expectedVersion: request.version) {
                case let .created(id): createdID = id
                case .needsReview:
                    if hadUncertainAttempt { needsLibraryReview = true } else { authority = nil }
                    return
                case .retrySameRequest:
                    hadUncertainAttempt = true
                    return
                }
            }
            guard let createdID else { return }
            if await sync.setWeekday(weekdayKey, to: createdID) { openSteps(createdID) }
        }
    }

    /// The run is on the weekday; plan its steps next. If the refreshed plan
    /// doesn't hold it yet, close: the weekday shows it and it can be planned
    /// from the workout later.
    private func openSteps(_ workoutID: String) {
        guard let slot = PlannedRunCreation.runSlot(in: sync.workout(id: workoutID)),
              let version = sync.plan?.version else {
            onFinished()
            return
        }
        planning = Planning(workoutID: workoutID, slot: slot, version: version)
    }
}
