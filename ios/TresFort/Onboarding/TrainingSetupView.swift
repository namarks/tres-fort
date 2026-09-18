import SwiftUI

struct TrainingSetupView: View {
    @StateObject private var model: TrainingSetupModel
    let showStarters: Bool
    let onDone: () -> Void
    let onStarterSaved: ((StarterWorkoutReceipt) -> Void)?
    @State private var page = 0
    @State private var selectedStarterID: String?
    @State private var showBaseline = false

    init(auth: AuthModel, showStarters: Bool = true,
         onStarterSaved: ((StarterWorkoutReceipt) -> Void)? = nil, onDone: @escaping () -> Void) {
        _model = StateObject(wrappedValue: TrainingSetupModel(auth: auth, defaults: auth.trainingSetupPersistence))
        self.showStarters = showStarters; self.onDone = onDone; self.onStarterSaved = onStarterSaved
    }

    var body: some View {
        NavigationStack {
            Form {
                if model.receipt != nil {
                    Section {
                        Label("Starter workout saved", systemImage: "checkmark.circle.fill")
                            .font(.title2.bold()).foregroundStyle(Theme.accent)
                        Text("Ready to review and start. You can edit it anytime in Workouts.")
                    }
                } else if !model.ready {
                    Section {
                        if model.busy { ProgressView("Loading your setup…") }
                        else { Button("Try again") { Task { await model.load() } } }
                    }
                } else {
                    if page == 0 { aboutYou }
                    if page == 1 { routine }
                    if page == 2 { workingWeights }
                    if page == 3 { preview }

                }
                if let error = model.error {
                    Section {
                        Text(error).foregroundStyle(Theme.danger).accessibilityIdentifier("trainingSetup.error")
                        if model.hasUnreadableDraft {
                            Button("Use saved profile") { Task { await model.load(discardDraft: true); page = 0 } }
                        } else if model.hasConflict && !model.hasUncertainAcceptance {
                            Button("Reload saved profile") { Task { await model.load(discardDraft: true); page = 0 } }
                        } else if model.hasUncertainAcceptance && page != 3 {
                            Button("Check saved workout") { Task { await model.load() } }
                        }
                    }
                }
                if page == 3 && model.receipt == nil {
                    Section { Button("Finish setup later", action: onDone) }
                }
            }
            // Each step starts with its own heading, even after scrolling a
            // long activity list at an accessibility text size.
            .id(model.receipt == nil ? page : 4)
            .disabled(model.busy)
            .safeAreaInset(edge: .bottom) {
                if model.receipt != nil {
                    Button(onStarterSaved == nil ? "Done" : "View workout") {
                        if let receipt = model.receipt, let onStarterSaved { onStarterSaved(receipt) }
                        else { onDone() }
                    }
                        .buttonStyle(WorkoutPrimaryButtonStyle())
                        .accessibilityIdentifier("trainingSetup.done")
                        .padding().background(Theme.background)
                } else if model.ready {
                    if page < 3 {
                        Button(model.busy ? "Saving…" : page < 2 ? "Next" : showStarters ? "Save & see workouts" : "Save profile") {
                            if page < 2 { page += 1 }
                            else {
                                Task {
                                    if await model.save(showStarters: showStarters) {
                                        if showStarters { page = 3; selectedStarterID = model.options?.workouts.first?.id }
                                        else { onDone() }
                                    }
                                }
                            }
                        }
                        .buttonStyle(WorkoutPrimaryButtonStyle())
                        .disabled(model.busy || model.hasConflict || model.hasUncertainAcceptance)
                        .accessibilityIdentifier("trainingSetup.next")
                        .padding().background(Theme.background)
                    } else if let options = model.options, options.can_accept,
                              let starter = options.workouts.first(where: { $0.id == selectedStarterID }) {
                        Button(model.busy ? "Saving…" : model.hasUncertainAcceptance ? "Retry saving this workout" : "Use this workout") {
                            Task { await model.accept(starter) }
                        }
                        .buttonStyle(WorkoutPrimaryButtonStyle())
                        .disabled(model.busy || model.hasConflict)
                        .accessibilityIdentifier("trainingSetup.accept")
                        .padding().background(Theme.background)
                    }
                }
            }
            .navigationTitle(showStarters ? "Your starting point" : "Training profile")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(model.receipt != nil ? "Close" : showStarters ? "Skip setup" : "Close") { model.cancel(); onDone() }
                        .accessibilityIdentifier("trainingSetup.skip")
                }
                if page > 0 && model.receipt == nil {
                    ToolbarItem(placement: .primaryAction) {
                        Button("Back") { page -= 1 }.disabled(model.busy || model.hasUncertainAcceptance)
                    }
                }
            }
        }
        .preferredColorScheme(.dark)
        .task { await model.load() }
        .onChange(of: model.receipt) { _, receipt in
            if let receipt, let onStarterSaved { onStarterSaved(receipt) }
        }
        .onDisappear { model.cancel() }
        .sheet(isPresented: $showBaseline) {
            BaselineEntryView { value in
                model.profile.baselines.removeAll { $0.exercise_id == value.exercise_id }
                model.profile.baselines.append(value)
            }
        }
    }

    private var aboutYou: some View {
        Group {
            Section("What would you like to work toward?") {
                Picker("Main goal", selection: $model.profile.goal) {
                    Text("Overall fitness & consistency").tag("general_fitness")
                    Text("Get stronger").tag("strength")
                    Text("Build muscle").tag("muscle")
                    Text("Support my other sports").tag("support_sport")
                }
            }
            Section {
                Text("Your activities").font(.headline)
                Text("Select all that apply. You can change these later.")
                    .font(.footnote).foregroundStyle(Theme.muted)
                ForEach(Self.activities, id: \.0) { id, title in
                    selection(title, id: id, values: $model.profile.activities)
                }
                TextField("Your usual week or next goal (optional)", text: $model.profile.activity_context, axis: .vertical)
                    .lineLimit(2...4).accessibilityIdentifier("trainingSetup.activityContext")
                    .onChange(of: model.profile.activity_context) { _, value in
                        if value.count > 300 { model.profile.activity_context = String(value.prefix(300)) }
                    }
            } footer: {
                Text("For example: two runs and a weekend swim.")
            }
        }
    }

    private var routine: some View {
        Group {
            Section("Make room for strength") {
                Picker("Lifting experience", selection: $model.profile.experience) {
                    Text("I’m new to lifting").tag("new")
                    Text("Returning after a break").tag("returning")
                    Text("I lift regularly").tag("regular")
                }
                Stepper("\(model.profile.strength_days) strength days per week", value: $model.profile.strength_days, in: 1...4)
                Picker("Time for a strength workout", selection: $model.profile.session_minutes) {
                    ForEach([15, 30, 45, 60], id: \.self) { Text("\($0) minutes").tag($0) }
                }
                Text("Choose workout dates later in Calendar.")
                    .font(.footnote).foregroundStyle(Theme.muted)
                Picker("Available equipment", selection: $model.profile.equipment) {
                    Text("Bodyweight & a stable raised surface").tag("bodyweight")
                    Text("Dumbbells & a stable raised surface").tag("dumbbells")
                    Text("Gym with machines, bench & dumbbells").tag("gym")
                }
            }
            Section {
                ForEach(Self.movements, id: \.0) { id, title in selection(title, id: id, values: $model.profile.avoid) }
            } header: { Text("Any movements you want to avoid? (optional)") }
            footer: { Text("Selected movements are left out of starters and shared with your connected coach. You can also skip or change individual exercises.") }
        }
    }

    private var workingWeights: some View {
        Group {
            Section {
                Text("Know a recent comfortable set?").font(.headline)
                Text("Optional. Add working sets you remember; no maximum tests needed.")
                ForEach(model.profile.baselines) { baseline in
                    VStack(alignment: .leading, spacing: 6) {
                        Text(TrainingProfile.baselineExercises.first { $0.id == baseline.exercise_id }?.name ?? baseline.exercise_id)
                        Text("\(baseline.weight, specifier: "%g") \(baseline.unit) × \(baseline.reps) · \(baseline.effort)")
                            .font(.footnote)
                        Button("Remove", role: .destructive) { model.profile.baselines.removeAll { $0.id == baseline.id } }
                    }
                }
                if model.profile.baselines.count < 5 {
                    Button("Add a working set") { showBaseline = true }.accessibilityIdentifier("trainingSetup.addBaseline")
                }
            } footer: {
                Text("These are self-reported starting points for your coach. You’ll choose your starter loads in the workout.")
            }
            Section {
                Text("Private to you and the coach you connect. Your group does not see these answers. Edit them later in Profile → Training profile.")
                    .font(.footnote)
            }
        }
    }

    @ViewBuilder private var preview: some View {
        if let options = model.options, !options.can_accept {
            Section {
                Text("Your training profile is saved")
                Text("Open your workout library to choose or create a workout. Starter selection is available before your first workout is added.")
                Button("Done", action: onDone)
            }
        } else if let options = model.options, options.workouts.isEmpty {
            Section {
                Text("Your preferences need a custom workout")
                Text("Your answers are saved. Build your own workout or connect your coach to choose exercises that fit.")
                Button("Continue", action: onDone)
            }
        } else if let options = model.options {
            Section("Choose a starting workout") {
                ForEach(options.workouts) { starter in
                    Button {
                        selectedStarterID = starter.id
                    } label: {
                        HStack {
                            Text(starter.name)
                            Spacer()
                            if selectedStarterID == starter.id { Image(systemName: "checkmark.circle.fill") }
                        }
                    }.disabled(model.hasUncertainAcceptance)
                }
                Text("Matched to your equipment. Every workout is editable.")
                    .font(.footnote).foregroundStyle(Theme.muted)
            }
            if let starter = options.workouts.first(where: { $0.id == selectedStarterID }) {
                Section {
                    Text(starter.explanation)
                    ForEach(starter.exercises) { slot in
                        VStack(alignment: .leading, spacing: 6) {
                            Text(slot.name).font(.headline)
                            Text("\(slot.sets) set\(slot.sets == 1 ? "" : "s") × \(slot.reps) reps · Choose a comfortable load")
                            Text(slot.cues).font(.footnote).foregroundStyle(Theme.muted)
                        }.padding(.vertical, 4)
                    }
                    Text("Choose a comfortable load when you start. Weighted exercises begin at 0.")
                        .font(.footnote)

                }
            }
        }
    }

    private func selection(_ title: String, id: String, values: Binding<[String]>) -> some View {
        Toggle(title, isOn: Binding(get: { values.wrappedValue.contains(id) }, set: { selected in
            values.wrappedValue.removeAll { $0 == id }
            if selected { values.wrappedValue.append(id) }
        })).accessibilityIdentifier("trainingSetup.\(id)")
    }
    static let activities = [("weightlifting", "Weightlifting"), ("running", "Running"), ("swimming", "Swimming"),
                             ("cycling", "Cycling"), ("walking", "Walking / hiking"), ("yoga", "Yoga / mobility"), ("other", "Other activities")]
    static let movements = [("squat", "Squatting / leg press"), ("hinge", "Hip hinges / deadlifts"),
                            ("push", "Pressing / push-ups"), ("pull", "Rows / pulldowns"), ("core", "Core exercises")]
}

private struct BaselineEntryView: View {
    let onSave: (TrainingProfile.Baseline) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var exerciseID = "ex_goblet_squat"
    @State private var weight = ""
    @State private var unit = "lb"
    @State private var reps = 8
    @State private var effort = "moderate"
    @State private var date = Date()
    private var numericWeight: Double? { Double(weight.replacingOccurrences(of: ",", with: ".")) }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Picker("Exercise", selection: $exerciseID) {
                        ForEach(TrainingProfile.baselineExercises, id: \.id) { Text($0.name).tag($0.id) }
                    }
                    Text(TrainingProfile.baselineExercises.first { $0.id == exerciseID }?.load ?? "")
                        .font(.footnote)
                    TextField("Weight", text: $weight).keyboardType(.decimalPad).accessibilityIdentifier("trainingSetup.baselineWeight")
                    Picker("Unit", selection: $unit) { Text("lb").tag("lb"); Text("kg").tag("kg") }.pickerStyle(.segmented)
                    Stepper("\(reps) reps", value: $reps, in: 1...30)
                    Picker("How did it feel?", selection: $effort) {
                        Text("Easy").tag("easy"); Text("Moderate").tag("moderate"); Text("Hard").tag("hard")
                    }
                    DatePicker("When was this set?", selection: $date, in: ...Date(), displayedComponents: .date)
                }

            }
            .navigationTitle("A recent working set").navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        guard let value = numericWeight else { return }
                        onSave(.init(exercise_id: exerciseID, weight: value, unit: unit, reps: reps, effort: effort,
                                     performed_at: floor(date.timeIntervalSince1970 * 1000)))
                        dismiss()
                    }.disabled(numericWeight == nil || !(0...1500).contains(numericWeight ?? -1))
                        .accessibilityIdentifier("trainingSetup.saveBaseline")
                }
            }
        }
    }
}
