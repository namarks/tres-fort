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
    @State private var selectedTab: Tab = .today

    enum Tab { case today, calendar, history, group, profile }

    /// Wraps the pending invite code as Identifiable so `.sheet(item:)` can
    /// drive the join-confirm sheet off AuthModel's optional code.
    private struct PendingInvite: Identifiable {
        let code: String
        var id: String { code }
    }

    init(auth: AuthModel) {
        self.auth = auth
        let sync = SyncModel(auth: auth)
        let groupModel = GroupModel(auth: auth)
        // Bridge group-side activity writes to the personal calendar here in
        // init — NOT in `.task` — so the closure is set before GroupTabView's
        // own `.task { groupModel.load() }` can drain the outbox on launch.
        // Setting it in a racing sibling task risked an early drain firing
        // while the closure was still nil (calendar never refreshed for those
        // rows). StateObject keeps the first instances, so the closure stays
        // bound to the retained sync across re-inits.
        groupModel.onActivityPersisted = { [weak sync] in await sync?.load() }
        _sync = StateObject(wrappedValue: sync)
        _groupModel = StateObject(wrappedValue: groupModel)
    }

    var body: some View {
        TabView(selection: $selectedTab) {
            TodayView(sync: sync,
                      auth: auth,
                      onLogActivity: { showActivitySheet = true })
                .tabItem {
                    Label("Today", systemImage: "figure.strengthtraining.traditional")
                }
                .tag(Tab.today)
            CalendarView(sync: sync)
                .tabItem { Label("Calendar", systemImage: "calendar") }
                .tag(Tab.calendar)
            HistoryView(sync: sync)
                .tabItem { Label("History", systemImage: "chart.xyaxis.line") }
                .tag(Tab.history)
            GroupTabView(groupModel: groupModel, auth: auth)
                .tabItem { Label("Group", systemImage: "person.2.fill") }
                .tag(Tab.group)
            ProfileView(groupModel: groupModel, auth: auth)
                .tabItem { Label("Profile", systemImage: "person.crop.circle") }
                .tag(Tab.profile)
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
        // A group invite opened via Universal Link (AuthModel stashed the
        // code). Present the confirm sheet HERE — the one place a retained
        // GroupModel and the signed-in surface coexist — and on success jump
        // to the Group tab so the freshly-joined group is right there. A code
        // that arrived during sign-in/onboarding simply waits until this view
        // appears, then presents. Dismiss clears the code (the Binding setter).
        .sheet(item: Binding(
            get: { auth.pendingInviteCode.map(PendingInvite.init) },
            set: { auth.pendingInviteCode = $0?.code }
        )) { invite in
            JoinInviteConfirmSheet(groupModel: groupModel, code: invite.code) {
                selectedTab = .group
            }
        }
    }
}
