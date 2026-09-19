import SwiftUI

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
        let liveDayIDs = Set(plan?.availableWorkouts.map(\.id) ?? [])
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

    @State private var showArchived = false
    @State private var selectedTag = ""
    @State private var taggingDay: Workout?
    @State private var archivingDay: Workout?
    private var visibleWorkouts: [Workout] {
        let days = showArchived && date == nil ? (sync.plan?.workouts.filter(\.isArchived) ?? [])
            : WorkoutLibraryPolicy.choices(plan: sync.plan, date: date ?? sync.todayString)
        return selectedTag.isEmpty ? days : days.filter { $0.workoutTags.contains(selectedTag) }
    }
    private var canReorder: Bool { !showArchived && selectedTag.isEmpty && date == nil
        && !(sync.plan?.trips.contains(where: { sync.todayString >= $0.start && sync.todayString <= $0.end }) ?? false) }
    @State private var renameDayName = ""
    @State private var addingDay = false
    @State private var renamingDay: Workout?
    @State private var deletingDay: Workout?
    @State private var detailTarget: IdentifiedString?
    @State private var editTarget: IdentifiedString?
    @State private var assignmentTarget: Workout?
    @State private var showHistory = false

    var body: some View {
        NavigationStack {
            Group {
                if sync.plan == nil && !sync.canCreateRoutine {
                    PlanLoadRecoveryView(sync: sync)
                } else {
                    routineList
                }
            }
            .background(Theme.background)
            .navigationTitle(date == nil ? "Workouts" : "Choose a workout")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Done") { dismiss() }.foregroundStyle(Theme.accent)
                }
                if canReorder && visibleWorkouts.count > 1 {
                    ToolbarItem(placement: .topBarTrailing) {
                        EditButton().disabled(sync.isRoutineMutationInFlight)
                    }
                }
            }
            .toolbarColorScheme(.dark, for: .navigationBar)
            .sheet(isPresented: $addingDay) {
                CreateWorkoutView(sync: sync, onStart: onStart.map { start in
                    { id in dismiss(); start(id) }
                })
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
            .sheet(item: $taggingDay) { workout in
                WorkoutTagsSheet(sync: sync, workout: workout)
            }
            .alert("Archive \(archivingDay?.name ?? "this workout")?", isPresented: Binding(
                get: { archivingDay != nil }, set: { if !$0 { archivingDay = nil } }
            )) {
                Button("Archive workout", role: .destructive) {
                    guard let day = archivingDay else { return }
                    archivingDay = nil
                    Task { await sync.setWorkoutArchived(dayID: day.id, archived: true) }
                }
                Button("Cancel", role: .cancel) { archivingDay = nil }
            } message: {
                Text("Completed workouts and logged sets stay in your history. Weekly and planned date assignments become rest. You can restore this workout later.")
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

    private var routineList: some View {
        List {
            Section {
                if date == nil {
                    Picker("Library", selection: $showArchived) {
                        Text("Active").tag(false)
                        Text("Archived").tag(true)
                    }
                    .pickerStyle(.segmented)
                    .accessibilityIdentifier("library.scope")
                }
                let tags = Array(Set((sync.plan?.workouts ?? []).flatMap(\.workoutTags))).sorted()
                if !tags.isEmpty {
                    Picker("Tag", selection: $selectedTag) {
                        Text("All tags").tag("")
                        ForEach(tags, id: \.self) { Text($0).tag($0) }
                    }
                    .accessibilityIdentifier("library.tagFilter")
                }
            }
            Section {
                if visibleWorkouts.isEmpty {
                    Text(showArchived ? "No archived workouts." : selectedTag.isEmpty ? "Choose exercises to build a workout." : "No workouts with this tag.")
                        .font(Theme.mono(12)).foregroundStyle(Theme.muted)
                } else {
                    ForEach(visibleWorkouts) { day in
                        HStack(spacing: 0) {
                            Button {
                                detailTarget = IdentifiedString(id: day.id)
                            } label: {
                                HStack(spacing: 12) {
                                    VStack(alignment: .leading, spacing: 4) {
                                        Text(day.name)
                                            .font(Theme.mono(15, .bold))
                                            .foregroundStyle(Theme.text)
                                        Text(day.isArchived ? "Archived" : WorkoutLibraryPolicy.scheduleBadge(workoutID: day.id, plan: sync.plan))
                                            .font(Theme.mono(10, .bold)).foregroundStyle(Theme.accent)
                                            .accessibilityIdentifier("workoutSchedule-\(day.id)")
                                        if !day.workoutTags.isEmpty {
                                            Text(day.workoutTags.joined(separator: " · "))
                                                .font(Theme.mono(11)).foregroundStyle(Theme.muted)
                                                .accessibilityIdentifier("workoutTags-\(day.id)")
                                        }
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
                                Button("Edit tags", systemImage: "tag") { taggingDay = day }
                                if day.isArchived {
                                    Button("Restore workout", systemImage: "arrow.uturn.backward") {
                                        Task { await sync.setWorkoutArchived(dayID: day.id, archived: false) }
                                    }
                                } else {
                                Button("Use on a date", systemImage: "calendar.badge.plus") {
                                    assignmentTarget = day
                                }
                                Button("Unschedule", systemImage: "calendar.badge.minus") {
                                    Task { await sync.unscheduleWorkout(workoutID: day.id) }
                                }
                                .disabled(!WorkoutLibraryPolicy.isScheduled(workoutID: day.id, plan: sync.plan))
                                Button("Archive workout", systemImage: "archivebox") { archivingDay = day }
                                    .disabled(sync.running && sync.selectedDayID == day.id)
                                }
                                if !day.isArchived {
                                    Button("Edit exercises") {
                                        editTarget = IdentifiedString(id: day.id)
                                    }
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
                        .moveDisabled(sync.isRoutineMutationInFlight || !canReorder)
                    }
                    .onMove(perform: moveDays)
                }

                if !showArchived {
                Button {
                    addingDay = true
                } label: {
                    Label("Add workout", systemImage: "plus.circle.fill")
                        .font(Theme.mono(13, .bold))
                        .foregroundStyle(Theme.accent)
                }
                .disabled(sync.isRoutineMutationInFlight)
                }
            } header: {
                Text(showArchived ? "Archived workouts" : "Workouts")
            } footer: {
                Text(showArchived ? "Restore a workout to use it again. Completed workouts and logged sets stay in your history."
                    : "Open a workout to view its exercises, start it, or edit the saved workout.")
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
              canReorder,
              let days = sync.plan?.availableWorkouts,
              days.indices.contains(source)
        else { return }
        var reordered = days
        let movedID = days[source].id
        reordered.move(fromOffsets: offsets, toOffset: destination)
        guard let target = reordered.firstIndex(where: { $0.id == movedID }) else { return }
        let remaining = (sync.plan?.workouts ?? []).filter { $0.id != movedID }
        let following = reordered.dropFirst(target + 1).first
        let fullIndex = following.flatMap { next in remaining.firstIndex { $0.id == next.id } } ?? remaining.count
        Task { await sync.moveWorkoutDay(dayID: movedID, toIndex: fullIndex) }
    }
}
