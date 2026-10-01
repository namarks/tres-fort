import SwiftUI

enum WeightUnit: String, CaseIterable {
    case lb, kg
    static let preferenceKey = "com.nmarkspdx.tresfort.weight-entry-unit"
    private var pounds: Double { self == .kg ? 1 / 0.45359237 : 1 }

    func convert(_ value: Double, to unit: Self) -> Double {
        self == unit ? value : value * pounds / unit.pounds
    }

    static func text(_ value: Double) -> String {
        String(format: "%.3f", locale: Locale(identifier: "en_US_POSIX"), value)
            .replacingOccurrences(of: "\\.?0+$", with: "", options: .regularExpression)
    }

    /// Per-unit totals side by side ("1200 lb · 300 kg", lb first), never
    /// added together. Empty when there are no totals.
    static func totals(_ values: [Self: Double], number: (Double) -> String) -> String {
        allCases.compactMap { unit in values[unit].map { "\(number($0)) \(unit.rawValue)" } }
            .joined(separator: " · ")
    }
}

extension TemplateExercise {
    /// Read the saved prescription, never a runner draft or a historical load.
    /// Two-dumbbell targets are stored per hand; conversion keeps that meaning.
    /// The load converts from the slot's own `target_weight_unit`.
    func prescriptionLabel(in unit: WeightUnit) -> String {
        var parts = [targetLabel]
        if showsLoadControl, let weight = target_weight {
            let value = WeightUnit.text(targetWeightUnit.convert(abs(weight), to: unit))
            if allowsAssistance && weight == 0 {
                parts.append("Bodyweight")
            } else if allowsAssistance && weight < 0 {
                parts.append("\(value) \(unit.rawValue) assistance")
            } else {
                let prefix = allowsAssistance && weight > 0 ? "+" : ""
                let perHand = isPerHand ? " each hand" : ""
                parts.append("\(prefix)\(value) \(unit.rawValue)\(perHand)")
            }
        }
        if let rpe = target_rpe { parts.append("RPE \(SetValueFormatter.number(rpe))") }
        return parts.joined(separator: " · ")
    }
}

/// Changing the display unit or saving untouched rounded text preserves the
/// exact original load. Only an edited number changes the stored value.
struct WeightEntryDraft {
    let storedUnit: WeightUnit
    private(set) var unit: WeightUnit
    private var originalWeight: Double
    private var originalText: String
    var text: String

    init(weight: Double, storedUnit: WeightUnit, unit: WeightUnit) {
        self.storedUnit = storedUnit
        self.unit = unit
        originalWeight = weight
        originalText = WeightUnit.text(storedUnit.convert(weight, to: unit))
        text = originalText
    }

    var storedWeight: Double? {
        guard let value = Double(text.trimmingCharacters(in: .whitespacesAndNewlines)), value.isFinite else { return nil }
        let converted = text == originalText ? originalWeight : unit.convert(value, to: storedUnit)
        return converted.isFinite ? converted : nil
    }

    mutating func select(_ next: WeightUnit) {
        guard next != unit else { return }
        if let value = storedWeight {
            self = Self(weight: value, storedUnit: storedUnit, unit: next)
        } else {
            unit = next
            originalText = ""
        }
    }
}

struct WeightUnitPicker: View {
    @Binding var selection: WeightUnit
    var identifier = "weight.unit"
    var body: some View {
        Picker("Weight unit", selection: $selection) {
            ForEach(WeightUnit.allCases, id: \.self) { unit in
                Text(unit.rawValue).tag(unit)
            }
        }
        .pickerStyle(.segmented)
        .accessibilityIdentifier(identifier)
    }
}
