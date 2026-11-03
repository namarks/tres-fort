import SwiftUI

/// One weekday of the repeating week, opened by tapping it on the Plan tab.
/// Pick rest or any saved workout, or make something new for that day: an
/// activity such as a soccer match, or a workout with exercises. Only this
/// weekday changes; dates already assigned stay as they are.
struct WeekdayPlanSheet: View {
    @ObservedObject var sync: SyncModel
    let weekdayKey: String
    /// Closes the sheet and opens a workout on the Plan tab's own stack.
    var onOpenWorkout: (String) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var saving = false
    @State private var addingActivity = false
    @State private var creatingWorkout = false
    @State private var createdWorkoutID: String?

    private var dayName: String { WorkoutLibraryPolicy.weekdayNames[weekdayKey] ?? weekdayKey }
    private var current: WorkoutLibraryPolicy.WeekRow? {
        WorkoutLibraryPolicy.weekRows(plan: sync.plan).first { $0.weekdayKey == weekdayKey }
    }
    private var busy: Bool { saving || sync.isRoutineMutationInFlight || sync.plan == nil }

    var body: some View {
        NavigationStack {
            List {
                Section {
                    choice("Rest", detail: nil, workoutID: nil)
                    ForEach(sync.plan?.availableWorkouts ?? []) { workout in
                        choice(workout.name, detail: Self.detail(for: workout), workoutID: workout.id)
                    }
                } header: {
                    Text("Every \(dayName)")
                } footer: {
                    Text("Repeats every week. To change one date, use the calendar.")
                }
                Section {
                    Button { addingActivity = true } label: {
                        newRow("New activity", detail: "Soccer, a class, a hike: anything without sets",
                               systemImage: "sportscourt")
                    }
                    .accessibilityIdentifier("weekday.newActivity")
                    Button { creatingWorkout = true } label: {
                        newRow("New workout", detail: "Pick exercises to log set by set",
                               systemImage: "dumbbell")
                    }
                    .accessibilityIdentifier("weekday.newWorkout")
                } header: {
                    Text("Something new")
                }
                .disabled(busy)
                if let id = current?.workoutID, let name = current?.workoutName {
                    Section {
                        Button("View \(name)") { onOpenWorkout(id) }
                            .accessibilityIdentifier("weekday.viewWorkout")
                    }
                }
                if let error = sync.loadError {
                    Section {
                        Text(error).foregroundStyle(Theme.danger)
                            .accessibilityIdentifier("weekday.error")
                    }
                }
            }
            .scrollContentBackground(.hidden)
            .background(Theme.background)
            .navigationTitle(dayName)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                        .disabled(saving)
                        .accessibilityIdentifier("weekday.done")
                }
            }
            .navigationDestination(isPresented: $addingActivity) {
                NewActivityView(sync: sync, weekdayKey: weekdayKey) { dismiss() }
            }
        }
        // The workout gets its weekday once its creator closes, so the
        // schedule write never races the targets being edited there.
        .sheet(isPresented: $creatingWorkout, onDismiss: assignCreatedWorkout) {
            CreateWorkoutView(sync: sync, onCreated: { createdWorkoutID = $0 })
        }
        .interactiveDismissDisabled(saving)
    }

    static func detail(for workout: Workout) -> String {
        if PlannedActivity.isActivity(workout) { return "Activity" }
        let count = workout.exercises.count
        return "\(count) exercise\(count == 1 ? "" : "s")"
    }

    private func choice(_ title: String, detail: String?, workoutID: String?) -> some View {
        let selected = (current?.workoutID) == workoutID
        return Button { choose(workoutID) } label: {
            HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 3) {
                    Text(title).font(Theme.mono(15, .bold)).foregroundStyle(Theme.text)
                    if let detail {
                        Text(detail).font(Theme.mono(11)).foregroundStyle(Theme.muted)
                    }
                }
                Spacer(minLength: 0)
                if selected {
                    Image(systemName: "checkmark")
                        .font(.system(size: 15, weight: .bold)).foregroundStyle(Theme.accent)
                        .accessibilityHidden(true)
                }
            }
            .frame(minHeight: 44)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(busy)
        .accessibilityAddTraits(selected ? [.isSelected] : [])
        .accessibilityIdentifier("weekday.choice.\(workoutID ?? "rest")")
    }

    private func newRow(_ title: String, detail: String, systemImage: String) -> some View {
        HStack(spacing: 12) {
            Image(systemName: systemImage)
                .font(.system(size: 17)).foregroundStyle(Theme.accent)
                .frame(width: 24)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 3) {
                Text(title).font(Theme.mono(15, .bold)).foregroundStyle(Theme.accent)
                Text(detail).font(Theme.mono(11)).foregroundStyle(Theme.muted)
            }
            Spacer(minLength: 0)
        }
        .frame(minHeight: 44)
        .contentShape(Rectangle())
    }

    private func choose(_ workoutID: String?) {
        guard !busy else { return }
        guard current?.workoutID != workoutID else { dismiss(); return }
        saving = true
        Task {
            let accepted = await sync.setWeekday(weekdayKey, to: workoutID)
            saving = false
            if accepted { dismiss() }
        }
    }

    private func assignCreatedWorkout() {
        guard let id = createdWorkoutID else { return }
        createdWorkoutID = nil
        saving = true
        Task {
            await sync.setWeekday(weekdayKey, to: id)
            saving = false
        }
    }
}

/// Names an activity and puts it on a weekday in one step. It is saved as a
/// workout with no exercises, which Today shows as something to log.
struct NewActivityView: View {
    @ObservedObject var sync: SyncModel
    let weekdayKey: String
    var onScheduled: () -> Void
    @State private var name = ""
    @State private var saving = false
    /// The activity saved by an earlier attempt whose weekday write failed.
    @State private var createdID: String?
    @State private var authority: Authority?
    @State private var hadUncertainAttempt = false
    @State private var needsLibraryReview = false
    @FocusState private var nameFocused: Bool

    private struct Authority { let planID: String; let version: Int; let name: String }

    private var dayName: String { WorkoutLibraryPolicy.weekdayNames[weekdayKey] ?? weekdayKey }
    private var cleanName: String { name.trimmingCharacters(in: .whitespacesAndNewlines) }
    private var existing: Workout? {
        createdID == nil ? PlannedActivity.existing(named: cleanName, in: sync.plan) : nil
    }

    var body: some View {
        Form {
            Section {
                TextField("Soccer", text: $name)
                    .textInputAutocapitalization(.words)
                    .submitLabel(.done)
                    .focused($nameFocused)
                    .disabled(saving || authority != nil)
                    .accessibilityIdentifier("newActivity.name")
            } header: {
                Text("What do you do on \(dayName)s?")
            } footer: {
                Text("On the day, Today shows it with a button to log it once it's done.")
            }
            if authority == nil {
                Section("Ideas") {
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 8) {
                            ForEach(PlannedActivity.suggestions, id: \.self) { idea in
                                Button(idea) { name = idea }
                                    .font(Theme.mono(13, .bold))
                                    .padding(.horizontal, 12).frame(minHeight: 36)
                                    .background(cleanName == idea ? Theme.accent.opacity(0.18) : Theme.surface2)
                                    .clipShape(Capsule())
                                    .buttonStyle(.plain)
                                    .accessibilityIdentifier("newActivity.idea.\(idea)")
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
                    .disabled(cleanName.isEmpty || saving || needsLibraryReview
                              || sync.isRoutineMutationInFlight || sync.plan == nil)
                    .listRowBackground(Color.clear)
                    .listRowInsets(EdgeInsets(top: 4, leading: 0, bottom: 4, trailing: 0))
                    .accessibilityIdentifier("newActivity.save")
            } footer: {
                if let existing {
                    Text("You already have \(existing.name), so this uses it instead of making another.")
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
        .navigationTitle("New activity")
        .navigationBarTitleDisplayMode(.inline)
        .navigationBarBackButtonHidden(saving || authority != nil)
        .onAppear { nameFocused = true }
    }

    private var buttonTitle: String {
        if saving { return "Saving…" }
        if createdID != nil || authority != nil { return "Try again" }
        return "Do it every \(dayName)"
    }

    private func save() {
        guard !saving, !cleanName.isEmpty, let plan = sync.plan else { return }
        nameFocused = false
        saving = true
        Task {
            defer { saving = false }
            if createdID == nil, let existing {
                if await sync.setWeekday(weekdayKey, to: existing.id) { onScheduled() }
                return
            }
            if createdID == nil {
                // Keep the first request's version on a retry, so a reply lost
                // after the save can't quietly make a second activity.
                let request = authority ?? Authority(planID: plan.id, version: plan.version, name: cleanName)
                authority = request
                switch await sync.createLibraryWorkout(name: request.name, exerciseIDs: [],
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
            if await sync.setWeekday(weekdayKey, to: createdID) { onScheduled() }
        }
    }
}
