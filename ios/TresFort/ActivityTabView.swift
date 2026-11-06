import SwiftUI

enum ActivitySide: Hashable { case history, progress }

/// An entry opened from History. Each row pushes its own value: rows that
/// share a date must not share one, or the list highlights and opens the
/// first row with that value instead of the one tapped.
struct ActivityHistoryDay: Hashable {
    let entryID: String
    let date: String
    let focus: DayAgendaFocus?
}

/// The Activity tab. History lists what the member has done, newest first,
/// and opens each date's record: the sets of a workout, a run's route map, a
/// logged activity. Progress keeps the consistency, strength, endurance and
/// weight trends.
struct ActivityTabView: View {
    @ObservedObject var sync: SyncModel
    var weight: BodyWeightModel? = nil
    var onHealthSettings: () -> Void = {}
    /// Continuing today's workout from its record shows it on Today.
    var onShowWorkout: (() -> Void)? = nil
    @State private var side = ActivitySide.history

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                Picker("Activity", selection: $side) {
                    Text("History").tag(ActivitySide.history)
                    Text("Progress").tag(ActivitySide.progress)
                }
                .pickerStyle(.segmented)
                .accessibilityIdentifier("activity.side")
                .padding(.horizontal, 16)
                .padding(.vertical, 8)
                switch side {
                case .history:
                    ActivityHistoryView(sync: sync)
                case .progress:
                    TrainingProgressView(sync: sync, weight: weight, onHealthSettings: onHealthSettings)
                }
            }
            .background(Theme.background)
            .navigationTitle("Activity")
            .navigationBarTitleDisplayMode(.inline)
            .navigationDestination(for: ActivityHistoryDay.self) { day in
                DayAgendaView(sync: sync, dateString: day.date, focus: day.focus,
                              onStartWorkout: onShowWorkout)
                    .navigationTitle(ActivityHistory.dayTitle(day.date))
                    .navigationBarTitleDisplayMode(.inline)
            }
        }
    }
}

/// Every workout, run, ride and logged activity, by month, with a filter for
/// the kinds the member has done.
struct ActivityHistoryView: View {
    @ObservedObject var sync: SyncModel
    @AppStorage(RunDistanceUnit.preferenceKey) private var unitRaw = RunDistanceUnit.miles.rawValue
    @State private var category: ActivityHistory.Category?

    var body: some View {
        let history = makeHistory()
        let categories = history.categories
        // A filter whose last entry went away shows everything again.
        let shown = category.flatMap { categories.contains($0) ? $0 : nil }
        let months = history.months(in: shown)
        List {
            if sync.isUsingCachedState {
                CachedStateBanner()
                    .listRowBackground(Color.clear)
                    .listRowInsets(EdgeInsets(top: 4, leading: 0, bottom: 4, trailing: 0))
            }
            if let error = sync.loadError {
                Section {
                    Text(error).foregroundStyle(Theme.danger)
                    Button("Retry") { Task { await sync.load() } }
                }
            }
            if categories.count > 1 {
                filters(categories, selected: shown)
                    .listRowBackground(Color.clear)
                    .listRowInsets(EdgeInsets(top: 0, leading: 0, bottom: 0, trailing: 0))
            }
            if months.isEmpty {
                Section {
                    if sync.isLoading {
                        ProgressView("Loading your activity…")
                    } else {
                        Text("Nothing here yet. Workouts you finish, runs you record and activities you log show up here.")
                            .font(.subheadline).foregroundStyle(Theme.muted)
                            .fixedSize(horizontal: false, vertical: true)
                            .accessibilityIdentifier("activityHistory.empty")
                    }
                }
            }
            ForEach(months) { month in
                Section {
                    ForEach(month.entries) { entry in
                        NavigationLink(value: ActivityHistoryDay(entryID: entry.id, date: entry.date,
                                                                 focus: entry.focus)) {
                            ActivityHistoryRow(entry: entry)
                        }
                        .accessibilityIdentifier("activityHistory.entry." + entry.id)
                    }
                } header: {
                    Text(ActivityHistory.monthTitle(month.id)).textCase(nil)
                }
            }
        }
        .scrollContentBackground(.hidden)
        .refreshable { await sync.load() }
    }

    private func makeHistory() -> ActivityHistory {
        let today = sync.todayString
        var hidden: [String: Bool] = [:]
        return ActivityHistory(
            sessions: sync.sessions,
            activities: sync.activities,
            logged: sync.manualActivities,
            today: today,
            unit: RunDistanceUnit(rawValue: unitRaw) ?? .miles,
            setCount: { sync.loggedSetCount(sessionID: $0) },
            workout: { id in
                sync.workout(id: id).map { workout in
                    ActivityHistory.WorkoutInfo(
                        name: workout.name,
                        isRunOnly: !workout.exercises.isEmpty && workout.exercises.allSatisfy(\.isOutdoorRun))
                }
            },
            // Like the calendar, a trip day without training hides the
            // activities a provider still reports for it.
            isHidden: { date in
                if let known = hidden[date] { return known }
                let value = sync.projection(for: date, today: today).suppressesScheduleAndEndurance
                hidden[date] = value
                return value
            })
    }

    private func filters(_ categories: [ActivityHistory.Category],
                         selected: ActivityHistory.Category?) -> some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                chip("All", isSelected: selected == nil, id: "all") { category = nil }
                ForEach(categories) { item in
                    chip(item.title, isSelected: selected == item, id: item.rawValue) { category = item }
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 4)
        }
    }

    private func chip(_ title: String, isSelected: Bool, id: String,
                      action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(.subheadline.weight(.semibold))
                .padding(.horizontal, 14)
                .frame(minHeight: 36)
                .foregroundStyle(isSelected ? Theme.onAccent : Theme.text)
                .background(isSelected ? Theme.accent : Theme.surface, in: Capsule())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
        .accessibilityIdentifier("activityHistory.filter." + id)
    }
}

private struct ActivityHistoryRow: View {
    let entry: ActivityHistory.Entry

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: entry.glyph)
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(color)
                .frame(width: 34, height: 34)
                .background(color.opacity(0.15), in: Circle())
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(entry.title)
                        .font(.subheadline.weight(.semibold)).foregroundStyle(Theme.text)
                        .lineLimit(2)
                    if entry.hasRoute {
                        Image(systemName: "map")
                            .font(.caption).foregroundStyle(Theme.muted)
                            .accessibilityLabel("Has a route map")
                    }
                }
                Text(([ActivityHistory.dayTitle(entry.date)] + entry.details).joined(separator: " · "))
                    .font(.caption).foregroundStyle(Theme.muted)
                    .monospacedDigit()
                if entry.inProgress {
                    Text("In progress").font(.caption.weight(.semibold)).foregroundStyle(Theme.accent)
                }
                SourceAttributionLabel(text: entry.attribution)
            }
            Spacer(minLength: 0)
        }
        .padding(.vertical, 2)
        .accessibilityElement(children: .combine)
    }

    private var color: Color {
        switch entry.category {
        case .workouts: return Theme.accent
        case .other: return WorkoutCategory.activity.color
        case .runs, .rides, .swims, .walks: return WorkoutCategory.endurance.color
        }
    }
}
