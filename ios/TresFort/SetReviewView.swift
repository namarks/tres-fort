import SwiftUI

/// One correction surface is used by both the active slot and final review.
/// Original server values remain visible until the correction is acknowledged.
struct SetReviewList: View {
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @ObservedObject var sync: SyncModel
    let sets: [SetLog]
    let pending: [PendingSetIntent]
    @State private var editing: ReviewItem?
    @AppStorage(WeightUnit.preferenceKey) private var weightUnitRaw = "lb"

    private struct ReviewItem: Identifiable {
        let set: SetLog?
        let pending: PendingSetIntent?
        var id: String { self.set?.id ?? pending!.id }
        var setIndex: Int { self.set?.set_index ?? pending!.body.set_index }
        var exerciseID: String { self.set?.exercise_id ?? pending!.body.exercise_id }
        var values: SetCorrectionValues {
            SetCorrectionValues(weight: set?.weight ?? pending!.body.weight,
                                reps: set?.reps ?? pending!.body.reps,
                                rpe: set != nil ? set!.rpe : pending!.body.rpe,
                                durationSeconds: set != nil ? set!.duration_s : pending!.body.duration_s)
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(sets) { set in row(ReviewItem(set: set, pending: nil)) }
            ForEach(pending) { intent in row(ReviewItem(set: nil, pending: intent)) }
            if sync.correctionRefreshNeeded {
                Text("Correction saved. Refresh needed.").font(.caption).foregroundStyle(Theme.muted)
            }
        }
        .sheet(item: $editing) { item in
            SetValuesEditor(
                title: "Correct set", values: item.values,
                setDescription: "set \(item.setIndex) of \(sync.exerciseName(item.exerciseID))",
                timed: item.set.map { sync.isTimedSet($0) } ?? item.pending!.body.is_timed,
                allowsAssistance: sync.isBodyweightExercise(item.exerciseID)
                    || sync.isTimedExercise(item.exerciseID),
                storedUnit: WeightUnit(rawValue: sync.catalogRow(item.exerciseID)?.unit ?? "lb") ?? .lb,
                onSave: { values in
                    if let set = item.set { return sync.enqueueCorrection(set: set, values: values) }
                    return sync.enqueueCorrection(pending: item.pending!, values: values)
                }, onDelete: {
                    if let set = item.set { return sync.enqueueCorrection(set: set, values: nil) }
                    return sync.enqueueCorrection(pending: item.pending!, values: nil)
                })
        }
    }

    @ViewBuilder private func recoveryButtons(_ correction: PendingSetCorrection, context: String) -> some View {
        Button { Task { await sync.retryCorrection(id: correction.id) } } label: {
            Text("Retry").frame(minWidth: 44, minHeight: 44).contentShape(Rectangle())
        }
        .accessibilityLabel("Retry correction for " + context)
        Button { Task { await sync.dismissRejectedCorrection(id: correction.id) } } label: {
            Text("Reload to review").frame(minWidth: 44, minHeight: 44).contentShape(Rectangle())
        }
        .accessibilityLabel("Reload to review " + context)
        .accessibilityIdentifier("reload-correction-\(correction.setID)")
    }

    private func row(_ item: ReviewItem) -> some View {
        let unit = WeightUnit(rawValue: weightUnitRaw) ?? .lb
        let storedUnit = WeightUnit(rawValue: sync.catalogRow(item.exerciseID)?.unit ?? "lb") ?? .lb
        let correction = sync.correction(for: item.id)
        let timed = item.set.map { sync.isTimedSet($0) } ?? item.pending!.body.is_timed
        return VStack(alignment: .leading, spacing: 6) {
            let layout = dynamicTypeSize.isAccessibilitySize
                ? AnyLayout(VStackLayout(alignment: .leading, spacing: 8)) : AnyLayout(HStackLayout())
            layout {
                VStack(alignment: .leading, spacing: 4) {
                    Text(sync.exerciseName(item.exerciseID)).font(Theme.mono(11))
                    Text(SetValueFormatter.value(
                        weight: storedUnit.convert(item.values.weight, to: unit), reps: item.values.reps,
                        durationSeconds: item.values.durationSeconds, timed: timed,
                        bodyweight: sync.isBodyweightExercise(item.exerciseID), unit: unit.rawValue))
                        .font(Theme.mono(14, .bold))
                    if item.values.weight != 0 { Text("Load in \(unit.rawValue)").font(.caption).foregroundStyle(Theme.muted) }
                    if let rpe = item.values.rpe { Text("RPE \(SetValueFormatter.number(rpe))").font(.caption) }
                    if (item.set?.is_warmup == 1) || item.pending?.body.is_warmup == true {
                        Text("Warm-up").font(.caption).foregroundStyle(Theme.muted)
                    }
                }
                if !dynamicTypeSize.isAccessibilitySize { Spacer() }
                Button { editing = item } label: {
                    Text("Edit").frame(minWidth: 44, minHeight: 44).contentShape(Rectangle())
                }
                .accessibilityLabel("Edit set \(item.setIndex) of \(sync.exerciseName(item.exerciseID))")
                .accessibilityIdentifier("edit-set-\(item.id)")
                .disabled(correction != nil || sync.hasPendingTerminalIntentForCurrentWorkout)
            }
            if let correction {
                let failed = correction.deliveryState == .failed
                Text(failed
                     ? (correction.failedHTTPStatus == 409
                        ? "Correction needs review: this set or workout changed."
                        : "\(correction.isDelete ? "Delete" : "Edit") rejected (HTTP \(correction.failedHTTPStatus ?? 400)).")
                     : "\(correction.isDelete ? "Delete" : "Edit") pending — original retained until saved.")
                    .font(.caption).foregroundStyle(failed ? Theme.danger : Theme.muted)
                if let values = correction.values {
                    Text("Requested: " + SetValueFormatter.value(
                        weight: storedUnit.convert(values.weight, to: unit), reps: values.reps, durationSeconds: values.durationSeconds,
                        timed: timed, bodyweight: sync.isBodyweightExercise(item.exerciseID), unit: unit.rawValue))
                        .font(.caption).foregroundStyle(Theme.muted)
                }
                if failed {
                    let context = "set \(item.setIndex) of \(sync.exerciseName(item.exerciseID))"
                    ViewThatFits(in: .horizontal) {
                        HStack { recoveryButtons(correction, context: context) }
                        VStack(alignment: .leading) { recoveryButtons(correction, context: context) }
                    }.font(.caption)
                }
            }
            if let pending = item.pending {
                HStack {
                    Text(pending.deliveryState == .failed ? "Set not saved" : "Set queued on this device")
                        .font(.caption).foregroundStyle(Theme.muted)
                    Spacer()
                    if pending.deliveryState == .failed {
                        Button("Retry set") { Task { await sync.retrySetIntent(id: pending.id) } }
                    }
                }
            }
        }
        .foregroundStyle(Theme.text)
        .padding(12).background(Theme.surface)
        .clipShape(RoundedRectangle(cornerRadius: 10))
    }
}

struct SetValuesEditor: View {
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    let title: String
    let setDescription: String?
    let timed: Bool
    let allowsAssistance: Bool
    let onSave: (SetCorrectionValues) -> Bool
    let onDelete: (() -> Bool)?
    @Environment(\.dismiss) private var dismiss
    @State private var weight: WeightEntryDraft
    @AppStorage(WeightUnit.preferenceKey) private var weightUnitRaw = "lb"
    @State private var reps: String
    @State private var rpe: String
    @State private var duration: String
    @State private var error: String?

    init(title: String, values: SetCorrectionValues, setDescription: String? = nil,
         timed: Bool, allowsAssistance: Bool, storedUnit: WeightUnit = .lb,
         onSave: @escaping (SetCorrectionValues) -> Bool, onDelete: (() -> Bool)? = nil) {
        self.title = title; self.setDescription = setDescription
        self.timed = timed; self.allowsAssistance = allowsAssistance
        self.onSave = onSave; self.onDelete = onDelete
        _weight = State(initialValue: WeightEntryDraft(weight: values.weight, storedUnit: storedUnit, unit: storedUnit))
        _reps = State(initialValue: String(values.reps))
        _rpe = State(initialValue: values.rpe.map(SetValueFormatter.number) ?? "")
        _duration = State(initialValue: String(values.durationSeconds ?? (timed ? values.reps : 30)))
    }

    private var values: SetCorrectionValues? {
        guard let weight = weight.storedWeight, allowsAssistance || weight >= 0,
              let reps = Int(reps), reps >= 0,
              rpe.isEmpty || Double(rpe).map({ $0.isFinite && (0...10).contains($0) }) == true,
              !timed || Int(duration).map({ $0 > 0 }) == true else { return nil }
        return SetCorrectionValues(weight: weight, reps: timed ? (Int(duration) ?? 0) : reps,
                                   rpe: Double(rpe), durationSeconds: timed ? Int(duration) : nil)
    }

    @ViewBuilder private func valueField(_ label: String, placeholder: String,
                                         text: Binding<String>, keyboard: UIKeyboardType) -> some View {
        if dynamicTypeSize.isAccessibilitySize {
            VStack(alignment: .leading, spacing: 8) {
                Text(label)
                TextField(placeholder, text: text)
                    .keyboardType(keyboard).textFieldStyle(.roundedBorder)
                    .accessibilityLabel(label).accessibilityIdentifier(placeholder)
            }
        } else {
            LabeledContent(label) {
                TextField(placeholder, text: text)
                    .keyboardType(keyboard).multilineTextAlignment(.trailing)
                    .accessibilityLabel(label).accessibilityIdentifier(placeholder)
            }
        }
    }

    var body: some View {
        NavigationStack {
            Form {
                WeightUnitPicker(selection: Binding(get: { weight.unit }, set: {
                    weight.select($0)
                    weightUnitRaw = $0.rawValue
                }))
                valueField(allowsAssistance ? "Load / assist (\(weight.unit.rawValue))" : "Weight (\(weight.unit.rawValue))",
                           placeholder: "Weight", text: $weight.text, keyboard: .numbersAndPunctuation)
                valueField(timed ? "Duration (seconds)" : "Reps",
                           placeholder: timed ? "Seconds" : "Reps", text: timed ? $duration : $reps,
                           keyboard: .numberPad)
                valueField("RPE (optional)", placeholder: "—", text: $rpe, keyboard: .decimalPad)
                if allowsAssistance { Text("Use a negative load for assistance, 0 for bodyweight, or a positive added load.").font(.caption) }
                if let error { Text(error).foregroundStyle(.red) }
                if let onDelete {
                    Button("Delete set", role: .destructive) {
                        if onDelete() { dismiss() } else { error = "Workout changed. Close this sheet and review the set again." }
                    }
                    .accessibilityLabel("Delete " + (setDescription ?? "set"))
                }
            }
            .scrollDismissesKeyboard(.interactively)
            .navigationTitle(title).navigationBarTitleDisplayMode(.inline)
            .onAppear { weight.select(WeightUnit(rawValue: weightUnitRaw) ?? .lb) }
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        if let values, onSave(values) { dismiss() }
                        else { error = "Workout changed. Close this sheet and review the values again." }
                    }.disabled(values == nil)
                }
            }
        }
    }
}

/// Recovery must expose corrections even before the runner is resumed.
struct PendingCorrectionsView: View {
    @ObservedObject var sync: SyncModel
    var body: some View {
        DisclosureGroup("\(sync.setCorrections.count) set correction\(sync.setCorrections.count == 1 ? "" : "s") waiting to sync") {
            ForEach(sync.setCorrections) { intent in
                VStack(alignment: .leading, spacing: 6) {
                    Text("\(sync.exerciseName(intent.exerciseID)) · \(intent.isDelete ? "delete" : "edit") · \(intent.deliveryState == .failed ? "needs review" : "pending")")
                    HStack {
                        Button("Retry") { Task { await sync.retryCorrection(id: intent.id) } }
                            .disabled(sync.sendingCorrectionIDs.contains(intent.id))
                        if intent.deliveryState == .failed {
                            Spacer()
                            Button("Reload to review") { Task { await sync.dismissRejectedCorrection(id: intent.id) } }
                        }
                    }.frame(minHeight: 44)
                }.padding(.top, 8)
            }
        }
        .font(Theme.mono(11)).foregroundStyle(Theme.accent)
        .padding(14).background(Theme.surface)
    }
}
