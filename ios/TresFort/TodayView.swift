import SwiftUI

private func clock(_ s: Int) -> String {
    s <= 0 ? "GO" : String(format: "%d:%02d", s / 60, s % 60)
}

private struct PendingSetBanner: View {
    @ObservedObject var sync: SyncModel
    @State private var showAbandonConfirm = false
    @State private var abandonTarget: WorkoutTerminalActionTarget?

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: sync.failedSetIntentCount > 0
                ? "exclamationmark.triangle.fill"
                : "arrow.triangle.2.circlepath")
                .font(.system(size: 12, weight: .bold))
                .foregroundStyle(sync.failedSetIntentCount > 0
                    ? Theme.danger : Theme.accent)
            VStack(alignment: .leading, spacing: 2) {
                Text("\(sync.pendingSetIntentCount) SET\(sync.pendingSetIntentCount == 1 ? "" : "S") WAITING TO SYNC")
                    .font(Theme.mono(10, .bold)).tracking(1)
                    .foregroundStyle(Theme.text)
                Text(sync.failedSetIntentCount > 0
                    ? "\(sync.failedSetIntentCount) failed — retry when ready"
                    : (sync.sendingSetIntentCount > 0 ? "Sending…" : "Saved on this device"))
                    .font(Theme.mono(10)).foregroundStyle(Theme.muted)
            }
            Spacer()
            if sync.failedSetIntentCount > 0 {
                HStack(spacing: 10) {
                    Button("RETRY") {
                        Task { await sync.retryFailedSetIntents() }
                    }
                    .foregroundStyle(Theme.accent)
                    if sync.canAbandonRecoveredWorkout {
                        Button("DISCARD") {
                            abandonTarget = sync.terminalActionTarget
                            showAbandonConfirm = abandonTarget != nil
                        }
                            .foregroundStyle(Theme.danger)
                    }
                }
                .font(Theme.mono(10, .bold))
            } else if sync.queuedSetIntentCount > 0,
                      sync.sendingSetIntentCount == 0 {
                Button("RETRY") {
                    Task { await sync.drainWorkoutWriteOutboxes() }
                }
                .font(Theme.mono(10, .bold))
                .foregroundStyle(Theme.accent)
            }
        }
        .padding(.horizontal, 14).padding(.vertical, 10)
        .background(Theme.surface)
        .overlay(alignment: .bottom) { Divider().overlay(Theme.surface2) }
        .confirmationDialog(
            "Discard this recovered workout?",
            isPresented: $showAbandonConfirm,
            titleVisibility: .visible
        ) {
            Button("Discard workout", role: .destructive) {
                guard let target = abandonTarget else { return }
                Task { await sync.discardWorkout(expected: target) }
            }
            Button("Keep workout", role: .cancel) {}
        } message: {
            Text("The failed saved sets will be removed and the server session will be discarded so you can start again.")
        }
    }
}

/// Normal online delivery takes a moment but does not need to move the whole
/// runner down and announce itself. Keep the durable queue truthful, while
/// surfacing its banner only when it outlives a short online grace period (or
/// immediately when the server rejects a set and the user can act on it).
private struct PendingSetBannerGate: View {
    @ObservedObject var sync: SyncModel
    @State private var graceElapsed = false

    var body: some View {
        Group {
            if sync.pendingSetIntentCount > 0,
               sync.failedSetIntentCount > 0 || graceElapsed {
                PendingSetBanner(sync: sync)
            }
        }
        .task(id: sync.pendingSetIntentCount > 0) {
            guard sync.pendingSetIntentCount > 0 else {
                graceElapsed = false
                return
            }
            graceElapsed = false
            do {
                try await Task.sleep(nanoseconds: 3_000_000_000)
            } catch {
                return
            }
            guard sync.pendingSetIntentCount > 0 else { return }
            graceElapsed = true
        }
    }
}

struct CachedStateBanner: View {
    var canTrainOffline = false
    var body: some View {
        HStack(spacing: 9) {
            Image(systemName: "wifi.slash")
                .font(.system(size: 12, weight: .bold))
                .foregroundStyle(Theme.muted)
            Text(canTrainOffline ? "OFFLINE · SAVING WORK ON THIS IPHONE" : "OFFLINE · SHOWING LAST SAVED DATA")
                .font(Theme.mono(10, .bold)).tracking(1)
                .foregroundStyle(Theme.muted)
            Spacer()
        }
        .padding(.horizontal, 14).padding(.vertical, 9)
        .background(Theme.surface)
        .overlay(alignment: .bottom) { Divider().overlay(Theme.surface2) }
    }
}

private struct PendingTerminalBanner: View {
    @ObservedObject var sync: SyncModel
    @State private var reviewingFeedback: WorkoutTerminalIntent?

    var body: some View {
        if let intent = sync.visibleTerminalIntent {
            if intent.feedbackConflict != nil {
                HStack(spacing: 12) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Feedback changed elsewhere").font(.headline)
                        Text("Your version is saved on this device.").font(.caption)
                    }
                    Spacer()
                    Button("Review feedback") { reviewingFeedback = intent }
                        .frame(minHeight: 44)
                }
                .padding(14).background(Theme.surface).foregroundStyle(Theme.text)
                .sheet(item: $reviewingFeedback) { item in
                    WorkoutFeedbackConflictSheet(sync: sync, intent: item)
                }
            } else {
            HStack(spacing: 10) {
                Image(systemName: intent.deliveryState == .failed
                    ? "exclamationmark.triangle.fill"
                    : "arrow.triangle.2.circlepath")
                    .font(.system(size: 12, weight: .bold))
                    .foregroundStyle(intent.deliveryState == .failed
                        ? Theme.danger : Theme.accent)
                VStack(alignment: .leading, spacing: 2) {
                    Text(intent.action == .finish
                        ? "WORKOUT FINISH WAITING TO SYNC"
                        : "WORKOUT DISCARDED — WAITING TO SYNC")
                        .font(Theme.mono(10, .bold)).tracking(1)
                        .foregroundStyle(Theme.text)
                    Text(intent.deliveryState == .failed
                        ? "Server rejected it — retry when ready"
                        : (sync.sendingTerminalIntentCount > 0
                            ? "Sending…" : "Saved on this device"))
                        .font(Theme.mono(10)).foregroundStyle(Theme.muted)
                }
                Spacer()
                if intent.deliveryState == .failed {
                    Button("RETRY") {
                        Task { await sync.retryTerminalIntent(id: intent.id) }
                    }
                    .font(Theme.mono(10, .bold))
                    .foregroundStyle(Theme.accent)
                }
            }
            .padding(.horizontal, 14).padding(.vertical, 10)
            .background(Theme.surface)
            .overlay(alignment: .bottom) { Divider().overlay(Theme.surface2) }
            }
        }
    }
}

struct TodayView: View {
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @State private var feedbackPresentation: WorkoutFeedbackPresentation?
    @ObservedObject var sync: SyncModel
    @ObservedObject var auth: AuthModel
    /// Opens the shared ManualActivitySheet hosted by MainTabView so a user
    /// can log "I just did Pilates" without tab-switching. Optional so
    /// existing tests / previews can construct the view without the new
    /// dependency.
    var onLogActivity: (() -> Void)? = nil
    var isWorkoutFocused = true
    var onMinimizeWorkout: (() -> Void)? = nil
    var onResumeWorkout: (() -> Void)? = nil
    @State private var isLocallyMinimized = false
    private var workoutFocused: Bool { sync.running && !sync.finished && isWorkoutFocused && !isLocallyMinimized }

    /// Opens the saved workout library from the explicit Today action.
    @State private var showOverridePicker = false
    @State private var showTodayPicker: IdentifiedString?
    /// Confirms discarding the in-progress workout (destructive, undo-less).
    @State private var showDiscardConfirm = false
    @State private var discardTarget: WorkoutTerminalActionTarget?
    /// Compact controls are the default. Expanding the clock is a presentation
    /// choice only; the model retains the rest deadline while navigating.
    @State private var restExpanded = false
    /// Direct creation of a named saved workout.
    @State private var showRoutine = false
    @State private var showTrainingSetup = false
    @State private var trainingSetupAccountID: String?
    @State private var trainingSetupEpoch: UInt64 = 0
    @State private var starterWorkoutToOpen: String?
    @State private var starterAvailable: Bool?
    @State private var starterAvailabilityFailed = false
    /// The day whose workout the editor sheet is editing.
    @State private var previewTarget: IdentifiedString?
    @State private var unresolvedDate: IdentifiedString?
    /// Keeps a double tap from starting twice while iOS is presenting the
    /// one-time notification permission prompt before a new workout.
    @State private var isPreparingWorkoutStart = false
    @State private var showFreestyle = false
    @State private var showStation = false
    /// iPhone end of the iPad Station link; it browses only while a workout
    /// runs with the setting on, so the local network prompt is opt-in.
    @StateObject private var stationLink = StationLinkController()
    @AppStorage(StationLink.enabledDefaultsKey) private var stationLinkEnabled = false
    private var stationLinkAccount: String? {
        guard stationLinkEnabled, sync.running, !sync.finished,
              UIDevice.current.userInterfaceIdiom == .phone else { return nil }
        return auth.userID
    }

    var body: some View {
        let fullRestOverlayVisible = sync.restEndDate != nil && restExpanded && (workoutFocused || sync.finished)
        NavigationStack {
            ZStack(alignment: .top) {
                Theme.background
                VStack(spacing: 0) {
                    if sync.isUsingCachedState {
                        CachedStateBanner(canTrainOffline: sync.canUseOfflineWorkoutState)
                    }
                    if sync.pendingTerminalIntentCount > 0 {
                        PendingTerminalBanner(sync: sync)
                    }
                    PendingSetBannerGate(sync: sync)
                    if !sync.setCorrections.isEmpty {
                        PendingCorrectionsView(sync: sync)
                    }
                    if starterWorkoutToOpen != nil && !showTrainingSetup {
                        Button("View saved workout", action: openSavedStarter)
                            .frame(minHeight: 44)
                            .accessibilityIdentifier("today.openSavedStarter")
                    }
                    content
                    if sync.canStartFreestyle {
                        Button { showFreestyle = true } label: {
                            Label(sync.isFreestyle ? "Continue freestyle" : "Start freestyle", systemImage: "figure.strengthtraining.traditional")
                                .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
                        }.padding(.horizontal, 20).accessibilityIdentifier("today.startFreestyle")
                    }
                    if let onLogActivity, !sync.running, !sync.finished {
                        Button(action: onLogActivity) {
                            Label("Log an activity", systemImage: "figure.walk")
                                .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
                        }
                        .accessibilityIdentifier("today.logActivity")
                        .padding(.horizontal, 20).padding(.bottom, 8)
                    }
                }
                // The full rest screen is modal. Without explicitly removing
                // the runner from hit testing and the accessibility tree,
                // assistive actions can start/log a hidden set underneath it.
                .disabled(fullRestOverlayVisible)
                .accessibilityHidden(fullRestOverlayVisible)
                if fullRestOverlayVisible {
                    RestOverlay(sync: sync) { restExpanded = false }
                }
            }
            .navigationTitle(sync.running ? "Workout" : "Today")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                if UIDevice.current.userInterfaceIdiom == .pad {
                    ToolbarItem(placement: .topBarLeading) {
                        Button { showStation = true } label: {
                            Label("Station Mode", systemImage: "figure.strengthtraining.traditional")
                        }
                        .accessibilityIdentifier("today.station")
                    }
                }
                if sync.running {
                    if workoutFocused {
                        ToolbarItem(placement: .topBarLeading) {
                            Button("Minimize", systemImage: "chevron.down") {
                                restExpanded = false
                                if let onMinimizeWorkout { onMinimizeWorkout() }
                                else { isLocallyMinimized = true }
                            }
                            .accessibilityIdentifier("runner.minimize")
                        }
                    }
                    ToolbarItem(placement: .topBarTrailing) {
                        Menu {
                            if !sync.finished {
                                Button("Finish workout", systemImage: "checkmark.circle") {
                                    guard let target = sync.terminalActionTarget else { return }
                                    feedbackPresentation = WorkoutFeedbackPresentation(target: target)
                                }
                                .disabled(sync.hasPendingTerminalIntentForCurrentWorkout)
                            }
                            Button("Discard workout", systemImage: "trash", role: .destructive) {
                                discardTarget = sync.terminalActionTarget
                                showDiscardConfirm = discardTarget != nil
                            }
                            .disabled(sync.hasDiscardIntentForCurrentWorkout)
                            .accessibilityIdentifier("today.discardWorkout")
                        } label: {
                            Image(systemName: "ellipsis.circle")
                        }
                        .accessibilityLabel("Workout actions")
                        .accessibilityIdentifier("today.workoutActions")
                    }
                }
            }
            // The expanded rest screen is modal across the whole app chrome,
            // not just the scroll content. Hiding both bars removes Log
            // Activity, destructive menu actions, and tab switches from taps
            // and the VoiceOver tree until rest is minimized or dismissed.
            .toolbar(
                fullRestOverlayVisible ? .hidden : .visible,
                for: .navigationBar)
            .toolbar(
                workoutFocused || fullRestOverlayVisible ? .hidden : .visible,
                for: .tabBar)
            .toolbarColorScheme(.dark, for: .navigationBar)
            .alert(
                "Discard this workout?",
                isPresented: $showDiscardConfirm
            ) {
                Button("Discard — don't save", role: .destructive) {
                    guard let target = discardTarget else { return }
                    Task { await sync.discardWorkout(expected: target) }
                }
                Button("Keep workout", role: .cancel) {}
            } message: {
                Text("The sets you logged will be deleted and this session won't count. The day goes back to its normal schedule. This can't be undone.")
            }
            .sheet(item: $feedbackPresentation) { item in
                WorkoutFeedbackSheet(sync: sync, target: item.target, finishAfterSave: true)
            }
            .fullScreenCover(isPresented: $showStation) {
                let accountID = auth.userID
                let epoch = auth.featureSessionEpoch
                StationEntryView(workoutName: sync.selectedDay?.name, accountID: accountID, epoch: epoch,
                    isCurrentSession: { [weak stationAuth = auth] in
                        stationAuth?.isCurrentFeatureSession(accountID: accountID, epoch: epoch) == true
                    }, observeBoundary: { [weak stationAuth = auth] observer in
                        _ = stationAuth?.observeFeatureSessionBoundary(observer)
                    })
                    .environment(\.dynamicTypeSize, dynamicTypeSize)
            }
            .sheet(item: $previewTarget) { target in
                WorkoutDetailsView(sync: sync, workoutID: target.id,
                                   date: sync.todayString, onStart: startChosenWorkout)
            }
            .sheet(item: $unresolvedDate) { target in
                NavigationStack {
                    DayAgendaView(sync: sync, dateString: target.id)
                        .navigationTitle("Workout record")
                        .navigationBarTitleDisplayMode(.inline)
                        .toolbar { ToolbarItem(placement: .cancellationAction) {
                            Button("Done") { unresolvedDate = nil }
                        } }
                }
            }
            .sheet(isPresented: $showOverridePicker) {
                WorkoutsView(sync: sync, onStart: sync.todayIsCompleted ? nil : startChosenWorkout)
            }
            .sheet(item: $showTodayPicker) { target in
                WorkoutDatePickerView(sync: sync, date: target.id)
            }
            .sheet(isPresented: $showFreestyle) { FreestyleExercisePicker(sync: sync, starting: true) }
            .sheet(isPresented: $showRoutine) {
                CreateWorkoutView(sync: sync, onStart: sync.todayIsCompleted ? nil : startChosenWorkout)
            }
            .sheet(isPresented: $showTrainingSetup, onDismiss: openSavedStarter) {
                TrainingSetupView(auth: auth, onStarterSaved: { receipt in
                    guard receipt.acknowledged,
                          auth.isCurrentFeatureSession(accountID: trainingSetupAccountID, epoch: trainingSetupEpoch) else { return }
                    starterWorkoutToOpen = receipt.workout_id
                    showTrainingSetup = false
                }) {
                    showTrainingSetup = false
                }
            }
        }
        .preferredColorScheme(.dark)
        .task(id: sync.canChooseStarterWorkout) { await loadStarterAvailability() }
        .task(id: stationLinkAccount) {
            if let account = stationLinkAccount { stationLink.start(accountID: account) } else { stationLink.stop() }
        }
        .onChange(of: sync.restEndDate) { if sync.restEndDate == nil { restExpanded = false } }
        .onChange(of: sync.running) { if !sync.running { isLocallyMinimized = false } }
    }

    /// Queue only after the setup sheet has dismissed. The member-entry route
    /// refreshes the acknowledged workout before exposing its Start action.
    private func openSavedStarter() {
        guard let workoutID = starterWorkoutToOpen else { return }
        guard auth.isCurrentFeatureSession(accountID: trainingSetupAccountID, epoch: trainingSetupEpoch) else {
            starterWorkoutToOpen = nil
            return
        }
        if auth.requestEntry(.workout(workoutID)) { starterWorkoutToOpen = nil }
    }

    /// A verified empty library alone cannot prove this account has an unused
    /// starter. Check the server's durable receipt before advertising one.
    @MainActor private func loadStarterAvailability() async {
        starterAvailable = nil; starterAvailabilityFailed = false
        guard sync.canChooseStarterWorkout, !auth.isReviewAccount, let jwt = auth.featureJWT else { return }
        let accountID = auth.userID, epoch = auth.featureSessionEpoch
        do {
            let options = try await APIClient().starterWorkouts(jwt: jwt)
            guard !Task.isCancelled, auth.isCurrentFeatureSession(accountID: accountID, epoch: epoch),
                  sync.canChooseStarterWorkout else { return }
            starterAvailable = options.can_accept
        } catch {
            guard !Task.isCancelled, auth.isCurrentFeatureSession(accountID: accountID, epoch: epoch),
                  sync.canChooseStarterWorkout else { return }
            starterAvailabilityFailed = true
        }
    }

    private var scrollableRestExpansion: (() -> Void)? {
        guard sync.restEndDate != nil else { return nil }
        return { restExpanded = true }
    }

    @ViewBuilder private var content: some View {
        if sync.finished {
            FinishedView(sync: sync, onExpandRest: scrollableRestExpansion)
        } else if sync.running && !workoutFocused {
            VStack(alignment: .leading, spacing: 16) {
                Text("Workout in progress").font(.title2.weight(.semibold))
                if let ex = sync.currentExercise {
                    Text(ex.exercise_name).font(.headline)
                    Text("Set \(sync.currentPhysicalSetNumber)").font(.subheadline).foregroundStyle(Theme.muted)
                }
                Button {
                    isLocallyMinimized = false
                    onResumeWorkout?()
                } label: {
                    Label("Resume workout", systemImage: "play.fill")
                        .frame(maxWidth: .infinity, minHeight: 52)
                        .background(Theme.accent).foregroundStyle(.black)
                        .clipShape(RoundedRectangle(cornerRadius: 12))
                }
                .accessibilityIdentifier("runner.resume")
            }
            .padding(20).background(Theme.surface)
            .clipShape(RoundedRectangle(cornerRadius: 16)).padding(20)
            Spacer()
        } else if sync.running {
            RunnerView(sync: sync, auth: auth, stationLink: stationLink, onExpandRest: { restExpanded = true })
        } else if sync.plan == nil && !sync.canCreateRoutine {
            PlanLoadRecoveryView(sync: sync)
        } else if sync.canChooseStarterWorkout && !sync.todayIsCompleted {
            VStack(spacing: 14) {
                Text(starterAvailable == false ? "YOUR NEXT WORKOUT" : "YOUR FIRST WORKOUT")
                    .font(Theme.display(28)).foregroundStyle(Theme.text)
                if starterAvailable == true {
                    Button("Find a starting workout") {
                        trainingSetupAccountID = auth.userID
                        trainingSetupEpoch = auth.featureSessionEpoch
                        showTrainingSetup = true
                    }
                        .buttonStyle(WorkoutPrimaryButtonStyle())
                        .accessibilityIdentifier("today.starterWorkout")
                } else if starterAvailabilityFailed {
                    Button("Try loading starting workouts again") { Task { await loadStarterAvailability() } }
                        .frame(minHeight: 44)
                }
                Text("Build and schedule your first workout here, or connect your own AI coach to help with your plan. You can use both paths anytime.")
                    .font(.callout).foregroundStyle(Theme.text)
                    .accessibilityIdentifier("today.empty-guidance")
                    .multilineTextAlignment(.center)
                Button {
                    showRoutine = true
                } label: {
                    Label("Create a workout", systemImage: "plus.circle.fill")
                        .font(Theme.mono(14, .bold))
                        .foregroundStyle(Theme.bg)
                        .padding(.horizontal, 18).padding(.vertical, 13)
                        .background(Theme.accent)
                        .clipShape(RoundedRectangle(cornerRadius: 12))
                }
                .padding(.top, 6)
                .accessibilityIdentifier("today.createWorkout")
                Button("Set up my coach") { auth.requestEntry(.coach) }
                    .frame(minWidth: 44, minHeight: 44)
            }
            .padding(24)
        } else if sync.todayIsCompleted {
            // Today's session is already COMPLETED. Show a done/recap
            // state with NO start and NO override: one session per
            // (user,date) means any "start" re-opens & double-logs the
            // completed row (server getOrCreateSession is idempotent on
            // (user,date)), so we never offer an action the data model
            // can't safely honor.
            VStack(spacing: 0) {
                WorkoutDoneView(sync: sync)
                Button { showOverridePicker = true } label: {
                    todayRoute("Workouts", subtitle: "Your saved workouts")
                }
                .accessibilityIdentifier("today.chooseWorkout")
            }
            .padding(.horizontal, 20)
        } else {
            ScrollView {
                VStack(alignment: .leading, spacing: 22) {
                    Text(sync.todayString).font(Theme.mono(12)).foregroundStyle(Theme.muted)
                    if sync.isFreestyle {
                        Text("Freestyle").font(Theme.display(30)).foregroundStyle(Theme.text)
                        Text("Add exercises as you go. Your weekly schedule stays unchanged.").foregroundStyle(Theme.muted)
                        if sync.hasResumableWorkout {
                            Button("Continue freestyle") { sync.resumeWorkout() }
                                .buttonStyle(WorkoutPrimaryButtonStyle()).accessibilityIdentifier("today.resumeFreestyle")
                        }
                    } else if let workout = sync.todayPreviewWorkout {
                        VStack(alignment: .leading, spacing: 14) {
                            Text(sync.hasResumableWorkout ? "In progress" : "Scheduled for today")
                                .font(Theme.mono(12)).foregroundStyle(Theme.muted)
                            Text(workout.name).font(Theme.display(30)).foregroundStyle(Theme.text)
                            Text("\(workout.exercises.count) \(workout.exercises.count == 1 ? "exercise" : "exercises")")
                                .font(.subheadline).foregroundStyle(Theme.muted)
                            let actionsLayout = dynamicTypeSize.isAccessibilitySize
                                ? AnyLayout(VStackLayout(alignment: .leading, spacing: 4))
                                : AnyLayout(HStackLayout())
                            actionsLayout {
                                Button("View workout", systemImage: "chevron.right") { previewTarget = IdentifiedString(id: workout.id) }
                                    .fixedSize(horizontal: false, vertical: true)
                                    .frame(minHeight: 44).accessibilityIdentifier("today.viewWorkout")
                                if !dynamicTypeSize.isAccessibilitySize { Spacer() }
                                if !sync.hasResumableWorkout && !sync.blocksNewWorkoutStart {
                                    Button("Change today") { showTodayPicker = IdentifiedString(id: sync.todayString) }
                                        .fixedSize(horizontal: false, vertical: true)
                                        .frame(minHeight: 44).accessibilityIdentifier("today.changeWorkout")
                                }
                            }
                            Button(isPreparingWorkoutStart ? "Preparing…" : sync.hasResumableWorkout ? "Continue workout" : "Start workout") {
                                prepareNewWorkout {
                                    if sync.hasResumableWorkout { sync.resumeWorkout() }
                                    else { sync.startToday() }
                                }
                            }
                            .buttonStyle(WorkoutPrimaryButtonStyle())
                            .accessibilityIdentifier("today.startWorkout")
                            .disabled(workout.exercises.isEmpty || isPreparingWorkoutStart
                                || (sync.blocksNewWorkoutStart && !sync.hasResumableWorkout))
                        }
                        .padding(20).background(Theme.surface)
                        .clipShape(RoundedRectangle(cornerRadius: 16))
                    } else if let session = sync.todaySession,
                              ["planned", "in_progress"].contains(session.status) {
                        Text("Workout needs review").font(Theme.display(30)).foregroundStyle(Theme.text)
                        Text("There is a workout for today, but its saved workout details are unavailable. Your recorded sets are still available.")
                            .foregroundStyle(Theme.muted)
                        Button("View workout record") { unresolvedDate = IdentifiedString(id: session.date) }
                            .frame(minHeight: 44).accessibilityIdentifier("today.viewUnresolvedWorkout")
                        Button("Refresh workout") { Task { await sync.load() } }.frame(minHeight: 44)
                    } else {
                        Text("Nothing scheduled").font(Theme.display(30)).foregroundStyle(Theme.text)
                        Text("Choose a saved workout or create one for today.")
                            .foregroundStyle(Theme.muted)
                    }
                    Button { showOverridePicker = true } label: {
                        todayRoute("Workouts", subtitle: "Browse, create, and edit")
                    }
                    .accessibilityIdentifier("today.chooseWorkout")
                    if let error = sync.loadError {
                        Text(error).font(.footnote).foregroundStyle(Theme.danger)
                    }
                }
                .padding(20)
            }
            .refreshable { await sync.load() }
        }
    }

    private func todayRoute(_ title: String, subtitle: String) -> some View {
        HStack {
            VStack(alignment: .leading, spacing: 5) {
                Text(title).font(.headline).foregroundStyle(Theme.text)
                Text(subtitle).font(.subheadline).foregroundStyle(Theme.muted)
            }
            Spacer()
            Image(systemName: "chevron.right").foregroundStyle(Theme.muted)
        }
        .frame(minHeight: 56)
    }

    private func startChosenWorkout(_ id: String) {
        showOverridePicker = false
        showRoutine = false
        previewTarget = nil
        prepareNewWorkout {
            if sync.hasResumableWorkout && sync.resumableCheckpoint?.selectedDayID == id { sync.resumeWorkout() }
            else { sync.startOverride(dayID: id) }
        }
    }

    /// Ask at the user's explicit start action, before the runner begins. Rest
    /// scheduling itself must never surprise-interrupt the first logged set.
    private func prepareNewWorkout(_ start: @escaping @MainActor () -> Void) {
        guard !isPreparingWorkoutStart else { return }
        isPreparingWorkoutStart = true
        Task { @MainActor in
            await RestCue.requestNotificationPermissionIfNeeded()
            guard !Task.isCancelled else {
                isPreparingWorkoutStart = false
                return
            }
            start()
            isPreparingWorkoutStart = false
        }
    }
}

private struct NextWorkoutCard: View {
    @ObservedObject var sync: SyncModel
    let next: SyncModel.NextWorkout
    @State private var preview: IdentifiedString?

    var body: some View {
        Button {
            preview = IdentifiedString(id: next.dateString)
        } label: {
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Text("NEXT WORKOUT")
                        .font(Theme.mono(11, .bold)).tracking(2)
                        .foregroundStyle(Theme.muted)
                    Spacer()
                    Image(systemName: "chevron.right")
                        .font(.system(size: 12, weight: .bold))
                        .foregroundStyle(Theme.muted)
                }
                // `next.day` is nil when the resolved template isn't cached
                // — still show the real next date (never skip ahead), just
                // without detail; the tap still opens the live preview.
                Text((next.day?.title ?? "Workout scheduled").uppercased())
                    .font(Theme.display(28))
                    .foregroundStyle(Theme.text)
                    .lineLimit(2).minimumScaleFactor(0.6)
                Text(sync.relativeLabel(for: next.dateString).uppercased())
                    .font(Theme.mono(13, .bold)).tracking(1)
                    .foregroundStyle(Theme.accent)
                if let day = next.day, !day.exercises.isEmpty {
                    Text(day.exercises
                            .map(\.exercise_name)
                            .joined(separator: " · "))
                        .font(Theme.mono(11))
                        .foregroundStyle(Theme.muted)
                        .multilineTextAlignment(.leading)
                        .padding(.top, 2)
                }
            }
            .padding(20)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Theme.surface)
            .clipShape(RoundedRectangle(cornerRadius: 16))
        }
        .buttonStyle(.plain)
        .sheet(item: $preview) { d in
            NavigationStack {
                DayAgendaView(sync: sync, dateString: d.id)
                    .navigationTitle("Workout date")
                    .navigationBarTitleDisplayMode(.inline)
                    .toolbar {
                        ToolbarItem(placement: .cancellationAction) {
                            Button("Done") { preview = nil }
                        }
                    }
            }
            .presentationDetents([.large])
            .presentationDragIndicator(.visible)
        }
    }
}

// MARK: - Workout complete (today's session is done)

/// Shown when today's resolved session is COMPLETED. A clean recap with
/// NO primary START WORKOUT CTA and NO "Train a different day" override —
/// the single session-per-(user,date) invariant means any start would
/// re-open and double-log the completed row. The next workout is surfaced
/// so the screen still tells you what's next (same forward-scan the rest
/// day uses); pull-to-refresh remains so a server change is reflected.
private struct WorkoutDoneView: View {
    @ObservedObject var sync: SyncModel
    /// Confirms discarding the just-completed session ("didn't really do
    /// this" — e.g. an accidental/test End workout).
    @State private var recordDate: IdentifiedString?
    @State private var showDiscardConfirm = false
    @State private var discardTarget: WorkoutTerminalActionTarget?

    private var doneTemplateTitle: String {
        sync.sessionDisplayTemplate(forDateString: sync.todayString, allowScheduleInference: false)?.name ?? "Workout"
    }

    /// Logged WORKING sets for today's completed session — warmups
    /// excluded so the recap numbers match FinishedView (which uses
    /// `is_warmup == 0`) and never disagree seconds apart.
    private var todaySets: [SetLog] {
        guard let sid = sync.sessionsByDate[sync.todayString]?.id else { return [] }
        return sync.setsForSession(sid).filter { $0.is_warmup == 0 }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                let sets = todaySets
                VStack(alignment: .leading, spacing: 10) {
                    Text("TODAY")
                        .font(Theme.mono(11, .bold)).tracking(2)
                        .foregroundStyle(Theme.muted)
                    HStack(spacing: 10) {
                        Image(systemName: "checkmark.seal.fill")
                            .font(.system(size: 26))
                            .foregroundStyle(Theme.done)
                        Text("WORKOUT COMPLETE")
                            .font(Theme.display(34))
                            .foregroundStyle(Theme.text)
                            .lineLimit(2).minimumScaleFactor(0.6)
                    }
                    Text(doneTemplateTitle)
                        .font(Theme.mono(13, .bold)).tracking(1)
                        .foregroundStyle(Theme.accent)
                    let exerciseCount = Set(sets.map(\.exercise_id)).count
                    Text("\(sets.count) working \(sets.count == 1 ? "set" : "sets") · \(exerciseCount) \(exerciseCount == 1 ? "exercise" : "exercises")")
                        .font(.subheadline).foregroundStyle(Theme.muted)
                        .accessibilityIdentifier("today.completedSummary")
                    Button("View workout", systemImage: "chevron.right") {
                        recordDate = IdentifiedString(id: sync.todayString)
                    }
                    .frame(minHeight: 44)
                    .accessibilityIdentifier("today.viewCompletedWorkout")
                }
                .padding(20)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Theme.surface)
                .clipShape(RoundedRectangle(cornerRadius: 16))

                if let next = sync.nextWorkout() {
                    NextWorkoutCard(sync: sync, next: next)
                }

                if let err = sync.loadError {
                    Text(err).font(Theme.mono(12)).foregroundStyle(Theme.danger)
                }


            }
            .padding(16)
        }
        .refreshable { await sync.load() }
        .sheet(item: $recordDate) { date in
            NavigationStack {
                DayAgendaView(sync: sync, dateString: date.id)
                    .navigationTitle("Workout record")
                    .navigationBarTitleDisplayMode(.inline)
                    .toolbar {
                        ToolbarItem(placement: .cancellationAction) {
                            Button("Done") { recordDate = nil }
                        }
                        ToolbarItem(placement: .bottomBar) {
                            Button("Discard workout", role: .destructive) {
                                let target = sync.terminalActionTarget
                                discardTarget = target?.date == date.id ? target : nil
                                showDiscardConfirm = discardTarget != nil
                            }
                            .disabled(sync.hasDiscardIntentForCurrentWorkout)
                        }
                    }
                    .confirmationDialog("Discard this workout?", isPresented: $showDiscardConfirm,
                                        titleVisibility: .visible) {
                        Button("Discard — don't save", role: .destructive) {
                            guard let target = discardTarget else { return }
                            Task { await sync.discardWorkout(expected: target); recordDate = nil }
                        }
                        Button("Keep workout", role: .cancel) {}
                    } message: {
                        Text("The logged sets will be removed and this workout will no longer count.")
                    }
            }
            .preferredColorScheme(.dark)
        }
    }
}

private struct ProgressBar: View {
    let exercises: [TemplateExercise]
    let currentIndex: Int
    let sync: SyncModel

    var body: some View {
        HStack(spacing: 6) {
            ForEach(Array(exercises.enumerated()), id: \.element.id) { i, ex in
                GeometryReader { geo in
                    let ratio = min(1, Double(sync.runnerSetsDone(ex)) / Double(max(1, ex.target_sets)))
                    let complete = sync.runnerSetsDone(ex) >= ex.target_sets
                    ZStack(alignment: .leading) {
                        RoundedRectangle(cornerRadius: 2).fill(Theme.surface2)
                        RoundedRectangle(cornerRadius: 2)
                            .fill(complete ? Theme.done : Theme.accent)
                            .frame(width: geo.size.width * (complete ? 1 : ratio))
                    }
                    .overlay(
                        RoundedRectangle(cornerRadius: 2)
                            .stroke(i == currentIndex ? Theme.accent : .clear, lineWidth: 1))
                }
                .frame(height: 4)
            }
        }
    }
}

// MARK: - Runner

private struct RunnerView: View {
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @ObservedObject var sync: SyncModel
    @ObservedObject var auth: AuthModel
    @ObservedObject var stationLink: StationLinkController
    var onExpandRest: (() -> Void)? = nil

    /// Tap-to-edit on the big weight number → decimal-pad sheet. Persists
    /// the in-flight edit string (`""` while the sheet is open and the user
    /// has cleared the field — TextField needs a Binding, not a transient
    /// value) so a partially-typed entry isn't lost on a re-render.
    @State private var editingWeight = false
    @State private var weightDraft = WeightEntryDraft(weight: 0, storedUnit: .lb, unit: .lb)
    @AppStorage(WeightUnit.preferenceKey) private var weightUnitRaw = "lb"
    private var weightUnit: WeightUnit { WeightUnit(rawValue: weightUnitRaw) ?? .lb }
    /// Exercise information sheet, openable mid-workout — not just from the
    /// pre-start preview (#54).
    @State private var informationFor: TemplateExercise?
    private struct SetValueDraft: Identifiable {
        let id = UUID()
        let input: RunnerInputState
        let exercise: TemplateExercise
    }
    @State private var valueDraft: SetValueDraft?
    @State private var weightPrescription: RunnerPrescription?
    @AppStorage(RestCue.defaultsKey) private var timerCuesEnabled = true
    @AppStorage(StationLink.enabledDefaultsKey) private var stationLinkEnabled = false
    private var showsStationLink: Bool { UIDevice.current.userInterfaceIdiom == .phone }

    @State private var showingOutline = false
    @State private var loadRevealedFor: Set<String> = []

    var body: some View {
        if let ex = sync.currentExercise {
            let blocks = ExerciseGroupBlock.blocks(sync.exercises)
            let group = blocks.first { $0.isGroup && $0.members.contains { $0.id == ex.id } }
            VStack(spacing: 0) {
                ScrollView {
                    VStack(alignment: .leading, spacing: 12) {
                        HStack {
                            Text(sync.isFreestyle ? "Freestyle" : "Exercise \(sync.exerciseIndex + 1) of \(sync.exercises.count)")
                                .font(.subheadline).foregroundStyle(Theme.muted)
                            Spacer()
                            if sync.workoutStart != nil {
                                TimelineView(.periodic(from: .now, by: 1)) { _ in
                                    Text(clock(sync.workoutElapsedSeconds))
                                        .font(.subheadline.monospacedDigit()).foregroundStyle(Theme.muted)
                                        .accessibilityLabel("Workout elapsed")
                                        .accessibilityValue(clock(sync.workoutElapsedSeconds))
                                }
                            }
                        }
                        if !sync.isFreestyle {
                            ProgressBar(exercises: sync.exercises, currentIndex: sync.exerciseIndex, sync: sync)
                        }
                        let titleLayout = dynamicTypeSize.isAccessibilitySize
                            ? AnyLayout(VStackLayout(alignment: .leading, spacing: 4))
                            : AnyLayout(HStackLayout(alignment: .center, spacing: 8))
                        titleLayout {
                            Text(ex.exercise_name.uppercased())
                                .font(Theme.display(32)).foregroundStyle(Theme.text)
                                .fixedSize(horizontal: false, vertical: true)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .accessibilityIdentifier("runner.exerciseTitle")
                            if dynamicTypeSize.isAccessibilitySize {
                                Button("Technique & history", systemImage: "info.circle") { informationFor = ex }
                                    .font(.subheadline).frame(minHeight: 44)
                                    .accessibilityLabel("Exercise information for " + ex.exercise_name)
                            } else {
                                ExerciseInfoButton(exerciseName: ex.exercise_name) { informationFor = ex }
                            }
                        }
                        if let group {
                            groupCard(group, current: ex)
                        } else {
                            HStack {
                                Text(sync.isFreestyle ? "Set \(sync.currentSetNumber)" : "Set \(min(sync.currentSetNumber, ex.target_sets)) of \(ex.target_sets)")
                                if ex.isWarmup { WarmupTag() }
                                Spacer()
                                Text("\(ex.rest_seconds)s rest")
                            }
                            .font(.subheadline).foregroundStyle(Theme.muted)
                        }
                        setEntry(ex)
                        Button { showingOutline = true } label: {
                            Label("Workout outline", systemImage: "list.bullet")
                                .font(.subheadline.weight(.semibold))
                                .frame(maxWidth: .infinity, minHeight: 44)
                        }
                        .accessibilityIdentifier("runner.outline")
                    }
                    .padding(.horizontal, 20).padding(.vertical, 12)
                    // The footer stays fixed at ordinary sizes. At accessibility
                    // sizes all actions share the scroll view so none are clipped.
                    if dynamicTypeSize.isAccessibilitySize { runnerActions(ex) }
                }
                .contentShape(Rectangle())
                if !dynamicTypeSize.isAccessibilitySize { runnerActions(ex) }
            }
            .sheet(isPresented: $showingOutline) { workoutOutline(blocks: blocks) }
            .onChange(of: sync.timedActive) { wasActive, isActive in
                if wasActive && !isActive { showingOutline = false }
            }
            .sheet(isPresented: $editingWeight) {
                WeightEditorSheet(
                    draft: $weightDraft,
                    allowsAssistance: ex.allowsAssistance,
                    onSave: {
                        // Trim and parse — empty / non-numeric drafts cancel
                        // silently rather than zeroing the working weight.
                        if let v = weightDraft.storedWeight, sync.currentExercise.map(RunnerPrescription.init) == weightPrescription {
                            sync.setWeight(v)
                        }
                        editingWeight = false
                    },
                    onCancel: { editingWeight = false }
                )
            }
            .sheet(item: $valueDraft) { draft in
                SetValuesEditor(title: "Next set", values: SetCorrectionValues(
                    weight: draft.input.weight, reps: draft.input.reps, rpe: draft.input.rpe,
                    durationSeconds: draft.input.prescription.timed ? draft.input.durationSeconds : nil),
                    timed: draft.input.prescription.timed, allowsAssistance: draft.exercise.allowsAssistance,
                    storedUnit: draft.exercise.targetWeightUnit,
                    unilateral: draft.exercise.isUnilateral,
                    onSave: { values in
                        sync.setRunnerValues(values, expected: draft.input.prescription)
                    })
            }
            .sheet(item: $informationFor) { ex in
                ExerciseInformationSheet(sync: sync, information: ExerciseInformation(
                    prescription: ex, catalog: sync.catalogRow(ex.exercise_id)))
            }
        }
    }

    private func openValues(_ ex: TemplateExercise) {
        if let input = sync.currentInputState { valueDraft = SetValueDraft(input: input, exercise: ex) }
    }

    /// Match the correction view's visible source, including a queued set or
    /// a tombstone arriving after its shortcut was first shown.
    private var hasLastSetReview: Bool {
        guard let id = sync.lastRunnerSetID else { return false }
        return sync.sets.contains {
            $0.id == id && $0.deleted_at == nil && $0.session_id == sync.todaySession?.id
        } || sync.setOutbox.pending.contains {
            $0.id == id && $0.date == sync.todayString
        }
    }

    private func runnerActions(_ ex: TemplateExercise) -> some View {
        VStack(spacing: 4) {
            // A reserved row keeps the current inputs and the logging action in
            // place as rest starts/ends. End rest never becomes a logging button.
            RestPill(sync: sync, horizontalPadding: 0, onExpand: { onExpandRest?() })
            if hasLastSetReview {
                LastRunnerSetReview(sync: sync, compact: true)
                    .frame(minHeight: 44, alignment: .leading)
            } else {
                // Reserve layout without mounting an empty correction view or
                // a Color-backed container, which SwiftUI exposes to AX audits.
                Spacer(minLength: 0).frame(height: 44)
            }
            if showsStationLink && stationLinkEnabled {
                StationLinkRunnerPanel(sync: sync, link: stationLink, ex: ex)
            }
            RunnerSetAction(sync: sync, ex: ex)
        }
        .padding(.horizontal, 20).padding(.vertical, 8)
        .background(Theme.bg)
    }

    private func setEntry(_ ex: TemplateExercise) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            if !sync.isFreestyle {
                Text("Target · " + ex.prescriptionLabel(in: weightUnit))
                    .font(.caption).foregroundStyle(Theme.muted)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("runner.target")
            }
            if ex.showsLoadControl {
                if ex.isBodyweight && sync.weight == 0 && !loadRevealedFor.contains(ex.id) {
                    Button { loadRevealedFor.insert(ex.id) } label: {
                        HStack {
                            Text("Bodyweight").foregroundStyle(Theme.text)
                            Spacer()
                            Text("Add load/assistance").foregroundStyle(Theme.accent)
                        }
                        .font(.subheadline).frame(minHeight: 44)
                    }
                    .accessibilityIdentifier("runner.addBodyweightLoad")
                    .disabled(sync.timedActive)
                } else {
                    loadControl(ex: ex).disabled(sync.timedActive)
                }
            }
            if ex.isTimed {
                if sync.timedActive {
                    TimedSetView(sync: sync, ex: ex)
                } else {
                    Button { openValues(ex) } label: { TimedSetView(sync: sync, ex: ex) }
                        .buttonStyle(.plain).disabled(sync.isSetEntryBlocked(ex))
                        .accessibilityLabel("Edit duration")
                }
            } else {
                stepper(label: ex.isUnilateral ? "Reps per side" : "Reps",
                        value: "\(sync.reps)", context: ex.isUnilateral ? "reps per side" : "reps",
                        steps: [("−1", { sync.adjustReps(-1) }, false),
                                ("+1", { sync.adjustReps(1) }, false)],
                        onTapValue: { openValues(ex) })
                if ex.isUnilateral {
                    Text("Complete both sides, then log one set.")
                        .font(.caption).foregroundStyle(Theme.muted)
                }
            }
            Button { openValues(ex) } label: {
                HStack {
                    Text(sync.rpe.map { "RPE \(SetValueFormatter.number($0))" } ?? "Add RPE")
                    Spacer()
                    Image(systemName: "slider.horizontal.3")
                }
                .font(.subheadline).frame(minHeight: 44)
            }
            .accessibilityLabel("Edit next set for \(ex.exercise_name)")
            .accessibilityIdentifier("runner.editValues")
            .disabled(sync.timedActive || sync.isSetEntryBlocked(ex))
        }
        .padding(12).background(Theme.surface)
        .clipShape(RoundedRectangle(cornerRadius: 14))
    }

    private func groupCard(_ block: ExerciseGroupBlock, current: TemplateExercise) -> some View {
        let next = sync.nextGroupExercise(afterLogging: current)
        return VStack(alignment: .leading, spacing: 5) {
            Text((block.isWarmup ? "Warm-up · " : "") + "\(block.title) · Round \(min(sync.currentSetNumber, block.rounds)) of \(block.rounds)")
                .font(.subheadline.weight(.semibold)).foregroundStyle(Theme.accent)
                .accessibilityIdentifier("runner.group")
            ForEach(Array(block.members.enumerated()), id: \.element.id) { index, member in
                let active = member.id == current.id
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Image(systemName: active ? "arrow.right.circle.fill" : "circle")
                        .accessibilityHidden(true)
                    Text(block.memberLabel(at: index) + " · " + member.exercise_name)
                        .fontWeight(active ? .semibold : .regular)
                    Spacer(minLength: 0)
                    if sync.isSkipped(member) { Text("Skipped") }
                    else if active { Text("Now") }
                    else { Text("\(sync.runnerSetsDone(member))/\(member.target_sets)").monospacedDigit() }
                }
                .font(.caption).foregroundStyle(active ? Theme.accent : Theme.muted)
                .accessibilityElement(children: .combine)
                .accessibilityIdentifier("runner.group.member.\(member.id)")
            }
            if let next {
                Text(next.id == current.id ? "Next · Continue \(next.exercise_name)"
                     : "Next · \(next.exercise_name): \(next.prescriptionLabel(in: weightUnit))")
                    .font(.caption).foregroundStyle(Theme.text)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("runner.group.next")
            }
        }
    }

    private func workoutOutline(blocks: [ExerciseGroupBlock]) -> some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    if sync.timedActive {
                        Text("Timer running · Browse freely. Return to the timer to log this set.")
                            .font(.subheadline).foregroundStyle(Theme.accent)
                            .accessibilityIdentifier("runner.preview.timer")
                    }
                    if let ex = sync.currentExercise {
                        DisclosureGroup { outlineOptions(ex) } label: {
                            Text("Current exercise options").frame(minHeight: 44)
                        }
                        .font(.subheadline)
                    }
                    ForEach(blocks) { block in
                        VStack(alignment: .leading, spacing: 12) {
                            if block.isGroup {
                                Text(block.title).font(.headline).foregroundStyle(Theme.accent)
                                Text("\(block.rounds) rounds · \(block.roundRest)s round rest · \(block.transitionRest)s between exercises")
                                    .font(.caption).foregroundStyle(Theme.muted)
                            }
                            ForEach(block.members) { member in
                                VStack(alignment: .leading, spacing: 8) {
                                    Button {
                                        guard !sync.timedActive else { return }
                                        if let index = sync.exercises.firstIndex(where: { $0.id == member.id }) { navigate(to: index) }
                                        showingOutline = false
                                    } label: {
                                        VStack(alignment: .leading, spacing: 4) {
                                            Text(member.exercise_name).font(.headline)
                                            Text(member.id == sync.currentExercise?.id ? "Current exercise" : sync.isSkipped(member) ? "Skipped" : "\(sync.runnerSetsDone(member)) of \(member.target_sets) sets")
                                                .font(.caption).foregroundStyle(Theme.muted)
                                        }
                                        .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
                                        .contentShape(Rectangle())
                                    }
                                    .buttonStyle(.plain)
                                    .disabled(sync.timedActive)
                                    .accessibilityLabel(member.exercise_name)
                                    .accessibilityIdentifier("runner.outline.exercise.\(member.id)")
                                    prescriptionContext(ex: member, isPreview: true)
                                    SetReviewList(sync: sync, sets: sync.todaySlotSets(member), pending: sync.pendingSetIntents(for: member))
                                }
                                if member.id != block.members.last?.id { Divider() }
                            }
                        }
                        .padding(16).frame(maxWidth: .infinity, alignment: .leading)
                        .background(Theme.surface).clipShape(RoundedRectangle(cornerRadius: 14))
                    }
                }.padding(20)
            }
            .background(Theme.bg)
            .navigationTitle("Workout outline").navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) {
                Button(sync.timedActive ? "Return to timer" : "Done") { showingOutline = false }
                    .accessibilityIdentifier("runner.outline.done")
            } }
        }
        .preferredColorScheme(.dark)
    }

    private func outlineOptions(_ ex: TemplateExercise) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Current exercise").font(.headline)
            NavigationLink("Technique & history") {
                ExerciseInformationSheet(sync: sync, information: ExerciseInformation(
                    prescription: ex, catalog: sync.catalogRow(ex.exercise_id)))
            }.frame(minHeight: 44)
            if sync.isFreestyle {
                NavigationLink("Add an exercise") { FreestyleExercisePicker(sync: sync) }
                    .frame(minHeight: 44).disabled(sync.timedActive)
                    .accessibilityIdentifier("runner.addFreestyleExercise")
            } else if let target = sync.workoutSwapTarget {
                NavigationLink {
                    WorkoutExerciseSwapSheet(sync: sync, target: target)
                } label: { Label("Swap exercise", systemImage: "arrow.triangle.swap") }
                    .frame(minHeight: 44).accessibilityIdentifier("runner.swap-exercise")
            }
            Button { sync.skip(); showingOutline = false } label: {
                Text("Skip this exercise").frame(minHeight: 44)
            }
            .disabled(sync.timedActive)
            .accessibilityLabel("Skip \(ex.exercise_name)")
            Divider()
            WeightUnitPicker(selection: Binding(get: { weightUnit }, set: { weightUnitRaw = $0.rawValue }), identifier: "runner.weight.unit")
            Toggle("Timer sounds", isOn: $timerCuesEnabled)
                .tint(Theme.accent).frame(minHeight: 44)
                .onChange(of: timerCuesEnabled) { sync.refreshTimerCues() }
            if showsStationLink {
                Toggle("Count reps with iPad Station", isOn: $stationLinkEnabled)
                    .tint(Theme.accent).frame(minHeight: 44)
                    .accessibilityIdentifier("runner.stationLink")
            }
            if ex.exercise_modality == "barbell" {
                NavigationLink("Plates & warm-up guide") {
                    BarbellLoadingView(target: sync.weight, unit: ex.targetWeightUnit)
                }.frame(minHeight: 44)
            }
        }
        .font(.subheadline)
    }

    /// Outline browsing during a hold must never reseed inputs or change the
    /// executing slot. Full prescriptions stay readable in the outline.
    private func navigate(to index: Int) {
        guard !sync.timedActive, sync.exercises.indices.contains(index) else { return }
        sync.jump(to: index)
    }

    private func loadControl(ex: TemplateExercise) -> some View {
        let storedUnit = ex.targetWeightUnit
        let unit = weightUnit.rawValue
        let displayedWeight = storedUnit.convert(sync.weight, to: weightUnit)
        let label = ex.allowsAssistance ? "Load / assistance (\(unit))"
            : "Weight (\(unit))" + (ex.isPerHand ? " · each hand" : "")
        let sign = ex.allowsAssistance && displayedWeight > 0 ? "+" : ""
        let value = sign + WeightUnit.text(displayedWeight)
        // Converted loads (18 lb → 8.165 kg) truncate at the display size;
        // show one decimal and keep the exact value for editing/VoiceOver.
        let display = sign + SetValueFormatter.number(displayedWeight)
        let small = weightUnit == .kg ? 2.5 : 5.0
        let large = weightUnit == .kg ? 5.0 : 10.0
        return VStack(spacing: 8) {
            stepper(
                label: label,
                value: value,
                display: display,
                context: "weight in \(unit)" + (ex.isPerHand ? " per hand" : ""),
                steps: [
                    ("−" + WeightUnit.text(large), { sync.adjustWeight(weightUnit.convert(-large, to: storedUnit)) }, true),
                    ("−" + WeightUnit.text(small), { sync.adjustWeight(weightUnit.convert(-small, to: storedUnit)) }, false),
                    ("+" + WeightUnit.text(small), { sync.adjustWeight(weightUnit.convert(small, to: storedUnit)) }, false),
                    ("+" + WeightUnit.text(large), { sync.adjustWeight(weightUnit.convert(large, to: storedUnit)) }, true),
                ],
                onTapValue: {
                    weightDraft = WeightEntryDraft(weight: sync.weight, storedUnit: storedUnit, unit: weightUnit)
                    weightPrescription = RunnerPrescription(ex)
                    editingWeight = true
                })
        }
    }

    private func stepper(label: String, value: String, display: String? = nil, context: String,
                         steps: [(String, () -> Void, Bool)],
                         onTapValue: (() -> Void)? = nil) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(label).font(.caption).foregroundStyle(Theme.muted)
            if dynamicTypeSize.isAccessibilitySize {
                stepperValue(value, display: display, context: context, onTap: onTapValue)
                LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 8) {
                    ForEach(steps, id: \.0) { s in
                        stepBtn(s.0, s.2, context: context, value: value, s.1)
                    }
                }
            } else {
                HStack(spacing: 8) {
                    ForEach(Array(steps.prefix(steps.count / 2)), id: \.0) { s in
                        stepBtn(s.0, s.2, context: context, value: value, s.1)
                    }
                    stepperValue(value, display: display, context: context, onTap: onTapValue)
                    ForEach(Array(steps.suffix(steps.count - steps.count / 2)), id: \.0) { s in
                        stepBtn(s.0, s.2, context: context, value: value, s.1)
                    }
                }
            }
        }
    }

    @ViewBuilder private func stepperValue(_ value: String, display: String? = nil, context: String,
                                          onTap: (() -> Void)?) -> some View {
        let number = Text(display ?? value).font(Theme.number(32)).foregroundStyle(Theme.text)
            .lineLimit(1).minimumScaleFactor(0.5)
            .frame(maxWidth: .infinity)
            .frame(minHeight: 44)
        if let onTap {
            Button(action: onTap) {
                number.overlay(alignment: .bottom) {
                    Rectangle().fill(Theme.muted.opacity(0.35))
                        .frame(height: 1).padding(.horizontal, 8)
                }
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Edit " + context)
            .accessibilityValue(value)
            .accessibilityIdentifier(context.hasPrefix("weight") ? "runner.weight" : "runner.reps")
        } else {
            number.accessibilityLabel(context).accessibilityValue(value)
        }
    }

    private func stepBtn(_ t: String, _ lg: Bool, context: String, value: String,
                         _ a: @escaping () -> Void) -> some View {
        Button(action: a) {
            Text(t).font(Theme.mono(15, .bold))
                .frame(maxWidth: dynamicTypeSize.isAccessibilitySize ? .infinity : nil)
                .frame(width: dynamicTypeSize.isAccessibilitySize ? nil : 44)
                .frame(minHeight: 44)
                .background(Theme.surface2).foregroundStyle(Theme.text)
                .clipShape(RoundedRectangle(cornerRadius: 10))
        }
        .accessibilityLabel("\(t.hasPrefix("−") ? "Decrease" : "Increase") \(context) by \(t.dropFirst())")
        .accessibilityValue(value)
    }

    private func prescriptionContext(ex: TemplateExercise, isPreview: Bool = false) -> some View {
        let target = (isPreview ? "" : "PRESCRIBED · ") + ex.prescriptionLabel(in: weightUnit)
        let previous = sync.comparablePreviousSets(for: ex)
        let previousLabel = previous.map { set in
            let value = SetValueFormatter.value(weight: set.weightUnit.convert(set.weight, to: weightUnit),
                reps: set.reps, durationSeconds: set.duration_s, timed: ex.isTimed,
                bodyweight: ex.isBodyweight, unit: weightUnit.rawValue, unilateral: ex.isUnilateral)
            let effort = set.rpe.map { " RPE " + SetValueFormatter.number($0) } ?? ""
            return value + effort
        }.joined(separator: " · ")
        return VStack(alignment: .leading, spacing: isPreview ? 6 : 8) {
            Text(target).font(Theme.mono(isPreview ? 18 : 11, .bold)).foregroundStyle(Theme.text)
                .fixedSize(horizontal: false, vertical: true)
            if let cues = ex.cues, !cues.isEmpty {
                Text(cues).font(.subheadline).foregroundStyle(Theme.muted)
            }
            if !previous.isEmpty {
                Text("LAST TIME (\(weightUnit.rawValue)) · " + previousLabel).font(Theme.mono(11)).foregroundStyle(Theme.muted)
            } else if !isPreview {
                Text("No comparable previous session").font(.caption).foregroundStyle(Theme.muted)
            }
        }.padding(.top, isPreview ? 0 : 16)
    }

}

// MARK: - Weight editor sheet

/// Decimal-pad sheet for direct weight entry — handles weird-increment
/// machines (14.3 lb plate stack) the ±5/±10 stepper can't reach without
/// adding more buttons. Parent holds the draft string so an in-flight edit
/// survives a re-render. Auto-focus + select-all so the typical flow is
/// tap → keypad up → type → Save.
private struct WeightEditorSheet: View {
    @Binding var draft: WeightEntryDraft
    @AppStorage(WeightUnit.preferenceKey) private var weightUnitRaw = "lb"
    private var unit: String { draft.unit.rawValue }
    let allowsAssistance: Bool
    let onSave: () -> Void
    let onCancel: () -> Void

    @FocusState private var focused: Bool

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 20) {
                    WeightUnitPicker(selection: Binding(get: { draft.unit }, set: {
                        draft.select($0)
                        weightUnitRaw = $0.rawValue
                    }))
                    Text("WEIGHT (\(unit))")
                        .font(Theme.mono(11, .bold)).tracking(2)
                        .foregroundStyle(Theme.muted)
                        .padding(.top, 8)
                    TextField("0", text: $draft.text)
                        .keyboardType(allowsAssistance ? .numbersAndPunctuation : .decimalPad)
                        .multilineTextAlignment(.center)
                        .font(Theme.number(56))
                        .foregroundStyle(Theme.text)
                        .padding(.horizontal, 20).padding(.vertical, 14)
                        .background(Theme.surface)
                        .clipShape(RoundedRectangle(cornerRadius: 14))
                        .focused($focused)
                        .accessibilityLabel("Weight in \(unit)")
                        .accessibilityIdentifier("weight.entry")
                    Text(allowsAssistance
                         ? "Positive adds load · negative records assistance"
                         : "Any value — \(unit) (e.g. 14.3)")
                        .font(Theme.mono(11)).foregroundStyle(Theme.muted)
                }
                .padding(20)
            }
            .scrollDismissesKeyboard(.interactively)
            .background(Theme.bg.ignoresSafeArea())
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Cancel", action: onCancel)
                        .foregroundStyle(Theme.muted)
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Save", action: onSave)
                        .disabled(draft.storedWeight == nil || (!allowsAssistance && (draft.storedWeight ?? -1) < 0))
                        .font(Theme.mono(14, .bold))
                        .foregroundStyle(Theme.accent)
                }
            }
        }
        .presentationDetents([.large])
        .presentationDragIndicator(.visible)
        .preferredColorScheme(.dark)
        .onAppear { focused = true }
    }
}

private struct TimedSetView: View {
    @ObservedObject var sync: SyncModel
    let ex: TemplateExercise

    var body: some View {
        VStack(spacing: 16) {
            Text(sync.timedActive ? "HOLD" : "DURATION")
                .font(Theme.mono(10, .bold)).tracking(2).foregroundStyle(Theme.muted)

            if sync.timedActive, let end = sync.timedEndDate {
                TimelineView(.periodic(from: .now, by: 0.2)) { ctx in
                    let remaining = max(0, Int(ceil(end.timeIntervalSince(ctx.date))))
                    Text("\(remaining)s")
                        .font(Theme.number(64))
                        .foregroundStyle(remaining <= 0 ? Theme.done : Theme.accent)
                        .accessibilityIdentifier("runner.timer.remaining")
                }
            } else {
                Text("\(sync.holdDurationSeconds)s")
                    .font(Theme.number(64))
                    .foregroundStyle(Theme.text)
            }

        }
        .frame(maxWidth: .infinity)
        .padding(20)
        .background(Theme.surface).clipShape(RoundedRectangle(cornerRadius: 14))
        .padding(.top, 16)
    }
}

/// The current set action stays in the reserved footer while inputs scroll.
/// Keep the rendered slot and physical set number bound to the logging intent.
private struct RunnerSetAction: View {
    @ObservedObject var sync: SyncModel
    let ex: TemplateExercise
    var body: some View {
        let displayedSetNumber = sync.currentPhysicalSetNumber
        let physicalSetNumber = sync.currentPhysicalSetNumber
        let resting = sync.restEndDate != nil
        VStack(spacing: 6) {
            if ex.isTimed && sync.timedActive {
                Button {
                    Task { await sync.stopTimedSet() }
                } label: {
                    Text("STOP & LOG").font(Theme.display(24)).tracking(1.2)
                        .frame(maxWidth: .infinity).padding(.vertical, 16)
                        .contentShape(Rectangle())
                }
                .background(Theme.surface2).foregroundStyle(Theme.text)
                .clipShape(RoundedRectangle(cornerRadius: 14))
                .accessibilityIdentifier("runner.stopTimedSet")
                .disabled(
                    sync.isTerminalMutationInFlight
                        || sync.hasPendingTerminalIntentForCurrentWorkout)
            } else if !sync.isFreestyle && sync.runnerSetsDone(ex) >= ex.target_sets {
                Text("EXERCISE COMPLETE")
                    .font(Theme.display(24)).tracking(1.2)
                    .frame(maxWidth: .infinity).padding(.vertical, 16)
                    .foregroundStyle(Theme.done)
                    .accessibilityIdentifier("runner.exerciseComplete")
            } else if ex.isTimed {
                Button {
                    sync.startTimedSet(
                        expected: ex,
                        expectedSetNumber: physicalSetNumber)
                } label: {
                    Text("START SET \(displayedSetNumber)")
                        .font(Theme.display(24)).tracking(1.2)
                        .frame(maxWidth: .infinity).padding(.vertical, 16)
                        .contentShape(Rectangle())
                }
                .background(Theme.accent).foregroundStyle(.black)
                .clipShape(RoundedRectangle(cornerRadius: 14))
                .accessibilityIdentifier("runner.startSet")
                .disabled(sync.isSetEntryBlocked(ex))
                .opacity(sync.isSetEntryBlocked(ex) ? 0.55 : 1)
            } else {
                Button {
                    Task { await sync.logCurrentSet(expected: ex, expectedSetNumber: physicalSetNumber) }
                } label: {
                    Text("LOG SET \(displayedSetNumber)")
                        .font(Theme.display(26)).tracking(1.2)
                        .frame(maxWidth: .infinity).padding(.vertical, 16)
                        .contentShape(Rectangle())
                }
                // Logging during rest stays available, but a quieter button
                // keeps the rest card the loudest thing on screen.
                .background(resting ? Theme.surface2 : Theme.accent)
                .foregroundStyle(resting ? Theme.accent : .black)
                .clipShape(RoundedRectangle(cornerRadius: 14))
                .overlay(RoundedRectangle(cornerRadius: 14)
                    .strokeBorder(Theme.accent.opacity(resting ? 0.6 : 0), lineWidth: 1))
                .accessibilityIdentifier("runner.logSet")
                .disabled(sync.isSetEntryBlocked(ex))
                .opacity(sync.isSetEntryBlocked(ex) ? 0.55 : 1)
            }
        }
        .frame(maxWidth: .infinity)
        .background(Theme.bg)
        .buttonStyle(.plain)
    }
}

// MARK: - Rest overlay (full screen)

private struct RestOverlay: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @ObservedObject var sync: SyncModel
    /// Collapse the overlay to in-flow controls (timer keeps running). The
    /// pill caller restores it; this view never ends rest on its own —
    /// only DONE / +15 / −15 mutate the timer.
    let onMinimize: () -> Void

    var body: some View {
        TimelineView(.periodic(from: .now, by: 0.2)) { ctx in
            // restEndDate can flip to nil mid-render when DONE is tapped —
            // never force-unwrap it.
            let remaining = sync.restEndDate
                .map { Int(ceil($0.timeIntervalSince(ctx.date))) } ?? 0
            let frac: Double = {
                guard let end = sync.restEndDate, sync.restTotal > 0 else { return 0 }
                return max(0, min(1, end.timeIntervalSince(ctx.date) / Double(sync.restTotal)))
            }()
            ZStack {
                Theme.bg.ignoresSafeArea()
                GeometryReader { geometry in
                    ScrollView {
                        VStack(spacing: 0) {
                            Text("REST").font(Theme.mono(11, .bold)).tracking(4)
                                .foregroundStyle(Theme.muted).padding(.bottom, 8)
                            Text(clock(remaining))
                                .font(Theme.display(140))
                                .lineLimit(1).minimumScaleFactor(0.2)
                                .frame(maxWidth: .infinity)
                                .accessibilityLabel(remaining <= 0 ? "Rest complete" : "Rest remaining")
                                .accessibilityValue(remaining <= 0 ? "" : "\(remaining) seconds")
                                .accessibilityIdentifier("rest.status")
                                .foregroundStyle(remaining <= 0 ? Theme.done : Theme.accent)
                                .shadow(color: (remaining <= 0 ? Theme.done : Theme.accent).opacity(0.4),
                                        radius: 30)
                                .opacity(remaining <= 0 && !reduceMotion ? (Int(ctx.date.timeIntervalSince1970 * 2) % 2 == 0 ? 1 : 0.4) : 1)

                            RoundedRectangle(cornerRadius: 3).fill(Theme.surface)
                                .frame(width: 240, height: 6)
                                .overlay(alignment: .leading) {
                                    RoundedRectangle(cornerRadius: 3).fill(Theme.accent)
                                        .frame(width: 240 * frac, height: 6)
                                }
                                .padding(.top, 24)

                            let buttonsLayout = dynamicTypeSize.isAccessibilitySize
                                ? AnyLayout(VStackLayout(spacing: 12)) : AnyLayout(HStackLayout(spacing: 12))
                            buttonsLayout {
                                restBtn("−15s") { sync.addRest(-15) }
                                    .accessibilityLabel("Shorten rest by 15 seconds")
                                restBtn("+15s") { sync.addRest(15) }
                                    .accessibilityLabel("Extend rest by 15 seconds")
                                restBtn("DONE", primary: true) { sync.skipRest() }
                                    .accessibilityLabel("End rest").accessibilityIdentifier("rest.done")
                            }
                            .padding(.top, 36)

                            VStack(spacing: 4) {
                                Text("UP NEXT").font(Theme.mono(11, .bold)).tracking(2)
                                    .foregroundStyle(Theme.muted)
                                Text(sync.finished ? "DONE" : sync.currentExercise?.exercise_name.uppercased() ?? "DONE")
                                    .font(Theme.display(22)).foregroundStyle(Theme.text)
                                    .accessibilityIdentifier("rest.upNext")
                            }
                            .padding(.top, 28)
                            RestNextSetValues(sync: sync).padding(.top, 6)
                            LastRunnerSetReview(sync: sync).padding(.top, 16)

                            // Peek-through: collapse to in-flow controls so the runner
                            // (current exercise, jump strip, completed sets) is
                            // visible/scrollable without ending the timer. Discoverable
                            // tap target; swipe-down on the overlay also minimizes.
                            Button(action: onMinimize) {
                                HStack(spacing: 6) {
                                    Image(systemName: "chevron.down")
                                        .font(.system(size: 11, weight: .bold))
                                    Text("PREVIEW WORKOUT")
                                        .font(Theme.mono(11, .bold)).tracking(2)
                                }
                                .foregroundStyle(Theme.muted)
                                .padding(.horizontal, 16).padding(.vertical, 12)
                                .frame(minHeight: 44)
                                .background(Capsule().fill(Theme.surface))
                            }
                            .padding(.top, 36)
                            .accessibilityIdentifier("rest.minimize")
                        }
                        .padding(20)
                        .frame(maxWidth: .infinity, minHeight: geometry.size.height)
                    }
                }
            }
            // Swipe-down anywhere on the overlay minimizes (matches the
            // sheet-dismissal idiom). Threshold high enough not to fight the
            // button taps above.
            .contentShape(Rectangle())
            .simultaneousGesture(
                DragGesture(minimumDistance: 30)
                    .onEnded { v in
                        if !dynamicTypeSize.isAccessibilitySize, v.translation.height > 60 {
                            onMinimize()
                        }
                    }
            )
        }
    }

    private func restBtn(_ t: String, primary: Bool = false,
                         _ a: @escaping () -> Void) -> some View {
        Button(action: a) {
            Text(t).font(Theme.mono(13, .bold))
                .padding(.horizontal, 18).padding(.vertical, 14)
                .background(primary ? Theme.accent : Theme.surface)
                .foregroundStyle(primary ? .black : Theme.text)
                .clipShape(RoundedRectangle(cornerRadius: 10))
        }
    }
}

// MARK: - Compact rest controls

/// Rest owns a stable, separate row. Its End rest target remains an End rest
/// action after the deadline; logging is always a different button below it.
private struct RestPill: View {
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @ObservedObject var sync: SyncModel
    var horizontalPadding: CGFloat = 20
    let onExpand: () -> Void

    var body: some View {
        Group {
            if let end = sync.restEndDate {
                TimelineView(.periodic(from: .now, by: 0.25)) { ctx in
                    let remaining = max(0, Int(ceil(end.timeIntervalSince(ctx.date))))
                    HStack(spacing: 10) {
                        Button(action: onExpand) {
                            Label(remaining == 0 ? "Rest complete" : "Rest · " + clock(remaining), systemImage: "timer")
                                .font(.subheadline.monospacedDigit())
                                .foregroundStyle(remaining == 0 ? Theme.done : Theme.accent)
                                .frame(minHeight: 44).contentShape(Rectangle())
                        }
                        .accessibilityLabel("Expand rest timer")
                        .accessibilityValue("\(remaining) seconds remaining")
                        Spacer(minLength: 4)
                        Button { sync.skipRest() } label: {
                            Text("End rest").font(.subheadline.weight(.semibold))
                                .padding(.horizontal, 12).frame(minHeight: 44)
                                .background(Theme.accent).foregroundStyle(.black)
                                .clipShape(RoundedRectangle(cornerRadius: 10))
                        }
                        .accessibilityIdentifier("rest.done")
                    }
                }
            } else {
                HStack(spacing: 10) {
                    Label(sync.timedActive ? "Timer running" : "Ready when you are", systemImage: sync.timedActive ? "timer" : "checkmark.circle")
                        .font(.subheadline).foregroundStyle(Theme.muted)
                        .frame(minHeight: 44)
                    Spacer(minLength: 0)
                }
            }
        }
        .buttonStyle(.plain)
        .padding(.horizontal, horizontalPadding)
    }
}

private struct RestNextSetValues: View {
    @ObservedObject var sync: SyncModel
    @AppStorage(WeightUnit.preferenceKey) private var weightUnitRaw = "lb"

    var body: some View {
        if !sync.finished, let exercise = sync.currentExercise {
            let unit = WeightUnit(rawValue: weightUnitRaw) ?? .lb
            let storedUnit = exercise.targetWeightUnit
            let values = SetValueFormatter.value(
                weight: storedUnit.convert(sync.weight, to: unit), reps: sync.reps,
                durationSeconds: exercise.isTimed ? sync.holdDurationSeconds : nil,
                timed: exercise.isTimed, bodyweight: exercise.isBodyweight,
                unit: unit.rawValue, unilateral: exercise.isUnilateral)
            Text("Set \(sync.currentPhysicalSetNumber)" + (sync.isFreestyle ? " · " : " of \(exercise.target_sets) · ") + values
                 + (sync.weight != 0 && !exercise.isTimed ? " · \(unit.rawValue)" : "")
                 + (exercise.isPerHand ? " each hand" : ""))
                .font(.caption).foregroundStyle(Theme.muted)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityIdentifier("rest.nextValues")
        }
    }
}

// MARK: - Finished

private struct FinishedView: View {
    @ObservedObject var sync: SyncModel
    var onExpandRest: (() -> Void)? = nil

    /// All live WORKING sets in today's session (warm-ups excluded), taken
    /// straight from the session rather than per-slot so the same movement in
    /// two slots can't double-count the summary.
    private var todaysSets: [SetLog] {
        guard let sid = sync.todaySession?.id else { return [] }
        return sync.sets.filter {
            $0.session_id == sid && $0.deleted_at == nil && $0.is_warmup == 0
        }
    }

    var body: some View {
        let finishPending = sync.currentTerminalIntent?.action == .finish
            && sync.currentTerminalIntent?.deliveryState != .acknowledged
        let readyToFinish = sync.canFinishResolvedWorkout
        ScrollView {
            VStack(spacing: 16) {
                if let onExpandRest {
                    RestPill(sync: sync, horizontalPadding: 0, onExpand: onExpandRest)
                }
                Text(finishPending ? "WAITING" : readyToFinish ? "SETS DONE" : "REVIEW SETS")
                    .font(Theme.display(finishPending ? 64 : 58))
                    .foregroundStyle(Theme.done)
                Text(finishPending
                    ? "FINISH SAVED ON THIS DEVICE"
                    : readyToFinish ? "READY TO FINISH" : "EXERCISES TO COMPLETE")
                    .font(Theme.mono(11, .bold)).tracking(2)
                    .foregroundStyle(Theme.muted)

                let sets = todaysSets
                // Match the WorkoutDoneView rollup: reps count both sides;
                // volume also counts both implements for per-hand loads.
                let reps = sync.totalReps(for: sets)
                // One clock, one scan: the queued count and the review list
                // below both need today's undelivered intents.
                let pendingToday = sync.setOutbox.pending.filter { $0.date == sync.todayString }
                VStack(spacing: 0) {
                    sumRow("Sets saved", "\(sets.count)")
                    let queued = pendingToday.count
                    if queued > 0 { sumRow("Sets queued on this device", "\(queued)") }
                    if reps > 0 {
                        sumRow("Total reps", "\(reps)")
                    }
                    // Each unit keeps its own total; lb and kg never sum.
                    let tonnage = sync.tonnageByUnit(for: sets)
                    if !tonnage.isEmpty {
                        sumRow("External-load volume", WeightUnit.totals(tonnage) { "\(Int($0))" })
                    }
                }
                .padding(.top, 20)
                Text("Completion summary and records are pending until the workout is saved.")
                    .font(.caption).foregroundStyle(Theme.muted)
                ForEach(sync.metricCohorts(for: sets)) { cohort in
                    sumRow(sync.exerciseName(cohort.key.exerciseID), cohort.valueLabel)
                }

                SetReviewList(sync: sync, sets: sync.sets.filter {
                    $0.session_id == sync.todaySession?.id && $0.deleted_at == nil
                }, pending: pendingToday)
                WorkoutFeedbackEntry(sync: sync)
                if readyToFinish {
                    Button { sync.jump(to: sync.exerciseIndex) } label: {
                        Text("Return to exercises").frame(minHeight: 44).contentShape(Rectangle())
                    }
                    .disabled(sync.hasPendingTerminalIntentForCurrentWorkout)
                }

            }
            .padding(28)
        }
        .safeAreaInset(edge: .bottom, spacing: 0) {
            Button {
                guard readyToFinish else { sync.reviewIncompleteExercises(); return }
                guard let target = sync.terminalActionTarget else { return }
                Task { await sync.finishResolvedWorkout(expected: target) }
            } label: {
                Text(finishPending ? "WAITING TO SYNC" : readyToFinish ? "FINISH WORKOUT" : "REVIEW EXERCISES")
                    .font(Theme.display(24)).tracking(1.5)
                    .frame(maxWidth: .infinity).padding(.vertical, 16)
            }
            .background(Theme.accent).foregroundStyle(.black)
            .clipShape(RoundedRectangle(cornerRadius: 14))
            .accessibilityIdentifier(readyToFinish || finishPending ? "FINISH" : "finished.reviewExercises")
            .disabled(
                sync.hasPendingTerminalIntentForCurrentWorkout)
            .padding(.horizontal, 20).padding(.vertical, 10)
            .background(Theme.background)
        }
    }

    private func sumRow(_ a: String, _ b: String) -> some View {
        HStack {
            Text(a).font(Theme.mono(13)).foregroundStyle(Theme.text)
            Spacer()
            Text(b).font(Theme.mono(13)).foregroundStyle(Theme.muted)
                .accessibilityIdentifier("summary.value." + a)
        }
        .padding(.vertical, 12)
        .overlay(alignment: .bottom) { Divider().overlay(Theme.surface2) }
    }
}
