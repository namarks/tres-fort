import SwiftUI

/// Presentation preference only. Canonical changes are always fetched from
/// plan history; this marker can never authorize a mutation or erase history.
enum PlanChangeDismissalStore {
    private struct Marker: Codable { let planID: String; let throughVersion: Int }
    static func key(userID: String) -> String { "com.nmarkspdx.tresfort.plan-changes-dismissed.v1.\(userID)" }

    static func load(userID: String?, planID: String, defaults: LocalPersistence) -> Int {
        guard let userID, let data = defaults.data(forKey: key(userID: userID)),
              let marker = try? JSONDecoder().decode(Marker.self, from: data),
              marker.planID == planID else { return 0 }
        return marker.throughVersion
    }

    static func dismiss(through version: Int, userID: String?, planID: String, defaults: LocalPersistence) {
        guard let userID else { return }
        let marker = Marker(planID: planID, throughVersion: max(version,
            load(userID: userID, planID: planID, defaults: defaults)))
        guard let data = try? JSONEncoder().encode(marker) else { return }
        defaults.set(data, forKey: key(userID: userID))
    }
}
