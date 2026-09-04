import SwiftUI

private struct RoutineDayTarget: Identifiable {
    let id: String
}

/// The routine editor reloads after every plan-tree write, but an exercise or
/// name edit must not erase weekday choices that have not been saved yet.
/// Only a different plan identity or persisted weekday mapping resets them.
enum RoutineScheduleDraftPolicy {
    static func persistedIdentity(for plan: PlanTree?) -> [String] {
        guard let plan else { return [] }
        return [plan.id] + PlanSchedule.weekdayKeys.map {
            plan.schedule?.templateID(forWeekdayKey: $0) ?? ""
        }
    }

    static func persistedDraft(for plan: PlanTree?) -> [String: String] {
        guard let plan else { return [:] }
        return Dictionary(uniqueKeysWithValues: PlanSchedule.weekdayKeys.map {
            ($0, plan.schedule?.templateID(forWeekdayKey: $0) ?? "")
        })
    }

    static func reconcile(
        currentDraft: [String: String],
        loadedIdentity: [String],
        plan: PlanTree?
    ) -> (draft: [String: String], identity: [String]) {
        let identity = persistedIdentity(for: plan)
        guard identity == loadedIdentity else {
            return (persistedDraft(for: plan), identity)
        }
        let liveDayIDs = Set(plan?.days.map(\.id) ?? [])
        var draft = currentDraft
        for key in PlanSchedule.weekdayKeys {
            let dayID = draft[key] ?? ""
            if !dayID.isEmpty, !liveDayIDs.contains(dayID) {
                draft[key] = ""
            }
        }
        return (draft, identity)
    }
}

/// Decide whether the second half of routine bootstrap still needs to run.
/// `ensureActivePlan` is intentionally idempotent, so a retry after its
/// response or state refresh was lost returns `created == false`. An empty
/// ensured plan must still receive the requested first workout. The existing
/// plan-version CAS on `addWorkoutDay` makes concurrent retries converge on a
/// single day; a non-empty winner is only loaded, never appended to here.
enum RoutineCreationPolicy {
    static func shouldAddFirstDay(
        wasCreated: Bool,
        ensuredPlanID: String,
        loadedPlanID: String?,
        loadedDayCount: Int
    ) -> Bool {
        loadedPlanID == ensuredPlanID && (wasCreated || loadedDayCount == 0)
    }
}

/// Compact member-owned editor for the same plan tree and weekly schedule the
/// coach reads and edits. There is intentionally no separate "manual" plan.
struct RoutineView: View {
    @ObservedObject var sync: SyncModel
    @Environment(\.dismiss) private var dismiss

    @State private var planName = "My Training"
    @State private var firstDayName = "Workout A"
    @State private var newDayName = ""
    @State private var renameDayName = ""
    @State private var addingDay = false
    @State private var renamingDay: DayTemplate?
    @State private var deletingDay: DayTemplate?
    @State private var editTarget: RoutineDayTarget?
    @State private var scheduleDraft: [String: String] = [:]
    @State private var loadedScheduleIdentity: [String] = []
    @State private var creatingRoutine = false

    private let weekdayNames = [
        "mon": "Monday", "tue": "Tuesday", "wed": "Wednesday",
        "thu": "Thursday", "fri": "Friday", "sat": "Saturday",
        "sun": "Sunday",
    ]

    var body: some View {
        NavigationStack {
            Group {
                if sync.plan == nil {
                    createRoutineForm
                } else {
                    routineList
                }
            }
            .background(Theme.background)
            .navigationTitle("Routine")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Done") { dismiss() }.foregroundStyle(Theme.accent)
                }
                if (sync.plan?.days.count ?? 0) > 1 {
                    ToolbarItem(placement: .topBarTrailing) {
                        EditButton().disabled(sync.isRoutineMutationInFlight)
                    }
                }
            }
            .toolbarColorScheme(.dark, for: .navigationBar)
            .alert("Add workout", isPresented: $addingDay) {
                TextField("Workout name", text: $newDayName)
                Button("Add") { addDay() }
                    .disabled(
                        sync.isRoutineMutationInFlight
                            || newDayName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("This adds a reusable workout to your routine. You can schedule it after adding exercises.")
            }
            .alert("Rename workout", isPresented: Binding(
                get: { renamingDay != nil },
                set: { if !$0 { renamingDay = nil } }
            )) {
                TextField("Workout name", text: $renameDayName)
                Button("Save") { renameDay() }
                    .disabled(
                        sync.isRoutineMutationInFlight
                            || renameDayName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                Button("Cancel", role: .cancel) { renamingDay = nil }
            }
            .confirmationDialog(
                "Remove \(deletingDay?.name ?? "this workout")?",
                isPresented: Binding(
                    get: { deletingDay != nil },
                    set: { if !$0 { deletingDay = nil } }
                ),
                titleVisibility: .visible
            ) {
                Button("Remove workout", role: .destructive) { deleteDay() }
                    .disabled(
                        sync.isRoutineMutationInFlight
                            || (sync.running && sync.selectedDayID == deletingDay?.id))
                Button("Cancel", role: .cancel) { deletingDay = nil }
            } message: {
                Text("Past sessions and logged sets stay in your history. Recurring weekdays using this workout become rest days.")
            }
            .sheet(item: $editTarget) { target in
                EditWorkoutSheet(sync: sync, dayID: target.id)
            }
            .task(id: [sync.plan?.id ?? "", String(sync.plan?.version ?? 0)]) {
                reconcileScheduleDraft()
            }
        }
        .preferredColorScheme(.dark)
    }

    private var createRoutineForm: some View {
        Form {
            Section {
                TextField("Routine name", text: $planName)
                TextField("First workout", text: $firstDayName)
            } header: {
                Text("Build without AI")
            } footer: {
                Text("Creates an active routine only if you do not already have one. A concurrent coach update is loaded, never replaced.")
            }

            Section {
                Button {
                    createRoutine()
                } label: {
                    HStack {
                        Spacer()
                        if creatingRoutine { ProgressView().tint(Theme.accent) }
                        Text(creatingRoutine ? "Creating…" : "Create routine")
                            .font(Theme.mono(14, .bold))
                        Spacer()
                    }
                }
                .disabled(
                    creatingRoutine
                        || planName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                        || firstDayName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }

            if let error = sync.loadError {
                Section { Text(error).foregroundStyle(Theme.danger) }
            }
        }
        .scrollContentBackground(.hidden)
    }

    private var routineList: some View {
        List {
            Section {
                if let days = sync.plan?.days, days.isEmpty {
                    Text("Add your first workout, then choose exercises and targets.")
                        .font(Theme.mono(12)).foregroundStyle(Theme.muted)
                } else {
                    ForEach(sync.plan?.days ?? []) { day in
                        HStack(spacing: 10) {
                            Button {
                                editTarget = RoutineDayTarget(id: day.id)
                            } label: {
                                VStack(alignment: .leading, spacing: 4) {
                                    Text(day.name)
                                        .font(Theme.mono(15, .bold))
                                        .foregroundStyle(Theme.text)
                                    Text(day.exercises.isEmpty
                                         ? "No exercises yet"
                                         : "\(day.exercises.count) exercise\(day.exercises.count == 1 ? "" : "s")")
                                        .font(Theme.mono(11)).foregroundStyle(Theme.muted)
                                }
                                .frame(maxWidth: .infinity, alignment: .leading)
                            }
                            .buttonStyle(.plain)
                            .disabled(sync.isRoutineMutationInFlight)

                            Menu {
                                Button("Edit exercises") {
                                    editTarget = RoutineDayTarget(id: day.id)
                                }
                                Button("Rename") {
                                    renameDayName = day.name
                                    renamingDay = day
                                }
                                Button("Remove", role: .destructive) {
                                    deletingDay = day
                                }
                                .disabled(sync.running && sync.selectedDayID == day.id)
                            } label: {
                                Image(systemName: "ellipsis.circle")
                                    .foregroundStyle(Theme.muted)
                            }
                            .disabled(sync.isRoutineMutationInFlight)
                        }
                        .listRowBackground(Theme.surface)
                        .moveDisabled(sync.isRoutineMutationInFlight)
                    }
                    .onMove(perform: moveDays)
                }

                Button {
                    newDayName = "Workout \((sync.plan?.days.count ?? 0) + 1)"
                    addingDay = true
                } label: {
                    Label("Add workout", systemImage: "plus.circle.fill")
                        .font(Theme.mono(13, .bold))
                        .foregroundStyle(Theme.accent)
                }
                .disabled(sync.isRoutineMutationInFlight)
            } header: {
                Text("Workouts")
            } footer: {
                Text("Tap a workout to add, edit, remove, or reorder exercises and targets.")
            }

            Section {
                ForEach(PlanSchedule.weekdayKeys, id: \.self) { key in
                    Picker(weekdayNames[key] ?? key, selection: scheduleBinding(key)) {
                        Text("Rest").tag("")
                        ForEach(sync.plan?.days ?? []) { day in
                            Text(day.name).tag(day.id)
                        }
                    }
                    .disabled(sync.isRoutineMutationInFlight)
                }

                Button {
                    Task { await sync.saveRecurringSchedule(scheduleDraft) }
                } label: {
                    HStack {
                        Spacer()
                        if sync.isRoutineMutationInFlight { ProgressView().tint(Theme.accent) }
                        Text("Save weekly schedule")
                            .font(Theme.mono(13, .bold))
                        Spacer()
                    }
                }
                .disabled(sync.isRoutineMutationInFlight)
            } header: {
                Text("Every week")
            } footer: {
                Text("These choices recur and drive Today. Use the calendar for one-date changes; those do not alter this schedule.")
            }

            if let error = sync.loadError {
                Section { Text(error).foregroundStyle(Theme.danger) }
            }
        }
        .scrollContentBackground(.hidden)
    }

    private func scheduleBinding(_ key: String) -> Binding<String> {
        Binding(
            get: { scheduleDraft[key] ?? "" },
            set: { scheduleDraft[key] = $0 })
    }

    private func reconcileScheduleDraft() {
        let reconciled = RoutineScheduleDraftPolicy.reconcile(
            currentDraft: scheduleDraft,
            loadedIdentity: loadedScheduleIdentity,
            plan: sync.plan)
        scheduleDraft = reconciled.draft
        loadedScheduleIdentity = reconciled.identity
    }

    private func createRoutine() {
        creatingRoutine = true
        Task {
            defer { creatingRoutine = false }
            guard let ensured = await sync.ensureRoutinePlan(name: planName) else { return }
            // Complete a previously interrupted bootstrap when ensure returns
            // the same still-empty plan. If another writer already added a
            // day, load that winner without appending a duplicate.
            guard RoutineCreationPolicy.shouldAddFirstDay(
                    wasCreated: ensured.created,
                    ensuredPlanID: ensured.plan.id,
                    loadedPlanID: sync.plan?.id,
                    loadedDayCount: sync.plan?.days.count ?? 0),
                  let dayID = await sync.addWorkoutDay(
                    name: firstDayName,
                    expectedPlanID: ensured.plan.id,
                    expectedVersion: ensured.plan.version)
            else { return }
            editTarget = RoutineDayTarget(id: dayID)
        }
    }

    private func addDay() {
        guard !sync.isRoutineMutationInFlight else { return }
        let name = newDayName
        Task {
            guard let dayID = await sync.addWorkoutDay(name: name) else { return }
            editTarget = RoutineDayTarget(id: dayID)
        }
    }

    private func renameDay() {
        guard !sync.isRoutineMutationInFlight, let day = renamingDay else { return }
        let name = renameDayName
        renamingDay = nil
        Task { await sync.renameWorkoutDay(dayID: day.id, name: name) }
    }

    private func deleteDay() {
        guard !sync.isRoutineMutationInFlight, let day = deletingDay else { return }
        deletingDay = nil
        Task { await sync.deleteWorkoutDay(dayID: day.id) }
    }

    private func moveDays(from offsets: IndexSet, to destination: Int) {
        guard !sync.isRoutineMutationInFlight,
              let source = offsets.first,
              let days = sync.plan?.days,
              days.indices.contains(source)
        else { return }
        var reordered = days
        let movedID = days[source].id
        reordered.move(fromOffsets: offsets, toOffset: destination)
        guard let target = reordered.firstIndex(where: { $0.id == movedID }) else { return }
        Task { await sync.moveWorkoutDay(dayID: movedID, toIndex: target) }
    }
}
