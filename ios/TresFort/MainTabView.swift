import SwiftUI

/// Owns the single shared SyncModel + GroupModel so every tab reads the
/// same loaded state (one network pull, instant consistency). The
/// GroupModel and SyncModel are peers — they don't share data, only
/// the AuthModel reference.
struct MainTabView: View {
    @ObservedObject var auth: AuthModel
    @StateObject private var sync: SyncModel
    @StateObject private var groupModel: GroupModel
    @Environment(\.scenePhase) private var scenePhase

    @State private var showActivitySheet = false

    init(auth: AuthModel) {
        self.auth = auth
        _sync = StateObject(wrappedValue: SyncModel(auth: auth))
        _groupModel = StateObject(wrappedValue: GroupModel(auth: auth))
    }

    var body: some View {
        TabView {
            TodayView(sync: sync,
                      auth: auth,
                      onLogActivity: { showActivitySheet = true })
                .tabItem {
                    Label("Today", systemImage: "figure.strengthtraining.traditional")
                }
            CalendarView(sync: sync)
                .tabItem { Label("Calendar", systemImage: "calendar") }
            HistoryView(sync: sync)
                .tabItem { Label("History", systemImage: "chart.xyaxis.line") }
            GroupTabView(groupModel: groupModel, auth: auth)
                .tabItem { Label("Group", systemImage: "person.2.fill") }
        }
        .tint(Theme.accent)
        .task {
            await sync.load()
        }
        .onChange(of: scenePhase) { _, new in
            // On foreground, refresh the currently-visible group's feed +
            // drain any pending activity POSTs the user logged while the
            // app was backgrounded/offline. Same idea as iOS's URLSession
            // background-task continuation, just cooperative.
            if new == .active {
                Task {
                    await groupModel.drainOutbox()
                    if let gid = groupModel.selectedGroupID {
                        await groupModel.refreshGroup(groupID: gid)
                    }
                }
            }
        }
        .sheet(isPresented: $showActivitySheet) {
            // Shared sheet — the Today tab toolbar dispatches the same
            // GroupModel-backed handler the Group tab's FAB does. Logging
            // from Today drops into the user's currently-selected group's
            // feed; if they have no group yet, the optimistic insert
            // silently no-ops on the visible feed (groupModel.selected ==
            // nil) but the POST still hits the server.
            ManualActivitySheet { pending in
                await groupModel.logActivity(pending)
            }
        }
    }
}
