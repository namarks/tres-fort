import SwiftUI

private func fmt(_ w: Double) -> String {
    w.rounded() == w ? String(Int(w)) : String(format: "%.1f", w)
}

struct TodayView: View {
    @ObservedObject var auth: AuthModel
    @StateObject private var sync: SyncModel
    @State private var logging: TemplateExercise?

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
                    if let plan = sync.plan, plan.days.count > 1 {
                        Picker("Day", selection: Binding(
                            get: { sync.selectedDayID ?? plan.days.first?.id ?? "" },
                            set: { sync.selectedDayID = $0 })) {
                            ForEach(plan.days) { d in Text(d.day_label ?? d.name).tag(d.id) }
                        }
                    }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Menu {
                        Button("Refresh") { Task { await sync.load() } }
                        Button("Sign out", role: .destructive) { auth.signOut() }
                    } label: { Image(systemName: "ellipsis.circle") }
                }
            }
            .toolbarColorScheme(.dark, for: .navigationBar)
        }
        .preferredColorScheme(.dark)
        .task { await sync.load() }
        .sheet(item: $logging) { ex in
            LogSheet(sync: sync, ex: ex).presentationDetents([.height(360)])
        }
    }

    @ViewBuilder private var content: some View {
        if sync.isLoading && sync.plan == nil {
            ProgressView().tint(.white)
        } else if let day = sync.selectedDay {
            ScrollView {
                VStack(spacing: 10) {
                    ForEach(day.exercises) { ex in
                        ExerciseRow(ex: ex,
                                    last: sync.lastWorkingSet(ex.exercise_id),
                                    done: sync.todaySets(ex.exercise_id))
                            .onTapGesture { logging = ex }
                    }
                    if let err = sync.loadError {
                        Text(err).font(.footnote).foregroundStyle(.red)
                    }
                }
                .padding(16)
                .padding(.bottom, sync.restEndDate != nil ? 90 : 0)
            }
            .refreshable { await sync.load() }
        } else {
            VStack(spacing: 8) {
                Text("No plan yet").foregroundStyle(.white).font(.headline)
                Text("Ask Claude to build one, then pull to refresh.")
                    .font(.footnote).foregroundStyle(.secondary)
            }
        }
    }
}

private struct ExerciseRow: View {
    let ex: TemplateExercise
    let last: SetLog?
    let done: [SetLog]

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(ex.exercise_name.uppercased())
                    .font(.system(size: 20, weight: .heavy)).foregroundStyle(.white)
                Spacer()
                Text(ex.targetLabel)
                    .font(.system(.subheadline, design: .monospaced))
                    .foregroundStyle(.secondary)
            }
            HStack(spacing: 8) {
                if let last {
                    chip("last \(fmt(last.weight))×\(last.reps)", .gray)
                }
                ForEach(done) { s in
                    chip("\(fmt(s.weight))×\(s.reps)", .green)
                }
                if done.isEmpty && last == nil {
                    chip("tap to log", .blue)
                }
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(white: 0.09))
        .clipShape(RoundedRectangle(cornerRadius: 14))
    }

    private func chip(_ t: String, _ c: Color) -> some View {
        Text(t)
            .font(.system(.caption, design: .monospaced)).foregroundStyle(c)
            .padding(.horizontal, 9).padding(.vertical, 5)
            .background(c.opacity(0.15)).clipShape(Capsule())
    }
}

private struct LogSheet: View {
    @ObservedObject var sync: SyncModel
    let ex: TemplateExercise
    @Environment(\.dismiss) private var dismiss
    @State private var weight: Double = 0
    @State private var reps: Int = 0

    var body: some View {
        VStack(spacing: 22) {
            Text(ex.exercise_name.uppercased())
                .font(.system(size: 22, weight: .heavy)).foregroundStyle(.white)

            stepper(title: "WEIGHT (\(ex.exercise_unit))",
                    value: fmt(weight),
                    dec5: { weight = max(0, weight - 5) },
                    dec1: { weight = max(0, weight - 2.5) },
                    inc1: { weight += 2.5 }, inc5: { weight += 5 })

            stepper(title: "REPS",
                    value: "\(reps)",
                    dec5: { reps = max(0, reps - 1) },
                    dec1: nil,
                    inc1: nil, inc5: { reps += 1 })

            Button {
                Task { await sync.logSet(ex, weight: weight, reps: reps); dismiss() }
            } label: {
                Text("LOG  \(fmt(weight)) × \(reps)")
                    .font(.system(size: 18, weight: .bold)).frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent).tint(.white).foregroundStyle(.black)
            .controlSize(.large)
        }
        .padding(24)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color.black)
        .onAppear {
            let last = sync.lastWorkingSet(ex.exercise_id)
            weight = last?.weight ?? ex.target_weight ?? 45
            reps = last?.reps ?? ex.target_reps
        }
    }

    @ViewBuilder
    private func stepper(title: String, value: String,
                         dec5: @escaping () -> Void, dec1: (() -> Void)?,
                         inc1: (() -> Void)?, inc5: @escaping () -> Void) -> some View {
        VStack(spacing: 8) {
            Text(title).font(.caption).foregroundStyle(.secondary)
            HStack(spacing: 14) {
                bigBtn("−−", dec5)
                if let dec1 { bigBtn("−", dec1) }
                Text(value)
                    .font(.system(size: 38, weight: .heavy, design: .monospaced))
                    .foregroundStyle(.white).frame(minWidth: 90)
                if let inc1 { bigBtn("+", inc1) }
                bigBtn("++", inc5)
            }
        }
    }

    private func bigBtn(_ t: String, _ a: @escaping () -> Void) -> some View {
        Button(action: a) {
            Text(t).font(.system(size: 20, weight: .bold))
                .frame(width: 52, height: 52)
                .background(Color(white: 0.15)).foregroundStyle(.white)
                .clipShape(RoundedRectangle(cornerRadius: 12))
        }
    }
}

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
