#if DEBUG && targetEnvironment(simulator)
import HealthKit
import SwiftUI

@MainActor
final class FixtureWeightReader: BodyWeightReading {
    let isAvailable = true
    private var reads = 0
    private var authorizationRequests = 0
    private var failure: String? { ProcessInfo.processInfo.environment["TRESFORT_UI_WEIGHT_FAILURE"] }

    func requestAuthorization() async throws { authorizationRequests += 1 }
    func read(from: Date, through: Date) async throws -> [BodyWeightMeasurement] {
        reads += 1
        // Synthetic recovery fixtures exercise the same authorization and read
        // protocol as HealthKit without reading personal health data.
        if failure == "reconnect" && authorizationRequests < 2 {
            throw URLError(.cannotLoadFromNetwork)
        }
        if failure == "locked" && reads == 1 {
            throw NSError(domain: HKErrorDomain, code: HKError.Code.errorDatabaseInaccessible.rawValue)
        }
        if failure == "restricted" {
            throw NSError(domain: HKErrorDomain, code: HKError.Code.errorHealthDataRestricted.rawValue)
        }
        if ProcessInfo.processInfo.environment["TRESFORT_UI_WEIGHT_EMPTY"] == "1" || (ProcessInfo.processInfo.environment["TRESFORT_UI_WEIGHT_CLEAR_ON_REFRESH"] == "1" && reads > 1) { return [] }
        return (0..<20).map { day in
            BodyWeightMeasurement(id: UUID(),
                date: through.addingTimeInterval(-Double(day) * 86_400 - 60),
                kilograms: 80 + Double(day % 4) * 0.2 - Double(day) * 0.1,
                source: "Synthetic scale")
        }
    }
}

struct BodyWeightFixtureView: View {
    @StateObject private var model: BodyWeightModel
    @State private var showSettings = false

    init(auth: AuthModel) {
        _model = StateObject(wrappedValue: BodyWeightModel(auth: auth, defaults: UIFixtureModel.defaults,
            reader: FixtureWeightReader(), now: { ISO8601DateFormatter().date(from: "2026-09-12T12:00:00Z")! }))
    }

    var body: some View {
        NavigationStack {
            BodyWeightView(model: model, onManageAccess: { showSettings = true })
        }
        .sheet(isPresented: $showSettings) {
            NavigationStack {
                Form { BodyWeightAccessSection(model: model) }
                    .navigationTitle("Apple Health")
                    .toolbar { Button("Done") { showSettings = false } }
            }
        }
        .preferredColorScheme(.dark)
    }
}
#endif
