import Charts
import SwiftUI

/// A small overview that leads with workout consistency, then drills down
/// into strength and optional weight.
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
                        ConsistencyCard(sync: sync)
                        strength
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

/// The first thing Progress shows: this week, the running weekly streak and a
/// day-by-day calendar of completed workouts.
private struct ConsistencyCard: View {
    @ObservedObject var sync: SyncModel
    @Environment(\.horizontalSizeClass) private var sizeClass

    var body: some View {
        let weekCount = sizeClass == .regular ? 26 : 16
        let summary = WorkoutConsistency(sessions: sync.sessions, today: sync.todayString, weekCount: weekCount)
        let thisWeek = summary.weeks.last?.completed ?? 0
        let scheduled = WorkoutConsistency.scheduledPerWeek(sync.plan?.schedule)
        let thisWeekValue: String = scheduled.map { "\(thisWeek)/\($0)" } ?? "\(thisWeek)"
        let thisWeekLabel: String = scheduled.map { "\(thisWeek) of \($0) scheduled workouts this week" }
            ?? "\(thisWeek) workouts this week"
        NavigationLink {
            WorkoutConsistencyView(sync: sync)
        } label: {
            VStack(alignment: .leading, spacing: 14) {
                progressHeading("Consistency", icon: "calendar.badge.checkmark")
                ConsistencyStats(stats: [
                    .init(value: "\(summary.currentStreak)", caption: "week streak",
                          accessibility: "\(summary.currentStreak) week streak"),
                    .init(value: thisWeekValue, caption: "this week", accessibility: thisWeekLabel),
                    .init(value: "\(summary.total)", caption: "in \(weekCount) weeks",
                          accessibility: "\(summary.total) workouts in \(weekCount) weeks"),
                ])
                ConsistencyHeatmap(weeks: summary.weeks)
                Text("Completed in Très Fort · weeks run Monday–Sunday")
                    .font(.caption).foregroundStyle(Theme.muted)
            }
            .progressCard()
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("progress.consistency")
    }
}

struct WorkoutConsistencyView: View {
    @ObservedObject var sync: SyncModel
    @State private var weekCount = 16

    var body: some View {
        let summary = WorkoutConsistency(sessions: sync.sessions, today: sync.todayString, weekCount: weekCount)
        List {
            if sync.isUsingCachedState { CachedStateBanner() }
            if let error = sync.loadError { Text(error).foregroundStyle(.orange) }
            Section {
                Picker("Period", selection: $weekCount) {
                    ForEach([8, 16, 26], id: \.self) { Text("\($0) weeks").tag($0) }
                }.pickerStyle(.segmented)
                Text("\(summary.total) completed workouts").font(.title2.bold())
                    .accessibilityIdentifier("consistency.total")
                ConsistencyStats(stats: [
                    .init(value: "\(summary.currentStreak)", caption: "week streak",
                          accessibility: "Current streak: \(summary.currentStreak) weeks"),
                    .init(value: "\(summary.longestStreak)", caption: "best streak",
                          accessibility: "Best streak: \(summary.longestStreak) weeks"),
                    .init(value: "\(summary.activeDays)", caption: "days trained",
                          accessibility: "\(summary.activeDays) days trained in \(weekCount) weeks"),
                ])
                ConsistencyHeatmap(weeks: summary.weeks)
                WorkoutConsistencyChart(weeks: summary.weeks).frame(height: 180)
            } footer: {
                Text("Completed Très Fort workouts by workout date. Weeks run Monday–Sunday. A streak counts weeks in a row with at least one completed workout; the current week keeps it alive until Sunday ends. Activities imported from other apps or logged separately are in the calendar on Today.")
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

private struct ConsistencyStats: View {
    struct Stat: Identifiable {
        var id: String { caption }
        let value: String
        let caption: String
        let accessibility: String
    }

    let stats: [Stat]

    var body: some View {
        ViewThatFits(in: .horizontal) {
            HStack(alignment: .top, spacing: 12) { tiles }
            VStack(alignment: .leading, spacing: 10) { tiles }
        }
    }

    private var tiles: some View {
        ForEach(stats) { stat in
            VStack(alignment: .leading, spacing: 2) {
                Text(stat.value).font(Theme.number(24)).foregroundStyle(Theme.text)
                    .monospacedDigit().lineLimit(1)
                Text(stat.caption).font(.caption).foregroundStyle(Theme.muted)
                    .lineLimit(1)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(stat.accessibility)
        }
    }
}

/// One column per Monday–Sunday week, one square per day. A filled square has
/// at least one completed workout; today is outlined and later days are empty.
private struct ConsistencyHeatmap: View {
    let weeks: [WorkoutConsistency.Week]
    @State private var width: CGFloat = 0

    private let gap: CGFloat = 3
    private let labelWidth: CGFloat = 14
    private let maxCell: CGFloat = 22

    var body: some View {
        let cell = cellSize
        let monthLabels = monthLabelIndexes
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: gap) {
                Color.clear.frame(width: labelWidth, height: 1)
                ForEach(Array(weeks.enumerated()), id: \.element.id) { index, week in
                    Text(monthLabels.contains(index) ? monthName(week) : "")
                        .font(.caption2).foregroundStyle(Theme.muted)
                        .fixedSize()
                        .frame(width: cell, alignment: .leading)
                }
            }
            HStack(alignment: .top, spacing: gap) {
                VStack(spacing: gap) {
                    ForEach(Array(["M", "", "W", "", "F", "", ""].enumerated()), id: \.offset) { _, label in
                        Text(label).font(.caption2).foregroundStyle(Theme.muted)
                            .frame(width: labelWidth, height: cell)
                    }
                }
                ForEach(weeks) { week in
                    VStack(spacing: gap) {
                        ForEach(week.days) { day in square(day, size: cell) }
                    }
                }
            }
        }
        .dynamicTypeSize(...DynamicTypeSize.xLarge)
        .frame(maxWidth: .infinity, alignment: .leading)
        .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { width = $0 }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilitySummary)
        .accessibilityIdentifier("consistency.heatmap")
    }

    private var cellSize: CGFloat {
        guard !weeks.isEmpty else { return maxCell }
        let columns = CGFloat(weeks.count)
        let available = width - labelWidth - gap * columns
        return max(6, min(maxCell, (available / columns).rounded(.down)))
    }

    /// The first column and each week containing the 1st of a month, unless
    /// that would crowd the previous label.
    private var monthLabelIndexes: Set<Int> {
        var result: Set<Int> = []
        var last = -10
        for (index, week) in weeks.enumerated() {
            let startsMonth = index == 0 || week.days.contains { $0.date.hasSuffix("-01") }
            if startsMonth && index - last >= 3 { result.insert(index); last = index }
        }
        return result
    }

    private func monthName(_ week: WorkoutConsistency.Week) -> String {
        let date = week.days.first { $0.date.hasSuffix("-01") }?.date ?? week.start
        guard let parsed = CalendarProjection.date(from: date) else { return "" }
        return ProgressDateFormat.month.string(from: parsed)
    }

    @ViewBuilder
    private func square(_ day: WorkoutConsistency.Day, size: CGFloat) -> some View {
        let shape = RoundedRectangle(cornerRadius: max(2, size * 0.22))
        Group {
            if day.isFuture {
                shape.stroke(Theme.dim.opacity(0.5), lineWidth: 1)
            } else {
                shape.fill(day.completed > 0 ? Theme.accent : Theme.dim.opacity(0.45))
                    .overlay { if day.isToday { shape.stroke(Theme.text, lineWidth: 1.5) } }
            }
        }
        .frame(width: size, height: size)
    }

    private var accessibilitySummary: String {
        let days = weeks.flatMap(\.days).filter { $0.completed > 0 }.count
        let workouts = weeks.reduce(0) { $0 + $1.completed }
        return "Workout calendar for the last \(weeks.count) weeks: \(workouts) completed workouts on \(days) days."
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

private enum ProgressDateFormat {
    static let shortDate: DateFormatter = {
        let formatter = DateFormatter()
        formatter.calendar = CalendarProjection.calendar
        formatter.timeZone = CalendarProjection.calendar.timeZone
        formatter.setLocalizedDateFormatFromTemplate("MMM d")
        return formatter
    }()

    static let month: DateFormatter = {
        let formatter = DateFormatter()
        formatter.calendar = CalendarProjection.calendar
        formatter.timeZone = CalendarProjection.calendar.timeZone
        formatter.setLocalizedDateFormatFromTemplate("MMM")
        return formatter
    }()
}

private func shortDate(_ civilDate: String) -> String {
    guard let date = CalendarProjection.date(from: civilDate) else { return civilDate }
    return ProgressDateFormat.shortDate.string(from: date)
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
