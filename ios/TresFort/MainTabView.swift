import SwiftUI

/// Owns the single shared SyncModel + GroupModel so every tab reads the
/// same loaded state (one network pull, instant consistency). The
/// GroupModel and SyncModel are peers — they don't share data, only
/// the AuthModel reference.
struct MainTabView: View {
    @ObservedObject var auth: AuthModel
    @StateObject private var sync: SyncModel
    @StateObject private var groupModel: GroupModel
    @StateObject private var health: HealthKitSyncModel
    @StateObject private var setConnectivity: SetConnectivityMonitor
    @Environment(\.scenePhase) private var scenePhase

    @State private var showActivitySheet = false
    @State private var selectedTab: Tab = .today

    enum Tab { case today, history, group, profile }

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
        let health = HealthKitSyncModel(auth: auth)
        let setConnectivity = SetConnectivityMonitor()
        // Bridge group-side activity writes to the personal calendar here in
        // init — NOT in `.task` — so the closure is set before GroupTabView's
        // own `.task { groupModel.load() }` can drain the outbox on launch.
        // Setting it in a racing sibling task risked an early drain firing
        // while the closure was still nil (calendar never refreshed for those
        // rows). StateObject keeps the first instances, so the closure stays
        // bound to the retained sync across re-inits.
        groupModel.onActivityPersisted = {
            [weak sync] in await sync?.loadAfterMutation()
        }
        // HealthKit pushes land in external_activities (source='healthkit'),
        // which ride /api/state — so a completed sync must refresh the personal
        // calendar/agenda just like a manual activity does.
        health.onActivitiesPersisted = {
            [weak sync] in await sync?.loadAfterMutation()
        }
        setConnectivity.onSatisfiedTransition = { [weak sync] in
            Task { await sync?.recoverWorkoutWrites() }
        }
        _sync = StateObject(wrappedValue: sync)
        _groupModel = StateObject(wrappedValue: groupModel)
        _health = StateObject(wrappedValue: health)
        _setConnectivity = StateObject(wrappedValue: setConnectivity)
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
            HistoryView(sync: sync)
                .tabItem { Label("History", systemImage: "calendar") }
                .tag(Tab.history)
            GroupTabView(groupModel: groupModel, auth: auth)
                .tabItem { Label("Group", systemImage: "person.2.fill") }
                .tag(Tab.group)
            ProfileView(groupModel: groupModel, auth: auth, health: health)
                .tabItem { Label("Profile", systemImage: "person.crop.circle") }
                .tag(Tab.profile)
        }
        .tint(Theme.accent)
        .task {
            guard let initiatingUserID = auth.userID else { return }
            await auth.checkAppleCredentialState()
            guard auth.featureJWT != nil, auth.userID == initiatingUserID else { return }
            // Renew before the first authenticated pull when the fixed-expiry
            // app JWT is within its seven-day window. Offline failure is soft;
            // an expired/revoked bearer moves AuthModel to reauthentication.
            await auth.renewSessionIfNeeded()
            guard auth.featureJWT != nil, auth.userID == initiatingUserID else { return }
            await sync.recoverWorkoutWrites()
            guard auth.featureJWT != nil, auth.userID == initiatingUserID else { return }
            // Register the HealthKit observer + run an incremental sync if the
            // user has connected Apple Health (no-op otherwise). Anchored
            // foreground sync is the source of truth (background delivery is
            // best-effort); this is the reliable per-launch pass.
            health.start()
        }
        .onChange(of: scenePhase) { _, new in
            // On foreground, refresh the currently-visible group's feed +
            // drain any pending activity POSTs the user logged while the
            // app was backgrounded/offline. Same idea as iOS's URLSession
            // background-task continuation, just cooperative.
            if new == .active {
                Task {
                    guard let initiatingUserID = auth.userID else { return }
                    await auth.checkAppleCredentialState()
                    guard auth.featureJWT != nil, auth.userID == initiatingUserID else { return }
                    await auth.renewSessionIfNeeded()
                    guard auth.featureJWT != nil, auth.userID == initiatingUserID else { return }
                    await sync.recoverWorkoutWrites()
                    guard auth.featureJWT != nil, auth.userID == initiatingUserID else { return }
                    await groupModel.drainOutbox()
                    guard auth.featureJWT != nil, auth.userID == initiatingUserID else { return }
                    if let gid = groupModel.selectedGroupID {
                        await groupModel.refreshGroup(groupID: gid)
                    }
                    guard auth.featureJWT != nil, auth.userID == initiatingUserID else { return }
                    // Pull any workouts recorded while we were backgrounded.
                    await health.sync()
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
