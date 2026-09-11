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

struct PlanChangeRow: View {
    let item: PlanHistoryItem
    var compact = false

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(PlanHistoryPresentation.operation(item.operation))
                .font(Theme.mono(13, .bold)).foregroundStyle(Theme.text)
            Text(PlanHistoryPresentation.rationale(item))
                .font(Theme.mono(11)).foregroundStyle(Theme.muted)
                .lineLimit(compact ? 2 : nil)
            if let affected = item.affected, !affected.isEmpty {
                Text(affected.joined(separator: "; "))
                    .font(Theme.mono(11)).foregroundStyle(Theme.text)
                    .lineLimit(compact ? 2 : nil)
            } else if let count = item.summary?.total, count > 0 {
                Text("\(count) change\(count == 1 ? "" : "s")")
                    .font(Theme.mono(11)).foregroundStyle(Theme.muted)
            }
            Text("\(PlanHistoryPresentation.actor(item.actor)) · \(Date(timeIntervalSince1970: Double(item.created_at) / 1_000).formatted(date: .abbreviated, time: .shortened)) · v\(item.version)")
                .font(Theme.mono(10)).foregroundStyle(Theme.muted)
        }
        .accessibilityElement(children: .combine)
    }
}

struct RecentPlanChanges: View {
    @ObservedObject var sync: SyncModel
    let openHistory: () -> Void

    var body: some View {
        Group {
            if let latest = sync.recentPlanChanges.first, let history = sync.recentPlanHistory {
                VStack(alignment: .leading, spacing: 8) {
                    Text("RECENT PLAN CHANGES").font(Theme.mono(10, .bold)).foregroundStyle(Theme.accent)
                    PlanChangeRow(item: latest, compact: true)
                    HStack {
                        Button(action: openHistory) {
                            Text("Review changes").frame(minHeight: 44).contentShape(Rectangle())
                        }
                        .accessibilityIdentifier("planChanges.review")
                        Spacer()
                        Button {
                            sync.dismissRecentPlanChanges(through: latest.version, planID: history.plan_id)
                        } label: {
                            Text("Dismiss recent changes").frame(minHeight: 44).contentShape(Rectangle())
                        }
                        .accessibilityIdentifier("planChanges.dismiss")
                    }
                    .font(.caption).frame(minHeight: 44)
                    Text("Dismissed changes stay in Plan changes.")
                        .font(.caption2).foregroundStyle(Theme.muted)
                }
                .padding(14).background(Theme.surface)
            } else if let error = sync.planChangesError {
                HStack {
                    Text(error).font(.caption).foregroundStyle(Theme.muted)
                    Button("Refresh") {
                        Task {
                            await sync.load()
                            await sync.refreshRecentPlanChanges()
                        }
                    }
                    .frame(minHeight: 44)
                }.padding(.horizontal, 14)
            }
        }
    }
}
