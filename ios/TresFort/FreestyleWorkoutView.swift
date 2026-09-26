import SwiftUI

struct FreestyleExercisePicker: View {
    @ObservedObject var sync: SyncModel
    var starting = false
    var onStarted: (() -> Void)? = nil
    @Environment(\.dismiss) private var dismiss
    @State private var saving = false

    var body: some View {
        NavigationStack {
            ExercisePickerList(sync: sync) { exercise in
                Button {
                    saving = true
                    Task {
                        if starting { await RestCue.requestNotificationPermissionIfNeeded() }
                        let accepted = starting ? await sync.startFreestyleWorkout(with: exercise)
                            : sync.addFreestyleExercise(exercise)
                        saving = false
                        if accepted { dismiss(); onStarted?() }
                    }
                } label: {
                    HStack { ExerciseCatalogLabel(exercise: exercise); Spacer(); Image(systemName: "plus.circle") }
                        .frame(minHeight: 44).contentShape(Rectangle())
                }
                .disabled(saving)
                .accessibilityIdentifier("freestyle.exercise.\(exercise.id)")
            }
            .navigationTitle(starting ? "Start freestyle" : "Add an exercise")
            .navigationBarTitleDisplayMode(.inline)
            .safeAreaInset(edge: .bottom) {
                VStack(alignment: .leading, spacing: 8) {
                    Text(starting ? "Choose your first exercise. Add more as you go; your saved workouts stay unchanged."
                         : "Choose another exercise, or return to one already in this session.")
                    if let error = sync.loadError { Text(error).foregroundStyle(Theme.danger) }
                }.font(.footnote).padding().frame(maxWidth: .infinity, alignment: .leading).background(Theme.surface)
            }
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() }.disabled(saving) } }
        }
        .interactiveDismissDisabled(saving)
        .preferredColorScheme(.dark)
    }
}

struct SaveFreestyleWorkoutView: View {
    @ObservedObject var sync: SyncModel
    let session: SessionRow
    @Environment(\.dismiss) private var dismiss
    @State private var draft: FreestyleWorkoutDraft?
    @State private var sourceSlots: [FreestyleSlot] = []
    @State private var name = ""
    @State private var saving = false
    @State private var request: SaveFreestyleRequest?

    var body: some View {
        NavigationStack {
            Form {
                Section("Workout name") {
                    TextField("Workout name", text: $name).accessibilityIdentifier("freestyle.name").disabled(request != nil)
                }
                Section {
                    Text("Review these targets before saving. Sets are grouped by exercise, reps or time, and the exact load you used. Warm-ups are excluded.")
                    Text("Reps and duration start at the middle observed value for that group. The new workout will be unscheduled.")
                }
                if let draft {
                    ForEach(draft.slots.indices, id: \.self) { index in
                        slotSection(index, slot: draft.slots[index])
                    }
                    if draft.slots.isEmpty { Text("Log at least one working set before saving a workout.") }
                } else {
                    ProgressView("Loading recorded sets…")
                }
                if let error = sync.loadError { Text(error).foregroundStyle(Theme.danger) }
                Button(saving ? "Saving…" : request == nil ? "Save workout" : "Retry save") {
                    Task { await save() }
                }
                .disabled(saving || draft?.slots.isEmpty != false || name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                .accessibilityIdentifier("freestyle.save")
            }
            .disabled(saving)
            .navigationTitle("Save as workout")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() }.disabled(saving) } }
            .task {
                name = "Freestyle · \(session.date)"
                draft = await sync.loadFreestyleDraft(sessionID: session.id)
                sourceSlots = draft?.slots ?? []
            }
        }
        .interactiveDismissDisabled(saving)
        .preferredColorScheme(.dark)
    }

    @ViewBuilder private func slotSection(_ index: Int, slot: FreestyleSlot) -> some View {
        Section(sync.exerciseName(slot.exercise_id)) {
            Text("From \(sourceSlots[index].source_set_ids?.count ?? sourceSlots[index].target_sets) working sets at \(sourceSlots[index].target_weight.formatted()) \((WeightUnit(rawValue: sync.catalogRow(slot.exercise_id)?.unit ?? "") ?? .lb).rawValue)")
                .font(.caption).foregroundStyle(Theme.muted)
            Stepper("Sets: \(slot.target_sets)", value: binding(index, \.target_sets), in: 1...100)
            if slot.target_duration_s != nil {
                Stepper("Seconds: \(slot.target_duration_s ?? 1)", value: Binding(
                    get: { self.draft?.slots[index].target_duration_s ?? 1 },
                    set: { self.draft?.slots[index].target_duration_s = $0 }), in: 1...7200)
            } else {
                Stepper("Reps: \(slot.target_reps)", value: binding(index, \.target_reps), in: 1...1000)
            }
            HStack {
                Text("Load (\((WeightUnit(rawValue: sync.catalogRow(slot.exercise_id)?.unit ?? "") ?? .lb).rawValue))")
                TextField("Load", value: binding(index, \.target_weight), format: .number)
                    .keyboardType(.numbersAndPunctuation).multilineTextAlignment(.trailing)
            }
            Stepper("Rest: \(slot.rest_seconds)s", value: binding(index, \.rest_seconds), in: 0...1800, step: 15)
        }
        .disabled(request != nil)
    }

    private func binding<Value>(_ index: Int, _ key: WritableKeyPath<FreestyleSlot, Value>) -> Binding<Value> {
        Binding(get: { draft!.slots[index][keyPath: key] }, set: { draft?.slots[index][keyPath: key] = $0 })
    }

    private func save() async {
        guard let draft, let plan = sync.plan else { return }
        if request == nil {
            request = SaveFreestyleRequest(workout_id: UUID().uuidString, name: name,
                expected_plan_id: plan.id, expected_version: plan.version,
                expected_attempt: draft.session.attempt ?? 0,
                source_signature: draft.source_signature, slots: draft.slots)
        }
        guard let request else { return }
        saving = true
        defer { saving = false }
        let saved = await sync.saveFreestyleWorkout(sessionID: session.id, request: request)
        if saved { dismiss() }
        else if sync.freestyleSaveNeedsReview {
            self.request = nil
            self.draft = await sync.loadFreestyleDraft(sessionID: session.id)
            sourceSlots = self.draft?.slots ?? []
        }
    }
}
