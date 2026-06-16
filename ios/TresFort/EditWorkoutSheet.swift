import SwiftUI

/// In-app workout editor (#1/#2). Lets you add / remove / reorder exercises in
/// today's workout — including a prescribed warm-up (e.g. a 5-min erg) — without
/// going to Claude. It edits the active plan's DAY TEMPLATE via the REST editor
/// endpoints, so a change shows up immediately and (for a warm-up) recurs on
/// that day, which is what you want. Claude stays the brain for programming and
/// analysis; this is just the executor letting you tweak the session in front
/// of you.
///
/// Reads the live day off `sync` by id (not a captured snapshot) so the list
/// reflects edits the moment `sync.load()` returns.
struct EditWorkoutSheet: View {
    @ObservedObject var sync: SyncModel
    let dayID: String
    @Environment(\.dismiss) private var dismiss
    @State private var adding = false
    @State private var addPresetWarmup = false

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
        }
        .preferredColorScheme(.dark)
    }

    private func list(_ day: DayTemplate) -> some View {
        List {
            ForEach(day.exercises) { ex in
                HStack(spacing: 10) {
                    VStack(alignment: .leading, spacing: 3) {
                        Text(ex.exercise_name)
                            .font(Theme.mono(15, .bold))
                            .foregroundStyle(Theme.text)
                        Text(ex.targetLabel)
                            .font(Theme.mono(12))
                            .foregroundStyle(Theme.muted)
                    }
                    Spacer()
                    if ex.isWarmup { WarmupTag() }
                }
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
    @State private var minutes = 5
    @State private var seconds = 45
    @State private var restSeconds = 120
    @State private var working = false

    init(sync: SyncModel, dayID: String, exercise: ExerciseCatalog,
         presetWarmup: Bool, onDone: @escaping () -> Void) {
        self.sync = sync
        self.dayID = dayID
        self.exercise = exercise
        self.presetWarmup = presetWarmup
        self.onDone = onDone
        _isWarmup = State(initialValue: presetWarmup)
    }

    /// Cardio ergs (rowing/bike/ski, treadmill) are logged by minutes.
    private var isCardio: Bool { exercise.modality == "cardio" }
    /// Holds (planks, dead-hangs) are logged by seconds.
    private var isHold: Bool { exercise.modality == "timed" }

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
            } else if isHold {
                Section("Hold") {
                    Stepper("\(sets) set\(sets == 1 ? "" : "s")", value: $sets, in: 1...10)
                    Stepper("\(seconds)s each", value: $seconds, in: 5...300, step: 5)
                }
            } else {
                Section("Target") {
                    Stepper("\(sets) set\(sets == 1 ? "" : "s")", value: $sets, in: 1...10)
                    Stepper("\(reps) reps", value: $reps, in: 1...30)
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
                        await sync.addExerciseToDay(
                            dayID,
                            exercise: exercise.id,
                            isWarmup: isWarmup,
                            targetSets: isCardio ? 1 : sets,
                            targetReps: isCardio ? 1 : (isHold ? seconds : reps),
                            restSeconds: restSeconds,
                            targetDurationS: durationS)
                        working = false
                        onDone()
                    }
                } label: {
                    Text(working ? "Adding…" : "Add to workout")
                        .font(Theme.mono(15, .bold))
                        .frame(maxWidth: .infinity)
                }
                .disabled(working)
            }
        }
        .scrollContentBackground(.hidden)
        .background(Theme.background)
        .navigationTitle(exercise.name)
        .navigationBarTitleDisplayMode(.inline)
        .tint(Theme.accent)
    }
}
