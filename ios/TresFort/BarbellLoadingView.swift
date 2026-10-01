import SwiftUI

struct BarbellLoadingView: View {
    let target: Double
    /// The runner load's own unit: the bar, plates and every label use it.
    let unit: WeightUnit
    @State private var bar: Double
    @State private var steps: [WarmupStep] = []
    @Environment(\.dismiss) private var dismiss

    init(target: Double, unit: WeightUnit = .lb) {
        self.target = target
        self.unit = unit
        _bar = State(initialValue: BarbellLoading.standardBar(unit))
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("Plates") {
                    LabeledContent("Chosen load", value: "\(SetValueFormatter.number(target)) \(unit.rawValue)")
                    LabeledContent("Bar (\(unit.rawValue))") {
                        TextField("Bar", value: $bar, format: .number)
                            .keyboardType(.decimalPad).multilineTextAlignment(.trailing)
                    }
                    if let result = BarbellLoading.breakdown(target: target, unit: unit, bar: bar) {
                        if result.perSide.isEmpty { Text("Empty bar") }
                        else {
                            Text("Each side").font(.headline)
                            ForEach(result.perSide) { plate in
                                LabeledContent(BarbellLoading.plateLabel(plate.weight, unit: unit), value: "× \(plate.count)")
                            }
                        }
                        if result.remainingWeight > 0 {
                            Text("These plates make \(SetValueFormatter.number(result.achievableWeight)) \(unit.rawValue); \(SetValueFormatter.number(result.remainingWeight)) \(unit.rawValue) remains.")
                                .foregroundStyle(.secondary)
                        }
                        Text(BarbellLoading.platesNote(unit)).font(.caption).foregroundStyle(.secondary)
                    } else {
                        Text("Choose a positive bar weight at or below the target.").foregroundStyle(.secondary)
                    }
                }
                Section {
                    ForEach($steps) { $step in
                        HStack {
                            TextField("Load", value: $step.weight, format: .number).keyboardType(.decimalPad)
                            Text("\(unit.rawValue) ×")
                            TextField("Reps", value: $step.reps, format: .number).keyboardType(.numberPad)
                            Text("reps")
                        }
                    }
                    Button("Reset ramp for this load") { reset() }
                } header: {
                    Text("Warm-up guide")
                } footer: {
                    Text("Adjust the steps to suit your session. This loading guide does not log sets.")
                }
            }
            .navigationTitle("Barbell loading").navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
            .onAppear { reset() }
        }
    }

    private func reset() { steps = BarbellLoading.warmup(target: target, unit: unit, bar: bar) }
}
