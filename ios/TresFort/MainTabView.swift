import SwiftUI

/// Owns the single shared SyncModel so the Today runner and the History
/// tab read the same loaded state (one network pull, instant consistency).
struct MainTabView: View {
    @ObservedObject var auth: AuthModel
    @StateObject private var sync: SyncModel

    init(auth: AuthModel) {
        self.auth = auth
        _sync = StateObject(wrappedValue: SyncModel(auth: auth))
    }

    var body: some View {
        TabView {
            TodayView(sync: sync, auth: auth)
                .tabItem {
                    Label("Today", systemImage: "figure.strengthtraining.traditional")
                }
            CalendarView(sync: sync)
                .tabItem { Label("Calendar", systemImage: "calendar") }
            HistoryView(sync: sync)
                .tabItem { Label("History", systemImage: "chart.xyaxis.line") }
        }
        .tint(Theme.accent)
        .task { await sync.load() }
    }
}
