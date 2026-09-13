#if DEBUG && targetEnvironment(simulator)
import SwiftUI

@MainActor
private final class FixtureWeightReader: BodyWeightReading {
    let isAvailable = true
    private var reads = 0
    func requestAuthorization() async throws {}
    func read(from: Date, through: Date) async throws -> [BodyWeightMeasurement] {
        reads += 1
        if ProcessInfo.processInfo.environment["TRESFORT_UI_WEIGHT_EMPTY"] == "1" || reads > 1 { return [] }
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

    init(auth: AuthModel) {
        _model = StateObject(wrappedValue: BodyWeightModel(auth: auth, defaults: UIFixtureModel.defaults,
            reader: FixtureWeightReader(), now: { ISO8601DateFormatter().date(from: "2026-09-12T12:00:00Z")! }))
    }

    var body: some View {
        NavigationStack {
            BodyWeightView(model: model)
        }
        .preferredColorScheme(.dark)
    }
}
#endif
