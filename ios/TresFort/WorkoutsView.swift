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

/// The two sides of the Plan tab.
enum PlanSide: Hashable { case schedule, workouts }

/// Compact member-owned editor for the same plan tree and weekly schedule the
/// coach reads and edits. There is intentionally no separate "manual" plan.
/// It is the Plan tab's root, and the sheet Today opens to choose a workout.
/// Either way details and the editor push onto its one navigation stack.
struct WorkoutsView: View {
    @ObservedObject var sync: SyncModel
    var onStart: ((String) -> Void)? = nil
    var date: String? = nil
    /// The Plan tab: no Done, and two sides. Schedule is when you train;
    /// Workouts is what each saved workout contains.
    var isTabRoot = false
    /// Shows the workout on Today after the calendar starts one.
    var onShowWorkout: (() -> Void)? = nil
    @Environment(\.dismiss) private var dismiss

    @State private var showArchivedWorkouts = false
    @State private var selectedTag = ""
    @State private var taggingDay: Workout?
    @State private var archivingDay: Workout?
    private var availableTags: [String] {
        Array(Set((sync.plan?.availableWorkouts ?? []).flatMap(\.workoutTags))).sorted()
    }
    private var visibleWorkouts: [Workout] {
        let days = WorkoutLibraryPolicy.choices(plan: sync.plan, date: date ?? sync.todayString)
        return selectedTag.isEmpty ? days : days.filter { $0.workoutTags.contains(selectedTag) }
    }
    private var canReorder: Bool { selectedTag.isEmpty && date == nil
        && !(sync.plan?.trips.contains(where: { sync.todayString >= $0.start && sync.todayString <= $0.end }) ?? false) }
    @State private var renameDayName = ""
    @State private var addingDay = false
    @State private var renamingDay: Workout?
    @State private var deletingDay: Workout?
    @State private var detailTarget: IdentifiedString?
    @State private var editTarget: IdentifiedString?
    @State private var assignmentTarget: Workout?
    @State private var showHistory = false
    @State private var showWeeklySchedule = false
    @State private var showCalendar = false
    @State private var showAwayDates = false
    @State private var planSide = PlanSide.schedule
    /// The tab stays put when a workout starts; the sheet closes.
    private var staysOpen: Bool { isTabRoot }

    var body: some View {
        Group {
            if let date {
                WorkoutDatePickerView(sync: sync, date: date)
            } else {
                NavigationStack { libraryContent }
            }
        }
    }

    private var libraryContent: some View {
            Group {
                if sync.plan == nil && !sync.canCreateRoutine {
                    PlanLoadRecoveryView(sync: sync)
                } else if isTabRoot {
                    planHome
                } else {
                    routineList
                }
            }
            .onChange(of: availableTags) { _, tags in
                if !tags.contains(selectedTag) { selectedTag = "" }
            }
            .background(Theme.background)
            .navigationTitle(isTabRoot ? "Plan" : date == nil ? "Workouts" : "Choose a workout")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                if !isTabRoot {
                    ToolbarItem(placement: .topBarLeading) {
                        Button("Done") { dismiss() }.foregroundStyle(Theme.accent)
                    }
                }
                if isTabRoot {
                    ToolbarItem(placement: .topBarTrailing) {
                        Button { showHistory = true } label: {
                            Image(systemName: "clock.arrow.circlepath")
                        }
                        .disabled(sync.isRoutineMutationInFlight)
                        .accessibilityLabel("Plan changes")
                        .accessibilityIdentifier("plan.changes")
                    }
                }
                if (!isTabRoot || planSide == .workouts) && canReorder && visibleWorkouts.count > 1 {
                    ToolbarItem(placement: .topBarTrailing) {
                        EditButton().disabled(sync.isRoutineMutationInFlight)
                    }
                }
            }
            .sheet(isPresented: $addingDay) {
                CreateWorkoutView(sync: sync, onStart: onStart.map { start in
                    { id in
                        // The tab stays put and only its sheet closes.
                        if staysOpen { addingDay = false } else { dismiss() }
                        start(id)
                    }
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
            .navigationDestination(item: $detailTarget) { target in
                WorkoutDetailsView(sync: sync, workoutID: target.id, date: date,
                                   onStart: onStart.map { start in
                    { id in
                        // The tab stays put for next time; a sheet closes.
                        if staysOpen { detailTarget = nil } else { dismiss() }
                        start(id)
                    }
                }, isPushed: true)
            }
            .navigationDestination(item: $editTarget) { target in
                EditWorkoutSheet(sync: sync, dayID: target.id, isPushed: true)
            }
            .navigationDestination(isPresented: $showCalendar) {
                HistoryView(sync: sync, onStartWorkout: {
                    showCalendar = false
                    onShowWorkout?()
                })
            }
            .navigationDestination(isPresented: $showAwayDates) { AwayDatesView(sync: sync) }
            .navigationDestination(isPresented: $showArchivedWorkouts) { ArchivedWorkoutsView(sync: sync) }
            .sheet(item: $assignmentTarget) { workout in
                WorkoutDateSheet(sync: sync, workout: workout)
            }
            .sheet(isPresented: $showWeeklySchedule) { WeeklyScheduleView(sync: sync) }
            .sheet(isPresented: $showHistory) {
                PlanHistoryView(sync: sync, onCorrect: { showHistory = false })
            }
            .task(id: [sync.plan?.id ?? "", String(sync.plan?.version ?? 0)]) {
                await sync.refreshRecentPlanChanges()
            }
    }

    /// The tab opens on a plan with nothing in it: one clear first step.
    private var needsFirstWorkout: Bool {
        sync.plan?.availableWorkouts.isEmpty ?? true
    }

    private var archivedCount: Int {
        sync.plan?.workouts.filter(\.isArchived).count ?? 0
    }

    /// The Plan tab. Schedule answers when you train: the repeating week with
    /// the one action that changes it, the calendar and away dates. Workouts
    /// answers what you do: the saved workouts and making a new one.
    private var planHome: some View {
        List {
            Section {
                Picker("Plan", selection: $planSide) {
                    Text("Schedule").tag(PlanSide.schedule)
                    Text("Workouts").tag(PlanSide.workouts)
                }
                .pickerStyle(.segmented)
                .accessibilityIdentifier("plan.side")
                .listRowBackground(Color.clear)
                .listRowInsets(EdgeInsets(top: 4, leading: 0, bottom: 4, trailing: 0))
            }
            if planSide == .schedule {
                scheduleSections
            } else {
                workoutsSection
                archivedSection
            }
            if let error = sync.loadError {
                Section { Text(error).foregroundStyle(Theme.danger) }
            }
        }
        .scrollContentBackground(.hidden)
    }

    @ViewBuilder private var scheduleSections: some View {
        if needsFirstWorkout {
            Section {
                Text("Your week is empty. Save a workout on the Workouts side, then choose the days you do it.")
                    .font(Theme.mono(13)).foregroundStyle(Theme.muted)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.vertical, 6)
                Button { planSide = .workouts } label: { Text("Go to Workouts") }
                    .buttonStyle(WorkoutPrimaryButtonStyle())
                    .listRowBackground(Color.clear)
                    .listRowInsets(EdgeInsets(top: 4, leading: 0, bottom: 4, trailing: 0))
                    .accessibilityIdentifier("plan.goToWorkouts")
            } header: {
                Text("Your week")
            }
        } else {
            Section {
                PlanWeekSummary(sync: sync) { detailTarget = IdentifiedString(id: $0) }
                    .listRowInsets(EdgeInsets(top: 0, leading: 0, bottom: 0, trailing: 0))
                Button { showWeeklySchedule = true } label: {
                    Text(WorkoutLibraryPolicy.hasScheduledDay(plan: sync.plan)
                         ? "Edit weekly schedule" : "Choose your training days")
                }
                .buttonStyle(WorkoutPrimaryButtonStyle())
                .disabled(sync.isRoutineMutationInFlight || sync.plan == nil)
                .listRowBackground(Color.clear)
                .listRowInsets(EdgeInsets(top: 4, leading: 0, bottom: 4, trailing: 0))
                .accessibilityIdentifier("library.weeklySchedule")
            } header: {
                Text("Your week")
            } footer: {
                Text("Repeats every week. To change a single date, use the calendar.")
            }
        }
        Section {
            planLink("Calendar", systemImage: "calendar", id: "plan.calendar") { showCalendar = true }
            planLink("Away dates", systemImage: "airplane",
                     detail: nextAwayDates.map(AwayDatesText.range), id: "plan.awayDates") {
                showAwayDates = true
            }
            .disabled(sync.plan == nil)
        }
    }

    private func planLink(_ title: String, systemImage: String, detail: String? = nil,
                          id: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 12) {
                Label(title, systemImage: systemImage)
                    .font(Theme.mono(15, .bold)).foregroundStyle(Theme.text)
                Spacer()
                if let detail {
                    Text(detail).font(Theme.mono(13)).foregroundStyle(Theme.muted)
                }
                Image(systemName: "chevron.right")
                    .font(.system(size: 13, weight: .semibold)).foregroundStyle(Theme.muted)
                    .accessibilityHidden(true)
            }
            .frame(minHeight: 44)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier(id)
    }

    /// The workout library sheet Today opens.
    private var routineList: some View {
        List {
            workoutsSection
            archivedSection

            // The Plan tab keeps plan changes in its toolbar instead.
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

    @ViewBuilder private var archivedSection: some View {
        if date == nil && archivedCount > 0 {
            Section {
                Button { showArchivedWorkouts = true } label: {
                    HStack(spacing: 12) {
                        Label("Archived workouts", systemImage: "archivebox")
                            .font(Theme.mono(13, .bold)).foregroundStyle(Theme.text)
                        Spacer()
                        Text("\(archivedCount)")
                            .font(Theme.mono(12)).foregroundStyle(Theme.muted)
                        Image(systemName: "chevron.right")
                            .font(.system(size: 13, weight: .semibold)).foregroundStyle(Theme.muted)
                            .accessibilityHidden(true)
                    }
                    .frame(minHeight: 44)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("library.archived")
            } footer: {
                Text("Workouts you put away. Restore one to use it again.")
            }
        }
    }

    @ViewBuilder private var workoutsSection: some View {
        Section {
            if !availableTags.isEmpty {
                Picker("Tag", selection: $selectedTag) {
                    Text("All tags").tag("")
                    ForEach(availableTags, id: \.self) { Text($0).tag($0) }
                }
                .accessibilityIdentifier("library.tagFilter")
            }
            if visibleWorkouts.isEmpty {
                Text(selectedTag.isEmpty ? "Choose exercises to build a workout." : "No workouts with this tag.")
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
                                    Text(WorkoutLibraryPolicy.scheduleBadge(workoutID: day.id, plan: sync.plan))
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
                            Button("Use on a date", systemImage: "calendar.badge.plus") {
                                assignmentTarget = day
                            }
                            Button("Unschedule", systemImage: "calendar.badge.minus") {
                                Task { await sync.unscheduleWorkout(workoutID: day.id) }
                            }
                            .disabled(!WorkoutLibraryPolicy.isScheduled(workoutID: day.id, plan: sync.plan))
                            Button("Archive workout", systemImage: "archivebox") { archivingDay = day }
                                .disabled(sync.running && sync.selectedDayID == day.id)
                            Button("Edit exercises") {
                                editTarget = IdentifiedString(id: day.id)
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

            Button {
                addingDay = true
            } label: {
                Label("Add workout", systemImage: "plus.circle.fill")
                    .font(Theme.mono(13, .bold))
                    .foregroundStyle(Theme.accent)
            }
            .disabled(sync.isRoutineMutationInFlight)
            // The Plan tab edits the week on its Schedule side. The library
            // sheet keeps this route to the same editor.
            if !isTabRoot {
                Button {
                    showWeeklySchedule = true
                } label: {
                    Label("Weekly schedule", systemImage: "calendar.badge.clock")
                        .font(Theme.mono(13, .bold))
                        .foregroundStyle(Theme.accent)
                }
                .disabled(sync.isRoutineMutationInFlight || sync.plan == nil)
                .accessibilityIdentifier("library.weeklySchedule")
            }
        } header: {
            Text("Workouts")
        } footer: {
            Text("Saved workouts you can put on any day. Open one to view its exercises, start it, or edit it.")
        }
    }

    private var nextAwayDates: PlanTrip? {
        sync.plan?.awayDates.first { $0.end >= sync.todayString }
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
