import Foundation

struct PlateCount: Equatable, Identifiable {
    let weight: Double
    let count: Int
    var id: Double { weight }
}

struct PlateBreakdown: Equatable {
    let perSide: [PlateCount]
    let achievableWeight: Double
    let remainingWeight: Double
}

struct WarmupStep: Equatable, Identifiable {
    let id: Int
    var weight: Double
    var reps: Int
}

enum BarbellLoading {
    /// Standard bar and plates (heaviest first) in the runner load's own
    /// unit; the guide never converts a kg load to lb.
    static func standardBar(_ unit: WeightUnit) -> Double { unit == .kg ? 20 : 45 }

    static func standardPlates(_ unit: WeightUnit) -> [Double] {
        unit == .kg ? [25, 20, 15, 10, 5, 2.5, 1.25] : [45, 35, 25, 10, 5, 2.5]
    }

    /// Exact plate text, so a 1.25 kg plate never reads as 1.2.
    static func plateLabel(_ weight: Double, unit: WeightUnit) -> String {
        "\(WeightUnit.text(weight)) \(unit.rawValue)"
    }

    /// "Uses 45, 35, 25, 10, 5 and 2.5 lb plates."
    static func platesNote(_ unit: WeightUnit) -> String {
        let plates = standardPlates(unit).map(WeightUnit.text)
        return "Uses \(plates.dropLast().joined(separator: ", ")) and \(plates.last ?? "") \(unit.rawValue) plates."
    }

    /// Standard plates, unlimited pairs. Show the unfilled remainder instead
    /// of silently recommending a load heavier than the member chose.
    /// A nil bar is the unit's standard bar.
    static func breakdown(target: Double, unit: WeightUnit = .lb, bar: Double? = nil) -> PlateBreakdown? {
        let bar = bar ?? standardBar(unit)
        guard target.isFinite, bar.isFinite, bar > 0, target >= bar, target <= 10_000 else { return nil }
        var remainder = (target - bar) / 2
        var plates: [PlateCount] = []
        for plate in standardPlates(unit) {
            let count = Int((remainder / plate).rounded(.down))
            if count > 0 { plates.append(PlateCount(weight: plate, count: count)) }
            remainder -= Double(count) * plate
        }
        return PlateBreakdown(perSide: plates, achievableWeight: target - remainder * 2,
                              remainingWeight: remainder * 2)
    }

    static func warmup(target: Double, unit: WeightUnit = .lb, bar: Double? = nil) -> [WarmupStep] {
        let bar = bar ?? standardBar(unit)
        guard breakdown(target: target, unit: unit, bar: bar) != nil else { return [] }
        if target == bar { return [WarmupStep(id: 0, weight: bar, reps: 8)] }
        // Round down to the smallest loadable jump: a pair of the lightest plate.
        let jump = 2 * (standardPlates(unit).last ?? 2.5)
        let loads = [bar, max(bar, bar + ((target * 0.5 - bar) / jump).rounded(.down) * jump),
                     max(bar, bar + ((target * 0.75 - bar) / jump).rounded(.down) * jump)]
        var steps: [WarmupStep] = []
        for (index, load) in loads.enumerated() where steps.last?.weight != load {
            steps.append(WarmupStep(id: index, weight: min(target, load), reps: [8, 5, 3][index]))
        }
        return steps
    }
}
