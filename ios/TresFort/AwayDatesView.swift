import SwiftUI

/// Why a member is away: the same four types the coach's add_trip takes.
enum AwayKind: String, CaseIterable, Identifiable {
    case travel, rest, injury, other

    var id: String { rawValue }

    var label: String {
        switch self {
        case .travel: return "Travel"
        case .rest: return "Rest"
        case .injury: return "Injury"
        case .other: return "Other"
        }
    }
}

/// Away dates while the member edits them. A new range sends every field; an
/// edit sends only what changed, so a coach's edit to another field between
/// loads isn't overwritten.
struct AwayDatesDraft: Equatable {
    static let noteLimit = 500

    private(set) var start: Date
    private(set) var end: Date
    var kind: AwayKind
    var canTrainLight: Bool
    var note: String
    private let original: PlanTrip?

    init(trip: PlanTrip) {
        let start = CalendarProjection.date(from: trip.start) ?? Date()
        self.start = start
        end = max(start, CalendarProjection.date(from: trip.end) ?? start)
        kind = AwayKind(rawValue: trip.type ?? "") ?? .other
        canTrainLight = trip.can_train_light ?? true
        note = trip.note ?? ""
        original = trip
    }

    init(today: Date) {
        start = today
        end = today
        kind = .travel
        canTrainLight = true
        note = ""
        original = nil
    }

    var isNew: Bool { original == nil }
    var startString: String { CalendarProjection.dateString(start) }
    var endString: String { CalendarProjection.dateString(end) }
    private var trimmedNote: String { note.trimmingCharacters(in: .whitespacesAndNewlines) }

    /// Moving the first day past the last day moves the last day with it.
    mutating func setStart(_ date: Date) {
        start = date
        if CalendarProjection.dateString(end) < CalendarProjection.dateString(date) { end = date }
    }

    mutating func setEnd(_ date: Date) {
        end = CalendarProjection.dateString(date) < startString ? start : date
    }

    /// Why the range can't be saved yet, or nil.
    var problem: String? {
        if endString < startString { return "The last day can't be before the first day." }
        if trimmedNote.count > Self.noteLimit { return "Keep the note under \(Self.noteLimit) characters." }
        return nil
    }

    /// The request fields: all of them for a new range, only changes for an edit.
    var fields: [String: Any] {
        guard let original else {
            var all: [String: Any] = [
                "start": startString, "end": endString,
                "type": kind.rawValue, "can_train_light": canTrainLight,
            ]
            if !trimmedNote.isEmpty { all["note"] = trimmedNote }
            return all
        }
        var changed: [String: Any] = [:]
        if startString != original.start { changed["start"] = startString }
        if endString != original.end { changed["end"] = endString }
        if kind.rawValue != (original.type ?? AwayKind.other.rawValue) { changed["type"] = kind.rawValue }
        if canTrainLight != (original.can_train_light ?? true) { changed["can_train_light"] = canTrainLight }
        if trimmedNote != (original.note ?? "") { changed["note"] = trimmedNote }
        return changed
    }

    var canSave: Bool { problem == nil && (isNew || !fields.isEmpty) }

    static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.startString == rhs.startString && lhs.endString == rhs.endString && lhs.kind == rhs.kind
            && lhs.canTrainLight == rhs.canTrainLight && lhs.note == rhs.note && lhs.original == rhs.original
    }
}

enum AwayDatesText {
    private static let dayFormat: DateFormatter = {
        let f = DateFormatter()
        f.calendar = Calendar(identifier: .gregorian)
        f.setLocalizedDateFormatFromTemplate("EEE d MMM")
        return f
    }()

    /// "Sat 20 Dec – Sun 28 Dec", or one day when the range is a single day.
    static func range(_ trip: PlanTrip) -> String {
        guard let start = CalendarProjection.date(from: trip.start),
              let end = CalendarProjection.date(from: trip.end) else { return "\(trip.start) – \(trip.end)" }
        let first = dayFormat.string(from: start)
        return trip.start == trip.end ? first : "\(first) – \(dayFormat.string(from: end))"
    }

    static func detail(_ trip: PlanTrip) -> String {
        let kind = AwayKind(rawValue: trip.type ?? "")?.label ?? AwayKind.other.label
        return (trip.can_train_light ?? true) ? kind : "\(kind) · no training"
    }
}

/// The member's away dates: trips, planned rest and injuries that pause the
/// weekly schedule. The coach reads and writes the same ranges.
struct AwayDatesView: View {
    @ObservedObject var sync: SyncModel
    @State private var editing: AwayDatesTarget?

    /// What the editor opens with, including the plan version the member
    /// reviewed, so a later save can't overwrite a newer plan unseen.
    private struct AwayDatesTarget: Identifiable {
        let id: String
        let draft: AwayDatesDraft
        let version: Int
    }

    private var trips: [PlanTrip] { sync.plan?.awayDates ?? [] }
    private var upcoming: [PlanTrip] { trips.filter { $0.end >= sync.todayString } }
    private var past: [PlanTrip] { trips.filter { $0.end < sync.todayString } }

    var body: some View {
        List {
            Section {
                Button {
                    guard let version = sync.plan?.version else { return }
                    editing = AwayDatesTarget(id: "new", draft: AwayDatesDraft(today: Date()), version: version)
                } label: {
                    Label("Add away dates", systemImage: "plus.circle.fill")
                        .font(Theme.mono(13, .bold)).foregroundStyle(Theme.accent)
                }
                .disabled(sync.isRoutineMutationInFlight || sync.plan == nil)
                .accessibilityIdentifier("away.add")
                if upcoming.isEmpty {
                    Text("Nothing coming up.").font(Theme.mono(12)).foregroundStyle(Theme.muted)
                }
                ForEach(upcoming) { row($0) }
            } header: {
                Text("Coming up")
            } footer: {
                Text("Your weekly schedule pauses on these days. Today and the calendar show them as away.")
            }
            if !past.isEmpty {
                Section("Past") { ForEach(Array(past.reversed())) { row($0) } }
            }
            if let error = sync.loadError {
                Section { Text(error).foregroundStyle(Theme.danger) }
            }
        }
        .scrollContentBackground(.hidden)
        .background(Theme.background)
        .navigationTitle("Away dates")
        .navigationBarTitleDisplayMode(.inline)
        .toolbarColorScheme(.dark, for: .navigationBar)
        .sheet(item: $editing) { target in
            NavigationStack {
                AwayDatesEditor(sync: sync, tripID: target.id == "new" ? nil : target.id,
                                draft: target.draft, expectedVersion: target.version)
            }
            .preferredColorScheme(.dark)
        }
    }

    private func row(_ trip: PlanTrip) -> some View {
        Button {
            guard let version = sync.plan?.version else { return }
            editing = AwayDatesTarget(id: trip.id, draft: AwayDatesDraft(trip: trip), version: version)
        } label: {
            HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(AwayDatesText.range(trip)).foregroundStyle(Theme.text)
                    Text(AwayDatesText.detail(trip)).font(Theme.mono(12)).foregroundStyle(Theme.muted)
                    if let note = trip.note, !note.isEmpty {
                        Text(note).font(.footnote).foregroundStyle(Theme.muted).lineLimit(2)
                    }
                }
                Spacer()
                Image(systemName: "chevron.right")
                    .font(.system(size: 13, weight: .semibold)).foregroundStyle(Theme.muted)
                    .accessibilityHidden(true)
            }
            .frame(minHeight: 44)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(sync.isRoutineMutationInFlight)
        .accessibilityIdentifier("away.trip.\(trip.id)")
    }
}

/// Adds or edits one away-dates range. Every write carries the plan version
/// the editor opened with. When the plan has moved on (a conflict, or a
/// refresh while editing), a failed write closes the editor so the member
/// reviews the latest ranges before trying again.
struct AwayDatesEditor: View {
    @ObservedObject var sync: SyncModel
    let tripID: String?
    let expectedVersion: Int

    @Environment(\.dismiss) private var dismiss
    @State private var draft: AwayDatesDraft
    @State private var working = false
    @State private var confirmingRemove = false

    init(sync: SyncModel, tripID: String?, draft: AwayDatesDraft, expectedVersion: Int) {
        _sync = ObservedObject(wrappedValue: sync)
        self.tripID = tripID
        self.expectedVersion = expectedVersion
        _draft = State(initialValue: draft)
    }

    var body: some View {
        Form {
            Section("Dates") {
                DatePicker("First day", selection: Binding(get: { draft.start }, set: { draft.setStart($0) }),
                           displayedComponents: .date)
                    .accessibilityIdentifier("away.start")
                DatePicker("Last day", selection: Binding(get: { draft.end }, set: { draft.setEnd($0) }),
                           in: draft.start..., displayedComponents: .date)
                    .accessibilityIdentifier("away.end")
            }
            Section {
                Picker("Reason", selection: $draft.kind) {
                    ForEach(AwayKind.allCases) { Text($0.label).tag($0) }
                }
                .accessibilityIdentifier("away.kind")
                Toggle("I can still train", isOn: $draft.canTrainLight)
                    .tint(Theme.accent)
                    .accessibilityIdentifier("away.canTrain")
            } footer: {
                Text(draft.canTrainLight
                     ? "Your weekly schedule pauses on these days. You can still put a workout on one of them."
                     : "These days are blocked: your weekly schedule pauses and no workout can be put on them.")
            }
            Section("Note") {
                TextField("Optional, such as hotel gym only", text: $draft.note, axis: .vertical)
                    .lineLimit(1...4)
                    .accessibilityIdentifier("away.note")
            }
            if let problem = draft.problem {
                Section { Text(problem).foregroundStyle(Theme.danger) }
            }
            if tripID != nil {
                Section {
                    Button("Remove away dates", role: .destructive) { confirmingRemove = true }
                        .disabled(working)
                        .accessibilityIdentifier("away.remove")
                }
            }
            if let error = sync.loadError {
                Section { Text(error).foregroundStyle(Theme.danger) }
            }
        }
        .scrollContentBackground(.hidden)
        .background(Theme.background)
        .navigationTitle(tripID == nil ? "Add away dates" : "Away dates")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarLeading) {
                Button("Cancel") { dismiss() }.foregroundStyle(Theme.muted)
            }
            ToolbarItem(placement: .topBarTrailing) {
                Button(working ? "Saving…" : "Save") { save() }
                    .disabled(working || !draft.canSave)
                    .accessibilityIdentifier("away.save")
            }
        }
        .toolbarColorScheme(.dark, for: .navigationBar)
        .tint(Theme.accent)
        .alert("Remove these away dates?", isPresented: $confirmingRemove) {
            Button("Remove", role: .destructive) { remove() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Your weekly schedule applies to these days again.")
        }
    }

    private func save() {
        working = true
        let fields = draft.fields
        Task {
            let saved = await sync.saveAwayDates(id: tripID, fields: fields, expectedVersion: expectedVersion)
            working = false
            if saved || planMovedOn { dismiss() }
        }
    }

    private func remove() {
        guard let tripID else { return }
        working = true
        Task {
            let removed = await sync.removeAwayDates(id: tripID, expectedVersion: expectedVersion)
            working = false
            if removed || planMovedOn { dismiss() }
        }
    }

    /// The plan on screen is no longer the one this editor opened with.
    private var planMovedOn: Bool { sync.plan?.version != expectedVersion }
}
