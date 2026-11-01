import SwiftUI

/// Profile → Training thresholds: FTP, threshold heart rate and threshold
/// pace, each with the date it applies from. Runs and rides from every
/// source are scored against them, with no AI needed.
struct AthleteThresholdsView: View {
    @StateObject private var model: AthleteThresholdsModel
    @AppStorage(RunDistanceUnit.preferenceKey) private var unitRaw = RunDistanceUnit.miles.rawValue
    @State private var editing: EditorTarget?
    @State private var confirmingRemove: AthleteThreshold?

    private struct EditorTarget: Identifiable {
        let id: String
        let draft: ThresholdDraft
    }

    init(auth: AuthModel) {
        _model = StateObject(wrappedValue: AthleteThresholdsModel(auth: auth))
    }

    init(model: AthleteThresholdsModel) {
        _model = StateObject(wrappedValue: model)
    }

    private var unit: RunDistanceUnit { RunDistanceUnit(rawValue: unitRaw) ?? .miles }
    private var today: String { CalendarProjection.dateString(Date()) }

    var body: some View {
        List {
            Section {
                Text("Très Fort turns each run and ride into a training load, where an hour at threshold scores 100. It uses power first, then heart rate, then pace, and the values in effect on the workout’s date.")
                    .font(.footnote).foregroundStyle(Theme.muted)
            }
            if model.phase == .loading && model.thresholds.isEmpty {
                Section { ProgressView().frame(maxWidth: .infinity) }
            } else if model.phase == .failed && model.thresholds.isEmpty {
                Section {
                    Text("Your thresholds couldn’t be loaded.").foregroundStyle(Theme.text)
                    Button("Try again") { Task { await model.load() } }
                        .accessibilityIdentifier("thresholds.retry")
                }
            } else {
                ForEach(ThresholdSport.allCases) { sport in
                    Section {
                        ForEach(sport.metrics) { metric in
                            currentRow(sport: sport, metric: metric)
                        }
                    } header: {
                        Label(sport.title, systemImage: sport.glyph)
                    }
                }
                if !model.thresholds.isEmpty {
                    Section {
                        ForEach(history) { row in historyRow(row) }
                    } header: {
                        Text("History")
                    } footer: {
                        Text("Each value applies from its date until the next one. Workouts before your first value use it too. Tap a value to correct it.")
                    }
                }
            }
            if let error = model.errorMessage {
                Section { Text(error).foregroundStyle(Theme.danger) }
            }
        }
        .scrollContentBackground(.hidden)
        .background(Theme.background)
        .navigationTitle("Training thresholds")
        .navigationBarTitleDisplayMode(.inline)
        .toolbarColorScheme(.dark, for: .navigationBar)
        .task { await model.load() }
        .refreshable { await model.load() }
        .sheet(item: $editing) { target in
            NavigationStack {
                ThresholdEditor(model: model, draft: target.draft, unit: unit)
            }
            .preferredColorScheme(.dark)
        }
        .alert("Remove this value?", isPresented: Binding(
            get: { confirmingRemove != nil },
            set: { if !$0 { confirmingRemove = nil } })
        ) {
            Button("Remove", role: .destructive) {
                if let row = confirmingRemove { Task { await model.remove(row) } }
                confirmingRemove = nil
            }
            Button("Cancel", role: .cancel) { confirmingRemove = nil }
        } message: {
            Text("Workouts it covered are scored with your other values, or have no load if none are left.")
        }
    }

    /// Newest first across all sports and metrics.
    private var history: [AthleteThreshold] {
        model.thresholds
            .filter { $0.thresholdSport != nil && $0.thresholdMetric != nil }
            .sorted { a, b in
                a.effective_date != b.effective_date ? a.effective_date > b.effective_date
                    : a.created_at > b.created_at
            }
    }

    private func currentRow(sport: ThresholdSport, metric: ThresholdMetric) -> some View {
        let current = AthleteThresholdHistory.inEffect(model.thresholds, sport: sport, metric: metric, on: today)
        let next = AthleteThresholdHistory.upcoming(model.thresholds, sport: sport, metric: metric, after: today)
        return Button {
            model.errorMessage = nil
            editing = EditorTarget(id: "new.\(sport.rawValue).\(metric.rawValue)",
                                   draft: ThresholdDraft(sport: sport, metric: metric, today: Date()))
        } label: {
            HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 3) {
                    Text(metric.title).foregroundStyle(Theme.text)
                    if let next {
                        Text("\(ThresholdFormat.value(next.value, metric: metric, unit: unit)) from \(Self.day(next.effective_date))")
                            .font(.caption).foregroundStyle(Theme.muted)
                    } else if current == nil {
                        Text(metric.help(for: sport)).font(.caption).foregroundStyle(Theme.muted)
                    }
                }
                Spacer()
                Text(current.map { ThresholdFormat.value($0.value, metric: metric, unit: unit) } ?? "Add")
                    .font(Theme.mono(14, .bold))
                    .foregroundStyle(current == nil ? Theme.accent : Theme.text)
                    .monospacedDigit()
            }
            .frame(minHeight: 44)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(model.isSaving)
        .accessibilityHint(current == nil ? "Adds a value" : "Adds a new value from a date you choose")
        .accessibilityIdentifier("thresholds.\(sport.rawValue).\(metric.rawValue)")
    }

    private func historyRow(_ row: AthleteThreshold) -> some View {
        let sport = row.thresholdSport ?? .ride
        let metric = row.thresholdMetric ?? .ftp
        return Button {
            if let draft = ThresholdDraft(correcting: row, unit: unit) {
                model.errorMessage = nil
                editing = EditorTarget(id: row.id, draft: draft)
            }
        } label: {
            HStack(spacing: 12) {
                Image(systemName: sport.glyph).foregroundStyle(Theme.muted).frame(width: 24)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 3) {
                    Text(metric.title).foregroundStyle(Theme.text)
                    Text("From \(Self.day(row.effective_date))\(row.source == "coach" ? " · set by your coach" : "")")
                        .font(.caption).foregroundStyle(Theme.muted)
                }
                Spacer()
                Text(ThresholdFormat.value(row.value, metric: metric, unit: unit))
                    .font(Theme.mono(13, .bold)).foregroundStyle(Theme.text).monospacedDigit()
            }
            .frame(minHeight: 44)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(model.isSaving)
        .swipeActions {
            Button("Remove", role: .destructive) { confirmingRemove = row }
        }
        .accessibilityIdentifier("thresholds.history.\(row.id)")
    }

    private static let dayFormat: DateFormatter = {
        let f = DateFormatter()
        f.calendar = Calendar(identifier: .gregorian)
        f.setLocalizedDateFormatFromTemplate("d MMM yyyy")
        return f
    }()

    static func day(_ civilDate: String) -> String {
        CalendarProjection.date(from: civilDate).map { dayFormat.string(from: $0) } ?? civilDate
    }
}

/// Adds a value, or corrects one: a correction saves the new value, then
/// removes the old one.
private struct ThresholdEditor: View {
    @ObservedObject var model: AthleteThresholdsModel
    let unit: RunDistanceUnit

    @Environment(\.dismiss) private var dismiss
    @State private var draft: ThresholdDraft
    @State private var confirmingRemove = false

    init(model: AthleteThresholdsModel, draft: ThresholdDraft, unit: RunDistanceUnit) {
        _model = ObservedObject(wrappedValue: model)
        self.unit = unit
        _draft = State(initialValue: draft)
    }

    var body: some View {
        Form {
            Section {
                HStack {
                    TextField(draft.metric.placeholder, text: $draft.text)
                        .keyboardType(draft.metric == .pace ? .numbersAndPunctuation : .numberPad)
                        .font(Theme.mono(17, .bold))
                        .accessibilityLabel(draft.metric.title)
                        .accessibilityIdentifier("thresholds.value")
                    Text(draft.metric.unitLabel(unit)).foregroundStyle(Theme.muted)
                }
                DatePicker("Applies from", selection: $draft.date, displayedComponents: .date)
                    .accessibilityIdentifier("thresholds.date")
            } header: {
                Text("\(draft.sport.title) · \(draft.metric.title)")
            } footer: {
                Text(draft.metric.help(for: draft.sport))
            }
            if let problem = draft.problem(unit: unit) {
                Section { Text(problem).foregroundStyle(Theme.danger) }
            }
            if draft.replacing != nil {
                Section {
                    Button("Remove this value", role: .destructive) { confirmingRemove = true }
                        .disabled(model.isSaving)
                        .accessibilityIdentifier("thresholds.remove")
                }
            }
            if let error = model.errorMessage {
                Section { Text(error).foregroundStyle(Theme.danger) }
            }
        }
        .scrollContentBackground(.hidden)
        .background(Theme.background)
        .navigationTitle(draft.replacing == nil ? "New value" : "Correct value")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarLeading) {
                Button("Cancel") { dismiss() }.foregroundStyle(Theme.muted)
            }
            ToolbarItem(placement: .topBarTrailing) {
                Button(model.isSaving ? "Saving…" : "Save") {
                    Task { if await model.save(draft, unit: unit) { dismiss() } }
                }
                .disabled(model.isSaving || !draft.canSave(unit: unit))
                .accessibilityIdentifier("thresholds.save")
            }
        }
        .toolbarColorScheme(.dark, for: .navigationBar)
        .tint(Theme.accent)
        .alert("Remove this value?", isPresented: $confirmingRemove) {
            Button("Remove", role: .destructive) {
                guard let row = draft.replacing else { return }
                Task {
                    await model.remove(row)
                    if model.errorMessage == nil { dismiss() }
                }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Workouts it covered are scored with your other values, or have no load if none are left.")
        }
    }
}
