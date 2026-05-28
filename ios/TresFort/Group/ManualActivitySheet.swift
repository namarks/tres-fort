import SwiftUI

/// Quick-add form for a non-lift activity. Used from:
///   - the Group tab "+" floating button
///   - the Today screen toolbar (so logging Pilates doesn't require a
///     tab switch)
///
/// Submission delegates to a closure so the sheet doesn't need to know
/// about GroupModel directly — both call sites pass the same
/// `groupModel.logActivity(_:)` handler.
struct ManualActivitySheet: View {
    @Environment(\.dismiss) private var dismiss

    /// Closure invoked on Save. Caller is responsible for the optimistic-
    /// insert + outbox dance (see GroupModel.logActivity).
    var onSave: (PendingActivity) async -> Void

    @State private var kind: String = "pilates"
    @State private var title: String = ""
    @State private var durationMin: Int = 45
    @State private var date: Date = Date()
    @State private var notes: String = ""
    @State private var saving = false

    var body: some View {
        NavigationStack {
            Form {
                Section("Type") {
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
                }
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
                Section("When") {
                    DatePicker("Date",
                               selection: $date,
                               in: dateRange,
                               displayedComponents: [.date])
                }
                Section("Notes") {
                    TextEditor(text: $notes)
                        .frame(minHeight: 80)
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
                    Button("Save") { save() }
                        .disabled(!canSave)
                }
            }
        }
    }

    private var canSave: Bool {
        !title.trimmingCharacters(in: .whitespaces).isEmpty && !saving
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

    private func ymd(_ d: Date) -> String {
        let f = DateFormatter()
        f.calendar = Calendar(identifier: .gregorian)
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = .current
        f.dateFormat = "yyyy-MM-dd"
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
