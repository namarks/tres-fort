import SwiftUI

private struct ExerciseEditTarget: Identifiable {
    let exercise: TemplateExercise
    var id: String { exercise.id }
}

private struct ExerciseGroupEditTarget: Identifiable {
    let id: String
    let members: [TemplateExercise]
    let version: Int
    let isExisting: Bool
}

private struct ExerciseReplacementTarget: Identifiable {
    let exercise: TemplateExercise
    let version: Int
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
    var onDone: (() -> Void)? = nil
    @Environment(\.dismiss) private var dismiss
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @State private var adding = false
    @State private var addPresetWarmup = false
    @State private var editingExercise: ExerciseEditTarget?
    @State private var replacingExercise: ExerciseReplacementTarget?
    @State private var refreshing = false
    @State private var selectingGroup = false
    @State private var selectedSlots: Set<String> = []
    @State private var editingGroup: ExerciseGroupEditTarget?
    @State private var mutationWorking = false

    private var day: Workout? { sync.workout(id: dayID) }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                if day != nil {
                    Text("Edits apply to this saved workout whenever you use it. Completed records stay unchanged.")
                        .font(.footnote).foregroundStyle(Theme.muted)
                        .padding(.horizontal, 16).padding(.vertical, 10)
                }
                if day == nil || sync.workoutEditorRefreshNeeded {
                    refreshError(sync.loadError)
                }
                Group {
                    if let day, !day.exercises.isEmpty {
                        list(day)
                    } else {
                        emptyState
                    }
                }
                .disabled(day == nil || sync.workoutEditorRefreshNeeded || mutationWorking)
            }
            .background(Theme.background)
            .navigationTitle(day.map { "Edit \($0.name)" } ?? "Workout unavailable")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Done") { if let onDone { onDone() } else { dismiss() } }.foregroundStyle(Theme.accent)
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Menu {
                        Button { addPresetWarmup = false; adding = true } label: {
                            Label("Add exercise", systemImage: "plus")
                        }
                        Button { addPresetWarmup = true; adding = true } label: {
                            Label("Add warm-up", systemImage: "flame")
                        }
                        Button {
                            selectedSlots = []
                            selectingGroup = true
                        } label: {
                            Label("Select exercises", systemImage: "checkmark.circle")
                        }
                    } label: {
                        Image(systemName: "plus.circle.fill").foregroundStyle(Theme.accent)
                    }
                    .accessibilityLabel("Workout actions")
                    .accessibilityIdentifier("editor.actions")
                    .disabled(day == nil || sync.workoutEditorRefreshNeeded || mutationWorking || selectingGroup)
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
            .sheet(item: $replacingExercise) { target in
                ReplaceExerciseSheet(sync: sync, dayID: dayID, target: target)
            }
            .sheet(item: $editingGroup) { target in
                EditExerciseGroupSheet(sync: sync, dayID: dayID, target: target)
            }
            .safeAreaInset(edge: .bottom) {
                if selectingGroup { selectionBar }
            }
            .onChange(of: sync.plan?.version) {
                selectedSlots = []
                selectingGroup = false
            }
        }
        .preferredColorScheme(.dark)
    }

    private func refreshError(_ error: String?) -> some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 3) {
                Text("Workout details may be out of date.")
                    .font(Theme.mono(12, .bold))
                    .foregroundStyle(Theme.danger)
                Text(error ?? "Refresh to load the latest workout details.")
                    .font(Theme.mono(11))
                    .foregroundStyle(Theme.muted)
                    .lineLimit(2)
            }
            Spacer(minLength: 8)
            Button(refreshing ? "Refreshing…" : "Refresh") {
                refreshing = true
                Task {
                    await sync.load()
                    refreshing = false
                }
            }
            .font(Theme.mono(12, .bold))
            .foregroundStyle(Theme.accent)
            .disabled(refreshing)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(Theme.surface)
        .accessibilityIdentifier("editWorkoutRefreshError")
    }

    private var selectionBar: some View {
        let actionsLayout = dynamicTypeSize.isAccessibilitySize
            ? AnyLayout(VStackLayout(alignment: .leading, spacing: 8)) : AnyLayout(HStackLayout())
        return VStack(spacing: 8) {
            Text("Choose two or more adjacent exercises.")
                .font(Theme.mono(12)).foregroundStyle(Theme.muted)
            actionsLayout {
                Button("Cancel selection") { selectingGroup = false; selectedSlots = [] }
                    .foregroundStyle(Theme.muted)
                    .frame(minHeight: 44)
                if !dynamicTypeSize.isAccessibilitySize { Spacer() }
                Button("Group as superset") {
                    guard let plan = sync.plan, let day,
                          let members = ExerciseGroupBlock.selectedMembers(selectedSlots, in: day.exercises) else { return }
                    editingGroup = ExerciseGroupEditTarget(id: UUID().uuidString,
                        members: members, version: plan.version, isExisting: false)
                }
                .font(Theme.mono(13, .bold)).foregroundStyle(Theme.accent)
                .frame(minHeight: 44)
                .disabled(day.flatMap { ExerciseGroupBlock.selectedMembers(selectedSlots, in: $0.exercises) } == nil
                          || sync.workoutEditorRefreshNeeded)
            }
            .frame(minHeight: 44)
        }
        .padding(16).background(Theme.surface)
    }

    private func list(_ day: Workout) -> some View {
        let blocks = ExerciseGroupBlock.blocks(day.exercises)
        return List {
            ForEach(blocks) { block in
                if block.isGroup {
                    groupCard(block)
                        .deleteDisabled(true)
                        .moveDisabled(selectingGroup)
                        .listRowBackground(Theme.surface)
                } else {
                    exerciseRow(block.members[0])
                        .deleteDisabled(selectingGroup)
                        .moveDisabled(selectingGroup)
                        .listRowBackground(Theme.surface)
                }
            }
            .onDelete { offsets in
                guard let i = offsets.first, !blocks[i].isGroup else { return }
                removeSlot(blocks[i].members[0].id)
            }
            .onMove { offsets, newOffset in
                guard let source = offsets.first, offsets.count == 1, let version = sync.plan?.version else { return }
                let moved = blocks[source]
                var reordered = blocks
                reordered.move(fromOffsets: offsets, toOffset: newOffset)
                guard let destination = ExerciseGroupBlock.slotDestination(of: moved.id, in: reordered),
                      destination != ExerciseGroupBlock.slotDestination(of: moved.id, in: blocks) else { return }
                mutationWorking = true
                Task {
                    if let groupID = moved.groupID {
                        _ = await sync.saveExerciseGroup(dayID: dayID, groupID: groupID,
                            memberIDs: moved.members.map(\.id), expectedVersion: version,
                            roundRest: moved.roundRest, transitionRest: moved.transitionRest,
                            targetSets: moved.rounds, orderIndex: destination)
                    } else {
                        await sync.moveSlot(dayID: dayID, teID: moved.members[0].id, toIndex: destination)
                    }
                    mutationWorking = false
                }
            }
            if let error = sync.loadError, !sync.workoutEditorRefreshNeeded {
                Text(error).font(Theme.mono(12)).foregroundStyle(Theme.danger)
            }
        }
        .scrollContentBackground(.hidden)
        .environment(\.editMode, .constant(selectingGroup ? .inactive : .active))
    }

    private func groupCard(_ block: ExerciseGroupBlock) -> some View {
        let headerLayout = dynamicTypeSize.isAccessibilitySize
            ? AnyLayout(VStackLayout(alignment: .leading, spacing: 8)) : AnyLayout(HStackLayout())
        return VStack(alignment: .leading, spacing: 12) {
            headerLayout {
                Text(block.title).font(Theme.mono(16, .bold)).foregroundStyle(Theme.accent)
                    .accessibilityIdentifier("editor.group.\(block.letter ?? "")")
                if block.isWarmup { WarmupTag() }
                if !dynamicTypeSize.isAccessibilitySize { Spacer(minLength: 8) }
                Button {
                    guard let version = sync.plan?.version, let groupID = block.groupID else { return }
                    editingGroup = ExerciseGroupEditTarget(id: groupID, members: block.members,
                        version: version, isExisting: true)
                } label: {
                    Text("Edit group")
                        .font(Theme.mono(12, .bold)).foregroundStyle(Theme.accent)
                        .frame(minHeight: 44)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Edit \(block.title)")
                .disabled(selectingGroup)
            }
            VStack(alignment: .leading, spacing: 4) {
                Text("\(block.rounds) rounds")
                Text("Round rest: \(block.roundRest)s")
                Text("Transition rest: \(block.transitionRest)s")
            }
            .font(Theme.mono(12)).foregroundStyle(Theme.muted)
            ForEach(Array(block.members.enumerated()), id: \.element.id) { index, member in
                if index > 0 { Divider().overlay(Theme.dim.opacity(0.3)) }
                exerciseRow(member, label: block.memberLabel(at: index))
            }
        }
        .padding(.vertical, 6)
    }

    private func exerciseRow(_ ex: TemplateExercise, label: String? = nil) -> some View {
        HStack(spacing: 8) {
            if selectingGroup && ex.group_id == nil {
                Button {
                    if selectedSlots.contains(ex.id) { selectedSlots.remove(ex.id) }
                    else { selectedSlots.insert(ex.id) }
                } label: {
                    Image(systemName: selectedSlots.contains(ex.id) ? "checkmark.circle.fill" : "circle")
                        .foregroundStyle(Theme.accent).frame(width: 44, height: 44)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Select \(ex.exercise_name)")
                .accessibilityValue(selectedSlots.contains(ex.id) ? "Selected" : "Not selected")
                .accessibilityIdentifier("editor.select.\(ex.id)")
            }
            Button {
                editingExercise = ExerciseEditTarget(exercise: ex)
            } label: {
                HStack(spacing: 10) {
                    if let label { Text(label).font(Theme.mono(13, .bold)).foregroundStyle(Theme.accent) }
                    VStack(alignment: .leading, spacing: 3) {
                        Text(ex.exercise_name).font(Theme.mono(15, .bold)).foregroundStyle(Theme.text)
                        Text(ex.group_id == nil ? "\(ex.targetLabel) · \(ex.rest_seconds)s rest" : ex.targetLabel)
                            .font(Theme.mono(12)).foregroundStyle(Theme.muted)
                    }
                    Spacer()
                    if ex.isWarmup { WarmupTag() }
                    Image(systemName: "chevron.right").font(.system(size: 11, weight: .bold)).foregroundStyle(Theme.dim)
                }
                .frame(minHeight: 44)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(selectingGroup)
            .accessibilityIdentifier("editor.slot.\(ex.id)")
            Menu {
                Button("Replace with…", systemImage: "arrow.triangle.2.circlepath") {
                    guard let plan = sync.plan,
                          let current = plan.workouts.first(where: { $0.id == dayID })?
                            .exercises.first(where: { $0.id == ex.id }) else { return }
                    replacingExercise = ExerciseReplacementTarget(exercise: current, version: plan.version)
                }
                if ex.group_id != nil {
                    Button("Remove exercise", role: .destructive) { removeSlot(ex.id) }
                }
            } label: {
                Image(systemName: "ellipsis.circle").foregroundStyle(Theme.accent).frame(width: 44, height: 44)
            }
            .disabled(selectingGroup)
            .accessibilityLabel("Options for \(ex.exercise_name)")
        }
    }

    private func removeSlot(_ id: String) {
        mutationWorking = true
        Task {
            await sync.deleteSlot(dayID: dayID, teID: id)
            mutationWorking = false
        }
    }

    private var emptyState: some View {
        VStack(spacing: 10) {
            Text(day == nil ? "WORKOUT NOT LOADED" : "NO EXERCISES YET")
                .font(Theme.display(24)).foregroundStyle(Theme.text)
            Text(day == nil ? "Refresh to load this workout, or close the editor if it was removed."
                 : "Use ＋ to add an exercise or a warm-up.")
                .font(Theme.mono(13)).foregroundStyle(Theme.muted)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

private struct EditExerciseGroupSheet: View {
    @ObservedObject var sync: SyncModel
    let dayID: String
    let target: ExerciseGroupEditTarget
    @Environment(\.dismiss) private var dismiss
    @State private var rounds: Int
    @State private var roundRest: Int
    @State private var transitionRest: Int
    @State private var working = false
    private let roundRestUpperBound: Int
    private let transitionRestUpperBound: Int

    init(sync: SyncModel, dayID: String, target: ExerciseGroupEditTarget) {
        self.sync = sync
        self.dayID = dayID
        self.target = target
        let first = target.members[0]
        roundRestUpperBound = max(600, first.group_rest_seconds ?? first.rest_seconds)
        transitionRestUpperBound = max(600, first.group_transition_seconds ?? 0)
        _rounds = State(initialValue: first.target_sets)
        _roundRest = State(initialValue: first.group_rest_seconds ?? first.rest_seconds)
        _transitionRest = State(initialValue: first.group_transition_seconds ?? 0)
    }

    private var stale: Bool {
        sync.workoutEditorRefreshNeeded || sync.plan?.version != target.version
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("Exercises in order") {
                    ForEach(Array(target.members.enumerated()), id: \.element.id) { index, member in
                        HStack {
                            Text("\(index + 1)").foregroundStyle(Theme.muted)
                            Text(member.exercise_name)
                            if member.isWarmup { WarmupTag() }
                        }
                    }
                }
                Section {
                    Stepper("\(rounds) rounds", value: $rounds, in: 1...max(20, target.members[0].target_sets))
                        .accessibilityIdentifier("group.rounds")
                    Stepper("Round rest: \(roundRest)s", value: $roundRest, in: 0...roundRestUpperBound, step: 15)
                        .accessibilityIdentifier("group.roundRest")
                    Stepper("Transition rest: \(transitionRest)s", value: $transitionRest, in: 0...transitionRestUpperBound, step: 15)
                        .accessibilityIdentifier("group.transitionRest")
                } footer: {
                    Text("Perform one set of each exercise per round. Transition rest is between exercises; round rest follows the last exercise. Individual rests are kept for ungrouping.")
                }
                .disabled(working || stale)
                Section {
                    Button(working ? "Saving…" : "Save group") {
                        working = true
                        Task {
                            let saved = await sync.saveExerciseGroup(dayID: dayID, groupID: target.id,
                                memberIDs: target.members.map(\.id), expectedVersion: target.version,
                                roundRest: roundRest, transitionRest: transitionRest, targetSets: rounds)
                            working = false
                            if saved { dismiss() }
                        }
                    }
                    .disabled(working || stale)
                    if target.isExisting {
                        Button("Ungroup") {
                            working = true
                            Task {
                                let saved = await sync.clearExerciseGroup(dayID: dayID, groupID: target.id,
                                                                         expectedVersion: target.version)
                                working = false
                                if saved { dismiss() }
                            }
                        }
                        .disabled(working || stale)
                    }
                }
                if stale {
                    Section { Text("Workout changed. Close and reopen the group to review its latest values.").foregroundStyle(Theme.danger) }
                } else if let error = sync.loadError {
                    Section { Text(error).foregroundStyle(Theme.danger) }
                }
            }
            .scrollContentBackground(.hidden).background(Theme.background)
            .navigationTitle(target.isExisting ? "Edit group" : "New group")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Cancel") { dismiss() }.disabled(working)
                }
            }
            .toolbarColorScheme(.dark, for: .navigationBar)
        }
        .interactiveDismissDisabled(working)
        .preferredColorScheme(.dark).tint(Theme.accent)
    }
}

private struct ReplaceExerciseSheet: View {
    @ObservedObject var sync: SyncModel
    let dayID: String
    let target: ExerciseReplacementTarget
    @Environment(\.dismiss) private var dismiss
    @State private var query = ""
    @State private var selected: ExerciseCatalog?
    @State private var confirming = false
    @State private var working = false

    private var stale: Bool {
        sync.plan?.version != target.version || sync.workoutEditorRefreshNeeded
    }
    private var choices: [ExerciseCatalog] {
        let q = query.trimmingCharacters(in: .whitespaces).lowercased()
        return sync.catalog.filter {
            $0.id != target.exercise.exercise_id &&
            (q.isEmpty || $0.name.lowercased().contains(q) || $0.primary_muscle.lowercased().contains(q))
        }.sorted { $0.name < $1.name }
    }

    var body: some View {
        NavigationStack {
            List {
                Section {
                    Text(target.exercise.exercise_name).font(Theme.mono(15, .bold))
                    Text("\(target.exercise.targetLabel) · \(target.exercise.rest_seconds)s rest")
                        .font(Theme.mono(12)).foregroundStyle(Theme.muted)
                } footer: {
                    Text("Replacement keeps this workout’s saved targets, position, and warm-up setting. Logged sets keep their original exercise.")
                }
                if stale {
                    Section {
                        Text("Workout changed. Close and reopen this picker to review the latest targets.")
                            .foregroundStyle(Theme.danger)
                    }
                } else if let error = sync.loadError {
                    Section { Text(error).foregroundStyle(Theme.danger) }
                }
                Section("Choose replacement") {
                    ForEach(choices) { exercise in
                        Button {
                            selected = exercise
                            confirming = true
                        } label: {
                            VStack(alignment: .leading, spacing: 3) {
                                Text(exercise.name).font(Theme.mono(14, .bold))
                                Text("\(exercise.primary_muscle) · \(exercise.modality)")
                                    .font(Theme.mono(11)).foregroundStyle(Theme.muted)
                            }
                        }
                        .disabled(working || stale)
                    }
                    if choices.isEmpty { Text("No matching exercises.").foregroundStyle(Theme.muted) }
                }
            }
            .scrollContentBackground(.hidden)
            .background(Theme.background)
            .searchable(text: $query, prompt: "Search exercises")
            .navigationTitle(working ? "Replacing…" : "Replace with…")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Close") { dismiss() }.disabled(working)
                }
            }
            .confirmationDialog("Replace \(target.exercise.exercise_name)?",
                                isPresented: $confirming, titleVisibility: .visible) {
                if let selected {
                    Button("Replace with \(selected.name)") {
                        working = true
                        Task {
                            let saved = await sync.replaceSlot(
                                dayID: dayID, teID: target.exercise.id, exercise: selected.id,
                                expectedVersion: target.version)
                            working = false
                            if saved { dismiss() }
                        }
                    }
                    .disabled(working || stale)
                }
            } message: {
                Text("Saved targets carry over. Targets that are invalid for the new exercise will be rejected.")
            }
            .toolbarColorScheme(.dark, for: .navigationBar)
        }
        .interactiveDismissDisabled(working)
        .preferredColorScheme(.dark)
        .tint(Theme.accent)
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

    private var isGrouped: Bool { slot.group_id != nil }
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
                    Stepper("\(sets) \(isGrouped ? "rounds" : "sets")", value: $sets, in: 1...max(10, slot.target_sets))
                        .disabled(isGrouped)
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
                    Stepper("\(sets) \(isGrouped ? "rounds" : "sets")", value: $sets, in: 1...max(10, slot.target_sets))
                        .disabled(isGrouped)
                    Stepper("\(seconds)s each", value: $seconds, in: 1...7_200, step: 5)
                }
            } else if !isCardio {
                Section("Target") {
                    Stepper("\(sets) \(isGrouped ? "rounds" : "sets")", value: $sets, in: 1...max(10, slot.target_sets))
                        .disabled(isGrouped)
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

            Section {
                Stepper("\(restSeconds)s", value: $restSeconds, in: 0...max(600, slot.rest_seconds), step: 15)
                    .disabled(isGrouped)
                    .accessibilityIdentifier("slot.ordinaryRest")
            } header: {
                Text(isGrouped ? "Individual rest · inactive" : "Rest between sets")
            } footer: {
                if isGrouped {
                    Text("Rounds and rest are set on the group. This individual rest returns when you ungroup.")
                }
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
