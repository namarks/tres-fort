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

    /// Presents the demoted "Train a different day" override picker.
    @State private var showOverridePicker = false
    /// Confirms discarding the in-progress workout (destructive, undo-less).
    @State private var showDiscardConfirm = false
    @State private var discardTarget: WorkoutTerminalActionTarget?
    /// Rest overlay collapsed to a floating pill so the runner underneath
    /// (current exercise, jump strip, completed sets) is visible/scrollable
    /// without ending the rest timer. Reset whenever `restEndDate` clears so
    /// the next rest starts in the expanded state.
    @State private var restMinimized = false
    /// Presents the in-app workout editor (add/remove/reorder exercises +
    /// warm-ups) for the resolved day.
    @State private var editTarget: EditDayTarget?
    /// Full member-owned plan/day/schedule editor.
    @State private var showRoutine = false
    @State private var showPlanHistory = false
    @State private var showCoachingContext = false
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
                    RecentPlanChanges(sync: sync) { showPlanHistory = true }
                    content
                }
                // The full rest screen is modal. Without explicitly removing
                // the runner from hit testing and the accessibility tree,
                // assistive actions can start/log a hidden set underneath it.
                .allowsHitTesting(!fullRestOverlayVisible)
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
            // FIX 1: let the plan name degrade gracefully instead of hard-
            // truncating mid-word. A principal title shows short names full
            // size on one line, wraps medium names to 2 lines, and scales
            // long names down to 65% — the meaningful name always shows.
            .toolbar {
                ToolbarItem(placement: .principal) {
                    Text(sync.plan?.name ?? "Très Fort")
                        .font(Theme.mono(15, .bold))
                        .foregroundStyle(Theme.text)
                        .multilineTextAlignment(.center)
                        .lineLimit(2)
                        .minimumScaleFactor(0.65)
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: 280)
                }
                // Dedicated "Log activity" affordance — promoted out of the
                // overflow menu so logging an off-plan activity (Pilates,
                // walk, "lifted elsewhere") is one tap from the Today tab and
                // no longer feels tied to the Group tab. Same sheet the Group
                // FAB opens; both call groupModel.logActivity, and the result
                // now surfaces on the personal calendar regardless of groups.
                if let onLogActivity {
                    ToolbarItem(placement: .topBarTrailing) {
                        Button {
                            onLogActivity()
                        } label: {
                            Image(systemName: "plus.circle")
                                .foregroundStyle(Theme.accent)
                        }
                        .accessibilityLabel("Log activity")
                    }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Menu {
                        Button("Refresh") { Task { await sync.load() } }
                        Button("Coaching context") { showCoachingContext = true }
                        Button {
                            showRoutine = true
                        } label: {
                            Label(sync.plan == nil ? "Create workout" : "Workouts",
                                  systemImage: "calendar.badge.clock")
                        }
                        .disabled(sync.plan == nil && !sync.canCreateRoutine)
                        if sync.plan != nil {
                            Button("Workout history") { showPlanHistory = true }
                        }
                        if let id = sync.running ? sync.selectedDay?.id : sync.todayResolvedDay?.id {
                            Button {
                                editTarget = EditDayTarget(id: id)
                            } label: { Label("Edit exercises", systemImage: "slider.horizontal.3") }
                        }
                        if sync.running {
                            Button("End workout", role: .destructive) {
                                guard let target = sync.terminalActionTarget else {
                                    return
                                }
                                feedbackPresentation = WorkoutFeedbackPresentation(target: target)
                            }
                            .disabled(sync.hasPendingTerminalIntentForCurrentWorkout)
                            Button("Discard workout", role: .destructive) {
                                discardTarget = sync.terminalActionTarget
                                showDiscardConfirm = discardTarget != nil
                            }
                            .disabled(sync.hasDiscardIntentForCurrentWorkout)
                        }
                        Button("Sign out", role: .destructive) { auth.signOut() }
                    } label: {
                        Image(systemName: "ellipsis.circle").foregroundStyle(Theme.muted)
                            .frame(width: 44, height: 44).contentShape(Rectangle())
                    }
                    .accessibilityLabel("Workout options")
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
            .confirmationDialog(
                "Train a different day",
                isPresented: $showOverridePicker,
                titleVisibility: .visible
            ) {
                ForEach(sync.plan?.workouts ?? []) { d in
                    Button(d.title) {
                        prepareNewWorkout {
                            sync.startOverride(dayID: d.id)
                        }
                    }
                        .disabled(sync.blocksNewWorkoutStart)
                }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("Starts a one-off session. Your weekly schedule is unchanged; edit it from Workouts.")
            }
            .confirmationDialog(
                "Discard this workout?",
                isPresented: $showDiscardConfirm,
                titleVisibility: .visible
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
            .sheet(item: $editTarget) { t in
                EditWorkoutSheet(sync: sync, dayID: t.id)
            }
            .task(id: [sync.plan?.id ?? "", String(sync.plan?.version ?? 0)]) {
                await sync.refreshRecentPlanChanges()
            }
            .sheet(isPresented: $showCoachingContext) {
                CoachingContextView(sync: sync)
            }
            .sheet(isPresented: $showPlanHistory) {
                PlanHistoryView(sync: sync)
            }
            .sheet(isPresented: $showRoutine) {
                WorkoutsView(sync: sync)
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
            WorkoutDoneView(sync: sync)
        } else if let day = sync.todayResolvedDay {
            // Workout day (planned / in_progress / projected) — today
            // resolved via CalendarProjection (the SAME projection the
            // calendar uses), not a manual A/B default. in_progress
            // resumes into the runner via the existing start path.
            TodayWorkoutView(
                sync: sync, auth: auth, day: day,
                onOverride: { showOverridePicker = true },
                onEdit: { editTarget = EditDayTarget(id: day.id) },
                onStart: {
                    prepareNewWorkout {
                        if sync.hasResumableWorkout {
                            sync.resumeWorkout()
                        } else {
                            sync.startToday()
                        }
                    }
                },
                isPreparingWorkoutStart: isPreparingWorkoutStart)
        } else {
            // Pure rest day (or skipped) — no primary START CTA.
            RestDayView(
                sync: sync,
                onOverride: { showOverridePicker = true })
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

// MARK: - Rest day (schedule-driven)

/// Shown when today's projection resolves to rest (or a skipped session).
/// Surfaces the next upcoming workout found by forward-scanning the SAME
/// projection, plus a **primary "Start a workout" CTA** that opens the
/// override picker. The CTA matters because a rest-day projection can also
/// follow a discard (vanish to schedule) on a day that isn't scheduled —
/// without an obvious restart, the day looks stranded. Pair to the
/// finished-view's demoted `OverrideButton`, which stays demoted there
/// (the workout is done — "different day" is intentionally low-priority).
private struct RestDayView: View {
    @ObservedObject var sync: SyncModel
    let onOverride: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("TODAY")
                            .font(Theme.mono(11, .bold)).tracking(2)
                            .foregroundStyle(Theme.muted)
                        Text("— Rest day —")
                            .font(Theme.display(40))
                            .foregroundStyle(Theme.text)
                        Text("Nothing scheduled. Recover.")
                            .font(Theme.mono(13)).foregroundStyle(Theme.muted)
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

            // Primary CTA: ensures a rest day (recurring rest OR post-
            // discard fall-through) is never stranded — one tap to pick a
            // template and start. Same picker the workout-day "different
            // day" override uses (`onOverride` → showOverridePicker).
            StartWorkoutCTA(
                onOverride: onOverride,
                connectionTitle: sync.needsLiveWorkoutValidation
                    ? sync.liveWorkoutValidationActionTitle
                    : nil)
                .padding(16)
                .disabled(
                    (sync.plan?.workouts.isEmpty ?? true)
                        || sync.hasUnacknowledgedDiscardForToday
                        || sync.blocksNewWorkoutStart)
        }
    }
}

// MARK: - Next workout card (tappable → full preview)

/// The "NEXT WORKOUT" card, shared by the rest-day and workout-complete
/// screens. Tapping it opens the SAME full workout preview the calendar
/// uses (`DayAgendaView`) as a sheet for the upcoming date — so "what's
/// tomorrow's session" is one tap from Today, not a trip to the Calendar
/// tab. Preview only: DayAgendaView is read-only for future dates (start
/// still happens from the Today screen on the day itself).
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
    @State private var showDiscardConfirm = false
    @State private var discardTarget: WorkoutTerminalActionTarget?

    private var doneTemplateTitle: String {
        sync.todayResolvedDay?.title.uppercased() ?? "WORKOUT"
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
                    if let session = sync.sessionsByDate[sync.todayString] {
                        WorkoutSummaryView(sync: sync, sessionID: session.id)
                        let feedback = WorkoutFeedback(notes: session.notes, perceivedFatigue: session.perceived_fatigue)
                        if !feedback.isEmpty { SavedWorkoutFeedbackView(feedback: feedback) }
                    }
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

                // Demoted, non-primary escape hatch: an accidental/test
                // "End workout" recorded a session you didn't really do.
                // Discard throws it away and the day reverts to its normal
                // schedule (no SQL, fully reversible by just redoing it).
                Button(role: .destructive) {
                    discardTarget = sync.terminalActionTarget
                    showDiscardConfirm = discardTarget != nil
                } label: {
                    Text("Discard — didn't really do this")
                        .font(Theme.mono(12, .bold)).tracking(1)
                        .foregroundStyle(Theme.danger)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 14)
                }
                .buttonStyle(.plain)
                .disabled(sync.hasDiscardIntentForCurrentWorkout)
            }
            .padding(16)
        }
        .refreshable { await sync.load() }
        .confirmationDialog(
            "Discard this workout?",
            isPresented: $showDiscardConfirm,
            titleVisibility: .visible
        ) {
            Button("Discard — don't save", role: .destructive) {
                guard let target = discardTarget else { return }
                Task { await sync.discardWorkout(expected: target) }
            }
            Button("Keep workout", role: .cancel) {}
        } message: {
            Text("The sets you logged will be deleted and this session won't count. The day goes back to its normal schedule. This can't be undone.")
        }
    }
}

// MARK: - Workout day (schedule-driven)

/// Shown when today's projection resolves to a workout. Renders the
/// resolved template's exercises + the primary START WORKOUT CTA. The
/// runner executes whatever `sync.startToday` selected (the resolved
/// template), not a manual A/B default.
private struct TodayWorkoutView: View {
    @ObservedObject var sync: SyncModel
    @ObservedObject var auth: AuthModel
    let day: Workout
    let onOverride: () -> Void
    let onEdit: () -> Void
    let onStart: () -> Void
    let isPreparingWorkoutStart: Bool
    @State private var demoFor: TemplateExercise?

    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 10) {
                    Text("TODAY · \(day.title.uppercased())")
                        .font(Theme.mono(11, .bold)).tracking(2)
                        .foregroundStyle(Theme.muted).padding(.bottom, 6)
                    ForEach(ExerciseGroupBlock.blocks(day.exercises)) { block in
                        VStack(alignment: .leading, spacing: 12) {
                            if block.isGroup {
                                HStack {
                                    Text(block.title.uppercased()).font(Theme.mono(12, .bold)).foregroundStyle(Theme.accent)
                                    if block.isWarmup { WarmupTag() }
                                }
                                Text("\(block.rounds) rounds · \(block.roundRest)s round rest · \(block.transitionRest)s transition")
                                    .font(Theme.mono(11)).foregroundStyle(Theme.muted)
                            }
                            ForEach(Array(block.members.enumerated()), id: \.element.id) { index, ex in
                                HStack(spacing: 8) {
                                    if block.isGroup {
                                        Text(block.memberLabel(at: index)).font(Theme.mono(12, .bold)).foregroundStyle(Theme.accent)
                                    }
                                    Text(ex.exercise_name.uppercased())
                                        .font(Theme.display(22)).foregroundStyle(Theme.text)
                                    DemoInfoButton(exerciseName: ex.exercise_name) { demoFor = ex }
                                    if ex.isWarmup && !block.isWarmup { WarmupTag() }
                                    if ex.isWarmup && !block.isGroup { WarmupTag() }
                                    Spacer()
                                    Text(ex.targetLabel)
                                        .font(Theme.mono(14)).foregroundStyle(Theme.muted)
                                }
                            }
                        }
                        .padding(16)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(Theme.surface)
                        .clipShape(RoundedRectangle(cornerRadius: 14))
                    }
                    if let err = sync.loadError {
                        Text(err).font(Theme.mono(12)).foregroundStyle(Theme.danger)
                    }
                    EditWorkoutButton(onEdit: onEdit).padding(.top, 6)
                    OverrideButton(
                        onOverride: onOverride,
                        blocked: sync.blocksNewWorkoutStart,
                        connectionTitle: sync.needsLiveWorkoutValidation
                            ? sync.liveWorkoutValidationBlockTitle
                            : nil)
                }
                .padding(16)
            }
            .refreshable { await sync.load() }

            Button {
                onStart()
            } label: {
                Text(isPreparingWorkoutStart
                    ? "PREPARING…"
                    : (sync.hasResumableWorkout
                        ? "RESUME WORKOUT"
                        : (sync.needsLiveWorkoutValidation
                            ? sync.liveWorkoutValidationActionTitle
                            : "START WORKOUT")))
                    .font(Theme.display(26)).tracking(1.5)
                    .frame(maxWidth: .infinity).padding(.vertical, 18)
            }
            .background(Theme.accent).foregroundStyle(.black)
            .clipShape(RoundedRectangle(cornerRadius: 14))
            .shadow(color: Theme.accent.opacity(0.35), radius: 18, y: 8)
            .disabled(
                day.exercises.isEmpty
                    || isPreparingWorkoutStart
                    || sync.hasUnacknowledgedDiscardForToday
                    || (sync.blocksNewWorkoutStart
                        && !sync.hasResumableWorkout))
            .padding(16)
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

/// Demoted, secondary affordance — never the primary CTA. Opens the
/// day/template override picker.
/// Primary "Start a workout" CTA used on RestDayView. Same visual weight
/// as the schedule-day "START WORKOUT" button (Theme.accent fill, display
/// font, glow), but opens the day picker rather than auto-starting today's
/// resolved template — a rest day has no resolved template, so the user
/// chooses which day (A/B) to run. The picker itself is the existing
/// `showOverridePicker` confirmationDialog on TodayView.
private struct StartWorkoutCTA: View {
    let onOverride: () -> Void
    let connectionTitle: String?
    var body: some View {
        Button(action: onOverride) {
            Text(connectionTitle ?? "START A WORKOUT")
                .font(Theme.display(26)).tracking(1.5)
                .frame(maxWidth: .infinity).padding(.vertical, 18)
        }
        .background(Theme.accent).foregroundStyle(.black)
        .clipShape(RoundedRectangle(cornerRadius: 14))
        .shadow(color: Theme.accent.opacity(0.35), radius: 18, y: 8)
    }
}

private struct OverrideButton: View {
    let onOverride: () -> Void
    let blocked: Bool
    let connectionTitle: String?
    var body: some View {
        Button(action: onOverride) {
            HStack(spacing: 6) {
                Text(connectionTitle
                    ?? (blocked
                        ? "Resume saved workout first"
                        : "Train a different day"))
                    .font(Theme.mono(13, .bold))
                Image(systemName: "chevron.right").font(.system(size: 11, weight: .bold))
            }
            .foregroundStyle(Theme.muted)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 12)
            .background(Theme.surface.opacity(0.6))
            .clipShape(RoundedRectangle(cornerRadius: 10))
        }
        .disabled(blocked)
    }
}

/// Demoted secondary affordance: opens the in-app workout editor to tweak
/// today's exercises (add one, drop one, add an erg warm-up) without Claude.
private struct EditWorkoutButton: View {
    let onEdit: () -> Void
    var body: some View {
        Button(action: onEdit) {
            HStack(spacing: 6) {
                Image(systemName: "slider.horizontal.3").font(.system(size: 11, weight: .bold))
                Text("Edit workout")
                    .font(Theme.mono(13, .bold))
            }
            .foregroundStyle(Theme.muted)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 12)
            .background(Theme.surface.opacity(0.6))
            .clipShape(RoundedRectangle(cornerRadius: 10))
        }
    }
}

// MARK: - shared: segmented progress bar

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
    @State private var weightDraft = ""
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
            let physicalSetNumber = sync.currentPhysicalSetNumber
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

                    if let block = ExerciseGroupBlock.blocks(sync.exercises).first(where: { $0.members.contains(where: { $0.id == ex.id }) }),
                       block.isGroup, let memberIndex = block.members.firstIndex(where: { $0.id == ex.id }) {
                        Text("\(block.title.uppercased()) · \(block.memberLabel(at: memberIndex)) · \(block.transitionRest)s TRANSITION")
                            .font(Theme.mono(11, .bold)).foregroundStyle(Theme.accent)
                            .padding(.bottom, 8)
                            .accessibilityIdentifier("runner.group")
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

                        Button {
                            // Bind the intent to what this tap displayed. The
                            // Task may begin after an earlier tap advanced the
                            // runner, and must never log that successor slot.
                            let renderedExercise = ex
                            Task {
                                await sync.logCurrentSet(
                                    expected: renderedExercise,
                                    expectedSetNumber: physicalSetNumber)
                            }
                        } label: {
                            Text(ex.group_id == nil ? "LOG SET \(displayedSetNumber)" : "LOG ROUND \(displayedSetNumber)")
                                .font(Theme.display(26)).tracking(1.2)
                                .frame(maxWidth: .infinity).padding(.vertical, 18)
                        }
                        .background(Theme.accent).foregroundStyle(.black)
                        .clipShape(RoundedRectangle(cornerRadius: 14))
                        .shadow(color: Theme.accent.opacity(0.35), radius: 18, y: 8)
                        .padding(.top, 18)
                        .disabled(sync.isSetEntryBlocked(ex))
                        .opacity(sync.isSetEntryBlocked(ex) ? 0.55 : 1)
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
                // Native tab bars can overlay the tail of a tall runner. Keep
                // enough scroll content below Prev/Next/Skip for those controls
                // to clear the bar on every supported phone size.
                .padding(.bottom, 88)
                // When a rest is running the floating RestPill sits at the
                // top-centre; reserve space so it never lands on the WORKOUT
                // timer + progress bar (#53). Invisible when the full rest
                // overlay is up (it covers the runner anyway).
                .padding(.top, sync.restEndDate != nil ? 52 : 0)
            }
            .sheet(isPresented: $editingWeight) {
                WeightEditorSheet(
                    draft: $weightDraft,
                    unit: ex.allowsAssistance ? "lb" : ex.exercise_unit,
                    allowsAssistance: ex.allowsAssistance,
                    onSave: {
                        // Trim and parse — empty / non-numeric drafts cancel
                        // silently rather than zeroing the working weight.
                        let trimmed = weightDraft.trimmingCharacters(in: .whitespaces)
                        if let v = Double(trimmed), sync.currentExercise.map(RunnerPrescription.init) == weightPrescription {
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

    private func jumpStrip(ex: TemplateExercise) -> some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                ForEach(Array(sync.exercises.enumerated()), id: \.element.id) { i, e in
                    let cur = i == sync.exerciseIndex
                    let done = sync.isComplete(e)
                    let skipped = sync.isSkipped(e) && !done
                    Button { navigate(to: i) } label: {
                        Text(e.exercise_name + (done ? " ✓" : skipped ? " · skipped" : ""))
                            .font(Theme.mono(11, .bold))
                            .strikethrough(skipped, color: Theme.muted)
                            .padding(.horizontal, 12).padding(.vertical, 8)
                            .frame(minHeight: 44)
                            .background(cur ? Theme.accent : Theme.surface)
                            .foregroundStyle(cur ? .black : (done ? Theme.done : Theme.muted))
                            .clipShape(RoundedRectangle(cornerRadius: 8))
                            .overlay(RoundedRectangle(cornerRadius: 8)
                                .stroke(done && !cur ? Theme.done.opacity(0.3) : .clear))
                    }
                    .accessibilityLabel(e.exercise_name)
                    .accessibilityValue(done ? "Complete" : skipped ? "Skipped" : cur ? "Current exercise" : "Not completed")
                    .accessibilityAddTraits(cur ? [.isSelected] : [])
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
                            ForEach(sync.exercises) { ex in
                                VStack(alignment: .leading, spacing: 8) {
                                    Text(ex.exercise_name.uppercased())
                                        .font(Theme.display(28)).foregroundStyle(Theme.text)
                                    if ex.isWarmup { WarmupTag() }
                                    Text("\(ex.target_sets) \(ex.group_id == nil ? "sets" : "rounds") · \(ex.group_rest_seconds ?? ex.rest_seconds)s rest")
                                        .font(Theme.mono(12)).foregroundStyle(Theme.muted)
                                    prescriptionContext(ex: ex)
                                }
                                .padding(16)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .background(Theme.surface)
                                .clipShape(RoundedRectangle(cornerRadius: 14))
                                .id(ex.id)
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
        let unit = ex.allowsAssistance ? "lb" : ex.exercise_unit
        let label: String
        if ex.allowsAssistance {
            label = "ADDED LOAD / ASSIST (\(unit)) · TAP TO EDIT"
        } else if ex.isPerHand {
            label = "WEIGHT (\(unit)) · EACH HAND · TAP TO EDIT"
        } else {
            label = "WEIGHT (\(unit)) · TAP TO EDIT"
        }
        let value: String
        if ex.allowsAssistance && sync.weight > 0 {
            value = "+\(SetValueFormatter.number(sync.weight))"
        } else if ex.allowsAssistance && sync.weight < 0 {
            value = "−\(SetValueFormatter.number(abs(sync.weight)))"
        } else {
            value = SetValueFormatter.number(sync.weight)
        }
        return stepper(
            label: label,
            value: value,
            context: "weight in \(unit)" + (ex.isPerHand ? " per hand" : ""),
            steps: [
                ("−10", { sync.adjustWeight(-10) }, true),
                ("−5", { sync.adjustWeight(-5) }, false),
                ("+5", { sync.adjustWeight(5) }, false),
                ("+10", { sync.adjustWeight(10) }, true),
            ],
            onTapValue: {
                weightDraft = SetValueFormatter.number(sync.weight)
                weightPrescription = RunnerPrescription(ex)
                editingWeight = true
            })
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
        let load = ex.target_weight.map { SetValueFormatter.number($0) + " lb · " } ?? ""
        let effort = ex.target_rpe.map { " · RPE " + SetValueFormatter.number($0) } ?? ""
        let target = "PRESCRIBED · " + load + ex.targetLabel + effort
        let previous = sync.comparablePreviousSets(for: ex)
        let previousLabel = previous.map { set in
            let value = set.valueLabel(timed: ex.isTimed, bodyweight: ex.isBodyweight)
            let effort = set.rpe.map { " RPE " + SetValueFormatter.number($0) } ?? ""
            return value + effort
        }.joined(separator: " · ")
        return VStack(alignment: .leading, spacing: 8) {
            Text(target).font(Theme.mono(11, .bold)).foregroundStyle(Theme.text)
            if let cues = ex.cues, !cues.isEmpty {
                Text(cues).font(.subheadline).foregroundStyle(Theme.muted)
            }
            if !previous.isEmpty {
                Text("LAST TIME · " + previousLabel).font(Theme.mono(11)).foregroundStyle(Theme.muted)
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
    @Binding var draft: String
    let unit: String
    let allowsAssistance: Bool
    let onSave: () -> Void
    let onCancel: () -> Void

    @FocusState private var focused: Bool

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 20) {
                    Text("WEIGHT (\(unit))")
                        .font(Theme.mono(11, .bold)).tracking(2)
                        .foregroundStyle(Theme.muted)
                        .padding(.top, 8)
                    TextField("0", text: $draft)
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
        let displayedSetNumber = sync.currentSetNumber
        let physicalSetNumber = sync.currentPhysicalSetNumber
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

            if sync.timedActive {
                Button {
                    Task { await sync.stopTimedSet() }
                } label: {
                    Text("STOP & LOG").font(Theme.display(24)).tracking(1.2)
                        .frame(maxWidth: .infinity).padding(.vertical, 16)
                }
                .background(Theme.surface2).foregroundStyle(Theme.text)
                .clipShape(RoundedRectangle(cornerRadius: 14))
                .disabled(
                    sync.isTerminalMutationInFlight
                        || sync.hasPendingTerminalIntentForCurrentWorkout)
            } else {
                Button {
                    sync.startTimedSet(
                        expected: ex,
                        expectedSetNumber: physicalSetNumber)
                } label: {
                    Text(ex.group_id == nil ? "START SET \(displayedSetNumber)" : "START ROUND \(displayedSetNumber)")
                        .font(Theme.display(24)).tracking(1.2)
                        .frame(maxWidth: .infinity).padding(.vertical, 16)
                }
                .background(Theme.accent).foregroundStyle(.black)
                .clipShape(RoundedRectangle(cornerRadius: 14))
                .shadow(color: Theme.accent.opacity(0.35), radius: 18, y: 8)
                .disabled(sync.isSetEntryBlocked(ex))
                .opacity(sync.isSetEntryBlocked(ex) ? 0.55 : 1)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(20)
        .background(Theme.surface).clipShape(RoundedRectangle(cornerRadius: 14))
        .padding(.top, 16)
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
        ScrollView {
            VStack(spacing: 16) {
                Text(finishPending ? "WAITING" : "SETS DONE")
                    .font(Theme.display(finishPending ? 64 : 58))
                    .foregroundStyle(Theme.done)
                Text(finishPending
                    ? "FINISH SAVED ON THIS DEVICE"
                    : "READY TO FINISH")
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
                Button { sync.jump(to: sync.exerciseIndex) } label: {
                    Text("Return to exercises").frame(minHeight: 44).contentShape(Rectangle())
                }
                .disabled(sync.hasPendingTerminalIntentForCurrentWorkout)

                Button {
                    guard let target = sync.terminalActionTarget else { return }
                    Task { await sync.finishResolvedWorkout(expected: target) }
                } label: {
                    Text(finishPending ? "WAITING TO SYNC" : "FINISH")
                        .font(Theme.display(24)).tracking(1.5)
                        .frame(maxWidth: .infinity).padding(.vertical, 16)
                }
                .background(Theme.accent).foregroundStyle(.black)
                .clipShape(RoundedRectangle(cornerRadius: 14))
                .padding(.top, 24)
                .disabled(
                    sync.hasPendingTerminalIntentForCurrentWorkout)
            }
            .padding(28)
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
