import SwiftUI

/// Schedule membership belongs to the plan, not to a workout's identity.
enum WorkoutLibraryPolicy {
    static func choices(plan: PlanTree?, date: String) -> [Workout] {
        let workouts = plan?.availableWorkouts ?? []
        guard plan?.trips.contains(where: { date >= $0.start && date <= $0.end }) == true else { return workouts }
        // Stable partition: travel labels affect ordering, never eligibility.
        return workouts.filter { $0.workoutTags.contains("travel") }
            + workouts.filter { !$0.workoutTags.contains("travel") }
    }

    static func isScheduled(workoutID: String, plan: PlanTree?) -> Bool {
        PlanSchedule.weekdayKeys.contains { plan?.schedule?.templateID(forWeekdayKey: $0) == workoutID }
    }

    static func scheduleBadge(workoutID: String, plan: PlanTree?) -> String {
        let days = PlanSchedule.weekdayKeys.filter {
            plan?.schedule?.templateID(forWeekdayKey: $0) == workoutID
        }
        return days.isEmpty ? "On demand" : days.map { $0.capitalized }.joined(separator: " · ")
    }

    struct WeekRow: Equatable {
        let weekdayKey: String
        /// nil is a rest day.
        let workoutName: String?
    }

    /// The repeating week as the Plan tab shows it, Monday first. A weekday
    /// whose workout is missing or archived reads as rest, as the calendar
    /// projection treats it.
    static func weekRows(plan: PlanTree?) -> [WeekRow] {
        let available = Dictionary(uniqueKeysWithValues: (plan?.availableWorkouts ?? []).map { ($0.id, $0.name) })
        return PlanSchedule.weekdayKeys.map { key in
            WeekRow(weekdayKey: key,
                    workoutName: plan?.schedule?.templateID(forWeekdayKey: key).flatMap { available[$0] })
        }
    }

    static func hasScheduledDay(plan: PlanTree?) -> Bool {
        weekRows(plan: plan).contains { $0.workoutName != nil }
    }

    /// Use the persisted mapping. An unsaved picker draft must not accidentally
    /// schedule other workouts when the member chooses Unschedule on one card.
    static func unscheduling(workoutID: String, plan: PlanTree) -> [String: String] {
        Dictionary(uniqueKeysWithValues: PlanSchedule.weekdayKeys.map { key in
            let id = plan.schedule?.templateID(forWeekdayKey: key) ?? ""
            return (key, id == workoutID ? "" : id)
        })
    }
}

/// The repeating week at the top of the Plan tab: what each weekday holds.
struct PlanWeekSummary: View {
    @ObservedObject var sync: SyncModel
    private static let names = ["mon": "Monday", "tue": "Tuesday", "wed": "Wednesday",
                                "thu": "Thursday", "fri": "Friday", "sat": "Saturday", "sun": "Sunday"]

    var body: some View {
        VStack(spacing: 0) {
            ForEach(WorkoutLibraryPolicy.weekRows(plan: sync.plan), id: \.weekdayKey) { row in
                HStack(spacing: 12) {
                    Text(row.weekdayKey.uppercased())
                        .font(Theme.mono(11, .bold)).foregroundStyle(Theme.muted)
                        .frame(width: 40, alignment: .leading)
                    Text(row.workoutName ?? "Rest")
                        .font(Theme.mono(14, row.workoutName == nil ? .medium : .bold))
                        .foregroundStyle(row.workoutName == nil ? Theme.muted : Theme.text)
                        .lineLimit(1)
                    Spacer(minLength: 0)
                }
                .frame(minHeight: 30)
                .accessibilityElement(children: .ignore)
                .accessibilityLabel("\(Self.names[row.weekdayKey] ?? row.weekdayKey): \(row.workoutName ?? "Rest")")
                .accessibilityIdentifier("plan.week.\(row.weekdayKey)")
            }
        }
        .padding(.vertical, 4)
    }
}

/// Archived workouts get their own screen instead of a toggle that swaps the
/// whole library. Restoring one puts it back in the library; deleting asks first.
struct ArchivedWorkoutsView: View {
    @ObservedObject var sync: SyncModel
    @State private var detailTarget: IdentifiedString?
    @State private var deletingDay: Workout?

    private var archived: [Workout] { sync.plan?.workouts.filter(\.isArchived) ?? [] }

    var body: some View {
        List {
            Section {
                if archived.isEmpty {
                    Text("No archived workouts.")
                        .font(Theme.mono(12)).foregroundStyle(Theme.muted)
                        .accessibilityIdentifier("archived.empty")
                }
                ForEach(archived) { day in
                    HStack(spacing: 0) {
                        Button { detailTarget = IdentifiedString(id: day.id) } label: {
                            HStack(spacing: 12) {
                                VStack(alignment: .leading, spacing: 4) {
                                    Text(day.name)
                                        .font(Theme.mono(15, .bold)).foregroundStyle(Theme.text)
                                    if !day.workoutTags.isEmpty {
                                        Text(day.workoutTags.joined(separator: " · "))
                                            .font(Theme.mono(11)).foregroundStyle(Theme.muted)
                                    }
                                    Text(day.exercises.isEmpty
                                         ? "No exercises"
                                         : "\(day.exercises.count) exercise\(day.exercises.count == 1 ? "" : "s")")
                                        .font(Theme.mono(11)).foregroundStyle(Theme.muted)
                                }
                                .frame(maxWidth: .infinity, alignment: .leading)
                                Image(systemName: "chevron.right")
                                    .font(.system(size: 13, weight: .semibold)).foregroundStyle(Theme.muted)
                                    .accessibilityHidden(true)
                            }
                            .padding(.leading, 16).padding(.trailing, 8).padding(.vertical, 14)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .accessibilityIdentifier("library.workout.\(day.id)")
                        .accessibilityHint("Opens workout details")
                        .disabled(sync.isRoutineMutationInFlight)
                        Menu {
                            Button("Restore workout", systemImage: "arrow.uturn.backward") { restore(day) }
                            Button("Delete workout", role: .destructive) { deletingDay = day }
                        } label: {
                            Image(systemName: "ellipsis.circle")
                                .font(.system(size: 18)).foregroundStyle(Theme.muted)
                                .frame(width: 44, height: 44).contentShape(Rectangle())
                        }
                        .padding(.trailing, 4)
                        .disabled(sync.isRoutineMutationInFlight)
                        .accessibilityLabel("Actions for \(day.name)")
                    }
                    .listRowInsets(EdgeInsets())
                    .listRowBackground(Theme.surface)
                    .swipeActions(edge: .leading, allowsFullSwipe: true) {
                        Button { restore(day) } label: {
                            Label("Restore", systemImage: "arrow.uturn.backward")
                        }
                        .tint(Theme.accent)
                        .disabled(sync.isRoutineMutationInFlight)
                    }
                }
            } footer: {
                Text("Restore a workout to use it again. Completed workouts and logged sets stay in your history either way.")
            }
            if let error = sync.loadError {
                Section { Text(error).foregroundStyle(Theme.danger) }
            }
        }
        .scrollContentBackground(.hidden)
        .background(Theme.background)
        .navigationTitle("Archived workouts")
        .navigationBarTitleDisplayMode(.inline)
        .navigationDestination(item: $detailTarget) { target in
            WorkoutDetailsView(sync: sync, workoutID: target.id, date: nil, onStart: nil, isPushed: true)
        }
        .alert(
            "Delete \(deletingDay?.name ?? "this workout")?",
            isPresented: Binding(get: { deletingDay != nil }, set: { if !$0 { deletingDay = nil } })
        ) {
            Button("Delete workout", role: .destructive) {
                guard let day = deletingDay, !sync.isRoutineMutationInFlight else { return }
                deletingDay = nil
                Task { await sync.deleteWorkoutDay(dayID: day.id) }
            }
            .disabled(sync.isRoutineMutationInFlight)
            Button("Cancel", role: .cancel) { deletingDay = nil }
        } message: {
            Text("Past sessions and logged sets stay in your history.")
        }
    }

    private func restore(_ day: Workout) {
        guard !sync.isRoutineMutationInFlight else { return }
        Task { await sync.setWorkoutArchived(dayID: day.id, archived: false) }
    }
}

struct WorkoutDateSheet: View {
    @ObservedObject var sync: SyncModel
    let workout: Workout
    @Environment(\.dismiss) private var dismiss
    @State private var date = Date()
    @State private var saving = false

    init(sync: SyncModel, workout: Workout) {
        self.sync = sync
        self.workout = workout
        _date = State(initialValue: CalendarProjection.date(from: sync.todayString) ?? Date())
    }

    private var dateString: String { CalendarProjection.dateString(date) }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    DatePicker("Date", selection: $date,
                               in: (CalendarProjection.date(from: sync.todayString) ?? Date())...,
                               displayedComponents: .date)
                        .datePickerStyle(.graphical)
                        .accessibilityIdentifier("workoutAssignmentDate")
                } footer: {
                    Text("Use \(workout.name) on this date. Your weekly schedule stays the same.")
                }
                Section {
                    if let reason = sync.calendarAssignmentUnavailableReason(date: dateString) {
                        Text(reason).foregroundStyle(Theme.muted)
                    } else if let current = sync.previewWorkout(forDateString: dateString) {
                        Text("Replaces \(current.name) for this date only.")
                            .foregroundStyle(Theme.muted)
                    }
                    Button(saving ? "Saving…" : "Use \(workout.name)") {
                        saving = true
                        Task {
                            let accepted = await sync.setCalendarOverride(date: dateString, dayID: workout.id)
                            saving = false
                            if accepted { dismiss() }
                        }
                    }
                    .disabled(saving || sync.isRoutineMutationInFlight
                        || sync.workout(id: workout.id)?.isArchived != false
                        || sync.calendarAssignmentUnavailableReason(date: dateString) != nil)
                    .accessibilityIdentifier("assignLibraryWorkout")
                    if let error = sync.loadError {
                        Text(error).foregroundStyle(Theme.danger)
                    }
                }
            }
            .navigationTitle("Use on a date")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } } }
        }
        .environment(\.calendar, CalendarProjection.calendar)
        .environment(\.timeZone, CalendarProjection.calendar.timeZone)
    }
}

/// A failed transport keeps its original request for a receipt-safe retry.
struct MoveWorkoutDateSheet: View {
    @ObservedObject var sync: SyncModel
    let workout: Workout
    let fromDate: String
    @Environment(\.dismiss) private var dismiss
    @State private var date: Date
    @State private var request: APIClient.CalendarMoveRequest?
    @State private var saving = false

    init(sync: SyncModel, workout: Workout, fromDate: String) {
        self.sync = sync; self.workout = workout; self.fromDate = fromDate
        _date = State(initialValue: CalendarProjection.date(from: fromDate) ?? Date())
    }

    private var dateString: String { CalendarProjection.dateString(date) }
    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Text("Move \(workout.name) from \(fromDate).")
                    DatePicker("New date", selection: $date,
                               in: (CalendarProjection.date(from: sync.todayString) ?? Date())...,
                               displayedComponents: .date)
                        .datePickerStyle(.graphical)
                        .disabled(saving || request != nil)
                        .accessibilityIdentifier("calendar.moveDate")
                } footer: {
                    Text("The original date becomes rest. Your saved workout and weekly schedule stay the same.")
                }
                Section {
                    if request == nil, let reason = sync.calendarMoveUnavailableReason(from: fromDate, to: dateString, workoutID: workout.id) {
                        Text(reason).foregroundStyle(Theme.muted)
                    }
                    Button(saving ? "Moving…" : request == nil ? "Move workout" : "Retry move") {
                        if request == nil { request = sync.calendarMoveRequest(from: fromDate, to: dateString, workoutID: workout.id) }
                        guard let request else { return }
                        saving = true
                        Task {
                            let outcome = await sync.moveCalendarWorkout(request)
                            saving = false
                            switch outcome {
                            case .acknowledged: dismiss()
                            case .needsReview: self.request = nil
                            case .retrySameRequest: break
                            }
                        }
                    }
                    .disabled(saving || sync.isRoutineMutationInFlight || (request == nil
                        && sync.calendarMoveUnavailableReason(from: fromDate, to: dateString, workoutID: workout.id) != nil))
                    .accessibilityIdentifier("calendar.confirmMove")
                    if let error = sync.loadError {
                        Text(error).foregroundStyle(Theme.danger)
                        Button("Refresh calendar") { Task { await sync.load() } }
                            .disabled(saving || sync.isRoutineMutationInFlight)
                    }
                }
            }
            .navigationTitle("Move workout")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Done") { dismiss() }.disabled(saving) } }
        }
        .environment(\.calendar, CalendarProjection.calendar)
        .environment(\.timeZone, CalendarProjection.calendar.timeZone)
        .interactiveDismissDisabled(saving)
    }
}
