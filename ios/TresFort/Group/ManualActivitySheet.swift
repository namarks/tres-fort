import SwiftUI

/// Quick-add form for a non-lift activity. A run, ride, swim or walk goes to
/// intervals.icu with its distance and time when that's connected. Used from:
///   - the Group tab "+" floating button
///   - the Today screen toolbar (so logging Pilates doesn't require a
///     tab switch)
///
/// Submission delegates to closures so the sheet doesn't need to know
/// about GroupModel directly; `LogActivitySheet` below wires them for every
/// call site.
struct ManualActivitySheet: View {
    @Environment(\.dismiss) private var dismiss

    /// Closure invoked on Save. Caller is responsible for the optimistic-
    /// insert + outbox dance (see GroupModel.logActivity).
    var onSave: (PendingActivity) async -> Void
    /// Sends a run, ride, swim or walk to intervals.icu with its distance
    /// and time (GroupModel.logEndurance). Nil when intervals.icu isn't
    /// connected; those activities then stay in the local log as before.
    var onLogEndurance: ((EnduranceEntry) async throws -> Void)? = nil

    @State private var kind: String = "pilates"
    @State private var title: String = ""
    @State private var durationMin: Int = 45
    @State private var date: Date = Date()
    @State private var notes: String = ""
    @State private var saving = false
    // Endurance entries going to intervals.icu.
    @State private var timeText = ""
    @State private var distanceText = ""
    @State private var distanceUnit: EnduranceEntry.DistanceUnit =
        RunDistanceUnit.preferred() == .miles ? .mi : .km
    @State private var indoor = false
    /// Kept across attempts so retrying after an unclear failure can never
    /// create the activity twice.
    @State private var enduranceID = UUID().uuidString
    @State private var failure: String?
    @FocusState private var focusedField: Field?
    private enum Field { case time, distance }

    /// A run, ride, swim or walk goes to intervals.icu when it's connected.
    private var isEndurance: Bool {
        onLogEndurance != nil && EnduranceEntry.kinds.contains(kind)
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Picker("Type", selection: $kind) {
                        ForEach(PendingActivity.kinds, id: \.self) { k in
                            HStack {
                                Image(systemName: PendingActivity.glyph(for: k))
                                Text(PendingActivity.label(for: k))
                            }
                            .tag(k)
                        }
                    }
                    .pickerStyle(.menu)
                    .accessibilityIdentifier("activity.type")
                } header: {
                    Text("Type")
                } footer: {
                    if isEndurance {
                        Text("Saved to intervals.icu with its distance and time, so it counts toward your training load.")
                    } else if EnduranceEntry.kinds.contains(kind) {
                        Text("Connect intervals.icu in Profile to log distance and pace there. Without it, this stays in Tres Fort.")
                    }
                }
                if isEndurance {
                    enduranceFields
                } else {
                    Section("Title") {
                        TextField("e.g. Pilates class", text: $title)
                            .textInputAutocapitalization(.sentences)
                    }
                    Section("Duration") {
                        Stepper(value: $durationMin, in: 5...240, step: 5) {
                            HStack {
                                Text("Minutes")
                                Spacer()
                                Text("\(durationMin)").monospacedDigit()
                            }
                        }
                    }
                }
                Section("When") {
                    DatePicker(isEndurance ? "Start" : "Date",
                               selection: $date,
                               in: dateRange,
                               displayedComponents: isEndurance ? [.date, .hourAndMinute] : [.date])
                }
                Section("Notes") {
                    TextEditor(text: $notes)
                        .frame(minHeight: 80)
                }
                if let failure {
                    Section {
                        Text(failure).foregroundStyle(Theme.danger)
                            .accessibilityIdentifier("activity.failure")
                    }
                }
            }
            .navigationTitle("Log activity")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                        .disabled(saving)
                }
                ToolbarItem(placement: .confirmationAction) {
                    if saving {
                        ProgressView()
                    } else {
                        Button("Save") { save() }
                            .disabled(!canSave)
                            .accessibilityIdentifier("activity.save")
                    }
                }
                ToolbarItemGroup(placement: .keyboard) {
                    Spacer()
                    Button("Done") { focusedField = nil }
                }
            }
            .onChange(of: kind) { old, new in
                // Swims use pool units; switching back restores mi or km.
                if (old == "swim") != (new == "swim") {
                    distanceUnit = EnduranceEntry.DistanceUnit.choices(for: new)[
                        new == "swim" ? 0 : (RunDistanceUnit.preferred() == .miles ? 0 : 1)]
                }
                failure = nil
            }
        }
        .interactiveDismissDisabled(saving)
    }

    @ViewBuilder private var enduranceFields: some View {
        Section {
            TextField("Title (optional)", text: $title)
                .textInputAutocapitalization(.sentences)
            LabeledContent("Time") {
                TextField("mm:ss", text: $timeText)
                    .keyboardType(.numbersAndPunctuation)
                    .multilineTextAlignment(.trailing)
                    .focused($focusedField, equals: .time)
                    .accessibilityIdentifier("activity.time")
            }
            LabeledContent("Distance") {
                HStack(spacing: 8) {
                    TextField("Optional", text: $distanceText)
                        .keyboardType(.decimalPad)
                        .multilineTextAlignment(.trailing)
                        .focused($focusedField, equals: .distance)
                        .accessibilityIdentifier("activity.distance")
                    Picker("Unit", selection: $distanceUnit) {
                        ForEach(EnduranceEntry.DistanceUnit.choices(for: kind)) { Text($0.rawValue).tag($0) }
                    }
                    .pickerStyle(.segmented)
                    .fixedSize()
                    .accessibilityIdentifier("activity.distanceUnit")
                }
            }
            if kind != "swim" {
                Toggle(kind == "ride" ? "Indoor trainer" : "Treadmill", isOn: $indoor)
                    .tint(Theme.accent)
            }
        } header: {
            Text("Time and distance")
        } footer: {
            enduranceFooter
        }
    }

    @ViewBuilder private var enduranceFooter: some View {
        let seconds = EnduranceEntry.seconds(from: timeText)
        let meters = EnduranceEntry.meters(from: distanceText, unit: distanceUnit)
        if !timeText.isEmpty && seconds == nil {
            Text("Enter the time as minutes, mm:ss or h:mm:ss.")
        } else if !EnduranceEntry.isReadableDistance(distanceText, unit: distanceUnit) {
            Text("Enter the distance as a number, or leave it empty.")
        } else if let seconds, let meters,
                  let pace = EnduranceEntry.paceLabel(seconds: seconds, meters: meters,
                                                      unit: distanceUnit, kind: kind) {
            Text(pace).accessibilityIdentifier("activity.pace")
        } else {
            Text("Time is required. Distance is optional.")
        }
    }

    private var canSave: Bool {
        guard !saving else { return false }
        if isEndurance {
            return EnduranceEntry.seconds(from: timeText) != nil
                && EnduranceEntry.isReadableDistance(distanceText, unit: distanceUnit)
        }
        return !title.trimmingCharacters(in: .whitespaces).isEmpty
    }

    /// Limit the picker to today and the past 7 days. Backdating further
    /// than that is uncommon and would surprise feed readers ("why is a
    /// week-old activity bubbling to the top?"). M5 chose 7 days because
    /// it covers a forgotten Sunday Pilates logged the following weekend;
    /// revisit if users complain.
    private var dateRange: ClosedRange<Date> {
        let cal = Calendar(identifier: .gregorian)
        let now = Date()
        let past = cal.date(byAdding: .day, value: -7, to: now) ?? now
        return past...now
    }

    private func save() {
        if isEndurance, let onLogEndurance { saveEndurance(onLogEndurance); return }
        saving = true
        let activity = PendingActivity(
            id: UUID().uuidString,
            date: ymd(date),
            kind: kind,
            title: title.trimmingCharacters(in: .whitespaces),
            duration_minutes: durationMin,
            notes: notes.isEmpty ? nil : notes,
            logged_at: Int(Date().timeIntervalSince1970 * 1000))
        // Fire-and-dismiss: the optimistic insert + outbox semantics live
        // in GroupModel.logActivity; the sheet itself never blocks UI on
        // the network round trip.
        Task { await onSave(activity) }
        dismiss()
    }

    /// intervals.icu is the only place this is saved, so the sheet waits for
    /// it and keeps the entry on a failure.
    private func saveEndurance(_ send: @escaping (EnduranceEntry) async throws -> Void) {
        guard let seconds = EnduranceEntry.seconds(from: timeText) else { return }
        let trimmedTitle = title.trimmingCharacters(in: .whitespaces)
        let entry = EnduranceEntry(
            id: enduranceID, date: ymd(date), kind: kind, durationS: seconds,
            distanceM: EnduranceEntry.meters(from: distanceText, unit: distanceUnit),
            indoor: indoor, startTime: clock(date),
            title: trimmedTitle.isEmpty ? nil : trimmedTitle,
            notes: notes.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : notes)
        saving = true
        failure = nil
        focusedField = nil
        Task {
            do {
                try await send(entry)
                saving = false
                dismiss()
            } catch {
                saving = false
                failure = EnduranceEntry.failureMessage(error)
            }
        }
    }

    // Reads .current per call on purpose: this is a civil date the member
    // picks, so a device time-zone change must move it without a relaunch.
    private func ymd(_ d: Date) -> String {
        let f = DateFormatter()
        f.calendar = Calendar(identifier: .gregorian)
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = .current
        f.dateFormat = "yyyy-MM-dd"
        return f.string(from: d)
    }

    /// "HH:mm" start time in the device time zone, read like `ymd`.
    private func clock(_ d: Date) -> String {
        let f = DateFormatter()
        f.calendar = Calendar(identifier: .gregorian)
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = .current
        f.dateFormat = "HH:mm"
        return f.string(from: d)
    }
}

private extension PendingActivity {
    /// Convenience init that matches the form's field-by-field shape.
    init(id: String, date: String, kind: String, title: String,
         duration_minutes: Int?, notes: String?, logged_at: Int) {
        self.init(id: id, date: date, type: kind, title: title,
                  duration_minutes: duration_minutes, notes: notes,
                  logged_at: logged_at)
    }
}

/// The activity sheet wired to GroupModel, shared by Today and the Group
/// tab. A run, ride, swim or walk goes to intervals.icu when it's connected,
/// and the connection is checked on open, so this works before Profile or
/// Group has ever loaded it.
struct LogActivitySheet: View {
    @ObservedObject var groupModel: GroupModel

    var body: some View {
        ManualActivitySheet(
            onSave: { await groupModel.logActivity($0) },
            onLogEndurance: groupModel.canLogEndurance
                ? { try await groupModel.logEndurance($0) }
                : nil)
        .task {
            if groupModel.intervalsStatus == nil { await groupModel.refreshMe() }
        }
    }
}
