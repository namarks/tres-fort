import Charts
import SwiftUI

private func fmtW(_ w: Double) -> String {
    w.rounded() == w ? String(Int(w)) : String(format: "%.1f", w)
}

struct HistoryView: View {
    @ObservedObject var sync: SyncModel

    var body: some View {
        NavigationStack {
            ZStack {
                Theme.background
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
            .navigationTitle("History")
            .navigationBarTitleDisplayMode(.inline)
            .toolbarColorScheme(.dark, for: .navigationBar)
        }
        .preferredColorScheme(.dark)
    }

    private func row(_ id: String) -> some View {
        let hist = sync.history(for: id)
        let last = hist.last
        return HStack {
            VStack(alignment: .leading, spacing: 4) {
                Text(sync.exerciseName(id).uppercased())
                    .font(Theme.display(20)).foregroundStyle(Theme.text)
                if let last {
                    Text("\(fmtW(last.topWeight))×\(last.topReps) · \(last.setCount) sets · \(last.date)")
                        .font(Theme.mono(11)).foregroundStyle(Theme.muted)
                }
            }
            Spacer()
            if let last {
                VStack(alignment: .trailing, spacing: 2) {
                    Text("\(Int(last.est1RM))").font(Theme.mono(18, .bold))
                        .foregroundStyle(Theme.accent)
                    Text("est 1RM").font(Theme.mono(9)).foregroundStyle(Theme.dim)
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
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                if let best = hist.map(\.est1RM).max() {
                    HStack {
                        stat("BEST e1RM", "\(Int(best))")
                        Spacer()
                        stat("SESSIONS", "\(hist.count)")
                        Spacer()
                        stat("LAST", hist.last.map { "\(fmtW($0.topWeight))×\($0.topReps)" } ?? "—")
                    }
                }

                chartCard("ESTIMATED 1RM", hist) { s in s.est1RM }

                // Only timed holds have a meaningful set duration. Rep sets
                // logged before #30 still carry an incidental wall-clock
                // duration in the DB, so gate this chart on modality, not
                // just avgDuration > 0.
                if sync.isTimedExercise(exerciseID), hist.contains(where: { $0.avgDuration > 0 }) {
                    chartCard("AVG SET DURATION (s)", hist) { Double($0.avgDuration) }
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
