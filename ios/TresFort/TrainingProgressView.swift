import Charts
import SwiftUI

/// A small overview with separate drill-downs for exercise, weight and habit.
struct TrainingProgressView: View {
    @ObservedObject var sync: SyncModel
    var weight: BodyWeightModel? = nil
    var onHealthSettings: () -> Void = {}

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 24) {
                    if sync.isUsingCachedState { CachedStateBanner() }
                    if let error = sync.loadError {
                        Text(error).font(.footnote).foregroundStyle(.orange)
                        Button("Retry training history") { Task { await sync.load() } }
                    }
                    if sync.isLoading && sync.sessions.isEmpty && sync.sets.isEmpty {
                        ProgressView("Loading training history…")
                    } else if sync.hasVerifiedPlanState || !sync.sessions.isEmpty || !sync.sets.isEmpty {
                        strength
                        NavigationLink {
                            WorkoutConsistencyView(sync: sync)
                        } label: {
                            VStack(alignment: .leading, spacing: 14) {
                                progressHeading("Consistency", icon: "calendar.badge.checkmark")
                                let summary = WorkoutConsistency(sessions: sync.sessions, today: sync.todayString)
                                Text("\(summary.total) workouts in 8 weeks")
                                    .font(.headline).foregroundStyle(Theme.text)
                                WorkoutConsistencyChart(weeks: summary.weeks)
                                    .frame(height: 105)
                                Text("This week so far: \(summary.weeks.last?.completed ?? 0)")
                                    .font(.caption).foregroundStyle(Theme.accent)
                                Text("Completed in Très Fort · Monday–Sunday")
                                    .font(.caption).foregroundStyle(Theme.muted)
                            }
                            .progressCard()
                        }
                        .buttonStyle(.plain)
                        .accessibilityIdentifier("progress.consistency")
                    } else if sync.loadError == nil {
                        Text("Your training history will appear after syncing.")
                            .foregroundStyle(Theme.muted)
                    }
                    if let weight {
                        WeightProgressCard(model: weight, onHealthSettings: onHealthSettings)
                    }
                }
                .padding(16)
            }
            .background(Theme.background)
            .navigationTitle("Progress")
            .toolbarColorScheme(.dark, for: .navigationBar)
            .refreshable {
                await sync.load()
                await weight?.refresh()
            }
        }
        .preferredColorScheme(.dark)
    }

    private var strength: some View {
        VStack(alignment: .leading, spacing: 12) {
            NavigationLink {
                ExerciseHistoryList(sync: sync)
                    .background(Theme.background)
                    .navigationTitle("Strength")
                    .navigationBarTitleDisplayMode(.inline)
            } label: {
                progressHeading("Strength", icon: "dumbbell.fill")
            }
            .accessibilityIdentifier("progress.strength")
            if sync.loggedExerciseIDs.isEmpty {
                Text("Your first working set starts your progress.")
                    .font(.subheadline).foregroundStyle(Theme.muted)
            } else {
                Text("Recent lifts · tap for trends and best sets")
                    .font(.caption).foregroundStyle(Theme.muted)
                ForEach(Array(sync.loggedExerciseIDs.prefix(3)), id: \.self) { id in
                    NavigationLink {
                        ExerciseDetailView(sync: sync, exerciseID: id)
                    } label: {
                        ExerciseHistoryRow(sync: sync, exerciseID: id)
                    }
                    .accessibilityIdentifier("progress.exercise." + id)
                }
                NavigationLink("All exercises (\(sync.loggedExerciseIDs.count))") {
                    ExerciseHistoryList(sync: sync)
                        .background(Theme.background)
                        .navigationTitle("Strength")
                        .navigationBarTitleDisplayMode(.inline)
                }
                .font(.subheadline).frame(minHeight: 44)
            }
        }
        .progressCard()
        .buttonStyle(.plain)
    }
}

private struct WeightProgressCard: View {
    @ObservedObject var model: BodyWeightModel
    let onHealthSettings: () -> Void
    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        Group {
            if model.enabled {
                NavigationLink {
                    BodyWeightView(model: model, onManageAccess: onHealthSettings)
                } label: {
                    VStack(alignment: .leading, spacing: 12) {
                        progressHeading("Weight", icon: "scalemass")
                        if let latest = model.history?.latest {
                            let unit: BodyWeightUnit = Locale.current.measurementSystem == .us ? .pounds : .kilograms
                            Text("\(unit.value(latest.kilograms).formatted(.number.precision(.fractionLength(1)))) \(unit.rawValue)")
                                .font(.title2.bold()).foregroundStyle(Theme.text)
                            Text(latest.date.formatted(date: .abbreviated, time: .omitted))
                                .font(.caption).foregroundStyle(Theme.muted)
                        } else {
                            Text(model.isBusy ? "Reading weight…" : model.errorMessage ?? "No weight yet")
                                .font(.subheadline).foregroundStyle(Theme.muted)
                        }
                        Text("Apple Health · Only visible to you")
                            .font(.caption).foregroundStyle(Theme.muted)
                    }
                    .progressCard()
                }
                .accessibilityIdentifier("progress.weight")
            } else if model.isAvailable && !model.requiresPersonalSignIn {
                Button(action: onHealthSettings) {
                    VStack(alignment: .leading, spacing: 10) {
                        progressHeading("Weight", icon: "scalemass")
                        Text("Optional · Show your Apple Health weight alongside your lifting.")
                            .font(.subheadline).foregroundStyle(Theme.muted)
                        Text("Manage in Apple Health settings").font(.subheadline).foregroundStyle(Theme.accent)
                    }
                    .progressCard()
                }
                .accessibilityIdentifier("progress.weightSettings")
            }
        }
        .buttonStyle(.plain)
        .task { await model.refresh() }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active { Task { await model.refresh() } }
        }
    }
}

struct WorkoutConsistencyView: View {
    @ObservedObject var sync: SyncModel
    @State private var weekCount = 8

    var body: some View {
        let summary = WorkoutConsistency(sessions: sync.sessions, today: sync.todayString, weekCount: weekCount)
        List {
            if sync.isUsingCachedState { CachedStateBanner() }
            if let error = sync.loadError { Text(error).foregroundStyle(.orange) }
            Section {
                Picker("Period", selection: $weekCount) {
                    ForEach([4, 8, 12], id: \.self) { Text("\($0) weeks").tag($0) }
                }.pickerStyle(.segmented)
                Text("\(summary.total) completed workouts").font(.title2.bold())
                    .accessibilityIdentifier("consistency.total")
                WorkoutConsistencyChart(weeks: summary.weeks).frame(height: 180)
            } footer: {
                Text("Completed Très Fort workouts by workout date. Weeks run Monday–Sunday; the highlighted current week is still in progress. Activities imported from other apps or logged separately are on Calendar.")
            }
            Section("By week") {
                ForEach(summary.weeks.reversed()) { week in
                    LabeledContent {
                        Text("\(week.completed)").monospacedDigit()
                    } label: {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(week.isCurrent ? "This week so far" : "Week of \(shortDate(week.start))")
                            Text("\(shortDate(week.start)) – \(shortDate(week.end))")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }
            }
        }
        .navigationTitle("Consistency")
        .navigationBarTitleDisplayMode(.inline)
        .refreshable { await sync.load() }
    }
}

private struct WorkoutConsistencyChart: View {
    let weeks: [WorkoutConsistency.Week]
    var body: some View {
        Chart(weeks) { week in
            BarMark(x: .value("Week of", week.start), y: .value("Workouts", week.completed))
                .foregroundStyle(week.isCurrent ? Theme.accent : Theme.muted)
                .accessibilityLabel(week.isCurrent ? "This week so far" : "Week of \(shortDate(week.start))")
                .accessibilityValue("\(week.completed) completed workouts")
        }
        .chartYScale(domain: 0...max(1, weeks.map(\.completed).max() ?? 0))
        .chartYAxis { AxisMarks(values: .stride(by: 1)) }
        .chartXAxis {
            AxisMarks(values: weeks.enumerated()
                .filter { [0, weeks.count / 2, weeks.count - 1].contains($0.offset) }
                .map { $0.element.start }) { value in
                AxisValueLabel(anchor: value.index == 0 ? .topLeading
                    : value.index == value.count - 1 ? .topTrailing : .top) {
                    if let date = value.as(String.self) { Text(shortDate(date)) }
                }
            }
        }
        .accessibilityIdentifier("consistency.chart")
    }
}

private func shortDate(_ civilDate: String) -> String {
    guard let date = CalendarProjection.date(from: civilDate) else { return civilDate }
    let formatter = DateFormatter()
    formatter.calendar = CalendarProjection.calendar
    formatter.timeZone = CalendarProjection.calendar.timeZone
    formatter.setLocalizedDateFormatFromTemplate("MMM d")
    return formatter.string(from: date)
}

private func progressHeading(_ title: String, icon: String) -> some View {
    ProgressHeading(title: title, icon: icon)
}

private struct ProgressHeading: View {
    let title: String
    let icon: String
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    var body: some View {
        HStack {
            if dynamicTypeSize.isAccessibilitySize {
                Text(title).font(.headline).lineLimit(1).minimumScaleFactor(0.8)
            } else {
                Label(title, systemImage: icon).font(.headline)
            }
            Spacer(minLength: 8)
            Image(systemName: "chevron.right").font(.system(size: 12, weight: .semibold))
        }
        .foregroundStyle(Theme.accent)
        .frame(minHeight: 44)
        .contentShape(Rectangle())
    }
}

private extension View {
    func progressCard() -> some View {
        padding(16).frame(maxWidth: .infinity, alignment: .leading)
            .background(Theme.surface).clipShape(RoundedRectangle(cornerRadius: 16))
    }
}
