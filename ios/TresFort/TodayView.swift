import SwiftUI

private func fmt(_ w: Double) -> String {
    w.rounded() == w ? String(Int(w)) : String(format: "%.1f", w)
}
private func clock(_ s: Int) -> String {
    s <= 0 ? "GO" : String(format: "%d:%02d", s / 60, s % 60)
}

struct TodayView: View {
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
    /// Rest overlay collapsed to a floating pill so the runner underneath
    /// (current exercise, jump strip, completed sets) is visible/scrollable
    /// without ending the rest timer. Reset whenever `restEndDate` clears so
    /// the next rest starts in the expanded state.
    @State private var restMinimized = false

    var body: some View {
        NavigationStack {
            ZStack(alignment: .top) {
                Theme.background
                content
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
                ToolbarItem(placement: .topBarTrailing) {
                    Menu {
                        Button("Refresh") { Task { await sync.load() } }
                        if let onLogActivity {
                            // M5: log Pilates/walk/etc. from the Today
                            // toolbar — the natural moment-of-truth for "I
                            // just did this". Same sheet as the Group tab's
                            // FAB; both call groupModel.logActivity.
                            Button {
                                onLogActivity()
                            } label: {
                                Label("Log activity", systemImage: "plus.circle")
                            }
                        }
                        if sync.running {
                            Button("End workout", role: .destructive) {
                                Task { await sync.finishWorkout() }
                            }
                            Button("Discard workout", role: .destructive) {
                                showDiscardConfirm = true
                            }
                        }
                        Button("Sign out", role: .destructive) { auth.signOut() }
                    } label: { Image(systemName: "ellipsis.circle").foregroundStyle(Theme.muted) }
                }
            }
            .toolbarColorScheme(.dark, for: .navigationBar)
            .confirmationDialog(
                "Train a different day",
                isPresented: $showOverridePicker,
                titleVisibility: .visible
            ) {
                ForEach(sync.plan?.days ?? []) { d in
                    Button(d.title) { sync.startOverride(dayID: d.id) }
                }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("Starts a one-off session. Your weekly schedule is unchanged — ask Claude to edit the schedule.")
            }
            .confirmationDialog(
                "Discard this workout?",
                isPresented: $showDiscardConfirm,
                titleVisibility: .visible
            ) {
                Button("Discard — don't save", role: .destructive) {
                    Task { await sync.discardWorkout() }
                }
                Button("Keep workout", role: .cancel) {}
            } message: {
                Text("The sets you logged will be deleted and this session won't count. The day goes back to its normal schedule. This can't be undone.")
            }
        }
        .preferredColorScheme(.dark)
    }

    @ViewBuilder private var content: some View {
        if sync.isLoading && sync.plan == nil {
            ProgressView().tint(Theme.accent)
        } else if sync.finished {
            FinishedView(sync: sync)
        } else if sync.running {
            RunnerView(sync: sync)
        } else if sync.plan == nil {
            VStack(spacing: 8) {
                Text("NO PLAN YET").font(Theme.display(28)).foregroundStyle(Theme.text)
                Text("Ask Claude to build one, then pull to refresh.")
                    .font(Theme.mono(13)).foregroundStyle(Theme.muted)
            }
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
                sync: sync, day: day,
                onOverride: { showOverridePicker = true })
        } else {
            // Pure rest day (or skipped) — no primary START CTA.
            RestDayView(
                sync: sync,
                onOverride: { showOverridePicker = true })
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
            StartWorkoutCTA(onOverride: onOverride)
                .padding(16)
                .disabled(sync.plan?.days.isEmpty ?? true)
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
                        .foregroundStyle(Theme.dim)
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
                        .foregroundStyle(Theme.dim)
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
                    let n = todaySets.count
                    if n > 0 {
                        // Unilateral exercises log reps per-side; double them
                        // so 45×8 Bulgarian split squat reads 16 reps / 720 lb.
                        let reps = todaySets.reduce(0) {
                            $0 + $1.reps * sync.sides(for: $1.exercise_id)
                        }
                        let vol = todaySets.reduce(0.0) {
                            $0 + $1.weight * Double($1.reps * sync.sides(for: $1.exercise_id))
                        }
                        Text("✓ \(n) SET\(n == 1 ? "" : "S") · \(reps) REPS · \(Int(vol)) LB")
                            .font(Theme.mono(12, .bold)).tracking(1)
                            .foregroundStyle(Theme.muted)
                            .padding(.top, 2)
                    } else {
                        Text("✓ DONE — LOGGED TO YOUR COACH")
                            .font(Theme.mono(12, .bold)).tracking(1)
                            .foregroundStyle(Theme.muted)
                            .padding(.top, 2)
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
                    showDiscardConfirm = true
                } label: {
                    Text("Discard — didn't really do this")
                        .font(Theme.mono(12, .bold)).tracking(1)
                        .foregroundStyle(Theme.danger)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 14)
                }
                .buttonStyle(.plain)
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
                Task { await sync.discardWorkout() }
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
    let day: DayTemplate
    let onOverride: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 10) {
                    Text("TODAY · \(day.title.uppercased())")
                        .font(Theme.mono(11, .bold)).tracking(2)
                        .foregroundStyle(Theme.muted).padding(.bottom, 6)
                    ForEach(day.exercises) { ex in
                        HStack {
                            Text(ex.exercise_name.uppercased())
                                .font(Theme.display(22)).foregroundStyle(Theme.text)
                            Spacer()
                            Text(ex.targetLabel)
                                .font(Theme.mono(14)).foregroundStyle(Theme.muted)
                        }
                        .padding(16)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(Theme.surface)
                        .clipShape(RoundedRectangle(cornerRadius: 14))
                    }
                    if let err = sync.loadError {
                        Text(err).font(Theme.mono(12)).foregroundStyle(Theme.danger)
                    }
                    OverrideButton(onOverride: onOverride).padding(.top, 6)
                }
                .padding(16)
            }
            .refreshable { await sync.load() }

            Button { sync.startToday() } label: {
                Text("START WORKOUT")
                    .font(Theme.display(26)).tracking(1.5)
                    .frame(maxWidth: .infinity).padding(.vertical, 18)
            }
            .background(Theme.accent).foregroundStyle(.black)
            .clipShape(RoundedRectangle(cornerRadius: 14))
            .shadow(color: Theme.accent.opacity(0.35), radius: 18, y: 8)
            .disabled(day.exercises.isEmpty)
            .padding(16)
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
    var body: some View {
        Button(action: onOverride) {
            Text("START A WORKOUT")
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
    var body: some View {
        Button(action: onOverride) {
            HStack(spacing: 6) {
                Text("Train a different day")
                    .font(Theme.mono(13, .bold))
                Image(systemName: "chevron.right").font(.system(size: 11, weight: .bold))
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
                    let ratio = min(1, Double(sync.setsDone(ex)) / Double(max(1, ex.target_sets)))
                    let complete = sync.isComplete(ex)
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
    @ObservedObject var sync: SyncModel

    /// Tap-to-edit on the big weight number → decimal-pad sheet. Persists
    /// the in-flight edit string (`""` while the sheet is open and the user
    /// has cleared the field — TextField needs a Binding, not a transient
    /// value) so a partially-typed entry isn't lost on a re-render.
    @State private var editingWeight = false
    @State private var weightDraft = ""

    var body: some View {
        if let ex = sync.currentExercise {
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    if let ws = sync.workoutStart {
                        TimelineView(.periodic(from: .now, by: 1)) { ctx in
                            let e = max(0, Int(ctx.date.timeIntervalSince(ws)))
                            Text("WORKOUT  \(e / 60):\(String(format: "%02d", e % 60))")
                                .font(Theme.mono(11, .bold)).tracking(2)
                                .foregroundStyle(Theme.muted)
                        }
                        .padding(.bottom, 12)
                    }

                    ProgressBar(exercises: sync.exercises,
                                currentIndex: sync.exerciseIndex, sync: sync)
                        .padding(.bottom, 22)

                    // Fixed-height single line so switching exercises with
                    // longer names never reflows the layout below.
                    Text(ex.exercise_name.uppercased())
                        .font(Theme.display(52)).foregroundStyle(Theme.text)
                        .lineLimit(1).minimumScaleFactor(0.4)
                        .frame(height: 56, alignment: .leading)
                        .frame(maxWidth: .infinity, alignment: .leading)

                    HStack {
                        let complete = sync.isComplete(ex)
                        meta("SET", "\(min(sync.currentSetNumber, ex.target_sets))",
                             complete ? "OF \(ex.target_sets) ✓" : "OF \(ex.target_sets)")
                        Spacer()
                        meta("TARGET", ex.targetLabel, "")
                        Spacer()
                        meta("REST", "\(ex.rest_seconds)s", "")
                    }
                    .padding(.top, 12)

                    jumpStrip(ex: ex)

                    if ex.isTimed {
                        TimedSetView(sync: sync, ex: ex)
                    } else {
                        if !ex.isBodyweight {
                            // Two-dumbbell lifts: the number is one dumbbell, so
                            // label it "EACH HAND" rather than implying a total.
                            let weightLabel = ex.isPerHand
                                ? "WEIGHT (\(ex.exercise_unit)) · EACH HAND · TAP TO EDIT"
                                : "WEIGHT (\(ex.exercise_unit)) · TAP TO EDIT"
                            stepper(label: weightLabel, value: fmt(sync.weight),
                                    steps: [("−10", { sync.adjustWeight(-10) }, true),
                                            ("−5", { sync.adjustWeight(-5) }, false),
                                            ("+5", { sync.adjustWeight(5) }, false),
                                            ("+10", { sync.adjustWeight(10) }, true)],
                                    onTapValue: {
                                        weightDraft = fmt(sync.weight)
                                        editingWeight = true
                                    })
                        }
                        stepper(label: "REPS", value: "\(sync.reps)",
                                steps: [("−1", { sync.adjustReps(-1) }, false),
                                        ("+1", { sync.adjustReps(1) }, false)])

                        Button { Task { await sync.logCurrentSet() } } label: {
                            Text("LOG SET \(sync.currentSetNumber)")
                                .font(Theme.display(26)).tracking(1.2)
                                .frame(maxWidth: .infinity).padding(.vertical, 18)
                        }
                        .background(Theme.accent).foregroundStyle(.black)
                        .clipShape(RoundedRectangle(cornerRadius: 14))
                        .shadow(color: Theme.accent.opacity(0.35), radius: 18, y: 8)
                        .padding(.top, 18)
                    }

                    completedChips(ex: ex)

                    HStack {
                        navBtn("← PREV") { sync.previous() }
                            .disabled(sync.exerciseIndex == 0)
                        Text("\(sync.exerciseIndex + 1) / \(sync.exercises.count)")
                            .font(Theme.mono(11)).tracking(1.5).foregroundStyle(Theme.muted)
                            .frame(maxWidth: .infinity)
                        navBtn("SKIP →") { sync.skip() }
                    }
                    .padding(.top, 24)
                }
                .padding(20)
            }
            .sheet(isPresented: $editingWeight) {
                WeightEditorSheet(
                    draft: $weightDraft,
                    unit: ex.exercise_unit,
                    onSave: {
                        // Trim and parse — empty / non-numeric drafts cancel
                        // silently rather than zeroing the working weight.
                        let trimmed = weightDraft.trimmingCharacters(in: .whitespaces)
                        if let v = Double(trimmed) { sync.setWeight(v) }
                        editingWeight = false
                    },
                    onCancel: { editingWeight = false }
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
                    Button { sync.jump(to: i) } label: {
                        Text(e.exercise_name)
                            .font(Theme.mono(11, .bold))
                            .strikethrough(skipped, color: Theme.muted)
                            .padding(.horizontal, 12).padding(.vertical, 8)
                            .background(cur ? Theme.accent : Theme.surface)
                            .foregroundStyle(cur ? .black : (done ? Theme.done : (skipped ? Theme.muted.opacity(0.5) : Theme.muted)))
                            .clipShape(RoundedRectangle(cornerRadius: 8))
                            .overlay(RoundedRectangle(cornerRadius: 8)
                                .stroke(done && !cur ? Theme.done.opacity(0.3) : .clear))
                    }
                }
            }
        }
        .padding(.top, 16)
    }

    private func stepper(label: String, value: String,
                         steps: [(String, () -> Void, Bool)],
                         onTapValue: (() -> Void)? = nil) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(label).font(Theme.mono(10, .bold)).tracking(2).foregroundStyle(Theme.muted)
            HStack(spacing: 8) {
                ForEach(Array(steps.prefix(steps.count / 2)), id: \.0) { s in
                    stepBtn(s.0, s.2, s.1)
                }
                // JetBrains Mono is fixed-width: every value is the same
                // size in a fixed-height slot (no digit jitter).
                // The whole slot is one tap target when `onTapValue` is set
                // (decimal-pad entry for weird-increment machines), with a
                // dotted underline as the hint. plain buttonStyle so the
                // number doesn't tint accent on press.
                Group {
                    if let onTapValue {
                        Button(action: onTapValue) {
                            Text(value)
                                .font(Theme.number(52))
                                .foregroundStyle(Theme.text)
                                .lineLimit(1).minimumScaleFactor(0.5)
                                .frame(maxWidth: .infinity)
                                .frame(height: 56)
                                .overlay(alignment: .bottom) {
                                    Rectangle()
                                        .fill(Theme.muted.opacity(0.35))
                                        .frame(height: 1)
                                        .padding(.horizontal, 8)
                                }
                        }
                        .buttonStyle(.plain)
                    } else {
                        Text(value)
                            .font(Theme.number(52))
                            .foregroundStyle(Theme.text)
                            .lineLimit(1).minimumScaleFactor(0.5)
                            .frame(maxWidth: .infinity)
                            .frame(height: 56)
                    }
                }
                ForEach(Array(steps.suffix(steps.count - steps.count / 2)), id: \.0) { s in
                    stepBtn(s.0, s.2, s.1)
                }
            }
        }
        .padding(16)
        .background(Theme.surface).clipShape(RoundedRectangle(cornerRadius: 14))
        .padding(.top, 16)
    }

    private func stepBtn(_ t: String, _ lg: Bool, _ a: @escaping () -> Void) -> some View {
        Button(action: a) {
            Text(t).font(Theme.mono(15, .bold))
                .frame(width: lg ? 60 : 54, height: 50)
                .background(Theme.surface2).foregroundStyle(Theme.text)
                .clipShape(RoundedRectangle(cornerRadius: 10))
        }
    }

    private func completedChips(ex: TemplateExercise) -> some View {
        let done = sync.todaySets(ex.exercise_id)
        return VStack(alignment: .leading, spacing: 10) {
            Text("COMPLETED SETS").font(Theme.mono(10, .bold)).tracking(2)
                .foregroundStyle(Theme.muted)
            if done.isEmpty {
                Text("No sets logged yet").font(Theme.mono(12)).italic()
                    .foregroundStyle(Theme.dim)
            } else {
                FlowChips(sets: done, timed: ex.isTimed, bodyweight: ex.isBodyweight) { s in Task { await sync.removeSet(s) } }
            }
        }
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
    let onSave: () -> Void
    let onCancel: () -> Void

    @FocusState private var focused: Bool

    var body: some View {
        NavigationStack {
            VStack(spacing: 20) {
                Text("WEIGHT (\(unit))")
                    .font(Theme.mono(11, .bold)).tracking(2)
                    .foregroundStyle(Theme.muted)
                    .padding(.top, 8)
                TextField("0", text: $draft)
                    .keyboardType(.decimalPad)
                    .multilineTextAlignment(.center)
                    .font(Theme.number(56))
                    .foregroundStyle(Theme.text)
                    .padding(.horizontal, 20).padding(.vertical, 14)
                    .background(Theme.surface)
                    .clipShape(RoundedRectangle(cornerRadius: 14))
                    .focused($focused)
                Text("Any value — \(unit) (e.g. 14.3)")
                    .font(Theme.mono(11)).foregroundStyle(Theme.dim)
                Spacer()
            }
            .padding(20)
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
        .presentationDetents([.height(280)])
        .presentationDragIndicator(.visible)
        .preferredColorScheme(.dark)
        .onAppear { focused = true }
    }
}

private struct FlowChips: View {
    let sets: [SetLog]
    let timed: Bool
    let bodyweight: Bool
    let onRemove: (SetLog) -> Void
    var body: some View {
        let cols = [GridItem(.adaptive(minimum: 110), spacing: 8)]
        LazyVGrid(columns: cols, alignment: .leading, spacing: 8) {
            ForEach(Array(sets.enumerated()), id: \.element.id) { i, s in
                HStack(spacing: 8) {
                    Text(String(format: "%02d", i + 1))
                        .font(Theme.mono(10)).foregroundStyle(Theme.dim)
                    Text(s.valueLabel(timed: timed, bodyweight: bodyweight))
                        .font(Theme.mono(13)).foregroundStyle(Theme.text)
                    Button { onRemove(s) } label: {
                        Image(systemName: "xmark").font(.system(size: 10))
                            .foregroundStyle(Theme.dim)
                    }
                }
                .padding(.horizontal, 12).padding(.vertical, 10)
                .background(Theme.surface).clipShape(RoundedRectangle(cornerRadius: 10))
            }
        }
    }
}

// MARK: - Timed set (plank, holds)

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
                }
            } else {
                Text("\(ex.holdSeconds)s")
                    .font(Theme.number(64))
                    .foregroundStyle(Theme.text)
            }

            if sync.timedActive {
                Button {
                    let held: Int = {
                        guard let end = sync.timedEndDate else { return ex.holdSeconds }
                        let left = max(0, Int(ceil(end.timeIntervalSince(Date()))))
                        return max(1, ex.holdSeconds - left)
                    }()
                    Task { await sync.finishTimedSet(held: held) }
                } label: {
                    Text("STOP & LOG").font(Theme.display(24)).tracking(1.2)
                        .frame(maxWidth: .infinity).padding(.vertical, 16)
                }
                .background(Theme.surface2).foregroundStyle(Theme.text)
                .clipShape(RoundedRectangle(cornerRadius: 14))
            } else {
                Button { sync.startTimedSet() } label: {
                    Text("START SET \(sync.currentSetNumber)")
                        .font(Theme.display(24)).tracking(1.2)
                        .frame(maxWidth: .infinity).padding(.vertical, 16)
                }
                .background(Theme.accent).foregroundStyle(.black)
                .clipShape(RoundedRectangle(cornerRadius: 14))
                .shadow(color: Theme.accent.opacity(0.35), radius: 18, y: 8)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(20)
        .background(Theme.surface).clipShape(RoundedRectangle(cornerRadius: 14))
        .padding(.top, 16)
        // Auto-log when the prescribed hold elapses (cancelled if STOPped).
        .task(id: sync.timedActive) {
            guard sync.timedActive else { return }
            let secs = ex.holdSeconds
            try? await Task.sleep(nanoseconds: UInt64(max(0, secs)) * 1_000_000_000)
            if sync.timedActive { await sync.finishTimedSet(held: secs) }
        }
    }
}

// MARK: - Rest overlay (full screen)

private struct RestOverlay: View {
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
                Theme.bg.opacity(0.96).ignoresSafeArea()
                VStack(spacing: 0) {
                    Text("REST").font(Theme.mono(11, .bold)).tracking(4)
                        .foregroundStyle(Theme.muted).padding(.bottom, 8)
                    Text(clock(remaining))
                        .font(Theme.display(140))
                        .foregroundStyle(remaining <= 0 ? Theme.done : Theme.accent)
                        .shadow(color: (remaining <= 0 ? Theme.done : Theme.accent).opacity(0.4),
                                radius: 30)
                        .opacity(remaining <= 0 ? (Int(ctx.date.timeIntervalSince1970 * 2) % 2 == 0 ? 1 : 0.4) : 1)

                    RoundedRectangle(cornerRadius: 3).fill(Theme.surface)
                        .frame(width: 240, height: 6)
                        .overlay(alignment: .leading) {
                            RoundedRectangle(cornerRadius: 3).fill(Theme.accent)
                                .frame(width: 240 * frac, height: 6)
                        }
                        .padding(.top, 24)

                    HStack(spacing: 12) {
                        restBtn("−15s") { sync.addRest(-15) }
                        restBtn("+15s") { sync.addRest(15) }
                        restBtn("DONE", primary: true) { sync.skipRest() }
                    }
                    .padding(.top, 36)

                    VStack(spacing: 4) {
                        Text("UP NEXT").font(Theme.mono(11, .bold)).tracking(2)
                            .foregroundStyle(Theme.muted)
                        Text(sync.currentExercise?.exercise_name.uppercased() ?? "DONE")
                            .font(Theme.display(22)).foregroundStyle(Theme.text)
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
                        .background(Capsule().fill(Theme.surface))
                    }
                    .padding(.top, 36)
                }
            }
            // Swipe-down anywhere on the overlay minimizes (matches the
            // sheet-dismissal idiom). Threshold high enough not to fight the
            // button taps above.
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 30)
                    .onEnded { v in
                        if v.translation.height > 60 { onMinimize() }
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
                .background(Capsule().fill(Theme.surface))
                .overlay(Capsule().stroke(color.opacity(0.5), lineWidth: 1))
                .shadow(color: .black.opacity(0.45), radius: 12, y: 4)
            }
            .buttonStyle(.plain)
            .padding(.top, 6)
        }
    }
}

// MARK: - Finished

private struct FinishedView: View {
    @ObservedObject var sync: SyncModel

    private var todaysSets: [SetLog] {
        sync.exercises.flatMap { sync.todaySets($0.exercise_id) }
    }

    var body: some View {
        ScrollView {
            VStack(spacing: 16) {
                Text("DONE").font(Theme.display(88))
                    .foregroundStyle(Theme.done)
                Text("LOGGED TO YOUR COACH").font(Theme.mono(11, .bold)).tracking(2)
                    .foregroundStyle(Theme.muted)

                let sets = todaysSets
                // Match the WorkoutDoneView rollup: unilateral reps & volume
                // are doubled (45×8 Bulgarian split squat → 16 reps / 720 lb).
                let reps = sets.reduce(0) {
                    $0 + $1.reps * sync.sides(for: $1.exercise_id)
                }
                let vol = sets.reduce(0.0) {
                    $0 + $1.weight * Double($1.reps * sync.sides(for: $1.exercise_id))
                }
                VStack(spacing: 0) {
                    sumRow("Sets logged", "\(sets.count)")
                    sumRow("Total reps", "\(reps)")
                    sumRow("Total volume", "\(Int(vol)) lb")
                }
                .padding(.top, 20)

                Button { Task { await sync.finishWorkout() } } label: {
                    Text("FINISH").font(Theme.display(24)).tracking(1.5)
                        .frame(maxWidth: .infinity).padding(.vertical, 16)
                }
                .background(Theme.accent).foregroundStyle(.black)
                .clipShape(RoundedRectangle(cornerRadius: 14))
                .padding(.top, 24)
            }
            .padding(28)
        }
    }

    private func sumRow(_ a: String, _ b: String) -> some View {
        HStack {
            Text(a).font(Theme.mono(13)).foregroundStyle(Theme.text)
            Spacer()
            Text(b).font(Theme.mono(13)).foregroundStyle(Theme.muted)
        }
        .padding(.vertical, 12)
        .overlay(alignment: .bottom) { Divider().overlay(Theme.surface2) }
    }
}
