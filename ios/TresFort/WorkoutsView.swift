import SwiftUI

private struct WorkoutTarget: Identifiable {
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
        let liveDayIDs = Set(plan?.workouts.map(\.id) ?? [])
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
struct WorkoutsView: View {
    @ObservedObject var sync: SyncModel
    var onStart: ((String) -> Void)? = nil
    var date: String? = nil
    @Environment(\.dismiss) private var dismiss

    @State private var planName = "My Training"
    @State private var firstDayName = "Workout A"
    @State private var newDayName = ""
    @State private var renameDayName = ""
    @State private var addingDay = false
    @State private var renamingDay: Workout?
    @State private var deletingDay: Workout?
    @State private var detailTarget: WorkoutTarget?
    @State private var editTarget: WorkoutTarget?
    @State private var assignmentTarget: Workout?
    @State private var creatingRoutine = false
    @State private var showHistory = false

    var body: some View {
        NavigationStack {
            Group {
                if sync.plan == nil && !sync.canCreateRoutine {
                    PlanLoadRecoveryView(sync: sync)
                } else if sync.plan == nil {
                    createRoutineForm
                } else {
                    routineList
                }
            }
            .background(Theme.background)
            .navigationTitle(onStart == nil && date == nil ? "Workouts" : "Choose a workout")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Done") { dismiss() }.foregroundStyle(Theme.accent)
                }
                if (sync.plan?.workouts.count ?? 0) > 1 {
                    ToolbarItem(placement: .topBarTrailing) {
                        EditButton().disabled(sync.isRoutineMutationInFlight)
                    }
                }
            }
            .toolbarColorScheme(.dark, for: .navigationBar)
            .alert("Add workout", isPresented: $addingDay) {
                TextField("Workout name", text: $newDayName)
                Button("Add") { addWorkout() }
                    .disabled(
                        sync.isRoutineMutationInFlight
                            || newDayName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("Save a reusable workout to use whenever you need it. A weekly schedule is optional.")
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
            .alert(
                "Delete \(deletingDay?.name ?? "this workout")?",
                isPresented: Binding(
                    get: { deletingDay != nil },
                    set: { if !$0 { deletingDay = nil } }
                )
            ) {
                Button("Delete workout", role: .destructive) { deleteWorkout() }
                    .disabled(
                        sync.isRoutineMutationInFlight
                            || (sync.running && sync.selectedDayID == deletingDay?.id))
                Button("Cancel", role: .cancel) { deletingDay = nil }
            } message: {
                Text("Past sessions and logged sets stay in your history. Recurring weekdays using this workout become rest days.")
            }
            .sheet(item: $detailTarget) { target in
                WorkoutDetailsView(sync: sync, workoutID: target.id, date: date,
                                   onStart: onStart.map { start in
                    { id in dismiss(); start(id) }
                })
            }
            .sheet(item: $editTarget) { target in
                EditWorkoutSheet(sync: sync, dayID: target.id)
            }
            .sheet(item: $assignmentTarget) { workout in
                WorkoutDateSheet(sync: sync, workout: workout)
            }
            .sheet(isPresented: $showHistory) {
                PlanHistoryView(sync: sync, onCorrect: { showHistory = false })
            }
            .task(id: [sync.plan?.id ?? "", String(sync.plan?.version ?? 0)]) {
                await sync.refreshRecentPlanChanges()
            }
        }
        .preferredColorScheme(.dark)
    }

    private var createRoutineForm: some View {
        Form {
            Section {
                TextField("Training plan name", text: $planName)
                TextField("First workout", text: $firstDayName)
            } header: {
                Text("Your first workout")
            } footer: {
                Text("Keep workouts for the gym, travel, or a quick session. Use them on demand or add an optional weekly schedule.")
            }

            Section {
                Button {
                    createRoutine()
                } label: {
                    HStack {
                        Spacer()
                        if creatingRoutine { ProgressView().tint(Theme.accent) }
                        Text(creatingRoutine ? "Creating…" : "Create workout")
                            .font(Theme.mono(14, .bold))
                        Spacer()
                    }
                }
                .disabled(
                    creatingRoutine || !sync.canCreateRoutine
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
                if let days = sync.plan?.workouts, days.isEmpty {
                    Text("Add your first workout, then choose exercises and targets.")
                        .font(Theme.mono(12)).foregroundStyle(Theme.muted)
                } else {
                    ForEach(sync.plan?.workouts ?? []) { day in
                        HStack(spacing: 0) {
                            Button {
                                detailTarget = WorkoutTarget(id: day.id)
                            } label: {
                                HStack(spacing: 12) {
                                    VStack(alignment: .leading, spacing: 4) {
                                        Text(day.name)
                                            .font(Theme.mono(15, .bold))
                                            .foregroundStyle(Theme.text)
                                        Text(WorkoutLibraryPolicy.scheduleBadge(workoutID: day.id, plan: sync.plan))
                                            .font(Theme.mono(10, .bold)).foregroundStyle(Theme.accent)
                                            .accessibilityIdentifier("workoutSchedule-\(day.id)")
                                        Text(day.exercises.isEmpty
                                             ? "No exercises yet"
                                             : "\(day.exercises.count) exercise\(day.exercises.count == 1 ? "" : "s")")
                                            .font(Theme.mono(11)).foregroundStyle(Theme.muted)
                                    }
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                    Image(systemName: "chevron.right")
                                        .font(.system(size: 13, weight: .semibold))
                                        .foregroundStyle(Theme.muted)
                                        .accessibilityHidden(true)
                                }
                                .padding(.leading, 16)
                                .padding(.trailing, 8)
                                .padding(.vertical, 14)
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                            .accessibilityIdentifier("library.workout.\(day.id)")
                            .accessibilityHint("Opens workout details")
                            .disabled(sync.isRoutineMutationInFlight)

                            Menu {
                                Button("Use on a date", systemImage: "calendar.badge.plus") {
                                    assignmentTarget = day
                                }
                                Button("Unschedule", systemImage: "calendar.badge.minus") {
                                    Task { await sync.unscheduleWorkout(workoutID: day.id) }
                                }
                                .disabled(!WorkoutLibraryPolicy.isScheduled(workoutID: day.id, plan: sync.plan))
                                Button("Edit exercises") {
                                    editTarget = WorkoutTarget(id: day.id)
                                }
                                Button("Rename") {
                                    renameDayName = day.name
                                    renamingDay = day
                                }
                                Button("Delete workout", role: .destructive) {
                                    deletingDay = day
                                }
                                .disabled(sync.running && sync.selectedDayID == day.id)
                            } label: {
                                Image(systemName: "ellipsis.circle")
                                    .font(.system(size: 18))
                                    .foregroundStyle(Theme.muted)
                                    .frame(width: 44, height: 44)
                                    .contentShape(Rectangle())
                            }
                            .padding(.trailing, 4)
                            .disabled(sync.isRoutineMutationInFlight)
                            .accessibilityLabel("Actions for \(day.name)")
                        }
                        .listRowInsets(EdgeInsets())
                        .listRowBackground(Theme.surface)
                        .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                            // Confirm first; a destructive swipe role would animate
                            // the row away before the member chooses to delete it.
                            Button {
                                deletingDay = day
                            } label: {
                                Label("Delete", systemImage: "trash")
                            }
                            .tint(.red)
                            .disabled(sync.isRoutineMutationInFlight
                                || (sync.running && sync.selectedDayID == day.id))
                        }
                        .moveDisabled(sync.isRoutineMutationInFlight)
                    }
                    .onMove(perform: moveDays)
                }

                Button {
                    newDayName = "Workout \((sync.plan?.workouts.count ?? 0) + 1)"
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
                Text("Open a workout to view its exercises, start it, or edit the saved workout.")
            }

            Section("Changes") {
                RecentPlanChanges(sync: sync) { showHistory = true }
                Button {
                    showHistory = true
                } label: {
                    Label("Plan changes", systemImage: "clock.arrow.circlepath")
                }
                .disabled(sync.isRoutineMutationInFlight)
            }

            if let error = sync.loadError {
                Section { Text(error).foregroundStyle(Theme.danger) }
            }
        }
        .scrollContentBackground(.hidden)
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
                    loadedDayCount: sync.plan?.workouts.count ?? 0),
                  let dayID = await sync.addWorkoutDay(
                    name: firstDayName,
                    expectedPlanID: ensured.plan.id,
                    expectedVersion: ensured.plan.version)
            else { return }
            editTarget = WorkoutTarget(id: dayID)
        }
    }

    private func addWorkout() {
        guard !sync.isRoutineMutationInFlight else { return }
        let name = newDayName
        Task {
            guard let dayID = await sync.addWorkoutDay(name: name) else { return }
            editTarget = WorkoutTarget(id: dayID)
        }
    }

    private func renameDay() {
        guard !sync.isRoutineMutationInFlight, let day = renamingDay else { return }
        let name = renameDayName
        renamingDay = nil
        Task { await sync.renameWorkoutDay(dayID: day.id, name: name) }
    }

    private func deleteWorkout() {
        guard !sync.isRoutineMutationInFlight, let day = deletingDay else { return }
        deletingDay = nil
        Task { await sync.deleteWorkoutDay(dayID: day.id) }
    }

    private func moveDays(from offsets: IndexSet, to destination: Int) {
        guard !sync.isRoutineMutationInFlight,
              let source = offsets.first,
              let days = sync.plan?.workouts,
              days.indices.contains(source)
        else { return }
        var reordered = days
        let movedID = days[source].id
        reordered.move(fromOffsets: offsets, toOffset: destination)
        guard let target = reordered.firstIndex(where: { $0.id == movedID }) else { return }
        Task { await sync.moveWorkoutDay(dayID: movedID, toIndex: target) }
    }
}
