import SwiftUI

// "How hard was it?" (docs/plans/sport-activities P2). A member rates a
// workout from 1 to 10 in one tap; when nothing measured (heart rate, power,
// pace or the provider's own load) scores it, the Worker scores it from the
// rating, one hour at 7 being 100, and labels it `load_method` "effort", an
// estimate. The scale and load live in src/trainingLoad.ts (EFFORT_SCALE).

/// The 1 to 10 scale, worded as a category-ratio (CR-10) scale.
enum EffortScale {
    static let range = 1...10

    static func label(_ effort: Int) -> String {
        switch effort {
        case ...1: return "Very easy"
        case 2: return "Easy"
        case 3: return "Moderate"
        case 4: return "Somewhat hard"
        case 5, 6: return "Hard"
        case 7, 8: return "Very hard"
        case 9: return "Extremely hard"
        default: return "All out"
        }
    }
}

extension ExternalActivity {
    /// Offer the rating while no measured load scores the workout, and keep
    /// offering it once the rating does, so it can be changed or cleared.
    var offersEffortRating: Bool { load_method == "effort" || shownLoad == nil }
}

/// `PUT /api/activities/:id/effort`; the app reads the rescored workout
/// through the next state pull.
struct ActivityEffortResponse: Decodable {
    struct Activity: Decodable {
        let id: String
        let effort: Int?
    }
    let activity: Activity
}

extension APIClient {
    /// Rates a workout 1 to 10, or clears its rating with nil.
    func rateActivityEffort(activityID: String, effort: Int?, jwt: String) async throws -> ActivityEffortResponse {
        let allowed = CharacterSet.urlPathAllowed.subtracting(CharacterSet(charactersIn: "/"))
        let id = activityID.addingPercentEncoding(withAllowedCharacters: allowed) ?? activityID
        let value: Any = effort.map { $0 as Any } ?? NSNull()
        return try await put("api/activities/\(id)/effort", body: ["effort": value], jwt: jwt)
    }
}

/// Ten buttons in two rows. Tapping the chosen number again clears it.
struct EffortRatingControl: View {
    let activity: ExternalActivity
    /// Saves the rating; nil when saved, else a message to show.
    let rate: (Int?) async -> String?

    @State private var saving: Int?? = nil
    @State private var error: String? = nil

    /// What the buttons show: the rating being saved, else the stored one.
    private var shown: Int? {
        if let saving { return saving }
        return activity.effort
    }

    private let columns = Array(repeating: GridItem(.flexible(), spacing: 6), count: 5)

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline) {
                Text("HOW HARD WAS IT?")
                    .font(Theme.mono(9, .bold)).tracking(1)
                    .foregroundStyle(Theme.dim)
                Spacer()
                if let shown {
                    Text(EffortScale.label(shown))
                        .font(Theme.mono(11, .bold))
                        .foregroundStyle(Theme.muted)
                }
            }
            LazyVGrid(columns: columns, spacing: 6) {
                ForEach(Array(EffortScale.range), id: \.self) { n in
                    let selected = shown == n
                    Button {
                        Task { await choose(n) }
                    } label: {
                        Text("\(n)")
                            .font(Theme.mono(15, .bold))
                            .frame(maxWidth: .infinity, minHeight: 44)
                            .foregroundStyle(selected ? Theme.onAccent : Theme.text)
                            .background(selected ? Theme.accent : Theme.surface2)
                            .clipShape(RoundedRectangle(cornerRadius: 10))
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("\(n), \(EffortScale.label(n))")
                    .accessibilityHint(selected ? "Clears your rating" : "Rates how hard it was")
                    .accessibilityAddTraits(selected ? .isSelected : [])
                    .accessibilityIdentifier("activity.effort.\(n)")
                }
            }
            .disabled(saving != nil)
            Text(activity.load_method == "effort"
                 ? "Its load is an estimate from your rating."
                 : "No heart rate, power or pace, so your rating sets its load.")
                .font(Theme.mono(11))
                .foregroundStyle(Theme.dim)
                .fixedSize(horizontal: false, vertical: true)
            if let error {
                Text(error)
                    .font(Theme.mono(11))
                    .foregroundStyle(Theme.danger)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("activity.effort")
    }

    private func choose(_ n: Int) async {
        let next: Int? = activity.effort == n ? nil : n
        saving = .some(next)
        error = nil
        error = await rate(next)
        saving = nil
    }
}
