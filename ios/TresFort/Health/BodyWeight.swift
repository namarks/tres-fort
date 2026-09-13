import Foundation

struct BodyWeightMeasurement: Identifiable, Equatable {
    let id: UUID
    let date: Date
    let kilograms: Double
    let source: String
}

enum BodyWeightUnit: String, CaseIterable {
    case pounds = "lb", kilograms = "kg"

    func value(_ kilograms: Double) -> Double {
        // Exact international avoirdupois pound, in kilograms.
        self == .pounds ? kilograms / 0.45359237 : kilograms
    }
}

/// Health remains the store. This disposable, in-memory projection selects the
/// latest reading per local day so repeated weigh-ins do not overweight a day.
struct BodyWeightHistory {
    let measurements: [BodyWeightMeasurement]
    let asOf: Date
    let calendar: Calendar

    init(_ measurements: [BodyWeightMeasurement], asOf: Date, calendar: Calendar = .current) {
        var unique: [UUID: BodyWeightMeasurement] = [:]
        for measurement in measurements where measurement.kilograms.isFinite
            && measurement.kilograms > 0 && measurement.date <= asOf {
            unique[measurement.id] = measurement
        }
        self.measurements = unique.values.sorted {
            $0.date == $1.date ? $0.id.uuidString < $1.id.uuidString : $0.date < $1.date
        }
        self.asOf = asOf
        self.calendar = calendar
    }

    var latest: BodyWeightMeasurement? { measurements.last }

    var daily: [BodyWeightMeasurement] {
        var days: [Date: BodyWeightMeasurement] = [:]
        for measurement in measurements {
            days[calendar.startOfDay(for: measurement.date)] = measurement
        }
        return days.values.sorted { $0.date < $1.date }
    }

    func recentDays(_ count: Int) -> [BodyWeightMeasurement] {
        let start = calendar.date(byAdding: .day, value: 1 - count,
                                  to: calendar.startOfDay(for: asOf))!
        return daily.filter { $0.date >= start }
    }

    func average(ending date: Date) -> Double? {
        let end = calendar.startOfDay(for: date)
        let start = calendar.date(byAdding: .day, value: -6, to: end)!
        let values = daily.filter {
            let day = calendar.startOfDay(for: $0.date)
            return day >= start && day <= end
        }.map(\.kilograms)
        guard !values.isEmpty else { return nil }
        return values.reduce(0, +) / Double(values.count)
    }
}
