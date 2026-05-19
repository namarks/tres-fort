import SwiftUI

private func fmt(_ w: Double) -> String {
    w.rounded() == w ? String(Int(w)) : String(format: "%.1f", w)
}

struct TodayView: View {
    @ObservedObject var auth: AuthModel
    @StateObject private var sync: SyncModel

    init(auth: AuthModel) {
        self.auth = auth
        _sync = StateObject(wrappedValue: SyncModel(auth: auth))
    }

    var body: some View {
        NavigationStack {
            ZStack(alignment: .bottom) {
                Color.black.ignoresSafeArea()
                content
                if sync.restEndDate != nil { RestBar(sync: sync) }
            }
            .navigationTitle(sync.plan?.name ?? "lift-coach")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    if !sync.running, let plan = sync.plan, plan.days.count > 1 {
                        Menu {
                            ForEach(plan.days) { d in
                                Button(d.title) { sync.selectedDayID = d.id }
                            }
                        } label: {
                            HStack(spacing: 4) {
                                Text(sync.selectedDay?.day_label ?? "Day")
                                Image(systemName: "chevron.down").font(.caption2)
                            }.font(.subheadline.weight(.semibold))
                        }
                    } else if sync.running {
                        Text("Ex \(sync.exerciseIndex + 1)/\(sync.exercises.count)")
                            .font(.subheadline.monospaced()).foregroundStyle(.secondary)
                    }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Menu {
                        Button("Refresh") { Task { await sync.load() } }
                        if sync.running {
                            Button("End workout", role: .destructive) {
                                Task { await sync.finishWorkout() }
                            }
                        }
                        Button("Sign out", role: .destructive) { auth.signOut() }
                    } label: { Image(systemName: "ellipsis.circle") }
                }
            }
            .toolbarColorScheme(.dark, for: .navigationBar)
        }
        .preferredColorScheme(.dark)
        .task { await sync.load() }
    }

    @ViewBuilder private var content: some View {
        if sync.isLoading && sync.plan == nil {
            ProgressView().tint(.white)
        } else if sync.finished {
            FinishedView(sync: sync)
        } else if sync.running {
            RunnerView(sync: sync)
        } else if let day = sync.selectedDay {
            OverviewView(sync: sync, day: day)
        } else {
            VStack(spacing: 8) {
                Text("No plan yet").foregroundStyle(.white).font(.headline)
                Text("Ask Claude to build one, then pull to refresh.")
                    .font(.footnote).foregroundStyle(.secondary)
            }
        }
    }
}

// MARK: - Overview (before start)

private struct OverviewView: View {
    @ObservedObject var sync: SyncModel
    let day: DayTemplate

    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(spacing: 10) {
                    HStack {
                        Text(day.title.uppercased())
                            .font(.system(size: 15, weight: .heavy)).foregroundStyle(.secondary)
                        Spacer()
                    }
                    ForEach(day.exercises) { ex in
                        HStack {
                            Text(ex.exercise_name.uppercased())
                                .font(.system(size: 19, weight: .heavy)).foregroundStyle(.white)
                            Spacer()
                            Text(ex.targetLabel)
                                .font(.system(.subheadline, design: .monospaced))
                                .foregroundStyle(.secondary)
                        }
                        .padding(16)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(Color(white: 0.09))
                        .clipShape(RoundedRectangle(cornerRadius: 14))
                    }
                    if let err = sync.loadError {
                        Text(err).font(.footnote).foregroundStyle(.red)
                    }
                }
                .padding(16)
            }
            .refreshable { await sync.load() }

            Button { sync.startWorkout() } label: {
                Label("START WORKOUT", systemImage: "play.fill")
                    .font(.system(size: 18, weight: .heavy)).frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent).tint(.white).foregroundStyle(.black)
            .controlSize(.large)
            .disabled(day.exercises.isEmpty)
            .padding(16)
        }
    }
}

// MARK: - Runner (one exercise at a time)

private struct RunnerView: View {
    @ObservedObject var sync: SyncModel

    var body: some View {
        if let ex = sync.currentExercise {
            ScrollView {
                VStack(spacing: 22) {
                    Text("SET \(sync.currentSetNumber) OF \(ex.target_sets)")
                        .font(.system(size: 14, weight: .heavy, design: .monospaced))
                        .foregroundStyle(.secondary)

                    Text(ex.exercise_name.uppercased())
                        .font(.system(size: 30, weight: .heavy))
                        .foregroundStyle(.white).multilineTextAlignment(.center)

                    Text("target \(ex.targetLabel)"
                         + (sync.lastWorkingSet(ex.exercise_id).map {
                            "  ·  last \(fmt($0.weight))×\($0.reps)" } ?? ""))
                        .font(.system(.subheadline, design: .monospaced))
                        .foregroundStyle(.secondary)

                    stepperRow(title: "WEIGHT (\(ex.exercise_unit))",
                               value: fmt(sync.weight),
                               buttons: [("−5", { sync.adjustWeight(-5) }),
                                         ("−2.5", { sync.adjustWeight(-2.5) }),
                                         ("+2.5", { sync.adjustWeight(2.5) }),
                                         ("+5", { sync.adjustWeight(5) })])

                    stepperRow(title: "REPS",
                               value: "\(sync.reps)",
                               buttons: [("−", { sync.adjustReps(-1) }),
                                         ("+", { sync.adjustReps(1) })])

                    Button { Task { await sync.logCurrentSet() } } label: {
                        Text("LOG SET").font(.system(size: 20, weight: .heavy))
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent).tint(.white).foregroundStyle(.black)
                    .controlSize(.large)

                    let done = sync.todaySets(ex.exercise_id)
                    if !done.isEmpty {
                        HStack(spacing: 8) {
                            ForEach(done) { s in
                                Text("\(fmt(s.weight))×\(s.reps)")
                                    .font(.system(.caption, design: .monospaced))
                                    .foregroundStyle(.green)
                                    .padding(.horizontal, 9).padding(.vertical, 5)
                                    .background(Color.green.opacity(0.15))
                                    .clipShape(Capsule())
                            }
                        }
                    }

                    HStack {
                        Button { sync.previous() } label: {
                            Label("Prev", systemImage: "chevron.left")
                        }.disabled(sync.exerciseIndex == 0)
                        Spacer()
                        Button { sync.advance() } label: {
                            Label("Skip", systemImage: "chevron.right")
                                .labelStyle(.titleAndIcon)
                        }
                    }
                    .font(.subheadline).tint(.secondary)
                    .padding(.top, 4)
                }
                .padding(20)
                .padding(.bottom, sync.restEndDate != nil ? 90 : 0)
            }
        }
    }

    @ViewBuilder
    private func stepperRow(title: String, value: String,
                            buttons: [(String, () -> Void)]) -> some View {
        VStack(spacing: 10) {
            Text(title).font(.caption.weight(.semibold)).foregroundStyle(.secondary)
            HStack(spacing: 10) {
                ForEach(Array(buttons.prefix(buttons.count / 2)), id: \.0) { b in
                    stepBtn(b.0, b.1)
                }
                Text(value)
                    .font(.system(size: 40, weight: .heavy, design: .monospaced))
                    .foregroundStyle(.white)
                    .lineLimit(1).minimumScaleFactor(0.5)
                    .frame(minWidth: 130)
                ForEach(Array(buttons.suffix(buttons.count - buttons.count / 2)), id: \.0) { b in
                    stepBtn(b.0, b.1)
                }
            }
        }
    }

    private func stepBtn(_ t: String, _ a: @escaping () -> Void) -> some View {
        Button(action: a) {
            Text(t).font(.system(size: 17, weight: .bold))
                .frame(width: 54, height: 54)
                .background(Color(white: 0.15)).foregroundStyle(.white)
                .clipShape(RoundedRectangle(cornerRadius: 12))
        }
    }
}

// MARK: - Finished

private struct FinishedView: View {
    @ObservedObject var sync: SyncModel

    var body: some View {
        VStack(spacing: 20) {
            Image(systemName: "checkmark.seal.fill")
                .font(.system(size: 52)).foregroundStyle(.green)
            Text("WORKOUT DONE")
                .font(.system(size: 24, weight: .heavy)).foregroundStyle(.white)
            Text("Logged to your coach. Ask Claude how it looked.")
                .font(.footnote).foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            Button { Task { await sync.finishWorkout() } } label: {
                Text("FINISH").font(.system(size: 18, weight: .heavy))
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent).tint(.white).foregroundStyle(.black)
            .controlSize(.large)
        }
        .padding(32)
    }
}

// MARK: - Rest bar

private struct RestBar: View {
    @ObservedObject var sync: SyncModel

    var body: some View {
        HStack(spacing: 14) {
            VStack(alignment: .leading, spacing: 2) {
                Text("REST · \(sync.restExercise.uppercased())")
                    .font(.caption2).foregroundStyle(.secondary)
                if let end = sync.restEndDate {
                    Text(timerInterval: Date()...end, countsDown: true)
                        .font(.system(size: 28, weight: .heavy, design: .monospaced))
                        .foregroundStyle(.white).monospacedDigit()
                }
            }
            Spacer()
            Button("+30s") { sync.addRest(30) }
                .buttonStyle(.bordered).tint(.white)
            Button("Skip") { sync.skipRest() }
                .buttonStyle(.borderedProminent).tint(.white).foregroundStyle(.black)
        }
        .padding(16)
        .background(.ultraThinMaterial)
        .clipShape(RoundedRectangle(cornerRadius: 16))
        .padding(16)
    }
}
