import Charts
import SwiftUI

private func fmtW(_ w: Double) -> String {
    w.rounded() == w ? String(Int(w)) : String(format: "%.1f", w)
}

/// Calendar combines the upcoming schedule with recorded training. Exercise
/// progress and the recurring weekly schedule have explicit, separate routes.
struct HistoryView: View {
    @ObservedObject var sync: SyncModel

    enum Segment { case calendar, exercises }

    @State private var segment: Segment = .calendar
    @State private var showWeeklySchedule = false

    var body: some View {
        NavigationStack {
            ZStack {
                Theme.background
                VStack(spacing: 0) {
                    if sync.isUsingCachedState {
                        CachedStateBanner()
                    }
                    switch segment {
                    case .calendar:
                        CalendarMonthView(sync: sync,
                                          onExerciseProgress: { segment = .exercises },
                                          onWeeklySchedule: { showWeeklySchedule = true })
                    case .exercises:
                        ExerciseHistoryList(sync: sync)
                    }
                }
            }
            .navigationTitle(segment == .calendar ? "Calendar" : "Exercise progress")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                if segment == .exercises {
                    ToolbarItem(placement: .topBarLeading) {
                        Button("Calendar", systemImage: "chevron.left") { segment = .calendar }
                    }
                }
            }
            .toolbarColorScheme(.dark, for: .navigationBar)
            .sheet(isPresented: $showWeeklySchedule) { WeeklyScheduleView(sync: sync) }
        }
        .preferredColorScheme(.dark)
    }
}

/// Per-exercise progress list — the original History content, now embeddable
/// in the merged tab's NavigationStack (owns no nav chrome of its own).
private struct ExerciseHistoryList: View {
    @ObservedObject var sync: SyncModel

    var body: some View {
        let ids = sync.loggedExerciseIDs
        if ids.isEmpty {
            VStack(spacing: 8) {
                Text("NO HISTORY").font(Theme.display(28)).foregroundStyle(Theme.text)
                Text("Log some sets and they'll show here.")
                    .font(Theme.mono(13)).foregroundStyle(Theme.muted)
            }
        } else {
            ScrollView {
                LazyVStack(spacing: 10) {
                    ForEach(ids, id: \.self) { id in
                        NavigationLink {
                            ExerciseDetailView(sync: sync, exerciseID: id)
                        } label: { row(id) }
                        .accessibilityIdentifier("history.exercise." + id)
                    }
                }
                .padding(16)
            }
            .refreshable { await sync.load() }
        }
    }

    private func row(_ id: String) -> some View {
        let last = sync.latestHistory(for: id)
        return HStack(spacing: 16) {
            VStack(alignment: .leading, spacing: 6) {
                Text(sync.exerciseName(id).uppercased())
                    .font(Theme.display(20)).foregroundStyle(Theme.text)
                if let last {
                    ForEach(Array(last.cohorts.prefix(2))) { cohort in
                        Text(cohort.valueLabel)
                            .font(Theme.mono(11)).foregroundStyle(Theme.muted)
                    }
                    if last.cohorts.count > 2 {
                        Text("+\(last.cohorts.count - 2) more load/mode combinations")
                            .font(Theme.mono(11)).foregroundStyle(Theme.muted)
                    }
                    Text("\(last.setCount) sets · \(last.date)")
                        .font(Theme.mono(11)).foregroundStyle(Theme.muted)
                }
            }
            Spacer()
            Image(systemName: "chevron.right").font(.caption).foregroundStyle(Theme.dim)
        }
        .padding(16)
        .background(Theme.surface).clipShape(RoundedRectangle(cornerRadius: 14))
    }
}

private struct ExerciseDetailView: View {
    @ObservedObject var sync: SyncModel
    let exerciseID: String

    @State private var selectedProgress: ExerciseHistoryProgress.ID?

    var body: some View {
        let hist = sync.history(for: exerciseID)
        let options = ExerciseHistoryProgress.options(hist)
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                if let progress = ExerciseHistoryProgress.selected(selectedProgress, from: options) {
                    progressCard(progress, options: options)
                }
                ForEach(hist.reversed()) { session in
                    DisclosureGroup("SESSION · \(session.date) · \(session.setCount) sets") {
                        VStack(alignment: .leading, spacing: 10) {
                            if session.totalReps > 0 {
                                Text("\(session.totalReps) total reps · work logged")
                            }
                            if let volume = session.volume {
                                Text("\(fmtW(volume)) lb external-load volume")
                            }
                            if let row = sync.sessions.first(where: { $0.id == session.id }) {
                                let feedback = WorkoutFeedback(notes: row.notes, perceivedFatigue: row.perceived_fatigue)
                                if !feedback.isEmpty { SavedWorkoutFeedbackView(feedback: feedback) }
                            }
                            ForEach(sessionSets(session.id)) { set in
                                Text(set.valueLabel(timed: sync.isTimedSet(set),
                                    bodyweight: sync.isBodyweightExercise(exerciseID)))
                            }
                        }
                        .font(Theme.mono(12)).foregroundStyle(Theme.text)
                        .frame(maxWidth: .infinity, alignment: .leading).padding(.top, 8)
                    }
                    .font(Theme.mono(11)).foregroundStyle(Theme.muted)
                }
            }
            .padding(20)
        }
        .background(Theme.background)
        .navigationTitle(sync.exerciseName(exerciseID))
        .navigationBarTitleDisplayMode(.inline)
        .toolbarColorScheme(.dark, for: .navigationBar)
        .preferredColorScheme(.dark)
    }

    private func progressCard(_ progress: ExerciseHistoryProgress,
                              options: [ExerciseHistoryProgress]) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("PROGRESS").font(Theme.mono(10, .bold)).tracking(2)
                .foregroundStyle(Theme.muted)
            if options.count > 1 {
                Picker("Progress", selection: Binding(
                    get: { progress.id },
                    set: { selectedProgress = $0 }
                )) {
                    ForEach(options) { option in
                        Text(option.title).tag(option.id)
                    }
                }
                .pickerStyle(.menu)
                .tint(Theme.accent)
                .accessibilityIdentifier("history.progress.selector")
            } else {
                Text(progress.title).font(Theme.mono(13, .bold)).foregroundStyle(Theme.text)
            }
            if let last = progress.points.last {
                if progress.hasTrend {
                    Text("Best \(fmtW(progress.points.map(\.value).max() ?? 0)) · Latest \(fmtW(last.value)) \(progress.unit)")
                        .font(Theme.mono(12)).foregroundStyle(Theme.accent)
                    Chart(progress.points) { point in
                        LineMark(x: .value("Date", point.date), y: .value(progress.title, point.value))
                            .foregroundStyle(Theme.accent)
                        PointMark(x: .value("Date", point.date), y: .value(progress.title, point.value))
                            .foregroundStyle(Theme.accent)
                    }
                    .chartXAxis {
                        AxisMarks(values: axisDates(progress.points.map(\.date))) { value in
                            AxisGridLine()
                            AxisValueLabel(anchor: value.index == 0 ? .topLeading
                                : value.index == value.count - 1 ? .topTrailing : .top)
                                .foregroundStyle(Theme.muted)
                        }
                    }
                    .chartYAxis { AxisMarks { AxisValueLabel().foregroundStyle(Theme.muted) } }
                    .frame(height: 180)
                    .accessibilityIdentifier("history.progress.chart")
                } else {
                    Text("\(fmtW(last.value)) \(progress.unit) · \(last.date)")
                        .font(Theme.mono(14)).foregroundStyle(Theme.accent)
                        .accessibilityIdentifier("history.progress.summary")
                    Text("Log another day to see a trend.")
                        .font(Theme.mono(11)).foregroundStyle(Theme.muted)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(16)
        .background(Theme.surface).clipShape(RoundedRectangle(cornerRadius: 14))
    }

    /// Retain every plotted day, but label only the range endpoints so full
    /// civil dates stay readable inside the progress card at phone widths.
    private func axisDates(_ dates: [String]) -> [String] {
        let unique = Array(Set(dates)).sorted()
        guard unique.count > 2 else { return unique }
        return [unique[0], unique[unique.count - 1]]
    }

    private func sessionSets(_ sid: String) -> [SetLog] {
        sync.setsForSession(sid).filter { $0.exercise_id == exerciseID
            && $0.is_warmup == 0 && $0.deleted_at == nil }
            .sorted { $0.set_index < $1.set_index }
    }
}
