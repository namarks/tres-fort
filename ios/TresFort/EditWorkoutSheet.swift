import SwiftUI

private struct ExerciseEditTarget: Identifiable {
    let exercise: TemplateExercise
    var id: String { exercise.id }
}

/// In-app workout editor (#1/#2). Lets you add / remove / reorder exercises in
/// today's workout — including a prescribed warm-up (e.g. a 5-min erg) — without
/// going to Claude. It edits the active plan's DAY TEMPLATE via the REST editor
/// endpoints, so a change shows up immediately and (for a warm-up) recurs on
/// that day. The member and coach share this one prescription; either can make
/// a later change without creating a separate manual-only workout.
///
/// Reads the live day off `sync` by id (not a captured snapshot) so the list
/// reflects edits the moment `sync.load()` returns.
struct EditWorkoutSheet: View {
    @ObservedObject var sync: SyncModel
    let dayID: String
    @Environment(\.dismiss) private var dismiss
    @State private var adding = false
    @State private var addPresetWarmup = false
    @State private var editingExercise: ExerciseEditTarget?

    private var day: DayTemplate? { sync.dayTemplate(id: dayID) }

    var body: some View {
        NavigationStack {
            Group {
                if let day, !day.exercises.isEmpty {
                    list(day)
                } else {
                    emptyState
                }
            }
            .background(Theme.background)
            .navigationTitle("Edit workout")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Done") { dismiss() }.foregroundStyle(Theme.accent)
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Menu {
                        Button { addPresetWarmup = false; adding = true } label: {
                            Label("Add exercise", systemImage: "plus")
                        }
                        Button { addPresetWarmup = true; adding = true } label: {
                            Label("Add warm-up", systemImage: "flame")
                        }
                    } label: {
                        Image(systemName: "plus.circle.fill").foregroundStyle(Theme.accent)
                    }
                }
            }
            .toolbarColorScheme(.dark, for: .navigationBar)
            .sheet(isPresented: $adding) {
                AddExerciseSheet(sync: sync, dayID: dayID, presetWarmup: addPresetWarmup)
            }
            .sheet(item: $editingExercise) { target in
                NavigationStack {
                    EditExerciseTargetView(
                        sync: sync,
                        dayID: dayID,
                        slot: target.exercise)
                }
            }
        }
        .preferredColorScheme(.dark)
    }

    private func list(_ day: DayTemplate) -> some View {
        List {
            ForEach(day.exercises) { ex in
                Button {
                    editingExercise = ExerciseEditTarget(exercise: ex)
                } label: {
                    HStack(spacing: 10) {
                        VStack(alignment: .leading, spacing: 3) {
                            Text(ex.exercise_name)
                                .font(Theme.mono(15, .bold))
                                .foregroundStyle(Theme.text)
                            Text("\(ex.targetLabel) · \(ex.rest_seconds)s rest")
                                .font(Theme.mono(12))
                                .foregroundStyle(Theme.muted)
                        }
                        Spacer()
                        if ex.isWarmup { WarmupTag() }
                        Image(systemName: "chevron.right")
                            .font(.system(size: 11, weight: .bold))
                            .foregroundStyle(Theme.dim)
                    }
                }
                .buttonStyle(.plain)
                .listRowBackground(Theme.surface)
            }
            .onDelete { offsets in
                guard let i = offsets.first else { return }
                let teID = day.exercises[i].id
                Task { await sync.deleteSlot(dayID: dayID, teID: teID) }
            }
            .onMove { offsets, newOffset in
                var arr = day.exercises
                arr.move(fromOffsets: offsets, toOffset: newOffset)
                guard let src = offsets.first else { return }
                let movedID = day.exercises[src].id
                guard let newIndex = arr.firstIndex(where: { $0.id == movedID }) else { return }
                Task { await sync.moveSlot(dayID: dayID, teID: movedID, toIndex: newIndex) }
            }
        }
        .scrollContentBackground(.hidden)
        .environment(\.editMode, .constant(.active))
    }

    private var emptyState: some View {
        VStack(spacing: 10) {
            Text("NO EXERCISES YET")
                .font(Theme.display(24)).foregroundStyle(Theme.text)
            Text("Use ＋ to add an exercise or a warm-up.")
                .font(Theme.mono(13)).foregroundStyle(Theme.muted)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

/// Small "WARM-UP" pill used wherever a warm-up slot is shown.
struct WarmupTag: View {
    var body: some View {
        Text("WARM-UP")
            .font(Theme.mono(9, .bold)).tracking(1)
            .foregroundStyle(Theme.accent)
            .padding(.horizontal, 8).padding(.vertical, 4)
            .background(Theme.accent.opacity(0.15))
            .clipShape(Capsule())
    }
}

// MARK: - Add exercise (catalog picker → configure → add)

private struct AddExerciseSheet: View {
    @ObservedObject var sync: SyncModel
    let dayID: String
    let presetWarmup: Bool
    @Environment(\.dismiss) private var dismiss
    @State private var query = ""

    private var filtered: [ExerciseCatalog] {
        let all = sync.catalog.sorted { $0.name < $1.name }
        let q = query.trimmingCharacters(in: .whitespaces).lowercased()
        guard !q.isEmpty else { return all }
        return all.filter {
            $0.name.lowercased().contains(q) || $0.primary_muscle.lowercased().contains(q)
        }
    }

    var body: some View {
        NavigationStack {
            List(filtered) { ex in
                NavigationLink {
                    ConfigureExerciseView(
                        sync: sync, dayID: dayID, exercise: ex,
                        presetWarmup: presetWarmup, onDone: { dismiss() })
                } label: {
                    VStack(alignment: .leading, spacing: 3) {
                        Text(ex.name).font(Theme.mono(14, .bold)).foregroundStyle(Theme.text)
                        Text("\(ex.primary_muscle) · \(ex.modality)")
                            .font(Theme.mono(11)).foregroundStyle(Theme.muted)
                    }
                }
                .listRowBackground(Theme.surface)
            }
            .scrollContentBackground(.hidden)
            .background(Theme.background)
            .searchable(text: $query, prompt: "Search exercises (try “erg”)")
            .navigationTitle(presetWarmup ? "Add warm-up" : "Add exercise")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Cancel") { dismiss() }.foregroundStyle(Theme.muted)
                }
            }
            .toolbarColorScheme(.dark, for: .navigationBar)
        }
        .preferredColorScheme(.dark)
    }
}

private struct ConfigureExerciseView: View {
    private enum TargetMode: String, CaseIterable {
        case reps = "Reps"
        case hold = "Hold"
    }

    // Plain reference (not @ObservedObject): this view only *triggers* an edit
    // and dismisses; it doesn't re-render off sync's published state, so it
    // needs no observation — which also keeps the custom init wrapper-free.
    let sync: SyncModel
    let dayID: String
    let exercise: ExerciseCatalog
    let presetWarmup: Bool
    let onDone: () -> Void

    @State private var isWarmup: Bool
    @State private var sets = 3
    @State private var reps = 8
    @State private var repsMax = 12
    @State private var usesRepRange = false
    @State private var minutes = 5
    @State private var seconds = 45
    @State private var restSeconds = 120
    @State private var working = false
    @State private var targetMode: TargetMode

    init(sync: SyncModel, dayID: String, exercise: ExerciseCatalog,
         presetWarmup: Bool, onDone: @escaping () -> Void) {
        self.sync = sync
        self.dayID = dayID
        self.exercise = exercise
        self.presetWarmup = presetWarmup
        self.onDone = onDone
        _isWarmup = State(initialValue: presetWarmup)
        _targetMode = State(initialValue: exercise.modality == "timed" ? .hold : .reps)
    }

    /// Cardio ergs (rowing/bike/ski, treadmill) are logged by minutes.
    private var isCardio: Bool { exercise.modality == "cardio" }
    /// Timed catalog rows are intrinsically holds. Until the slot schema has
    /// an explicit modality override, offering Reps would still execute them
    /// as seconds in TemplateExercise.isTimed.
    private var canChooseMeasure: Bool {
        ExercisePrescriptionPolicy.canChooseMeasure(for: exercise.modality)
    }
    private var isHold: Bool {
        exercise.modality == "timed" || targetMode == .hold
    }

    var body: some View {
        Form {
            Section {
                Toggle("Warm-up", isOn: $isWarmup)
                    .tint(Theme.accent)
            } footer: {
                Text("Warm-up sets stay out of your working-set totals and session intensity.")
            }

            if isCardio {
                Section("Duration") {
                    Stepper("\(minutes) min", value: $minutes, in: 1...60)
                }
            } else if canChooseMeasure {
                Section("Measure") {
                    Picker("Measure", selection: $targetMode) {
                        ForEach(TargetMode.allCases, id: \.self) { mode in
                            Text(mode.rawValue).tag(mode)
                        }
                    }
                    .pickerStyle(.segmented)
                }
            }

            if !isCardio && isHold {
                Section("Hold") {
                    Stepper("\(sets) set\(sets == 1 ? "" : "s")", value: $sets, in: 1...10)
                    Stepper("\(seconds)s each", value: $seconds, in: 5...300, step: 5)
                }
            } else if !isCardio {
                Section("Target") {
                    Stepper("\(sets) set\(sets == 1 ? "" : "s")", value: $sets, in: 1...10)
                    Stepper(usesRepRange ? "\(reps) reps minimum" : "\(reps) reps",
                            value: $reps, in: 1...30)
                    Toggle("Rep range", isOn: $usesRepRange)
                        .tint(Theme.accent)
                    if usesRepRange {
                        Stepper("Up to \(max(reps, repsMax)) reps",
                                value: Binding(
                                    get: { max(reps, repsMax) },
                                    set: { repsMax = max(reps, $0) }),
                                in: reps...30)
                    }
                }
            }

            Section("Rest between sets") {
                Stepper("\(restSeconds)s", value: $restSeconds, in: 0...600, step: 15)
            }

            Section {
                Button {
                    Task {
                        working = true
                        let durationS: Int? = isCardio ? minutes * 60 : (isHold ? seconds : nil)
                        let targetRepsMax = !isCardio && !isHold && usesRepRange
                            ? max(reps, repsMax)
                            : nil
                        let saved = await sync.addExerciseToDay(
                            dayID,
                            exercise: exercise.id,
                            isWarmup: isWarmup,
                            targetSets: isCardio ? 1 : sets,
                            targetReps: isCardio ? 1 : (isHold ? seconds : reps),
                            targetRepsMax: targetRepsMax,
                            restSeconds: restSeconds,
                            targetDurationS: durationS)
                        working = false
                        if saved { onDone() }
                    }
                } label: {
                    Text(working ? "Adding…" : "Add to workout")
                        .font(Theme.mono(15, .bold))
                        .frame(maxWidth: .infinity)
                }
                .disabled(working)
            }

            if let error = sync.loadError {
                Section { Text(error).foregroundStyle(Theme.danger) }
            }
        }
        .scrollContentBackground(.hidden)
        .background(Theme.background)
        .navigationTitle(exercise.name)
        .navigationBarTitleDisplayMode(.inline)
        .tint(Theme.accent)
    }
}

enum ExercisePrescriptionPolicy {
    static let ordinaryRepUpperBound = 1_000

    static func canChooseMeasure(for modality: String) -> Bool {
        modality != "timed" && modality != "cardio"
    }

    static func initialEditableReps(
        targetReps: Int,
        isTimed: Bool,
        modality: String
    ) -> Int {
        if isTimed, canChooseMeasure(for: modality) { return 8 }
        return max(1, targetReps)
    }

    static func editableRepUpperBound(
        reps: Int,
        repsMax: Int?
    ) -> Int {
        max(ordinaryRepUpperBound, reps, repsMax ?? 0)
    }
}

// MARK: - Edit an existing prescription

private struct EditExerciseTargetView: View {
    @ObservedObject var sync: SyncModel
    let dayID: String
    let slot: TemplateExercise
    @Environment(\.dismiss) private var dismiss

    @State private var isWarmup: Bool
    @State private var sets: Int
    @State private var reps: Int
    @State private var repsMax: Int
    @State private var usesRepRange: Bool
    @State private var usesHold: Bool
    @State private var seconds: Int
    @State private var restSeconds: Int
    @State private var working = false
    private let repUpperBound: Int

    init(sync: SyncModel, dayID: String, slot: TemplateExercise) {
        self.sync = sync
        self.dayID = dayID
        self.slot = slot
        let initialReps = ExercisePrescriptionPolicy.initialEditableReps(
            targetReps: slot.target_reps,
            isTimed: slot.isTimed,
            modality: slot.exercise_modality)
        let initialRepsMax = slot.isTimed
            ? initialReps
            : max(initialReps, slot.target_reps_max ?? initialReps)
        self.repUpperBound = ExercisePrescriptionPolicy.editableRepUpperBound(
            reps: initialReps,
            repsMax: initialRepsMax)
        _isWarmup = State(initialValue: slot.isWarmup)
        _sets = State(initialValue: max(1, slot.target_sets))
        _reps = State(initialValue: initialReps)
        _repsMax = State(initialValue: initialRepsMax)
        _usesRepRange = State(initialValue: !slot.isTimed && slot.target_reps_max != nil)
        _usesHold = State(initialValue: slot.isTimed)
        _seconds = State(initialValue: slot.holdSeconds)
        _restSeconds = State(initialValue: max(0, slot.rest_seconds))
    }

    private var isCardio: Bool { slot.exercise_modality == "cardio" }
    private var intrinsicallyTimed: Bool { slot.exercise_modality == "timed" }
    private var canChooseMeasure: Bool {
        ExercisePrescriptionPolicy.canChooseMeasure(for: slot.exercise_modality)
    }
    private var isHold: Bool { intrinsicallyTimed || usesHold }
    private var durationText: String {
        let minutes = seconds / 60
        let remainder = seconds % 60
        if minutes == 0 { return "\(seconds)s" }
        if remainder == 0 { return "\(minutes) min" }
        return "\(minutes)m \(remainder)s"
    }

    var body: some View {
        Form {
            Section {
                Toggle("Warm-up", isOn: $isWarmup).tint(Theme.accent)
            } footer: {
                Text("Warm-up sets stay out of working-set totals and session intensity.")
            }

            if isCardio {
                Section("Duration") {
                    Stepper("\(sets) set\(sets == 1 ? "" : "s")", value: $sets, in: 1...10)
                    Stepper(durationText, value: $seconds, in: 1...7_200, step: 15)
                }
            } else if canChooseMeasure {
                Section("Measure") {
                    Picker("Measure", selection: $usesHold) {
                        Text("Reps").tag(false)
                        Text("Hold").tag(true)
                    }
                    .pickerStyle(.segmented)
                }
            }

            if !isCardio && isHold {
                Section("Hold") {
                    Stepper("\(sets) set\(sets == 1 ? "" : "s")", value: $sets, in: 1...10)
                    Stepper("\(seconds)s each", value: $seconds, in: 1...7_200, step: 5)
                }
            } else if !isCardio {
                Section("Target") {
                    Stepper("\(sets) set\(sets == 1 ? "" : "s")", value: $sets, in: 1...10)
                    Stepper(usesRepRange ? "\(reps) reps minimum" : "\(reps) reps",
                            value: $reps, in: 1...repUpperBound)
                    Toggle("Rep range", isOn: $usesRepRange).tint(Theme.accent)
                    if usesRepRange {
                        Stepper(
                            "Up to \(max(reps, repsMax)) reps",
                            value: Binding(
                                get: { max(reps, repsMax) },
                                set: { repsMax = max(reps, $0) }),
                            in: reps...repUpperBound)
                    }
                }
            }

            Section("Rest between sets") {
                Stepper("\(restSeconds)s", value: $restSeconds, in: 0...600, step: 15)
            }

            Section {
                Button {
                    save()
                } label: {
                    Text(working ? "Saving…" : "Save targets")
                        .font(Theme.mono(15, .bold))
                        .frame(maxWidth: .infinity)
                }
                .disabled(working)
            }

            if let error = sync.loadError {
                Section { Text(error).foregroundStyle(Theme.danger) }
            }
        }
        .scrollContentBackground(.hidden)
        .background(Theme.background)
        .navigationTitle(slot.exercise_name)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarLeading) {
                Button("Cancel") { dismiss() }.foregroundStyle(Theme.muted)
            }
        }
        .toolbarColorScheme(.dark, for: .navigationBar)
        .tint(Theme.accent)
    }

    private func save() {
        working = true
        Task {
            let durationS: Int? = (isCardio || isHold) ? seconds : nil
            let rangeMax = !isCardio && !isHold && usesRepRange
                ? max(reps, repsMax)
                : nil
            let saved = await sync.updateSlot(
                dayID: dayID,
                teID: slot.id,
                isWarmup: isWarmup,
                targetSets: sets,
                targetReps: isCardio ? slot.target_reps : (isHold ? seconds : reps),
                targetRepsMax: rangeMax,
                restSeconds: restSeconds,
                targetDurationS: durationS)
            working = false
            if saved { dismiss() }
        }
    }
}
