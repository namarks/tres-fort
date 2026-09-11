import SwiftUI

/// One installed owner per account/feature identity. SwiftUI may recreate a
/// MainTabView value without installing new state; defer model construction
/// inside StateObject so those discarded values cannot subscribe to account
/// mutations, reserve sync tickets, or start connectivity monitors.
@MainActor
private final class MainTabModels: ObservableObject {
    let sync: SyncModel
    let group: GroupModel
    let health: HealthKitSyncModel
    let connectivity: SetConnectivityMonitor

    init(auth: AuthModel, defaults: LocalPersistence, now: @escaping () -> Date) {
        let sync = SyncModel(
            auth: auth, defaults: defaults, now: now,
            automaticWorkoutWriteRetryEnabled: true)
        let groupModel = GroupModel(auth: auth, defaults: defaults)
        let health = HealthKitSyncModel(auth: auth, defaults: defaults)
        let setConnectivity = SetConnectivityMonitor()
        // Bridge activity writes through AuthModel's account-scoped generation,
        // rather than directly to this SyncModel. An older GroupModel can finish
        // a POST after same-user reauthentication replaces MainTabView; the new
        // SyncModel observes the shared signal while the retired one rejects it
        // through its feature-session epoch.
        let accountID = auth.userID
        groupModel.onActivityPersisted = {
            [weak auth] in auth?.noteActivityPersisted(for: accountID)
        }
        // HealthKit pushes land in external_activities (source='healthkit'),
        // which ride /api/state — so a completed sync must refresh the personal
        // calendar/agenda just like a manual activity does.
        health.onActivitiesPersisted = {
            [weak auth] in auth?.noteActivityPersisted(for: accountID)
        }
        setConnectivity.onSatisfiedTransition = { [weak sync] in
            Task { await sync?.recoverWorkoutWrites() }
        }
        self.sync = sync
        self.group = groupModel
        self.health = health
        self.connectivity = setConnectivity
    }
}

struct MainTabView: View {
    @ObservedObject var auth: AuthModel
    @StateObject private var models: MainTabModels
    @Environment(\.scenePhase) private var scenePhase

    @State private var showActivitySheet = false
    @State private var selectedTab: Tab = .today

    private var sync: SyncModel { models.sync }
    private var groupModel: GroupModel { models.group }
    private var health: HealthKitSyncModel { models.health }

    enum Tab { case today, history, group, profile }

    init(auth: AuthModel, defaults: LocalPersistence = .standard, now: @escaping () -> Date = Date.init) {
        self.auth = auth
        _models = StateObject(wrappedValue: MainTabModels(auth: auth, defaults: defaults, now: now))
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
                .tabItem { Label("Calendar", systemImage: "calendar") }
                .tag(Tab.history)
            GroupTabView(groupModel: groupModel, auth: auth)
                .tabItem { Label("Group", systemImage: "person.2.fill") }
                .tag(Tab.group)
            ProfileView(groupModel: groupModel, auth: auth, health: health, sync: sync)
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
            // A block or restriction may have changed while backgrounded.
            // Drop every shared projection before authentication/network waits,
            // then reload the whole roster and drain queued private writes.
            if new == .active {
                groupModel.invalidateSharedGroups()
                Task {
                    guard let initiatingUserID = auth.userID else { return }
                    await auth.checkAppleCredentialState()
                    guard auth.featureJWT != nil, auth.userID == initiatingUserID else { return }
                    await auth.renewSessionIfNeeded()
                    guard auth.featureJWT != nil, auth.userID == initiatingUserID else { return }
                    await sync.finishTimedSetIfDue()
                    guard auth.featureJWT != nil, auth.userID == initiatingUserID else { return }
                    await sync.recoverWorkoutWrites()
                    guard auth.featureJWT != nil, auth.userID == initiatingUserID else { return }
                    await groupModel.reloadGroupState()
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
        .modifier(MemberEntryPresentation(auth: auth, sync: sync, groupModel: groupModel,
                                          onJoined: { selectedTab = .group },
                                          onCoach: { selectedTab = .profile }))
    }
}
