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
