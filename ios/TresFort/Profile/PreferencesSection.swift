import SwiftUI

/// App-wide units and timer sounds in one place. These same choices can still
/// be changed where they're used (the workout outline and the run recorder);
/// every control reads and writes the same stored preference.
struct PreferencesSection: View {
    /// Updates the timer cues already scheduled for a workout in progress.
    var sync: SyncModel?
    /// The run recorder applies a units change to a run in progress.
    var runs: RunRecorderModel?

    @AppStorage(WeightUnit.preferenceKey) private var weightUnitRaw = WeightUnit.lb.rawValue
    @AppStorage(RunDistanceUnit.preferenceKey) private var runUnitRaw = RunDistanceUnit.miles.rawValue
    @AppStorage(RestCue.defaultsKey) private var timerCuesEnabled = true

    private var weightUnit: Binding<WeightUnit> {
        Binding(get: { WeightUnit(rawValue: weightUnitRaw) ?? .lb },
                set: { weightUnitRaw = $0.rawValue })
    }

    private var runUnit: Binding<RunDistanceUnit> {
        Binding(get: { RunDistanceUnit(rawValue: runUnitRaw) ?? .miles },
                set: { unit in
                    if let runs { runs.unit = unit } else { runUnitRaw = unit.rawValue }
                })
    }

    var body: some View {
        Section {
            LabeledContent("Weights") {
                WeightUnitPicker(selection: weightUnit, identifier: "profile.weightUnit")
                    .fixedSize()
            }
            LabeledContent("Runs") {
                Picker("Run distance", selection: runUnit) {
                    ForEach(RunDistanceUnit.allCases, id: \.self) { Text($0.abbreviation).tag($0) }
                }
                .pickerStyle(.segmented)
                .fixedSize()
                .accessibilityIdentifier("profile.runUnit")
            }
            Toggle("Timer sounds", isOn: $timerCuesEnabled)
                .tint(Theme.accent)
                .accessibilityIdentifier("profile.timerSounds")
                .onChange(of: timerCuesEnabled) { sync?.refreshTimerCues() }
        } header: {
            Text("Units and sounds")
        } footer: {
            Text("Weights also sets how body weight reads in Progress. Timer sounds play when rest or a timed set ends.")
        }
    }
}
