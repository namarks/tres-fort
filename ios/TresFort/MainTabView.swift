import SwiftUI
import Combine

/// One installed owner per account/feature identity. SwiftUI may recreate a
/// MainTabView value without installing new state; defer model construction
/// inside StateObject so those discarded values cannot subscribe to account
/// mutations, reserve sync tickets, or start connectivity monitors.
@MainActor
private final class MainTabModels: ObservableObject {
    let sync: SyncModel
    let group: GroupModel
    let health: HealthKitSyncModel
    let runs: RunRecorderModel
    let connectivity: SetConnectivityMonitor
    let stationLink = StationLinkController()
    let agenda: TrainingAgendaPublisher
    private var syncObservation: AnyCancellable?

    init(auth: AuthModel, defaults: LocalPersistence, now: @escaping () -> Date,
         weightReader: (any BodyWeightReading)?) {
        let sync = SyncModel(
            auth: auth, defaults: defaults, now: now,
            automaticWorkoutWriteRetryEnabled: true)
        let groupModel = GroupModel(auth: auth, defaults: defaults)
        let health = HealthKitSyncModel(auth: auth, defaults: defaults, weightReader: weightReader, now: now)
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
        // Recorded runs upload to intervals.icu with this account's bearer;
        // the server refreshes its activity cache, so the calendar refreshes.
        let runs = RunRecorderModel(
            accountID: accountID,
            jwt: { [weak auth] in
                guard let auth, auth.userID == accountID else { return nil }
                return auth.featureJWT
            },
            onUnauthorized: { [weak auth] in
                guard let auth, auth.userID == accountID else { return }
                auth.requireReauthentication()
            },
            onUploaded: { [weak auth] in auth?.noteActivityPersisted(for: accountID) },
            now: now)
        setConnectivity.onSatisfiedTransition = { [weak sync] in
            Task { await sync?.recoverWorkoutWrites() }
        }
        self.sync = sync
        self.group = groupModel
        self.health = health
        self.runs = runs
        self.connectivity = setConnectivity
        // Today widget and opt-in workout reminders follow this account's
        // published projection and are cleared at its feature boundary.
        self.agenda = TrainingAgendaPublisher(sync: sync, auth: auth, now: now)
        // A linked iPad's controls reach this account's runner only.
        stationLink.onCommand = { [weak sync] command in
            guard let sync else { return .refused(command, StationLinkCommandReceipt.openWorkout) }
            return await StationLinkCommandRunner.apply(command, to: sync)
        }
        // The tab shell reads runner lifecycle state as well as owning its
        // models. Forward changes so first-start, minimize and completion
        // update its chrome immediately, without an unrelated tab interaction.
        syncObservation = sync.objectWillChange.sink { [weak self] _ in
            self?.objectWillChange.send()
        }
    }
}

struct MainTabView: View {
    @ObservedObject var auth: AuthModel
    @StateObject private var models: MainTabModels
    @Environment(\.scenePhase) private var scenePhase

    @State private var showHealthSettings = false
    @State private var showActivitySheet = false
    @State private var showRunRecorder = false
    @State private var selectedTab: Tab = .today
    @State private var isWorkoutFocused = true
    @State private var partnerOpen = false
    @AppStorage(StationLink.enabledAccountDefaultsKey) private var stationLinkEnabledAccount = ""

    private var sync: SyncModel { models.sync }
    private var groupModel: GroupModel { models.group }
    private var health: HealthKitSyncModel { models.health }

    enum Tab { case today, progress, group, profile }

    init(auth: AuthModel, defaults: LocalPersistence = .standard, now: @escaping () -> Date = Date.init,
         weightReader: (any BodyWeightReading)? = nil) {
        self.auth = auth
        _models = StateObject(wrappedValue: MainTabModels(auth: auth, defaults: defaults, now: now, weightReader: weightReader))
    }

    var body: some View {
        TabView(selection: $selectedTab) {
            TodayView(sync: sync,
                      auth: auth,
                      stationLink: models.stationLink,
                      onLogActivity: { showActivitySheet = true },
                      onRecordRun: RunRecorderModel.isSupported ? {
                          models.runs.plannedRun = nil
                          showRunRecorder = true
                      } : nil,
                      onStartRun: RunRecorderModel.isSupported ? { run in
                          // A run already recording keeps the plan it started with.
                          if !models.runs.isRecording { models.runs.plannedRun = run }
                          showRunRecorder = true
                      } : nil,
                      isWorkoutFocused: isWorkoutFocused,
                      onMinimizeWorkout: { isWorkoutFocused = false },
                      onResumeWorkout: resumeWorkout,
                      onPartnerOpenChange: { partnerOpen = $0 })
                .tabItem {
                    Label("Today", systemImage: "figure.strengthtraining.traditional")
                }
                .tag(Tab.today)
            TrainingProgressView(sync: sync, weight: health.weight,
                                 onHealthSettings: { showHealthSettings = true })
                .tabItem { Label("Progress", systemImage: "chart.xyaxis.line") }
                .tag(Tab.progress)
            Group {
                if auth.isReviewAccount {
                    ContentUnavailableView("Personal sign-in required", systemImage: "person.2.fill",
                        description: Text("This shared sample account cannot join real groups. Sign out in Profile > Account, then use Sign in with Apple to review group features."))
                } else {
                    GroupTabView(groupModel: groupModel, auth: auth)
                }
            }
                .tabItem { Label("Group", systemImage: "person.2.fill") }
                .tag(Tab.group)
            ProfileView(groupModel: groupModel, auth: auth, health: health, sync: sync,
                        runs: models.runs)
                .tabItem { Label("Profile", systemImage: "person.crop.circle") }
                .tag(Tab.profile)
        }
        .tint(Theme.accent)
        .safeAreaInset(edge: .bottom, spacing: 0) {
            if sync.running && !isWorkoutFocused && selectedTab != .today {
                Button(action: resumeWorkout) {
                    HStack(spacing: 12) {
                        Image(systemName: "figure.strengthtraining.traditional")
                        Text(sync.finished ? "Review workout" : "Resume workout").font(.headline)
                        Spacer()
                        Image(systemName: "arrow.up.right")
                    }
                    .padding(.horizontal, 20)
                    .frame(minHeight: 52)
                    .foregroundStyle(Theme.accent)
                    .background(Theme.surface)
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("workout.resume")
            }
        }
        .onChange(of: sync.running) { _, running in
            if running { isWorkoutFocused = true }
        }
        // A linked iPad follows and controls the workout whichever tab or
        // screen the iPhone shows; it pauses only when the iPhone app leaves
        // the foreground, which also closes the local connection.
        .background {
            StationWorkoutDisplayPublisher(sync: sync, link: models.stationLink,
                enabled: StationLink.phoneAccount(storedAccount: stationLinkEnabledAccount, auth: auth) != nil
                    && sync.running && !partnerOpen,
                paused: scenePhase == .background)
        }
        // While a linked iPad shows the workout, keep this iPhone awake so the
        // connection survives a quiet set or rest.
        .onChange(of: sync.running && scenePhase == .active, initial: true) { _, active in
            models.stationLink.setWorkoutActive(active)
        }
        .onDisappear { models.stationLink.setWorkoutActive(false) }
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
            // Reattach a run whose workout survived the app stopping, or
            // finish and upload one that didn't.
            if await models.runs.recover() { showRunRecorder = true }
        }
        .onChange(of: scenePhase) { _, new in
            // Group data may have changed while backgrounded. Keep showing the
            // cached groups through the authentication waits, then revalidate
            // the whole roster in place and drain queued private writes.
            if new == .active {
                // Whichever tab is showing, so the iPad link recovers too.
                models.stationLink.appBecameActive()
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
                    await groupModel.reloadGroupState(revalidate: true)
                    guard auth.featureJWT != nil, auth.userID == initiatingUserID else { return }
                    // Pull any workouts recorded while we were backgrounded.
                    await health.sync()
                    guard auth.featureJWT != nil, auth.userID == initiatingUserID else { return }
                    await models.runs.uploadPending()
                }
            }
        }
        .sheet(isPresented: $showHealthSettings) {
            NavigationStack {
                AppleHealthSettingsView(health: health, groupModel: groupModel)
                    .toolbar {
                        ToolbarItem(placement: .confirmationAction) {
                            Button("Done") { showHealthSettings = false }
                        }
                    }
            }
            .preferredColorScheme(.dark)
        }
        .sheet(isPresented: $showActivitySheet) {
            // Shared sheet — the Today tab toolbar dispatches the same
            // GroupModel-backed handler the Group tab's FAB does. Logging
            // from Today drops into the user's currently-selected group's
            // feed; if they have no group yet, the optimistic insert
            // silently no-ops on the visible feed (groupModel.selected ==
            // nil) but the POST still hits the server.
            LogActivitySheet(groupModel: groupModel)
        }
        .fullScreenCover(isPresented: $showRunRecorder) {
            RunRecorderView(model: models.runs) { showRunRecorder = false }
        }
        // The Today widget and workout reminders open Today; navigation only.
        .onReceive(NotificationCenter.default.publisher(for: TrainingAgendaLink.openToday)) { _ in
            resumeWorkout()
        }
        .modifier(MemberEntryPresentation(auth: auth, sync: sync, groupModel: groupModel,
                                          stationLink: models.stationLink,
                                          onJoined: { selectedTab = .group },
                                          onCoach: { selectedTab = .profile },
                                          onWorkout: resumeWorkout))
    }

    private func resumeWorkout() {
        isWorkoutFocused = true
        selectedTab = .today
    }
}
