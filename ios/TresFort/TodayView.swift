import SwiftUI

private func fmt(_ w: Double) -> String {
    w.rounded() == w ? String(Int(w)) : String(format: "%.1f", w)
}
private func clock(_ s: Int) -> String {
    s <= 0 ? "GO" : String(format: "%d:%02d", s / 60, s % 60)
}

/// Identifies the day whose workout the editor sheet is editing.
private struct EditDayTarget: Identifiable { let id: String }

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
    var body: some View {
        HStack(spacing: 9) {
            Image(systemName: "wifi.slash")
                .font(.system(size: 12, weight: .bold))
                .foregroundStyle(Theme.muted)
            Text("OFFLINE · SHOWING LAST SAVED DATA")
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
    @State private var feedbackPresentation: WorkoutFeedbackPresentation?
    @ObservedObject var sync: SyncModel
    @ObservedObject var auth: AuthModel
    /// Opens the shared ManualActivitySheet hosted by MainTabView so a user
    /// can log "I just did Pilates" without tab-switching. Optional so
    /// existing tests / previews can construct the view without the new
    /// dependency.
    var onLogActivity: (() -> Void)? = nil

    /// Opens the saved workout library from the explicit Today action.
    @State private var showOverridePicker = false
    /// Confirms discarding the in-progress workout (destructive, undo-less).
    @State private var showDiscardConfirm = false
    @State private var discardTarget: WorkoutTerminalActionTarget?
    /// Rest overlay collapsed to a floating pill so the runner underneath
    /// (current exercise, jump strip, completed sets) is visible/scrollable
    /// without ending the rest timer. Reset whenever `restEndDate` clears so
    /// the next rest starts in the expanded state.
    @State private var restMinimized = false
    /// Direct creation of a named saved workout.
    @State private var showRoutine = false
    @State private var previewTarget: EditDayTarget?
    @State private var unresolvedDate: AgendaDate?
    /// Keeps a double tap from starting twice while iOS is presenting the
    /// one-time notification permission prompt before a new workout.
    @State private var isPreparingWorkoutStart = false

    var body: some View {
        let fullRestOverlayVisible = sync.restEndDate != nil && !restMinimized
        NavigationStack {
            ZStack(alignment: .top) {
                Theme.background
                VStack(spacing: 0) {
                    if sync.isUsingCachedState {
                        CachedStateBanner()
                    }
                    if sync.pendingTerminalIntentCount > 0 {
                        PendingTerminalBanner(sync: sync)
                    }
                    PendingSetBannerGate(sync: sync)
                    if !sync.setCorrections.isEmpty {
                        PendingCorrectionsView(sync: sync)
                    }
                    content
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
                if sync.restEndDate != nil {
                    if restMinimized {
                        RestPill(sync: sync) { restMinimized = false }
                    } else {
                        RestOverlay(sync: sync) { restMinimized = true }
                    }
                }
            }
            .onChange(of: sync.restEndDate) { _, new in
                if new == nil { restMinimized = false }
            }
            .navigationTitle(sync.running ? "Workout" : "Today")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                if sync.running {
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
                fullRestOverlayVisible ? .hidden : .visible,
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
            .sheet(isPresented: $showRoutine) {
                CreateWorkoutView(sync: sync, onStart: sync.todayIsCompleted ? nil : startChosenWorkout)
            }
        }
        .preferredColorScheme(.dark)
    }

    @ViewBuilder private var content: some View {
        if sync.finished {
            FinishedView(sync: sync)
        } else if sync.running {
            RunnerView(sync: sync, auth: auth)
        } else if sync.plan == nil && !sync.canCreateRoutine {
            PlanLoadRecoveryView(sync: sync)
        } else if sync.plan == nil {
            VStack(spacing: 14) {
                Text("NO PLAN YET").font(Theme.display(28)).foregroundStyle(Theme.text)
                Text("Build and schedule your first workout here, or connect your own Claude to help with your plan. You can use both paths anytime.")
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
                    todayRoute("Choose a workout", subtitle: "View and edit your library")
                }
                .accessibilityIdentifier("today.chooseWorkout")
                Button { showRoutine = true } label: {
                    todayRoute("Create a workout", subtitle: "Save a workout for another day")
                }
                .accessibilityIdentifier("today.createWorkout")
            }
            .padding(.horizontal, 20)
        } else {
            ScrollView {
                VStack(alignment: .leading, spacing: 22) {
                    Text(sync.todayString).font(Theme.mono(12)).foregroundStyle(Theme.muted)
                    if let workout = sync.todayPreviewWorkout {
                        VStack(alignment: .leading, spacing: 14) {
                            Text(sync.hasResumableWorkout ? "In progress" : "Scheduled for today")
                                .font(Theme.mono(12)).foregroundStyle(Theme.muted)
                            Text(workout.name).font(Theme.display(30)).foregroundStyle(Theme.text)
                            Text("\(workout.exercises.count) exercises")
                                .font(.subheadline).foregroundStyle(Theme.muted)
                            Button("View workout", systemImage: "chevron.right") { previewTarget = EditDayTarget(id: workout.id) }
                                .frame(minHeight: 44).accessibilityIdentifier("today.viewWorkout")
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
                        Button("View workout record") { unresolvedDate = AgendaDate(id: session.date) }
                            .frame(minHeight: 44).accessibilityIdentifier("today.viewUnresolvedWorkout")
                        Button("Refresh workout") { Task { await sync.load() } }.frame(minHeight: 44)
                    } else {
                        Text("Nothing scheduled").font(Theme.display(30)).foregroundStyle(Theme.text)
                        Text("Choose a saved workout or create one for today.")
                            .foregroundStyle(Theme.muted)
                    }
                    Button { showOverridePicker = true } label: {
                        todayRoute("Choose a workout", subtitle: "From your library")
                    }
                    .accessibilityIdentifier("today.chooseWorkout")
                    Button { showRoutine = true } label: {
                        todayRoute("Create a workout", subtitle: "Build your own workout")
                    }
                    .accessibilityIdentifier("today.createWorkout")
                    .disabled(sync.blocksNewWorkoutStart)
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

private struct AgendaDate: Identifiable { let id: String }

private struct NextWorkoutCard: View {
    @ObservedObject var sync: SyncModel
    let next: SyncModel.NextWorkout
    @State private var preview: AgendaDate?

    var body: some View {
        Button {
            preview = AgendaDate(id: next.dateString)
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
            DayAgendaView(sync: sync, dateString: d.id)
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
    @State private var recordDate: AgendaDate?
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
                    Text("\(todaySets.count) working sets · \(Set(todaySets.map(\.exercise_id)).count) exercises")
                        .font(.subheadline).foregroundStyle(Theme.muted)
                    Button("View workout", systemImage: "chevron.right") {
                        recordDate = AgendaDate(id: sync.todayString)
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

    /// Tap-to-edit on the big weight number → decimal-pad sheet. Persists
    /// the in-flight edit string (`""` while the sheet is open and the user
    /// has cleared the field — TextField needs a Binding, not a transient
    /// value) so a partially-typed entry isn't lost on a re-render.
    @State private var editingWeight = false
    @State private var weightDraft = WeightEntryDraft(weight: 0, storedUnit: .lb, unit: .lb)
    @AppStorage(WeightUnit.preferenceKey) private var weightUnitRaw = "lb"
    private var weightUnit: WeightUnit { WeightUnit(rawValue: weightUnitRaw) ?? .lb }
    /// Exercise demo sheet, openable mid-workout — not just from the
    /// pre-start preview (#54).
    @State private var demoFor: TemplateExercise?
    @State private var editingValues = false
    @State private var valueDraft: RunnerInputState?
    @State private var weightPrescription: RunnerPrescription?
    @State private var loadingTarget: Double?
    @State private var showingLoading = false
    @State private var previewFor: TemplateExercise?
    @AppStorage(RestCue.defaultsKey) private var timerCuesEnabled = true

    var body: some View {
        if let ex = sync.currentExercise {
            let displayedSetNumber = sync.currentSetNumber
            VStack(spacing: 0) {
                ScrollView {
                    VStack(alignment: .leading, spacing: 0) {
                        if sync.workoutStart != nil {
                            TimelineView(.periodic(from: .now, by: 1)) { _ in
                                let e = sync.workoutElapsedSeconds
                                Text("WORKOUT  \(e / 60):\(String(format: "%02d", e % 60))")
                                    .font(Theme.mono(11, .bold)).tracking(2)
                                    .foregroundStyle(Theme.muted)
                            }
                            .padding(.bottom, 12)
                        }

                        ProgressBar(exercises: sync.exercises,
                                    currentIndex: sync.exerciseIndex, sync: sync)
                            .padding(.bottom, 22)

                        if let block = ExerciseGroupBlock.blocks(sync.exercises).first(where: { $0.members.contains(where: { $0.id == ex.id }) }), block.isGroup {
                            groupCard(block, current: ex)
                                .padding(.bottom, 20)
                        }

                        // Keep the compact scoreboard at ordinary sizes; allow
                        // the full exercise name to wrap at accessibility sizes.
                        HStack(alignment: .center, spacing: 10) {
                            Text(ex.exercise_name.uppercased())
                                .font(Theme.display(52)).foregroundStyle(Theme.text)
                                .lineLimit(dynamicTypeSize.isAccessibilitySize ? nil : 1)
                                .minimumScaleFactor(dynamicTypeSize.isAccessibilitySize ? 1 : 0.4)
                                .fixedSize(horizontal: false, vertical: true)
                            DemoInfoButton(exerciseName: ex.exercise_name) { demoFor = ex }
                            if ex.isWarmup { WarmupTag() }
                            Spacer(minLength: 0)
                        }
                        .frame(minHeight: 56)
                        .frame(maxWidth: .infinity, alignment: .leading)

                        let metadataLayout = dynamicTypeSize.isAccessibilitySize
                            ? AnyLayout(VStackLayout(alignment: .leading, spacing: 8))
                            : AnyLayout(HStackLayout())
                        metadataLayout {
                            let complete = sync.isComplete(ex)
                            meta(ex.group_id == nil ? "SET" : "ROUND", "\(min(displayedSetNumber, ex.target_sets))",
                                 complete ? "OF \(ex.target_sets) ✓" : "OF \(ex.target_sets)")
                            if !dynamicTypeSize.isAccessibilitySize { Spacer() }
                            meta("TARGET", ex.targetLabel, "")
                            if !dynamicTypeSize.isAccessibilitySize { Spacer() }
                            meta(ex.group_id == nil ? "REST" : "ROUND REST",
                                 "\(ex.group_rest_seconds ?? ex.rest_seconds)s", "")
                        }
                        .padding(.top, 12)

                        prescriptionContext(ex: ex)
                        Button {
                            valueDraft = sync.currentInputState
                            editingValues = true
                        } label: {
                            Text("Edit weight, \(ex.isTimed ? "duration" : "reps") & RPE")
                                .font(Theme.mono(12, .bold)).frame(minHeight: 44).contentShape(Rectangle())
                        }
                        .accessibilityLabel("Edit next set for \(ex.exercise_name)")
                        .disabled(sync.timedActive || sync.isSetEntryBlocked(ex))
                        if let rpe = sync.rpe {
                            Text("LOGGING RPE \(SetValueFormatter.number(rpe))")
                                .font(Theme.mono(11)).foregroundStyle(Theme.accent)
                        }
                        Toggle("Timer sounds", isOn: $timerCuesEnabled)
                            .font(Theme.mono(11)).tint(Theme.accent)
                            .onChange(of: timerCuesEnabled) { sync.refreshTimerCues() }
                        jumpStrip(ex: ex)

                        if ex.showsLoadControl {
                            loadControl(ex: ex).disabled(sync.timedActive)
                        }
                        if ex.exercise_modality == "barbell", ex.exercise_unit == "lb" {
                            Button {
                                loadingTarget = sync.weight
                                showingLoading = true
                            } label: {
                                Text("Plates & warm-up guide")
                                    .font(Theme.mono(12, .bold)).frame(minHeight: 44).contentShape(Rectangle())
                            }
                        }

                        if ex.isTimed {
                            TimedSetView(sync: sync, ex: ex)
                        } else {
                            stepper(label: "REPS", value: "\(sync.reps)", context: "reps",
                                    steps: [("−1", { sync.adjustReps(-1) }, false),
                                            ("+1", { sync.adjustReps(1) }, false)])
                        }

                        completedChips(ex: ex)


                        HStack {
                            navBtn("← PREV") { navigate(to: sync.exerciseIndex - 1) }
                                .disabled(sync.exerciseIndex == 0)
                            Text("\(sync.exerciseIndex + 1) / \(sync.exercises.count)")
                                .font(Theme.mono(11)).tracking(1.5).foregroundStyle(Theme.muted)
                                .frame(maxWidth: .infinity)
                            // Non-destructive: just move to the next exercise. Going
                            // out of order no longer strikes out the ones you pass (#3).
                            navBtn("NEXT →") { navigate(to: sync.exerciseIndex + 1) }
                                .disabled(sync.exerciseIndex >= sync.exercises.count - 1)
                        }
                        .padding(.top, 24)

                        // Explicit, lower-emphasis "I'm not doing this one" — strikes
                        // the exercise out and drops it from the queue so the workout
                        // can finish without it. Kept SEPARATE from NEXT so plain
                        // forward navigation never marks anything skipped (#3).
                        Button { sync.skip() } label: {
                            Text("Skip this exercise")
                                .font(Theme.mono(11, .bold)).tracking(1)
                                .foregroundStyle(Theme.muted)
                                .frame(maxWidth: .infinity)
                                .padding(.vertical, 12).frame(minHeight: 44)
                        }
                        .accessibilityLabel("Skip \(ex.exercise_name)")
                        .padding(.top, 8)
                    }
                    .padding(20)
                    // When a rest is running the floating RestPill sits at the
                    // top-centre; reserve space so it never lands on the WORKOUT
                    // timer + progress bar (#53). Invisible when the full rest
                    // overlay is up (it covers the runner anyway).
                    .padding(.top, sync.restEndDate != nil ? 52 : 0)
                }
                // A sibling keeps the action inside the runner's hit-testing
                // bounds as the full rest screen hides and restores app chrome.
                RunnerSetAction(sync: sync, ex: ex)
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
            .sheet(isPresented: $showingLoading) {
                BarbellLoadingView(target: loadingTarget ?? sync.weight)
            }
            .sheet(item: $previewFor) { selected in
                exercisePreview(startingAt: selected.id)
            }
            .onChange(of: sync.timedActive) {
                if !sync.timedActive { previewFor = nil }
            }
            .sheet(isPresented: $editingValues) {
                if let draft = valueDraft {
                    SetValuesEditor(title: "Next set", values: SetCorrectionValues(
                        weight: draft.weight, reps: draft.reps, rpe: draft.rpe,
                        durationSeconds: draft.prescription.timed ? draft.durationSeconds : nil),
                        timed: draft.prescription.timed, allowsAssistance: ex.allowsAssistance,
                        storedUnit: WeightUnit(rawValue: ex.exercise_unit) ?? .lb,
                        onSave: { values in
                            sync.setRunnerValues(values, expected: draft.prescription)
                        })
                }
            }
            .sheet(item: $demoFor) { ex in
                ExerciseDemoSheet(
                    exerciseID: ex.exercise_id,
                    name: ex.exercise_name,
                    primaryMuscle: sync.catalogRow(ex.exercise_id)?.primary_muscle
                        ?? ex.exercise_modality,
                    secondaryMuscles: [],
                    modality: ex.exercise_modality,
                    laterality: ex.exercise_laterality ?? "bilateral",
                    loadMode: ex.exercise_load_mode ?? "total",
                    demoSlug: ex.exercise_demo_slug,
                    jwt: auth.featureJWT
                )
            }
        }
    }

    private func meta(_ a: String, _ b: String, _ c: String) -> some View {
        (Text(a + " ").foregroundStyle(Theme.muted)
         + Text(b).foregroundStyle(Theme.accent)
         + Text(c.isEmpty ? "" : " " + c).foregroundStyle(Theme.muted))
            .font(Theme.mono(11, .bold)).tracking(1.5)
    }

    private func groupCard(_ block: ExerciseGroupBlock, current: TemplateExercise) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text(block.title.uppercased()).font(Theme.mono(13, .bold))
                    .accessibilityIdentifier("runner.group")
                Spacer()
                Text("ROUND \(min(sync.currentSetNumber, block.rounds)) / \(block.rounds)")
                    .font(Theme.mono(11, .bold))
            }
            .foregroundStyle(Theme.accent)
            ForEach(Array(block.members.enumerated()), id: \.element.id) { index, member in
                let active = member.id == current.id
                HStack(spacing: 10) {
                    Text(block.memberLabel(at: index)).font(Theme.mono(12, .bold))
                    VStack(alignment: .leading, spacing: 4) {
                        Text(member.exercise_name).font(.subheadline.weight(.semibold))
                        Text(member.targetLabel).font(Theme.mono(11)).foregroundStyle(Theme.muted)
                    }
                    Spacer()
                    Text(active ? "NOW" : (sync.isSkipped(member) ? "SKIPPED" : "\(sync.runnerSetsDone(member))/\(member.target_sets)"))
                        .font(Theme.mono(11, .bold))
                }
                .foregroundStyle(active ? Theme.accent : Theme.text)
                .padding(12)
                .background(active ? Theme.accent.opacity(0.1) : Theme.surface2)
                .clipShape(RoundedRectangle(cornerRadius: 10))
                .accessibilityElement(children: .combine)
                .accessibilityIdentifier("runner.group.member.\(member.id)")
            }
            Text("Log each exercise to advance automatically.")
                .font(.caption).foregroundStyle(Theme.text)
            Text("\(block.roundRest)s rest after each round" + (block.transitionRest > 0 ? " · \(block.transitionRest)s between exercises" : " · No rest between exercises"))
                .font(.caption).foregroundStyle(Theme.muted)
        }
        .padding(16)
        .background(Theme.surface)
        .clipShape(RoundedRectangle(cornerRadius: 14))
        .overlay(RoundedRectangle(cornerRadius: 14).stroke(Theme.accent.opacity(0.4)))
    }

    private func jumpStrip(ex: TemplateExercise) -> some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                ForEach(ExerciseGroupBlock.blocks(sync.exercises)) { block in
                    let current = block.members.contains { $0.id == ex.id }
                    let done = block.members.allSatisfy { sync.runnerSetsDone($0) >= $0.target_sets }
                    let skipped = block.members.allSatisfy { sync.isSkipped($0) } && !done
                    let title = block.isGroup ? block.title : block.members[0].exercise_name
                    Button {
                        if current { return }
                        let member = block.members.first(where: { !sync.isSkipped($0) && sync.runnerSetsDone($0) < $0.target_sets }) ?? block.members[0]
                        if let index = sync.exercises.firstIndex(where: { $0.id == member.id }) { navigate(to: index) }
                    } label: {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(title + (done ? " ✓" : skipped ? " · skipped" : ""))
                                .font(Theme.mono(11, .bold)).strikethrough(skipped, color: Theme.muted)
                            if block.isGroup {
                                Text(block.members.map(\.exercise_name).joined(separator: " + "))
                                    .font(.caption2).lineLimit(1)
                            }
                        }
                        .padding(.horizontal, 12).padding(.vertical, 8)
                        .frame(minHeight: 44)
                        .background(current ? Theme.accent : Theme.surface)
                        .foregroundStyle(current ? .black : (done ? Theme.done : Theme.muted))
                        .clipShape(RoundedRectangle(cornerRadius: 8))
                    }
                    .accessibilityLabel(title)
                    .accessibilityValue(done ? "Complete" : skipped ? "Skipped" : current ? "Current exercise" : "Not completed")
                    .accessibilityAddTraits(current ? [.isSelected] : [])
                }
            }
        }
        .padding(.top, 16)
    }

    /// Browsing during a hold must not change the executing slot: jumping
    /// reseeds inputs and invalidates the timer's original set identity.
    private func navigate(to index: Int) {
        guard sync.exercises.indices.contains(index) else { return }
        if sync.timedActive {
            guard index != sync.exerciseIndex else { return }
            previewFor = sync.exercises[index]
        } else {
            sync.jump(to: index)
        }
    }

    private func exercisePreview(startingAt slotID: String) -> some View {
        NavigationStack {
            VStack(spacing: 0) {
                if let active = sync.currentExercise, let end = sync.timedEndDate {
                    TimelineView(.periodic(from: .now, by: 1)) { context in
                        let remaining = max(0, Int(ceil(end.timeIntervalSince(context.date))))
                        Text("\(active.exercise_name) · \(remaining)s remaining")
                            .font(Theme.mono(13, .bold))
                            .foregroundStyle(Theme.accent)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(16)
                            .accessibilityIdentifier("runner.preview.timer")
                    }
                }
                ScrollViewReader { proxy in
                    ScrollView {
                        VStack(alignment: .leading, spacing: 12) {
                            ForEach(ExerciseGroupBlock.blocks(sync.exercises)) { block in
                                VStack(alignment: .leading, spacing: 16) {
                                    if block.isGroup {
                                        Text(block.title.uppercased()).font(Theme.mono(13, .bold)).foregroundStyle(Theme.accent)
                                        Text("\(block.rounds) rounds · \(block.roundRest)s round rest · \(block.transitionRest)s transition")
                                            .font(Theme.mono(11)).foregroundStyle(Theme.muted)
                                    }
                                    ForEach(Array(block.members.enumerated()), id: \.element.id) { index, ex in
                                        VStack(alignment: .leading, spacing: 8) {
                                            Text((block.isGroup ? block.memberLabel(at: index) + " · " : "") + ex.exercise_name.uppercased())
                                                .font(Theme.display(28)).foregroundStyle(Theme.text)
                                            if ex.isWarmup { WarmupTag() }
                                            if !block.isGroup {
                                                Text("SETS \(ex.target_sets) · \(ex.rest_seconds)s rest")
                                                    .font(Theme.mono(12)).foregroundStyle(Theme.muted)
                                            }
                                            prescriptionContext(ex: ex)
                                        }
                                        .id(ex.id)
                                    }
                                }
                                .padding(16)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .background(Theme.surface)
                                .clipShape(RoundedRectangle(cornerRadius: 14))
                            }
                        }
                        .padding(16)
                    }
                    .onAppear { proxy.scrollTo(slotID, anchor: .top) }
                }
            }
            .background(Theme.bg)
            .navigationTitle("Workout preview")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Return to timer") { previewFor = nil }
                }
            }
        }
    }

    private func loadControl(ex: TemplateExercise) -> some View {
        let storedUnit = WeightUnit(rawValue: ex.exercise_unit) ?? .lb
        let unit = weightUnit.rawValue
        let displayedWeight = storedUnit.convert(sync.weight, to: weightUnit)
        let label = ex.allowsAssistance ? "ADDED LOAD / ASSIST (\(unit)) · TAP TO EDIT"
            : "WEIGHT (\(unit))" + (ex.isPerHand ? " · EACH HAND" : "") + " · TAP TO EDIT"
        let value = (ex.allowsAssistance && displayedWeight > 0 ? "+" : "") + WeightUnit.text(displayedWeight)
        let small = weightUnit == .kg ? 2.5 : 5.0
        let large = weightUnit == .kg ? 5.0 : 10.0
        return VStack(spacing: 8) {
            WeightUnitPicker(selection: Binding(
                get: { weightUnit }, set: { weightUnitRaw = $0.rawValue }), identifier: "runner.weight.unit")
                .padding(.top, 16)
            stepper(
                label: label,
                value: value,
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

    private func stepper(label: String, value: String, context: String,
                         steps: [(String, () -> Void, Bool)],
                         onTapValue: (() -> Void)? = nil) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(label).font(Theme.mono(11, .bold)).tracking(2).foregroundStyle(Theme.muted)
            if dynamicTypeSize.isAccessibilitySize {
                stepperValue(value, context: context, onTap: onTapValue)
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
                    stepperValue(value, context: context, onTap: onTapValue)
                    ForEach(Array(steps.suffix(steps.count - steps.count / 2)), id: \.0) { s in
                        stepBtn(s.0, s.2, context: context, value: value, s.1)
                    }
                }
            }
        }
        .padding(16)
        .background(Theme.surface).clipShape(RoundedRectangle(cornerRadius: 14))
        .padding(.top, 16)
    }

    @ViewBuilder private func stepperValue(_ value: String, context: String,
                                          onTap: (() -> Void)?) -> some View {
        let number = Text(value).font(Theme.number(52)).foregroundStyle(Theme.text)
            .lineLimit(1).minimumScaleFactor(0.5)
            .frame(maxWidth: .infinity)
            .frame(minHeight: 56)
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
            .accessibilityIdentifier("runner.weight")
        } else {
            number.accessibilityLabel(context).accessibilityValue(value)
        }
    }

    private func stepBtn(_ t: String, _ lg: Bool, context: String, value: String,
                         _ a: @escaping () -> Void) -> some View {
        Button(action: a) {
            Text(t).font(Theme.mono(15, .bold))
                .frame(maxWidth: dynamicTypeSize.isAccessibilitySize ? .infinity : nil)
                .frame(width: dynamicTypeSize.isAccessibilitySize ? nil : (lg ? 60 : 54))
                .frame(minHeight: 50)
                .background(Theme.surface2).foregroundStyle(Theme.text)
                .clipShape(RoundedRectangle(cornerRadius: 10))
        }
        .accessibilityLabel("\(t.hasPrefix("−") ? "Decrease" : "Increase") \(context) by \(t.dropFirst())")
        .accessibilityValue(value)
    }

    private func prescriptionContext(ex: TemplateExercise) -> some View {
        let storedUnit = WeightUnit(rawValue: ex.exercise_unit) ?? .lb
        let load = ex.target_weight.map { WeightUnit.text(storedUnit.convert($0, to: weightUnit)) + " \(weightUnit.rawValue) · " } ?? ""
        let effort = ex.target_rpe.map { " · RPE " + SetValueFormatter.number($0) } ?? ""
        let target = "PRESCRIBED · " + load + ex.targetLabel + effort
        let previous = sync.comparablePreviousSets(for: ex)
        let previousLabel = previous.map { set in
            let value = SetValueFormatter.value(weight: storedUnit.convert(set.weight, to: weightUnit),
                reps: set.reps, durationSeconds: set.duration_s, timed: ex.isTimed,
                bodyweight: ex.isBodyweight, unit: weightUnit.rawValue)
            let effort = set.rpe.map { " RPE " + SetValueFormatter.number($0) } ?? ""
            return value + effort
        }.joined(separator: " · ")
        return VStack(alignment: .leading, spacing: 8) {
            Text(target).font(Theme.mono(11, .bold)).foregroundStyle(Theme.text)
            if let cues = ex.cues, !cues.isEmpty {
                Text(cues).font(.subheadline).foregroundStyle(Theme.muted)
            }
            if !previous.isEmpty {
                Text("LAST TIME (\(weightUnit.rawValue)) · " + previousLabel).font(Theme.mono(11)).foregroundStyle(Theme.muted)
            } else {
                Text("No comparable previous session").font(.caption).foregroundStyle(Theme.muted)
            }
        }.padding(.top, 16)
    }

    private func completedChips(ex: TemplateExercise) -> some View {
        SetReviewList(sync: sync, sets: sync.todaySlotSets(ex), pending: sync.pendingSetIntents(for: ex))
            .padding(.top, 24)
    }

    private func navBtn(_ t: String, _ a: @escaping () -> Void) -> some View {
        Button(action: a) {
            Text(t).font(Theme.mono(12, .bold)).tracking(1.2)
                .frame(maxWidth: .infinity).padding(.vertical, 14)
                .background(Theme.surface).foregroundStyle(Theme.text)
                .clipShape(RoundedRectangle(cornerRadius: 10))
        }
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

/// The current set action stays above the tab bar while inputs scroll. Keep
/// the rendered slot and physical set number bound to the logging intent.
private struct RunnerSetAction: View {
    @ObservedObject var sync: SyncModel
    let ex: TemplateExercise
    @AppStorage(WeightUnit.preferenceKey) private var weightUnitRaw = "lb"

    var body: some View {
        let displayedSetNumber = sync.currentSetNumber
        let physicalSetNumber = sync.currentPhysicalSetNumber
        let unit = WeightUnit(rawValue: weightUnitRaw) ?? .lb
        let storedUnit = WeightUnit(rawValue: ex.exercise_unit) ?? .lb
        VStack(spacing: 6) {
            Text(ex.exercise_name)
                .font(.subheadline.weight(.semibold)).foregroundStyle(Theme.text)
                .fixedSize(horizontal: false, vertical: true)
            let values = SetValueFormatter.value(
                weight: storedUnit.convert(sync.weight, to: unit), reps: sync.reps,
                durationSeconds: ex.isTimed ? sync.holdDurationSeconds : nil, timed: ex.isTimed,
                bodyweight: ex.isBodyweight, unit: unit.rawValue)
            Text(values + (!ex.isTimed && sync.weight != 0 ? " · \(unit.rawValue)" : "")
                 + (sync.rpe.map { " · RPE \(SetValueFormatter.number($0))" } ?? ""))
                .font(.caption).foregroundStyle(Theme.muted)
                .accessibilityIdentifier("runner.setSummary")
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
                .disabled(
                    sync.isTerminalMutationInFlight
                        || sync.hasPendingTerminalIntentForCurrentWorkout)
            } else if sync.runnerSetsDone(ex) >= ex.target_sets {
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
                    Text(ex.group_id == nil ? "START SET \(displayedSetNumber)" : "START ROUND \(displayedSetNumber)")
                        .font(Theme.display(24)).tracking(1.2)
                        .frame(maxWidth: .infinity).padding(.vertical, 16)
                        .contentShape(Rectangle())
                }
                .background(Theme.accent).foregroundStyle(.black)
                .clipShape(RoundedRectangle(cornerRadius: 14))
                .shadow(color: Theme.accent.opacity(0.35), radius: 18, y: 8)
                .disabled(sync.isSetEntryBlocked(ex))
                .opacity(sync.isSetEntryBlocked(ex) ? 0.55 : 1)
            } else {
                Button {
                    Task { await sync.logCurrentSet(expected: ex, expectedSetNumber: physicalSetNumber) }
                } label: {
                    Text(ex.group_id == nil ? "LOG SET \(displayedSetNumber)" : "LOG ROUND \(displayedSetNumber)")
                        .font(Theme.display(26)).tracking(1.2)
                        .frame(maxWidth: .infinity).padding(.vertical, 16)
                        .contentShape(Rectangle())
                }
                .background(Theme.accent).foregroundStyle(.black)
                .clipShape(RoundedRectangle(cornerRadius: 14))
                .disabled(sync.isSetEntryBlocked(ex))
                .opacity(sync.isSetEntryBlocked(ex) ? 0.55 : 1)
            }
        }
        .padding(.horizontal, 20).padding(.vertical, 10)
        .frame(maxWidth: .infinity)
        .background(Theme.background)
        .buttonStyle(.plain)
    }
}

// MARK: - Rest overlay (full screen)

private struct RestOverlay: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @ObservedObject var sync: SyncModel
    /// Collapse the overlay to the floating pill (timer keeps running). The
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

                            // Peek-through: collapse to a floating pill so the runner
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

// MARK: - Rest pill (minimized overlay)

/// Floating countdown chip shown when the rest overlay is minimized. Sits
/// at the top safe area, hit-tests only itself (taps elsewhere pass through
/// to the runner underneath), and re-expands the overlay on tap. The timer
/// state lives in SyncModel — this view only renders it.
private struct RestPill: View {
    @ObservedObject var sync: SyncModel
    let onExpand: () -> Void

    var body: some View {
        TimelineView(.periodic(from: .now, by: 0.5)) { ctx in
            let remaining = sync.restEndDate
                .map { Int(ceil($0.timeIntervalSince(ctx.date))) } ?? 0
            let color = remaining <= 0 ? Theme.done : Theme.accent
            Button(action: onExpand) {
                HStack(spacing: 10) {
                    Image(systemName: "timer")
                        .font(.system(size: 13, weight: .bold))
                    Text("REST")
                        .font(Theme.mono(11, .bold)).tracking(2)
                    Text(clock(remaining))
                        .font(Theme.mono(15, .bold))
                    Image(systemName: "chevron.up")
                        .font(.system(size: 10, weight: .bold))
                }
                .foregroundStyle(color)
                .padding(.horizontal, 14).padding(.vertical, 10)
                .frame(minHeight: 44)
                .background(Capsule().fill(Theme.surface))
                .overlay(Capsule().stroke(color.opacity(0.5), lineWidth: 1))
                .shadow(color: .black.opacity(0.45), radius: 12, y: 4)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Expand rest timer")
            .accessibilityValue(remaining <= 0 ? "Rest complete" : "\(remaining) seconds remaining")
            .padding(.top, 6)
        }
    }
}

// MARK: - Finished

private struct FinishedView: View {
    @ObservedObject var sync: SyncModel

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
                VStack(spacing: 0) {
                    sumRow("Sets saved", "\(sets.count)")
                    let queued = sync.setOutbox.pending.filter { $0.date == sync.todayString }.count
                    if queued > 0 { sumRow("Sets queued on this device", "\(queued)") }
                    if reps > 0 {
                        sumRow("Total reps", "\(reps)")
                    }
                    if let tonnage = sync.totalTonnage(for: sets) {
                        sumRow("External-load volume", "\(Int(tonnage)) lb")
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
                }, pending: sync.setOutbox.pending.filter { $0.date == sync.todayString })
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
