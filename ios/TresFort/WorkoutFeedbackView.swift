import SwiftUI

struct WorkoutFeedbackPresentation: Identifiable {
    let id = UUID()
    let target: WorkoutTerminalActionTarget
}

struct SavedWorkoutFeedbackView: View {
    let feedback: WorkoutFeedback
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Private workout feedback").font(.headline)
            if let fatigue = feedback.perceivedFatigue {
                Text("Fatigue: \(fatigue)/10").accessibilityIdentifier("feedback.saved-fatigue")
            }
            if let note = feedback.notes, !note.isEmpty {
                Text(verbatim: note).accessibilityIdentifier("feedback.saved-note")
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .foregroundStyle(Theme.text)
    }
}

struct WorkoutFeedbackSheet: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.scenePhase) private var scenePhase
    @ObservedObject var sync: SyncModel
    let target: WorkoutTerminalActionTarget
    let finishAfterSave: Bool
    @StateObject private var editor: WorkoutFeedbackEditor
    @State private var saveFailed = false
    @FocusState private var typing: Bool

    init(sync: SyncModel, target: WorkoutTerminalActionTarget, finishAfterSave: Bool = false) {
        self.sync = sync
        self.target = target
        self.finishAfterSave = finishAfterSave
        _editor = StateObject(wrappedValue: WorkoutFeedbackEditor(
            initial: sync.currentWorkoutFeedback, transcriber: WorkoutFeedbackTranscriberFactory.make()))
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Text("Optional. Saved feedback is shared with your coach and kept out of group feeds.")
                    if editor.isFinalizing {
                        Text("Finishing transcription…")
                        Button("Use current text") { editor.stop() }
                    } else if editor.isRecording || editor.isStarting {
                        Button(editor.isStarting ? "Cancel recording" : "Stop recording") {
                            if editor.isStarting { editor.cancelRecording() } else { editor.finishRecording() }
                        }
                        .accessibilityIdentifier("feedback.stop")
                        if editor.isRecording {
                            Button("Cancel recording", role: .cancel) { editor.cancelRecording() }
                        }
                    } else {
                        Button { typing = false; Task { await editor.talk() } } label: {
                            Label("Talk about your workout", systemImage: "mic.fill")
                        }
                        .accessibilityIdentifier("feedback.talk")
                    }
                    Button("Type instead") { editor.stop(); typing = true }
                    if let message = editor.message { Text(message).foregroundStyle(.secondary) }
                    Text("Recording stays on this iPhone and is discarded. Review the text before saving.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Section("Your words") {
                    TextEditor(text: Binding(get: { editor.text }, set: { editor.edit($0) }))
                        .frame(minHeight: 120).focused($typing)
                        .accessibilityLabel("Workout note").accessibilityIdentifier("feedback.note")
                }
                Section("Perceived fatigue (optional)") {
                    Picker("Fatigue", selection: $editor.fatigue) {
                        Text("Not rated").tag(Int?.none)
                        ForEach(1...10, id: \.self) { value in
                            Text("\(value) / 10").tag(Int?.some(value))
                        }
                    }
                    .pickerStyle(.menu)
                    .accessibilityIdentifier("feedback.fatigue")
                    Text("1 = fresh · 10 = exhausted").font(.caption).foregroundStyle(.secondary)
                }
                if saveFailed {
                    Section { Text("This workout changed. Close this sheet and review its current feedback before saving again.") }
                }
            }
            .navigationTitle(finishAfterSave ? "Finish workout" : "Feedback")
            .navigationBarTitleDisplayMode(.inline)
            .safeAreaInset(edge: .bottom, spacing: 0) {
                if finishAfterSave {
                    VStack(spacing: 8) {
                        Button(action: saveFeedback) {
                            Text("Save feedback & finish")
                                .frame(maxWidth: .infinity, minHeight: 44)
                        }
                        .buttonStyle(.borderedProminent)
                        .tint(Theme.accent).foregroundStyle(.black)
                        .disabled(editor.isRecording || editor.isStarting || editor.isFinalizing)
                        .accessibilityIdentifier("feedback.saveAndFinish")
                        Button(editor.initial?.isEmpty == false ? "Finish with saved feedback" : "Finish without feedback") {
                            editor.stop()
                            dismiss()
                            Task { await sync.finishWorkout(expected: target) }
                        }
                        .frame(minHeight: 44)
                        .accessibilityIdentifier("feedback.finishWithoutChanges")
                    }
                    .padding(.horizontal, 20).padding(.vertical, 8)
                    .frame(maxWidth: .infinity)
                    .background(Theme.background)
                }
            }
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(finishAfterSave ? "Keep working" : "Cancel") {
                        editor.stop()
                        dismiss()
                    }
                }
                if !finishAfterSave {
                    ToolbarItem(placement: .confirmationAction) {
                        Button("Save feedback", action: saveFeedback)
                            .disabled(editor.isRecording || editor.isStarting || editor.isFinalizing)
                    }
                }
                ToolbarItemGroup(placement: .keyboard) {
                    Spacer()
                    Button("Done") { typing = false }
                }
            }
        }
        .onChange(of: scenePhase) { _, phase in
            if phase == .background { editor.interrupt() }
        }
        .onDisappear { editor.stop() }
    }

    private func saveFeedback() {
        guard sync.saveWorkoutFeedback(editor.approvedFeedback(), expected: target, previous: editor.initial) else {
            saveFailed = true
            return
        }
        dismiss()
        if finishAfterSave, let savedTarget = sync.terminalActionTarget {
            Task { await sync.finishWorkout(expected: savedTarget) }
        }
    }
}

struct WorkoutFeedbackEntry: View {
    @ObservedObject var sync: SyncModel
    @State private var presentation: WorkoutFeedbackPresentation?
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if let feedback = sync.currentWorkoutFeedback, !feedback.isEmpty {
                SavedWorkoutFeedbackView(feedback: feedback)
                Text("Saved on this device until you finish.").font(.caption).foregroundStyle(Theme.muted)
            }
            Button {
                if let target = sync.terminalActionTarget {
                    presentation = WorkoutFeedbackPresentation(target: target)
                }
            } label: {
                Label(sync.currentWorkoutFeedback == nil ? "Talk about your workout" : "Edit workout feedback",
                      systemImage: "text.bubble")
            }
            .frame(minHeight: 44)
            .accessibilityIdentifier("feedback.open")
            .disabled(sync.hasPendingTerminalIntentForCurrentWorkout)
            Text("Optional — you can finish without feedback.").font(.caption).foregroundStyle(Theme.muted)
        }
        .sheet(item: $presentation) { item in
            WorkoutFeedbackSheet(sync: sync, target: item.target)
        }
    }
}

@MainActor
enum WorkoutFeedbackTranscriberFactory {
    static func make() -> any WorkoutFeedbackTranscribing {
        #if DEBUG && targetEnvironment(simulator)
        if UIFixtureScenario.selected != nil {
            return SyntheticFeedbackTranscriber()
        }
        #endif
        return OnDeviceFeedbackTranscriber()
    }
}

/// Long transcripts remain scrollable; neither choice can be pushed off the
/// screen by placing both versions in a fixed-height sync banner.
struct WorkoutFeedbackConflictSheet: View {
    @Environment(\.dismiss) private var dismiss
    @ObservedObject var sync: SyncModel
    let intent: WorkoutTerminalIntent
    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Text("Feedback changed elsewhere. Review both versions before finishing.")
                }
                if let feedback = intent.feedback {
                    Section("Your version") { SavedWorkoutFeedbackView(feedback: feedback) }
                }
                if let saved = intent.feedbackConflict {
                    Section("Saved version") {
                        SavedWorkoutFeedbackView(feedback: WorkoutFeedback(notes: saved.notes, perceivedFatigue: saved.perceivedFatigue))
                    }
                    Section {
                        Button("Keep saved feedback") { resolve(saved, useMine: false) }
                        Button("Use my feedback") { resolve(saved, useMine: true) }
                    }
                }
            }
            .navigationTitle("Review feedback")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Later") { dismiss() } } }
        }
    }
    private func resolve(_ expected: WorkoutFeedbackBaseline, useMine: Bool) {
        Task {
            await sync.resolveWorkoutFeedbackConflict(id: intent.id, expected: expected, useMine: useMine)
            dismiss()
        }
    }
}
