import SwiftUI

private struct EditingRunStep: Identifiable {
    let id: UUID
    let step: RunPlan.Step
}

/// Plans a run's steps in the app (docs/plans/planned-runs P5), so a member
/// doesn't need the coach to set up intervals or a heart rate run. Each part
/// of the plan is one step or a repeat group; a step ends after a time or a
/// distance and can carry a pace or heart rate range. Saves through the same
/// slot route and plan version check as the other workout edits.
struct RunPlanEditorView: View {
    @ObservedObject var sync: SyncModel
    let dayID: String
    let slot: TemplateExercise
    let expectedVersion: Int

    @Environment(\.dismiss) private var dismiss
    @State private var draft: RunPlanDraft
    @State private var editing: EditingRunStep?
    @State private var working = false
    private let original: RunPlan?
    /// The slot has steps in a format this app can't read, such as one a
    /// newer server added; editing would lose them, so only clearing is offered.
    private let unreadable: Bool
    private let unit = RunDistanceUnit.preferred()

    init(sync: SyncModel, dayID: String, slot: TemplateExercise, expectedVersion: Int) {
        _sync = ObservedObject(wrappedValue: sync)
        self.dayID = dayID
        self.slot = slot
        self.expectedVersion = expectedVersion
        let plan = slot.runPlan
        original = plan
        unreadable = slot.run_steps != nil && plan == nil
        _draft = State(initialValue: RunPlanDraft(plan: plan))
    }

    private var changed: Bool { draft.plan != original }

    var body: some View {
        Form {
            if unreadable {
                Section {
                    Text("This run's steps use a format this version of the app can't edit. Remove them to plan the run again here.")
                        .foregroundStyle(Theme.muted)
                }
            } else {
                if draft.items.isEmpty {
                    Section {
                        Text("No steps yet, so this is a run at your own pace. Add steps such as a warm-up, then a repeat for intervals, each with an optional pace or heart rate range.")
                            .foregroundStyle(Theme.muted)
                    }
                }
                ForEach(Array(draft.items.enumerated()), id: \.element.id) { index, item in
                    if let repeats = item.repeats {
                        repeatSection(item, repeats: repeats, index: index)
                    } else if let step = item.steps.first {
                        Section {
                            stepRow(step, itemMenu: itemMenu(item.id, index: index))
                        }
                    }
                }
                Section {
                    Button("Add step", systemImage: "plus") { draft.addStep() }
                        .disabled(!draft.canAddItem)
                        .accessibilityIdentifier("runPlan.addStep")
                    Button("Add repeat", systemImage: "repeat") { draft.addRepeat() }
                        .disabled(!draft.canAddItem)
                        .accessibilityIdentifier("runPlan.addRepeat")
                } footer: {
                    Text("Paces and distances use your run recorder's \(unit == .miles ? "miles" : "kilometers"). Under 1 km reads in meters.")
                }
            }

            if let problem = draft.problem, !unreadable {
                Section { Text(problem).foregroundStyle(Theme.danger) }
            }
            if let error = sync.loadError {
                Section { Text(error).foregroundStyle(Theme.danger) }
            }
            if slot.run_steps != nil {
                Section {
                    Button("Remove all steps", role: .destructive) { save(nil) }
                        .disabled(working)
                        .accessibilityIdentifier("runPlan.clear")
                } footer: {
                    Text("The run stays in the workout without steps.")
                }
            }
        }
        .scrollContentBackground(.hidden)
        .background(Theme.background)
        .navigationTitle("Plan run")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarLeading) {
                Button("Cancel") { dismiss() }.foregroundStyle(Theme.muted)
            }
            if !unreadable {
                ToolbarItem(placement: .topBarTrailing) {
                    Button(working ? "Saving…" : "Save") { save(draft.plan) }
                        .disabled(working || !changed || draft.problem != nil)
                        .accessibilityIdentifier("runPlan.save")
                }
            }
        }
        .tint(Theme.accent)
        .sheet(item: $editing) { target in
            NavigationStack {
                RunStepEditorView(step: target.step, unit: unit) { draft.update(target.id, to: $0) }
            }
        }
    }

    private func repeatSection(_ item: RunPlanDraft.Item, repeats: Int, index: Int) -> some View {
        Section {
            Stepper("\(repeats) time\(repeats == 1 ? "" : "s")",
                    value: Binding(
                        get: { repeats },
                        set: { value in
                            if let at = draft.items.firstIndex(where: { $0.id == item.id }) {
                                draft.items[at].repeats = value
                            }
                        }),
                    in: RunPlanLimits.repeats)
                .accessibilityIdentifier("runPlan.repeats.\(index)")
            ForEach(Array(item.steps.enumerated()), id: \.element.id) { stepIndex, step in
                stepRow(step, itemMenu: Menu {
                    Button("Move up", systemImage: "arrow.up") { draft.moveStep(step.id, inRepeat: item.id, by: -1) }
                        .disabled(stepIndex == 0)
                    Button("Move down", systemImage: "arrow.down") { draft.moveStep(step.id, inRepeat: item.id, by: 1) }
                        .disabled(stepIndex == item.steps.count - 1)
                    Button("Remove step", systemImage: "trash", role: .destructive) {
                        draft.removeStep(step.id, inRepeat: item.id)
                    }
                } label: {
                    Image(systemName: "ellipsis.circle").frame(width: 44, height: 44)
                }
                .accessibilityLabel("Options for this step"))
            }
            Button("Add step to repeat", systemImage: "plus") { draft.addStep(toRepeat: item.id) }
                .disabled(!draft.canAddStep(toRepeat: item.id))
        } header: {
            HStack {
                Text("Repeat")
                Spacer()
                itemMenu(item.id, index: index, removeLabel: "Remove repeat")
            }
        }
    }

    private func stepRow(_ step: RunPlanDraft.Step, itemMenu: some View) -> some View {
        HStack {
            Button {
                editing = EditingRunStep(id: step.id, step: step.step)
            } label: {
                VStack(alignment: .leading, spacing: 3) {
                    Text(RunPlanFormat.text(step.step, unit: unit))
                        .font(Theme.mono(15, .bold)).foregroundStyle(Theme.text)
                    if let problem = step.step.problem {
                        Text(problem).font(Theme.mono(12)).foregroundStyle(Theme.danger)
                    }
                }
                .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityHint("Edit this step")
            itemMenu
        }
    }

    private func itemMenu(_ id: UUID, index: Int, removeLabel: String = "Remove step") -> some View {
        Menu {
            Button("Move up", systemImage: "arrow.up") { draft.move(id, by: -1) }
                .disabled(index == 0)
            Button("Move down", systemImage: "arrow.down") { draft.move(id, by: 1) }
                .disabled(index == draft.items.count - 1)
            Button(removeLabel, systemImage: "trash", role: .destructive) { draft.remove(id) }
        } label: {
            Image(systemName: "ellipsis.circle").frame(width: 44, height: 44)
        }
        .accessibilityLabel(removeLabel == "Remove repeat" ? "Options for this repeat" : "Options for this step")
    }

    private func save(_ plan: RunPlan?) {
        working = true
        Task {
            let saved = await sync.updateRunSteps(dayID: dayID, teID: slot.id, steps: plan,
                                                  expectedVersion: expectedVersion)
            working = false
            if saved { dismiss() }
        }
    }
}

/// One step: what kind, when it ends, and an optional target range.
struct RunStepEditorView: View {
    private enum Ending: String, CaseIterable {
        case time = "Time", distance = "Distance"
    }

    private enum TargetChoice: String, CaseIterable {
        case off = "None", pace = "Pace", heartRate = "Heart rate"
    }

    let unit: RunDistanceUnit
    let onDone: (RunPlan.Step) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var kind: RunPlan.Kind
    @State private var ending: Ending
    @State private var minutes: Int
    @State private var seconds: Int
    @State private var distance: RunDistanceEntry
    @State private var targetChoice: TargetChoice
    @State private var fastestText: String
    @State private var slowestText: String
    @State private var lowBPM: Int
    @State private var highBPM: Int

    init(step: RunPlan.Step, unit: RunDistanceUnit, onDone: @escaping (RunPlan.Step) -> Void) {
        self.unit = unit
        self.onDone = onDone
        _kind = State(initialValue: step.kind)
        _ending = State(initialValue: step.distanceMeters == nil ? .time : .distance)
        let duration = step.durationSeconds ?? 600
        _minutes = State(initialValue: duration / 60)
        _seconds = State(initialValue: duration % 60)
        _distance = State(initialValue: RunDistanceEntry(meters: step.distanceMeters, preferred: unit))
        switch step.target {
        case .pace(let fastest, let slowest)?:
            _targetChoice = State(initialValue: .pace)
            _fastestText = State(initialValue: RunPaceInput.text(secondsPerKm: fastest, unit: unit))
            _slowestText = State(initialValue: RunPaceInput.text(secondsPerKm: slowest, unit: unit))
            _lowBPM = State(initialValue: 130)
            _highBPM = State(initialValue: 145)
        case .heartRate(let low, let high)?:
            _targetChoice = State(initialValue: .heartRate)
            _fastestText = State(initialValue: "")
            _slowestText = State(initialValue: "")
            _lowBPM = State(initialValue: low)
            _highBPM = State(initialValue: high)
        case nil:
            _targetChoice = State(initialValue: .off)
            _fastestText = State(initialValue: "")
            _slowestText = State(initialValue: "")
            _lowBPM = State(initialValue: 130)
            _highBPM = State(initialValue: 145)
        }
    }

    /// The step as entered, or a reason it can't be used yet.
    private var result: Result<RunPlan.Step, StepInputError> {
        var step = RunPlan.Step(kind: kind, durationSeconds: nil, distanceMeters: nil, target: nil)
        switch ending {
        case .time:
            step.durationSeconds = minutes * 60 + seconds
        case .distance:
            guard let meters = distance.meters else {
                return .failure(StepInputError("Enter a distance, such as 800 m or 1.5 km."))
            }
            step.distanceMeters = meters
        }
        switch targetChoice {
        case .off:
            break
        case .pace:
            guard let fastest = RunPaceInput.seconds(fastestText), let slowest = RunPaceInput.seconds(slowestText) else {
                return .failure(StepInputError("Enter paces as minutes and seconds, such as 4:05."))
            }
            step.target = .pace(fastestSecondsPerKm: RunPaceInput.secondsPerKm(fastest, unit: unit),
                                slowestSecondsPerKm: RunPaceInput.secondsPerKm(slowest, unit: unit))
        case .heartRate:
            step.target = .heartRate(minBPM: lowBPM, maxBPM: highBPM)
        }
        if let problem = step.problem { return .failure(StepInputError(problem)) }
        return .success(step)
    }

    private var canFinish: Bool {
        if case .success = result { return true }
        return false
    }

    var body: some View {
        Form {
            Section("Step") {
                Picker("Kind", selection: $kind) {
                    Text("Warm-up").tag(RunPlan.Kind.warmup)
                    Text("Work").tag(RunPlan.Kind.work)
                    Text("Recovery").tag(RunPlan.Kind.recovery)
                    Text("Cool-down").tag(RunPlan.Kind.cooldown)
                }
                .accessibilityIdentifier("runStep.kind")
            }

            Section("Ends after") {
                Picker("Ends after", selection: $ending) {
                    ForEach(Ending.allCases, id: \.self) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.segmented)
                .accessibilityIdentifier("runStep.ending")
                if ending == .time {
                    Stepper("\(minutes) min", value: $minutes, in: 0...360)
                    Stepper("\(seconds) s", value: $seconds, in: 0...55, step: 5)
                } else {
                    HStack {
                        TextField("Distance", text: $distance.text)
                            .keyboardType(.decimalPad)
                            .accessibilityIdentifier("runStep.distance")
                        Picker("Unit", selection: $distance.unit) {
                            ForEach(RunDistanceInput.allCases) { Text($0.rawValue).tag($0) }
                        }
                        .pickerStyle(.segmented)
                        .frame(maxWidth: 160)
                    }
                }
            }

            Section {
                Picker("Target", selection: $targetChoice) {
                    ForEach(TargetChoice.allCases, id: \.self) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.segmented)
                .accessibilityIdentifier("runStep.target")
                switch targetChoice {
                case .off:
                    EmptyView()
                case .pace:
                    paceField("Fastest", text: $fastestText, identifier: "runStep.fastest")
                    paceField("Slowest", text: $slowestText, identifier: "runStep.slowest")
                case .heartRate:
                    // Raising the low end past the high end carries the high
                    // end with it, so the range shown is the range saved.
                    Stepper("From \(lowBPM) bpm",
                            value: Binding(get: { lowBPM }, set: { lowBPM = $0; highBPM = max(highBPM, $0) }),
                            in: RunPlanLimits.heartRate)
                    Stepper("Up to \(highBPM) bpm", value: $highBPM,
                            in: lowBPM...RunPlanLimits.heartRate.upperBound)
                }
            } header: {
                Text("Target")
            } footer: {
                Text("The recorder says when you're outside the range during this step.")
            }

            if case .failure(let error) = result {
                Section { Text(error.message).foregroundStyle(Theme.danger) }
            }
        }
        .scrollContentBackground(.hidden)
        .background(Theme.background)
        .navigationTitle("Step")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarLeading) {
                Button("Cancel") { dismiss() }.foregroundStyle(Theme.muted)
            }
            ToolbarItem(placement: .topBarTrailing) {
                Button("Done") {
                    if case .success(let step) = result {
                        onDone(step)
                        dismiss()
                    }
                }
                .disabled(!canFinish)
                .accessibilityIdentifier("runStep.done")
            }
        }
        .tint(Theme.accent)
    }

    private func paceField(_ label: String, text: Binding<String>, identifier: String) -> some View {
        HStack {
            Text(label)
            Spacer()
            TextField("4:05", text: text)
                .keyboardType(.numbersAndPunctuation)
                .multilineTextAlignment(.trailing)
                .frame(maxWidth: 90)
                .accessibilityIdentifier(identifier)
            Text("/\(unit.abbreviation)").foregroundStyle(Theme.muted)
        }
    }
}

private struct StepInputError: Error {
    let message: String
    init(_ message: String) { self.message = message }
}
