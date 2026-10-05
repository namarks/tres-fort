import SwiftUI

struct StationCatalogView: View {
    let workout: [StationExerciseOption]
    let catalog: [StationExerciseOption]
    let select: (StationExerciseOption) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var search = ""

    private func matches(_ option: StationExerciseOption) -> Bool {
        search.isEmpty || option.name.localizedCaseInsensitiveContains(search)
    }

    var body: some View {
        NavigationStack {
            List {
                if !workout.isEmpty {
                    Section("This workout") {
                        ForEach(workout.filter(matches)) { row($0) }
                    }
                }
                Section("Exercise catalog") {
                    ForEach(catalog.filter(matches).sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }) { row($0) }
                }
                Section {
                    Text("Candidates need a counting rule and camera testing. Available experiments are estimates; none save sets or assess form.")
                }
            }
            .searchable(text: $search, prompt: "Find an exercise")
            .navigationTitle("Camera tracking")
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
        }
        .preferredColorScheme(.dark)
    }

    private func row(_ option: StationExerciseOption) -> some View {
        let entry = StationTrackingCatalog.bundled.entry(for: option.exerciseID)
        return Button {
            select(option)
            dismiss()
        } label: {
            VStack(alignment: .leading, spacing: 4) {
                Text(option.name).foregroundStyle(Theme.text)
                Text(entry.profile?.title ?? "Manual logging / timer").font(.subheadline)
                Text(entry.trial != nil && option.trial() == nil ? "Use the workout timer for this prescription" : entry.status)
                    .font(.caption).foregroundStyle(Theme.muted)
            }
        }
        .accessibilityIdentifier("station.catalog.\(option.id)")
    }
}

struct StationHoldPanel: View {
    @Binding var timer: StationHoldTimer
    let cameraRunning: Bool
    let title: String

    var body: some View {
        VStack(spacing: 16) {
            Text(title.uppercased()).font(Theme.display(30))
                .accessibilityIdentifier("station.movement")
            Text("\(Int(ceil(timer.remaining)))")
                .font(Theme.number(64)).monospacedDigit()
                .accessibilityLabel("\(Int(ceil(timer.remaining))) seconds remaining")
                .accessibilityIdentifier("station.holdRemaining")
            Text(timer.state.message).font(.headline).multilineTextAlignment(.center)
                .accessibilityIdentifier("station.holdStatus")
            Text("Observed hold: \(timer.elapsed, specifier: "%.1f") seconds")
                .font(.subheadline).foregroundStyle(Theme.muted)
            Stepper("Target: \(timer.targetSeconds) seconds", value: Binding(
                get: { timer.targetSeconds },
                set: { value in
                    guard !timer.isActive else { return }
                    timer = StationHoldTimer(kind: timer.kind, targetSeconds: value)
                }), in: 1...3600, step: 5)
                .disabled(timer.isActive)
                .accessibilityIdentifier("station.holdTarget")
            Button(timer.isActive ? "Stop hold test" : "Start hold test") {
                if timer.isActive { timer.stop() } else { timer.start() }
            }
            .buttonStyle(.borderedProminent).tint(Theme.accent).foregroundStyle(Theme.bg)
            .disabled(!cameraRunning)
            .accessibilityIdentifier("station.holdTrial")
            Text("The countdown starts after one second in position. It pauses when you leave the hold or joints become unclear, then requires another steady second before resuming.")
                .font(.subheadline).foregroundStyle(Theme.muted)
            if timer.wasInterrupted {
                Text("Interrupted hold · time includes only the portions we could observe.")
                    .font(.subheadline).foregroundStyle(.orange)
            }
            Text("Experimental timer · No sets are saved")
                .font(.subheadline).foregroundStyle(Theme.muted)
                .accessibilityIdentifier("station.trialNotice")
        }
        .padding(20).frame(maxWidth: .infinity)
        .background(Theme.surface, in: RoundedRectangle(cornerRadius: 20))
    }
}
