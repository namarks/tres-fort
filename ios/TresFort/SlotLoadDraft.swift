import Foundation

/// The editable target load and effort of a saved exercise slot. Only what the
/// member changed is sent, so an untouched load keeps its exact stored value,
/// and switching lb/kg back and forth without typing never drifts it.
struct SlotLoadDraft {
    /// Bodyweight and hold slots may carry a negative load (assistance).
    let allowsAssistance: Bool
    private let originalWeight: Double?
    private let originalUnit: WeightUnit
    private let originalRPE: Double?
    /// The exact value behind `text` until the member types, and its unit.
    private var sourceWeight: Double?
    private var sourceUnit: WeightUnit
    private var generatedText: String
    var text: String
    private(set) var unit: WeightUnit
    var rpe: Double?

    init(slot: TemplateExercise) {
        self.init(weight: slot.target_weight, unit: slot.targetWeightUnit, rpe: slot.target_rpe,
                  allowsAssistance: slot.allowsAssistance)
    }

    init(weight: Double?, unit: WeightUnit, rpe: Double?, allowsAssistance: Bool) {
        self.allowsAssistance = allowsAssistance
        originalWeight = weight
        originalUnit = unit
        originalRPE = rpe
        sourceWeight = weight
        sourceUnit = unit
        generatedText = weight.map(WeightUnit.text) ?? ""
        text = generatedText
        self.unit = unit
        self.rpe = rpe
    }

    private var trimmed: String { text.trimmingCharacters(in: .whitespacesAndNewlines) }
    private var isUntouched: Bool { text == generatedText }

    /// The load in `unit`: nil when the field is empty or unreadable.
    var weight: Double? {
        if isUntouched { return sourceWeight.map { sourceUnit.convert($0, to: unit) } }
        guard let value = Double(trimmed), value.isFinite else { return nil }
        return value
    }

    /// An empty field clears the target; anything else must be a number, and
    /// only an assistance-capable exercise may go below zero.
    var isValid: Bool {
        if trimmed.isEmpty { return true }
        guard let value = weight else { return false }
        return allowsAssistance || value >= 0
    }

    mutating func select(_ next: WeightUnit) {
        guard next != unit else { return }
        if !isUntouched {
            sourceWeight = trimmed.isEmpty ? nil : weight
            sourceUnit = unit
        }
        unit = next
        generatedText = sourceWeight.map { WeightUnit.text(sourceUnit.convert($0, to: next)) } ?? ""
        text = generatedText
    }

    /// Fields for the slot PATCH; empty when nothing changed.
    var changedFields: [String: Any] {
        var fields: [String: Any] = [:]
        let loadChanged = isUntouched
            ? !(sourceWeight == originalWeight && sourceUnit == originalUnit && unit == originalUnit)
            : true
        if loadChanged {
            if trimmed.isEmpty {
                if originalWeight != nil { fields["target_weight"] = NSNull() }
            } else if let value = weight {
                fields["target_weight"] = value
                fields["target_weight_unit"] = unit.rawValue
            }
        }
        if rpe != originalRPE { fields["target_rpe"] = rpe.map { $0 as Any } ?? NSNull() }
        return fields
    }
}
