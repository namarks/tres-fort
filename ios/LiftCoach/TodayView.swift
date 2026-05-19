import SwiftUI

private func fmt(_ w: Double) -> String {
    w.rounded() == w ? String(Int(w)) : String(format: "%.1f", w)
}
private func clock(_ s: Int) -> String {
    s <= 0 ? "GO" : String(format: "%d:%02d", s / 60, s % 60)
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
            ZStack {
                Theme.background
                content
                if sync.restEndDate != nil { RestOverlay(sync: sync) }
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
                            }.font(Theme.mono(14, .bold)).foregroundStyle(Theme.text)
                        }
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
                    } label: { Image(systemName: "ellipsis.circle").foregroundStyle(Theme.muted) }
                }
            }
            .toolbarColorScheme(.dark, for: .navigationBar)
        }
        .preferredColorScheme(.dark)
        .task { await sync.load() }
    }

    @ViewBuilder private var content: some View {
        if sync.isLoading && sync.plan == nil {
            ProgressView().tint(Theme.accent)
        } else if sync.finished {
            FinishedView(sync: sync)
        } else if sync.running {
            RunnerView(sync: sync)
        } else if let day = sync.selectedDay {
            OverviewView(sync: sync, day: day)
        } else {
            VStack(spacing: 8) {
                Text("NO PLAN YET").font(Theme.display(28)).foregroundStyle(Theme.text)
                Text("Ask Claude to build one, then pull to refresh.")
                    .font(Theme.mono(13)).foregroundStyle(Theme.muted)
            }
        }
    }
}

// MARK: - shared: segmented progress bar

private struct ProgressBar: View {
    let exercises: [TemplateExercise]
    let currentIndex: Int
    let sync: SyncModel

    var body: some View {
        HStack(spacing: 6) {
            ForEach(Array(exercises.enumerated()), id: \.element.id) { i, ex in
                GeometryReader { geo in
                    let ratio = min(1, Double(sync.setsDone(ex)) / Double(max(1, ex.target_sets)))
                    let complete = sync.isComplete(ex)
                    ZStack(alignment: .leading) {
                        RoundedRectangle(cornerRadius: 2).fill(Theme.surface2)
                        RoundedRectangle(cornerRadius: 2)
                            .fill(complete ? Theme.done : Theme.accent)
                            .frame(width: geo.size.width * (complete ? 1 : ratio))
                    }
                    .overlay(
                        RoundedRectangle(cornerRadius: 2)
                            .stroke(i == currentIndex ? Theme.accent : .clear, lineWidth: 1))
                }
                .frame(height: 4)
            }
        }
    }
}

// MARK: - Overview

private struct OverviewView: View {
    @ObservedObject var sync: SyncModel
    let day: DayTemplate

    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 10) {
                    Text(day.title.uppercased())
                        .font(Theme.mono(11, .bold)).tracking(2)
                        .foregroundStyle(Theme.muted).padding(.bottom, 6)
                    ForEach(day.exercises) { ex in
                        HStack {
                            Text(ex.exercise_name.uppercased())
                                .font(Theme.display(22)).foregroundStyle(Theme.text)
                            Spacer()
                            Text(ex.targetLabel)
                                .font(Theme.mono(14)).foregroundStyle(Theme.muted)
                        }
                        .padding(16)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(Theme.surface)
                        .clipShape(RoundedRectangle(cornerRadius: 14))
                    }
                    if let err = sync.loadError {
                        Text(err).font(Theme.mono(12)).foregroundStyle(Theme.danger)
                    }
                }
                .padding(16)
            }
            .refreshable { await sync.load() }

            Button { sync.startWorkout() } label: {
                Text("START WORKOUT")
                    .font(Theme.display(26)).tracking(1.5)
                    .frame(maxWidth: .infinity).padding(.vertical, 18)
            }
            .background(Theme.accent).foregroundStyle(.black)
            .clipShape(RoundedRectangle(cornerRadius: 14))
            .shadow(color: Theme.accent.opacity(0.35), radius: 18, y: 8)
            .disabled(day.exercises.isEmpty)
            .padding(16)
        }
    }
}

// MARK: - Runner

private struct RunnerView: View {
    @ObservedObject var sync: SyncModel

    var body: some View {
        if let ex = sync.currentExercise {
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    ProgressBar(exercises: sync.exercises,
                                currentIndex: sync.exerciseIndex, sync: sync)
                        .padding(.bottom, 22)

                    Text(ex.exercise_name.uppercased())
                        .font(Theme.display(52)).foregroundStyle(Theme.text)
                        .lineLimit(2).minimumScaleFactor(0.6)

                    HStack {
                        meta("SET", "\(sync.currentSetNumber)", "OF \(ex.target_sets)")
                        Spacer()
                        meta("TARGET", ex.targetLabel, "")
                        Spacer()
                        meta("REST", "\(ex.rest_seconds)s", "")
                    }
                    .padding(.top, 12)

                    jumpStrip(ex: ex)

                    if ex.exercise_unit != "bw" {
                        stepper(label: "WEIGHT (\(ex.exercise_unit))", value: fmt(sync.weight),
                                steps: [("−10", { sync.adjustWeight(-10) }, true),
                                        ("−5", { sync.adjustWeight(-5) }, false),
                                        ("+5", { sync.adjustWeight(5) }, false),
                                        ("+10", { sync.adjustWeight(10) }, true)])
                    }
                    stepper(label: "REPS", value: "\(sync.reps)",
                            steps: [("−1", { sync.adjustReps(-1) }, false),
                                    ("+1", { sync.adjustReps(1) }, false)])

                    Button { Task { await sync.logCurrentSet() } } label: {
                        Text("LOG SET \(sync.currentSetNumber)")
                            .font(Theme.display(26)).tracking(1.2)
                            .frame(maxWidth: .infinity).padding(.vertical, 18)
                    }
                    .background(Theme.accent).foregroundStyle(.black)
                    .clipShape(RoundedRectangle(cornerRadius: 14))
                    .shadow(color: Theme.accent.opacity(0.35), radius: 18, y: 8)
                    .padding(.top, 18)

                    completedChips(ex: ex)

                    HStack {
                        navBtn("← PREV") { sync.previous() }
                            .disabled(sync.exerciseIndex == 0)
                        Text("\(sync.exerciseIndex + 1) / \(sync.exercises.count)")
                            .font(Theme.mono(11)).tracking(1.5).foregroundStyle(Theme.muted)
                            .frame(maxWidth: .infinity)
                        navBtn("SKIP →") { sync.skip() }
                    }
                    .padding(.top, 24)
                }
                .padding(20)
            }
        }
    }

    private func meta(_ a: String, _ b: String, _ c: String) -> some View {
        (Text(a + " ").foregroundStyle(Theme.muted)
         + Text(b).foregroundStyle(Theme.accent)
         + Text(c.isEmpty ? "" : " " + c).foregroundStyle(Theme.muted))
            .font(Theme.mono(11, .bold)).tracking(1.5)
    }

    private func jumpStrip(ex: TemplateExercise) -> some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                ForEach(Array(sync.exercises.enumerated()), id: \.element.id) { i, e in
                    let cur = i == sync.exerciseIndex
                    let done = sync.isComplete(e)
                    Button { sync.jump(to: i) } label: {
                        Text(e.exercise_name)
                            .font(Theme.mono(11, .bold))
                            .padding(.horizontal, 12).padding(.vertical, 8)
                            .background(cur ? Theme.accent : Theme.surface)
                            .foregroundStyle(cur ? .black : (done ? Theme.done : Theme.muted))
                            .clipShape(RoundedRectangle(cornerRadius: 8))
                            .overlay(RoundedRectangle(cornerRadius: 8)
                                .stroke(done && !cur ? Theme.done.opacity(0.3) : .clear))
                    }
                }
            }
        }
        .padding(.top, 16)
    }

    private func stepper(label: String, value: String,
                         steps: [(String, () -> Void, Bool)]) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(label).font(Theme.mono(10, .bold)).tracking(2).foregroundStyle(Theme.muted)
            HStack(spacing: 8) {
                ForEach(Array(steps.prefix(steps.count / 2)), id: \.0) { s in
                    stepBtn(s.0, s.2, s.1)
                }
                Text(value)
                    .font(Theme.display(58)).foregroundStyle(Theme.text)
                    .lineLimit(1).minimumScaleFactor(0.4)
                    .frame(maxWidth: .infinity)
                ForEach(Array(steps.suffix(steps.count - steps.count / 2)), id: \.0) { s in
                    stepBtn(s.0, s.2, s.1)
                }
            }
        }
        .padding(16)
        .background(Theme.surface).clipShape(RoundedRectangle(cornerRadius: 14))
        .padding(.top, 16)
    }

    private func stepBtn(_ t: String, _ lg: Bool, _ a: @escaping () -> Void) -> some View {
        Button(action: a) {
            Text(t).font(Theme.mono(15, .bold))
                .frame(width: lg ? 60 : 54, height: 50)
                .background(Theme.surface2).foregroundStyle(Theme.text)
                .clipShape(RoundedRectangle(cornerRadius: 10))
        }
    }

    private func completedChips(ex: TemplateExercise) -> some View {
        let done = sync.todaySets(ex.exercise_id)
        return VStack(alignment: .leading, spacing: 10) {
            Text("COMPLETED SETS").font(Theme.mono(10, .bold)).tracking(2)
                .foregroundStyle(Theme.muted)
            if done.isEmpty {
                Text("No sets logged yet").font(Theme.mono(12)).italic()
                    .foregroundStyle(Theme.dim)
            } else {
                FlowChips(sets: done) { s in Task { await sync.removeSet(s) } }
            }
        }
        .padding(.top, 24)
    }

    private func navBtn(_ t: String, _ a: @escaping () -> Void) -> some View {
        Button(action: a) {
            Text(t).font(Theme.mono(12, .bold)).tracking(1.2)
                .frame(maxWidth: .infinity).padding(.vertical, 14)
                .background(Theme.surface).foregroundStyle(Theme.text)
                .clipShape(RoundedRectangle(cornerRadius: 10))
        }
    }
}

private struct FlowChips: View {
    let sets: [SetLog]
    let onRemove: (SetLog) -> Void
    var body: some View {
        let cols = [GridItem(.adaptive(minimum: 110), spacing: 8)]
        LazyVGrid(columns: cols, alignment: .leading, spacing: 8) {
            ForEach(Array(sets.enumerated()), id: \.element.id) { i, s in
                HStack(spacing: 8) {
                    Text(String(format: "%02d", i + 1))
                        .font(Theme.mono(10)).foregroundStyle(Theme.dim)
                    Text("\(fmt(s.weight))×\(s.reps)")
                        .font(Theme.mono(13)).foregroundStyle(Theme.text)
                    Button { onRemove(s) } label: {
                        Image(systemName: "xmark").font(.system(size: 10))
                            .foregroundStyle(Theme.dim)
                    }
                }
                .padding(.horizontal, 12).padding(.vertical, 10)
                .background(Theme.surface).clipShape(RoundedRectangle(cornerRadius: 10))
            }
        }
    }
}

// MARK: - Rest overlay (full screen)

private struct RestOverlay: View {
    @ObservedObject var sync: SyncModel

    var body: some View {
        TimelineView(.periodic(from: .now, by: 0.2)) { ctx in
            let remaining = Int(ceil((sync.restEndDate ?? ctx.date).timeIntervalSince(ctx.date)))
            let frac = sync.restTotal > 0
                ? max(0, min(1, (sync.restEndDate!.timeIntervalSince(ctx.date)) / Double(sync.restTotal)))
                : 0
            ZStack {
                Theme.bg.opacity(0.96).ignoresSafeArea()
                VStack(spacing: 0) {
                    Text("REST").font(Theme.mono(11, .bold)).tracking(4)
                        .foregroundStyle(Theme.muted).padding(.bottom, 8)
                    Text(clock(remaining))
                        .font(.system(size: 130, weight: .heavy))
                        .foregroundStyle(remaining <= 0 ? Theme.done : Theme.accent)
                        .monospacedDigit()
                        .shadow(color: (remaining <= 0 ? Theme.done : Theme.accent).opacity(0.4),
                                radius: 30)
                        .opacity(remaining <= 0 ? (Int(ctx.date.timeIntervalSince1970 * 2) % 2 == 0 ? 1 : 0.4) : 1)

                    RoundedRectangle(cornerRadius: 3).fill(Theme.surface)
                        .frame(width: 240, height: 6)
                        .overlay(alignment: .leading) {
                            RoundedRectangle(cornerRadius: 3).fill(Theme.accent)
                                .frame(width: 240 * frac, height: 6)
                        }
                        .padding(.top, 24)

                    HStack(spacing: 12) {
                        restBtn("−15s") { sync.addRest(-15) }
                        restBtn("+15s") { sync.addRest(15) }
                        restBtn("DONE", primary: true) { sync.skipRest() }
                    }
                    .padding(.top, 36)

                    VStack(spacing: 4) {
                        Text("UP NEXT").font(Theme.mono(11, .bold)).tracking(2)
                            .foregroundStyle(Theme.muted)
                        Text(sync.currentExercise?.exercise_name.uppercased() ?? "DONE")
                            .font(Theme.display(22)).foregroundStyle(Theme.text)
                    }
                    .padding(.top, 28)
                }
            }
        }
    }

    private func restBtn(_ t: String, primary: Bool = false,
                         _ a: @escaping () -> Void) -> some View {
        Button(action: a) {
            Text(t).font(Theme.mono(13, .bold))
                .padding(.horizontal, 18).padding(.vertical, 14)
                .background(primary ? Theme.accent : Theme.surface)
                .foregroundStyle(primary ? .black : Theme.text)
                .clipShape(RoundedRectangle(cornerRadius: 10))
        }
    }
}

// MARK: - Finished

private struct FinishedView: View {
    @ObservedObject var sync: SyncModel

    private var todaysSets: [SetLog] {
        sync.exercises.flatMap { sync.todaySets($0.exercise_id) }
    }

    var body: some View {
        ScrollView {
            VStack(spacing: 16) {
                Text("DONE").font(.system(size: 76, weight: .heavy))
                    .foregroundStyle(Theme.done)
                Text("LOGGED TO YOUR COACH").font(Theme.mono(11, .bold)).tracking(2)
                    .foregroundStyle(Theme.muted)

                let sets = todaysSets
                let reps = sets.reduce(0) { $0 + $1.reps }
                let vol = sets.reduce(0.0) { $0 + $1.weight * Double($1.reps) }
                VStack(spacing: 0) {
                    sumRow("Sets logged", "\(sets.count)")
                    sumRow("Total reps", "\(reps)")
                    sumRow("Total volume", "\(Int(vol)) lb")
                }
                .padding(.top, 20)

                Button { Task { await sync.finishWorkout() } } label: {
                    Text("FINISH").font(Theme.display(24)).tracking(1.5)
                        .frame(maxWidth: .infinity).padding(.vertical, 16)
                }
                .background(Theme.accent).foregroundStyle(.black)
                .clipShape(RoundedRectangle(cornerRadius: 14))
                .padding(.top, 24)
            }
            .padding(28)
        }
    }

    private func sumRow(_ a: String, _ b: String) -> some View {
        HStack {
            Text(a).font(Theme.mono(13)).foregroundStyle(Theme.text)
            Spacer()
            Text(b).font(Theme.mono(13)).foregroundStyle(Theme.muted)
        }
        .padding(.vertical, 12)
        .overlay(alignment: .bottom) { Divider().overlay(Theme.surface2) }
    }
}
