import Charts
import SwiftUI

private func fmtW(_ w: Double) -> String {
    w.rounded() == w ? String(Int(w)) : String(format: "%.1f", w)
}

/// The single home for "my training history," two ways to look back:
///   • Calendar — a month grid that condenses, as you scroll into the feed,
///     into a contribution heatmap; the reverse-chron feed of training days
///     sits beneath it. Tap a day (grid) or a row (feed) for full detail.
///   • Exercises — per-lift progress (est 1RM trend, last session).
/// The nav bar holds ONLY the centered segmented control — no trailing item,
/// so toggling segments never shifts the picker or leaves a blank slot. The
/// calendar owns its own "Today" affordance (and its month state) internally.
struct HistoryView: View {
    @ObservedObject var sync: SyncModel

    enum Segment: String, CaseIterable, Identifiable {
        case calendar, exercises
        var id: String { rawValue }
        var label: String { self == .calendar ? "Calendar" : "Exercises" }
    }

    @State private var segment: Segment = .calendar

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
                        CalendarMonthView(sync: sync)
                    case .exercises:
                        ExerciseHistoryList(sync: sync)
                    }
                }
            }
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .principal) {
                    Picker("View", selection: $segment) {
                        ForEach(Segment.allCases) { s in
                            Text(s.label).tag(s)
                        }
                    }
                    .pickerStyle(.segmented)
                    .frame(width: 240)
                }
            }
            .toolbarColorScheme(.dark, for: .navigationBar)
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
                VStack(spacing: 10) {
                    ForEach(ids, id: \.self) { id in
                        NavigationLink {
                            ExerciseDetailView(sync: sync, exerciseID: id)
                        } label: { row(id) }
                    }
                }
                .padding(16)
            }
            .refreshable { await sync.load() }
        }
    }

    private func row(_ id: String) -> some View {
        let hist = sync.history(for: id)
        let last = hist.last
        let bodyweight = sync.isBodyweightExercise(id)
        return HStack {
            VStack(alignment: .leading, spacing: 4) {
                Text(sync.exerciseName(id).uppercased())
                    .font(Theme.display(20)).foregroundStyle(Theme.text)
                if let last {
                    let summary = bodyweight && last.totalReps > 0
                        ? "\(last.topReps) best · \(last.totalReps) total reps"
                        : (last.bestHoldSeconds.map { "\($0)s best hold" }
                            ?? "\(fmtW(last.topWeight))×\(last.topReps)")
                    Text("\(summary) · \(last.setCount) sets · \(last.date)")
                        .font(Theme.mono(11)).foregroundStyle(Theme.muted)
                }
            }
            Spacer()
            if let last {
                VStack(alignment: .trailing, spacing: 2) {
                    if let estimate = last.est1RM {
                        Text("\(Int(estimate))").font(Theme.mono(18, .bold))
                            .foregroundStyle(Theme.accent)
                        Text("est 1RM").font(Theme.mono(9)).foregroundStyle(Theme.dim)
                    } else if let hold = last.bestHoldSeconds,
                              !bodyweight || last.totalReps == 0 {
                        Text("\(hold)s").font(Theme.mono(18, .bold))
                            .foregroundStyle(Theme.accent)
                        Text("best hold").font(Theme.mono(9)).foregroundStyle(Theme.dim)
                    } else if bodyweight && last.totalReps > 0 {
                        Text("\(last.topReps)").font(Theme.mono(18, .bold))
                            .foregroundStyle(Theme.accent)
                        Text("best reps").font(Theme.mono(9)).foregroundStyle(Theme.dim)
                    }
                }
            }
            Image(systemName: "chevron.right").font(.caption).foregroundStyle(Theme.dim)
        }
        .padding(16)
        .background(Theme.surface).clipShape(RoundedRectangle(cornerRadius: 14))
    }
}

private struct ExerciseDetailView: View {
    @ObservedObject var sync: SyncModel
    let exerciseID: String

    var body: some View {
        let hist = sync.history(for: exerciseID)
        let bodyweight = sync.isBodyweightExercise(exerciseID)
        let repHistory = bodyweight ? hist.filter { $0.bestReps != nil } : []
        let bodyweightReps = !repHistory.isEmpty
        let estimated = hist.filter { $0.est1RM != nil }
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                if bodyweightReps, let best = repHistory.compactMap(\.bestReps).max() {
                    HStack {
                        stat("BEST REPS", "\(best)")
                        Spacer()
                        stat("SESSIONS", "\(hist.count)")
                        Spacer()
                        stat("LAST TOTAL", repHistory.last.map { "\($0.totalReps)" } ?? "—")
                    }
                    chartCard("TOTAL REPS", repHistory) { Double($0.totalReps) }
                } else if let best = hist.compactMap(\.bestHoldSeconds).max() {
                    HStack {
                        stat("BEST HOLD", "\(best)s")
                        Spacer()
                        stat("SESSIONS", "\(hist.count)")
                        Spacer()
                        stat("LAST", hist.last?.bestHoldSeconds.map { "\($0)s" } ?? "—")
                    }
                } else if let best = estimated.compactMap(\.est1RM).max() {
                    HStack {
                        stat("BEST e1RM", "\(Int(best))")
                        Spacer()
                        stat("SESSIONS", "\(hist.count)")
                        Spacer()
                        stat("LAST", hist.last.map { "\(fmtW($0.topWeight))×\($0.topReps)" } ?? "—")
                    }
                }

                if !estimated.isEmpty {
                    chartCard("ESTIMATED 1RM", estimated) { $0.est1RM ?? 0 }
                }

                // Key hold history on the logged set, not catalog modality:
                // any movement can be prescribed as a hold.
                let held = hist.filter { $0.bestHoldSeconds != nil }
                if !held.isEmpty {
                    chartCard("BEST HOLD (s)", held) {
                        Double($0.bestHoldSeconds ?? 0)
                    }
                }

                if let last = hist.last {
                    VStack(alignment: .leading, spacing: 10) {
                        Text("LAST SESSION · \(last.date)")
                            .font(Theme.mono(10, .bold)).tracking(2)
                            .foregroundStyle(Theme.muted)
                        ForEach(lastSessionSets(last.id)) { s in
                            HStack {
                                Text(s.valueLabel(
                                    timed: sync.isTimedSet(s),
                                    bodyweight: sync.isBodyweightExercise(exerciseID)))
                                    .font(Theme.mono(14)).foregroundStyle(Theme.text)
                                Spacer()
                            }
                            .padding(.vertical, 8)
                            .overlay(alignment: .bottom) { Divider().overlay(Theme.surface2) }
                        }
                    }
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

    private func lastSessionSets(_ sid: String) -> [SetLog] {
        sync.sets
            .filter { $0.session_id == sid && $0.exercise_id == exerciseID
                && $0.is_warmup == 0 && $0.deleted_at == nil }
            .sorted { $0.set_index < $1.set_index }
    }

    private func stat(_ label: String, _ value: String) -> some View {
        VStack(spacing: 4) {
            Text(value).font(Theme.mono(20, .bold)).foregroundStyle(Theme.accent)
            Text(label).font(Theme.mono(9)).tracking(1).foregroundStyle(Theme.dim)
        }
    }

    private func chartCard(_ title: String, _ hist: [SyncModel.SessionStat],
                           _ y: @escaping (SyncModel.SessionStat) -> Double) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title).font(Theme.mono(10, .bold)).tracking(2).foregroundStyle(Theme.muted)
            Chart(hist) { s in
                LineMark(x: .value("Date", s.date), y: .value(title, y(s)))
                    .foregroundStyle(Theme.accent)
                    .interpolationMethod(.catmullRom)
                PointMark(x: .value("Date", s.date), y: .value(title, y(s)))
                    .foregroundStyle(Theme.accent)
            }
            .chartXAxis { AxisMarks { _ in AxisGridLine().foregroundStyle(Theme.surface2) } }
            .chartYAxis {
                AxisMarks { AxisGridLine().foregroundStyle(Theme.surface2)
                    AxisValueLabel().foregroundStyle(Theme.muted) }
            }
            .frame(height: 180)
        }
        .padding(16)
        .background(Theme.surface).clipShape(RoundedRectangle(cornerRadius: 14))
    }
}
