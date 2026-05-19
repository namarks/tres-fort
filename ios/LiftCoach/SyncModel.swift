import SwiftUI

@MainActor
final class SyncModel: ObservableObject {
    @Published var plan: PlanTree?
    @Published var sets: [SetLog] = []
    @Published var sessions: [SessionRow] = []
    /// Read-only ride overlay (intervals.icu etc). Already filtered to
    /// non-deleted events — the rest of the app never sees tombstones.
    @Published var rides: [ExternalEvent] = []
    @Published var catalog: [ExerciseCatalog] = []
    @Published var todaySession: SessionRow?
    @Published var selectedDayID: String?
    @Published var loadError: String?
    @Published var isLoading = false

    // Rest timer (local Live Activity arrives in milestone g).
    @Published var restEndDate: Date?
    @Published var restExercise: String = ""
    @Published var restTotal: Int = 0

    // Guided workout runner.
    @Published var running = false
    @Published var finished = false
    @Published var exerciseIndex = 0
    @Published var weight: Double = 0
    @Published var reps: Int = 0

    // Timers.
    @Published var workoutStart: Date?      // whole-session stopwatch
    @Published var timedActive = false      // a timed exercise is running
    @Published var timedEndDate: Date?
    private var setClock = Date()           // when the current set began

    private let api = APIClient()
    private unowned let auth: AuthModel

    init(auth: AuthModel) { self.auth = auth }

    var todayString: String {
        let f = DateFormatter()
        f.calendar = Calendar(identifier: .gregorian)
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = .current
        f.dateFormat = "yyyy-MM-dd"
        return f.string(from: Date())
    }

    var selectedDay: DayTemplate? {
        guard let plan else { return nil }
        return plan.days.first { $0.id == selectedDayID } ?? plan.days.first
    }

    func load() async {
        guard let jwt = auth.jwt else { return }
        isLoading = true
        defer { isLoading = false }
        do {
            let state = try await api.getState(jwt: jwt)
            plan = state.plan
            sets = state.sets
            sessions = state.sessions
            // Full reload every sync (getState uses events_since=0): the
            // server returns the full current non-deleted external_events
            // set, so this is a full replace, not a delta merge. No
            // client-side watermark/tombstone-merge is needed; we still
            // defensively drop any tombstoned events at the cache boundary
            // so glyphs, agenda, and conflict detection never see them.
            rides = state.external_events.filter { !$0.isDeleted }
            todaySession = state.sessions.first { $0.date == todayString }
            if selectedDayID == nil { selectedDayID = state.plan?.days.first?.id }
            if catalog.isEmpty {
                catalog = (try? await api.getExercises(jwt: jwt)) ?? []
            }
            loadError = nil
        } catch {
            handle(error)
        }
    }

    /// Live (non-deleted) working sets for an exercise.
    private func live(_ exerciseID: String) -> [SetLog] {
        sets.filter {
            $0.exercise_id == exerciseID && $0.is_warmup == 0 && $0.deleted_at == nil
        }
    }

    func lastWorkingSet(_ exerciseID: String) -> SetLog? {
        live(exerciseID).max { $0.logged_at < $1.logged_at }
    }

    func todaySets(_ exerciseID: String) -> [SetLog] {
        guard let sid = todaySession?.id else { return [] }
        return live(exerciseID)
            .filter { $0.session_id == sid }
            .sorted { $0.set_index < $1.set_index }
    }

    func exerciseName(_ id: String) -> String {
        catalog.first { $0.id == id }?.name ?? id
    }

    // MARK: history aggregation

    struct SessionStat: Identifiable {
        let id: String          // session id
        let date: String
        let est1RM: Double
        let topWeight: Double
        let topReps: Int
        let volume: Double
        let setCount: Int
        let avgDuration: Int
    }

    private func epley(_ w: Double, _ r: Int) -> Double { w * (1 + Double(r) / 30) }

    /// Exercise ids that have any logged set, most-recent first.
    var loggedExerciseIDs: [String] {
        let live = sets.filter { $0.is_warmup == 0 && $0.deleted_at == nil }
        let byId = Dictionary(grouping: live, by: \.exercise_id)
        return byId.keys.sorted {
            (byId[$0]?.map(\.logged_at).max() ?? 0) >
            (byId[$1]?.map(\.logged_at).max() ?? 0)
        }
    }

    func history(for exerciseID: String) -> [SessionStat] {
        let dateBySession = Dictionary(uniqueKeysWithValues: sessions.map { ($0.id, $0.date) })
        let grouped = Dictionary(grouping: live(exerciseID), by: \.session_id)
        return grouped.compactMap { sid, rows -> SessionStat? in
            guard let date = dateBySession[sid], !rows.isEmpty else { return nil }
            let top = rows.max { epley($0.weight, $0.reps) < epley($1.weight, $1.reps) }!
            let durs = rows.compactMap(\.duration_s)
            return SessionStat(
                id: sid, date: date,
                est1RM: epley(top.weight, top.reps).rounded(),
                topWeight: top.weight, topReps: top.reps,
                volume: rows.reduce(0) { $0 + $1.weight * Double($1.reps) },
                setCount: rows.count,
                avgDuration: durs.isEmpty ? 0 : durs.reduce(0, +) / durs.count)
        }
        .sorted { $0.date < $1.date }
    }

    func logSet(_ ex: TemplateExercise, weight: Double, reps: Int,
                durationOverride: Int? = nil) async {
        guard let jwt = auth.jwt else { return }
        let duration = durationOverride
            ?? max(0, Int(Date().timeIntervalSince(setClock)))
        do {
            if todaySession == nil {
                // Tie the lazily-created session to the day template the
                // runner is executing so the calendar/agenda resolve it as
                // that workout. `day_template_id` is part of the EXISTING
                // POST /api/sessions contract; getOrCreateSession is
                // idempotent per (user, date) — this is a one-off `sessions`
                // write, never a `plans.meta.schedule` mutation.
                todaySession = try await api.createSession(
                    date: todayString,
                    dayTemplateID: selectedDay?.id,
                    jwt: jwt)
            }
            guard let session = todaySession else { return }
            let nextIndex = todaySets(ex.exercise_id).count + 1
            let body: [String: Any] = [
                "id": UUID().uuidString,
                "exercise_id": ex.exercise_id,
                "set_index": nextIndex,
                "weight": weight,
                "reps": reps,
                "duration_s": duration,
            ]
            let res = try await api.logSet(sessionId: session.id, body: body, jwt: jwt)
            if !sets.contains(where: { $0.id == res.set.id }) { sets.append(res.set) }
            setClock = Date()
            startRest(seconds: ex.rest_seconds, name: ex.exercise_name)
        } catch {
            handle(error)
        }
    }

    // MARK: runner

    var exercises: [TemplateExercise] { selectedDay?.exercises ?? [] }
    var currentExercise: TemplateExercise? {
        exercises.indices.contains(exerciseIndex) ? exercises[exerciseIndex] : nil
    }
    /// 1-based number of the set about to be performed for the current exercise.
    var currentSetNumber: Int {
        guard let ex = currentExercise else { return 1 }
        return todaySets(ex.exercise_id).count + 1
    }

    func startWorkout() {
        running = true
        finished = false
        exerciseIndex = 0
        workoutStart = Date()
        seedInputs()
    }

    /// Seed weight/reps from last time → plan target → default. Resets the
    /// per-set clock (a new set begins on arrival at an exercise).
    private func seedInputs() {
        timedActive = false
        timedEndDate = nil
        setClock = Date()
        guard let ex = currentExercise else { return }
        let last = lastWorkingSet(ex.exercise_id)
        weight = last?.weight ?? ex.target_weight ?? 45
        reps = last?.reps ?? ex.target_reps
    }

    // MARK: timed exercises (plank, holds)

    func startTimedSet() {
        guard let ex = currentExercise, ex.isTimed else { return }
        setClock = Date()
        timedActive = true
        timedEndDate = Date().addingTimeInterval(TimeInterval(ex.target_reps))
    }

    /// End a timed set — `held` seconds actually performed (auto at 0, or
    /// early via STOP). Logs reps=held, duration=held.
    func finishTimedSet(held: Int) async {
        guard let ex = currentExercise, timedActive else { return }
        timedActive = false
        timedEndDate = nil
        await logSet(ex, weight: 0, reps: held, durationOverride: held)
        if isComplete(ex) {
            if let next = nextIncompleteIndex { jump(to: next) } else { finished = true }
        }
    }

    func adjustWeight(_ delta: Double) { weight = max(0, weight + delta) }
    func adjustReps(_ delta: Int) { reps = max(0, reps + delta) }

    func setsDone(_ ex: TemplateExercise) -> Int { todaySets(ex.exercise_id).count }
    func isComplete(_ ex: TemplateExercise) -> Bool { setsDone(ex) >= ex.target_sets }
    var allComplete: Bool { !exercises.isEmpty && exercises.allSatisfy { isComplete($0) } }

    /// First not-yet-complete exercise after the current one (wraps), so a
    /// completed lift never traps you and order is flexible.
    var nextIncompleteIndex: Int? {
        let n = exercises.count
        guard n > 0 else { return nil }
        for offset in 1...n {
            let i = (exerciseIndex + offset) % n
            if !isComplete(exercises[i]) { return i }
        }
        return nil
    }

    func jump(to index: Int) {
        guard exercises.indices.contains(index) else { return }
        exerciseIndex = index
        seedInputs()
    }

    func logCurrentSet() async {
        guard let ex = currentExercise else { return }
        await logSet(ex, weight: weight, reps: reps)   // also starts rest timer
        if isComplete(ex) {
            if let next = nextIncompleteIndex { jump(to: next) }
            else { finished = true }
        }
    }

    /// Manual "move on" — next exercise in order; falls back to any
    /// remaining work, else ends.
    func skip() {
        if exerciseIndex + 1 < exercises.count { jump(to: exerciseIndex + 1) }
        else if let next = nextIncompleteIndex { jump(to: next) }
        else { finished = true }
    }

    func previous() {
        guard exerciseIndex > 0 else { return }
        exerciseIndex -= 1
        seedInputs()
    }

    func finishWorkout() async {
        if let jwt = auth.jwt, let sid = todaySession?.id {
            todaySession = try? await api.completeSession(sessionId: sid, jwt: jwt)
        }
        running = false
        finished = false
        workoutStart = nil
        timedActive = false
        timedEndDate = nil
        skipRest()
        await load()
    }

    // MARK: rest timer

    /// Name of the next not-complete exercise (for the rest screen's UP NEXT).
    var upNextName: String {
        if let i = nextIncompleteIndex { return exercises[i].exercise_name }
        return "Done"
    }

    func removeSet(_ set: SetLog) async {
        guard let jwt = auth.jwt else { return }
        do {
            try await api.deleteSet(setId: set.id, jwt: jwt)
            sets.removeAll { $0.id == set.id }
        } catch { handle(error) }
    }

    func startRest(seconds: Int, name: String) {
        restExercise = name
        restTotal = seconds
        let end = Date().addingTimeInterval(TimeInterval(seconds))
        restEndDate = end
        RestLiveActivity.start(exercise: name, endDate: end, upNext: upNextName)
    }
    func addRest(_ seconds: Int) {
        guard let end = restEndDate else { return }
        let newEnd = end.addingTimeInterval(TimeInterval(seconds))
        restEndDate = newEnd
        RestLiveActivity.update(endDate: newEnd, upNext: upNextName)
    }
    func skipRest() {
        restEndDate = nil
        setClock = Date()   // next set begins when rest ends
        RestLiveActivity.endNow()
    }

    // MARK: calendar projection (read-only future calendar)

    /// Plan day_template ids (for dangling-schedule detection).
    var planTemplateIDs: Set<String> {
        Set(plan?.days.map(\.id) ?? [])
    }

    /// Real cached sessions keyed by YYYY-MM-DD. If multiple sessions share
    /// a date, prefer the most "advanced" one (completed > in_progress >
    /// planned > skipped) so the calendar shows the strongest signal.
    var sessionsByDate: [String: SessionRow] {
        func rank(_ s: String) -> Int {
            switch s {
            case "completed":   return 4
            case "in_progress": return 3
            case "planned":     return 2
            case "skipped":     return 1
            default:            return 0
            }
        }
        var out: [String: SessionRow] = [:]
        for s in sessions {
            if let cur = out[s.date], rank(cur.status) >= rank(s.status) { continue }
            out[s.date] = s
        }
        return out
    }

    /// Non-deleted external events for a `YYYY-MM-DD` date (read-only).
    func rides(on dateString: String) -> [ExternalEvent] {
        rides.filter { !$0.isDeleted && $0.date == dateString }
    }

    /// True if this calendar date carries a lift (real session OR a
    /// projected lift) — the precondition for any ride conflict.
    func dateHasLift(_ dateString: String) -> Bool {
        RideConflict.dateHasLift(projection(for: dateString))
    }

    /// Ride conflict severity for a date, mirroring the backend's
    /// `detectConflicts` byte-for-byte (see RideConflict).
    func rideConflict(for dateString: String) -> RideConflict.Severity {
        RideConflict.severity(
            forLiftDate: dateString,
            hasLift: { [self] in dateHasLift($0) },
            ridesOn: { [self] in rides(on: $0) })
    }

    /// Resolve one calendar day via the frozen projection algorithm,
    /// against an EXPLICITLY supplied `today`. Lets a caller that also
    /// needs the same `today` for a second decision (e.g. the
    /// `allowScheduleInference` gate in `dayLabel`) capture `todayString`
    /// ONCE and pass it here — eliminating the midnight TOCTOU where two
    /// separate `todayString` reads in one logical operation straddle the
    /// rollover and disagree. Same single algorithm; no forked logic.
    func projection(for dateString: String, today: String) -> DayProjection {
        CalendarProjection.project(
            dateString: dateString,
            today: today,
            sessionByDate: sessionsByDate,
            schedule: plan?.schedule,
            templateIDs: planTemplateIDs)
    }

    /// Resolve one calendar day via the frozen projection algorithm
    /// (convenience: reads `todayString` once for callers that don't
    /// need to share the clock with another decision).
    ///
    /// WARNING: reads todayString internally. Do NOT use at any call site
    /// that ALSO reads todayString separately (midnight TOCTOU) — use
    /// projection(for:today:) with a single captured clock there. Safe
    /// only when the result is used in isolation.
    func projection(for dateString: String) -> DayProjection {
        projection(for: dateString, today: todayString)
    }

    // MARK: schedule-driven Today

    /// Today's resolved projection — the SAME `projection(for:)` /
    /// `CalendarProjection` the calendar uses (single source of truth, no
    /// parallel resolution). Today screen reads this, not a manual default.
    ///
    /// Single-clock: `todayString` is a computed var (fresh `Date()` each
    /// access). It is read EXACTLY ONCE here and supplied as BOTH the date
    /// to resolve and the `today` reference, so the past/future split
    /// can't straddle midnight against itself (the convenience
    /// `projection(for:)` would otherwise read the clock a second time
    /// internally for `today:`).
    var todayProjection: DayProjection {
        let t = todayString
        return projection(for: t, today: t)
    }

    /// SINGLE definition of "is this raw session status a workout?" (i.e.
    /// not skipped / not a non-training terminal state). The ONLY place this
    /// rule is written on the iOS side.
    ///
    /// COUPLED TWIN — keep in lockstep with the `case "skipped": return
    /// .skipped` arm in the frozen, byte-for-byte `DayProjection.kind`
    /// status switch in `CalendarProjection.swift`. That `"skipped"` arm
    /// is the ONLY non-workout session state; every other status (incl.
    /// `default: return .planned` for unknowns) maps to a workout kind,
    /// which already agrees with this predicate returning `true` for
    /// anything but `"skipped"`. That file is the frozen projection
    /// contract and MUST NOT be edited, so the two sites cannot literally
    /// share one symbol; if a new NON-workout backend status (e.g.
    /// "cancelled"/"abandoned") is introduced, update BOTH this predicate
    /// AND that `"skipped"` arm of the `kind` switch.
    static func isWorkoutStatus(_ status: String) -> Bool {
        status != "skipped"
    }

    /// True when today's real session is already COMPLETED — Today renders
    /// a done/recap state with NO start/override path (the single
    /// session-per-(user,date) invariant means any "start" re-opens and
    /// double-logs the completed row; see `WorkoutDoneView`).
    var todayIsCompleted: Bool { todaySessionStatus == "completed" }

    /// The day template to DISPLAY for today when it's a workout — and
    /// the SINGLE authority for the Today workout-vs-rest split: non-nil
    /// ⇒ workout, nil ⇒ rest/skipped (callers use `todayResolvedDay !=
    /// nil` / its negation; there is no separate `todayIsWorkout` twin).
    /// A real session can BE a workout while its `day_template_id` is
    /// null (server-side `getOrCreateSession` ignores the passed template
    /// id for an existing same-date row). Fallback order so the workout
    /// still renders sensibly:
    ///   1. the session's own `day_template_id` (if populated), else
    ///   2. today's scheduled template (the SAME projection/schedule the
    ///      calendar uses — derived from `meta.schedule`, no fork), else
    ///   3. `selectedDay` (whatever the runner last targeted), else
    ///   4. the first plan day.
    /// Returns nil ONLY when today is genuinely not a workout.
    var todayResolvedDay: DayTemplate? {
        // Single-clock: capture `todayString` ONCE and derive the
        // projection ONCE from it, instead of touching the computed clock
        // multiple times (workout test + template switch +
        // `sessionDisplayTemplate(todayString)`). At a midnight rollover
        // those independent reads could otherwise resolve against
        // different civil days within this one property evaluation (the
        // workout-guard sees day N, the template switch day N+1, etc.).
        let today = todayString
        let proj = projection(for: today, today: today)
        // The workout-vs-rest test, evaluated ONCE against the SAME local
        // projection. This is the ONLY copy of this switch (no separate
        // `todayIsWorkout` property) — it still delegates to the single
        // `isWorkoutStatus` predicate, mirroring the projection's
        // `.skipped`-aware semantics, no forked logic.
        let isWorkout: Bool
        switch proj {
        case .projected:      isWorkout = true
        case .session(let s): isWorkout = Self.isWorkoutStatus(s)
        case .rest, .none:    isWorkout = false
        }
        guard isWorkout else { return nil }
        switch proj {
        case .projected(let tid):
            // Schedule projection: the template id IS the schedule's.
            return dayTemplate(id: tid) ?? selectedDay ?? plan?.days.first
        case .session:
            // Real workout-status session. Shared session→schedule
            // inference, then selected/first so Today always has something
            // to render. `allowScheduleInference: true` is passed
            // EXPLICITLY (matching the documented caller convention) so
            // the intent — today MUST schedule-infer its null-template
            // session (the BLOCKER fix) — is visible and a future
            // refactor of the default can't silently mis-gate it. The
            // captured `today` is by definition `todayString`, so the
            // resolver's `ymd >= today` boundary holds.
            return sessionDisplayTemplate(forDateString: today,
                                          allowScheduleInference: true)
                ?? selectedDay ?? plan?.days.first
        case .rest, .none:
            return nil   // unreachable (guarded by isWorkout)
        }
    }

    /// Raw status of today's real session, if any (for the Today header /
    /// CTA wording — e.g. "completed" vs "in_progress"). nil ⇒ no real
    /// session today (pure schedule projection or rest).
    var todaySessionStatus: String? {
        if case .session(let s) = todayProjection { return s }
        return nil
    }

    /// The day template the WEEKLY SCHEDULE assigns to `ymd` (the same
    /// `meta.schedule` + civil-weekday lookup `CalendarProjection` uses —
    /// the ONE place this fallback is written). Used to recover a sensible
    /// template/label when a real session row carries a null
    /// `day_template_id` (server `getOrCreateSession` drops it for an
    /// existing same-date row). Read-only — never writes the schedule.
    func scheduledTemplate(forDateString ymd: String) -> DayTemplate? {
        guard let key = CalendarProjection.weekdayKey(forDateString: ymd),
              let tid = plan?.schedule?.templateID(forWeekdayKey: key)
        else { return nil }
        return dayTemplate(id: tid)
    }

    /// The template to DISPLAY for a real session on `ymd`, regardless of
    /// whether its `day_template_id` is populated: session's own id →
    /// scheduled-by-weekday fallback. No `selectedDay`/first-day fallback
    /// here (callers that need a guaranteed non-nil add their own). Shared
    /// by Today and the calendar's `dayLabel` so the inference is identical.
    ///
    /// `allowScheduleInference` (default `true`) gates ONLY the
    /// schedule-by-weekday fallback (step 2). The session's own
    /// `day_template_id` (step 1) is ALWAYS honoured. Pass `false` for
    /// HISTORICAL dates: the *current* `meta.schedule` must not relabel a
    /// past completed session (a schedule edit would otherwise rewrite its
    /// A/B), so a null-`day_template_id` past session resolves to nil
    /// (glyph-only, no possibly-wrong label) rather than today's mapping.
    /// `true` is REQUIRED for today/future (the BLOCKER fix:
    /// `todayResolvedDay` must still infer today's template) — the valid
    /// inference window is exactly `ymd >= today`, the same civil-date
    /// boundary `CalendarProjection.project` uses (`dateString < today`),
    /// not a forked date rule. Callers pass `ymd >= todayString`.
    func sessionDisplayTemplate(forDateString ymd: String,
                                allowScheduleInference: Bool = true) -> DayTemplate? {
        if let day = dayTemplate(id: sessionsByDate[ymd]?.day_template_id) {
            return day
        }
        guard allowScheduleInference else { return nil }
        return scheduledTemplate(forDateString: ymd)
    }

    /// The next upcoming workout, found by forward-scanning the SAME
    /// projection used by the calendar (no second algorithm). Starts at
    /// tomorrow, walks up to `maxDays` civil days, and returns the FIRST
    /// date whose resolved state is a workout (a weekly-schedule projection
    /// OR a real planned/in_progress session — `.skipped` does not count).
    ///
    /// `day` is OPTIONAL: when the resolved template isn't in the local
    /// cache we still return THAT date (with `day == nil`) rather than
    /// skipping ahead to a wrong, later "next workout". The view renders
    /// the date/label without exercise detail.
    struct NextWorkout { let dateString: String; let day: DayTemplate? }

    func nextWorkout(within maxDays: Int = 14) -> NextWorkout? {
        // Single-clock: capture `todayString` ONCE (it's a computed var,
        // fresh `Date()` per access) for BOTH the `start` anchor and every
        // per-offset `projection(for:today:)` in the loop. Without this,
        // `projection(for: ymd)` re-read the clock each iteration; while
        // that was correctness-safe here (all `ymd` are strictly future,
        // so `allowScheduleInference: true` stays valid even post-
        // rollover), the prior comment overstated it — only the
        // start/`ymd` GENERATION was TOCTOU-free, not the projection call.
        // Now the whole scan runs off one clock.
        let today = todayString
        guard maxDays > 0,
              let start = CalendarProjection.date(from: today) else { return nil }
        for offset in 1...maxDays {
            guard let d = CalendarProjection.calendar
                .date(byAdding: .day, value: offset, to: start) else { continue }
            let ymd = CalendarProjection.dateString(d)
            switch projection(for: ymd, today: today) {
            case .projected(let tid):
                // Real next workout — return THIS date even if the
                // template isn't cached (day == nil), never skip past it.
                return NextWorkout(dateString: ymd, day: dayTemplate(id: tid))
            case .session(let status):
                if status == "planned" || status == "in_progress" {
                    // Use the SHARED session→schedule resolver (the same one
                    // Today/calendar use), not a bare day_template_id read:
                    // a real planned/in_progress session with a null
                    // day_template_id (server drops it for an existing
                    // same-date row) still resolves its template via the
                    // weekly schedule. `ymd` is strictly in the future
                    // here (offset 1...maxDays off the single `start`
                    // anchor, which derives from the one `today` capture),
                    // so `allowScheduleInference` is unconditionally
                    // valid; passed EXPLICITLY to match the documented
                    // caller convention. Stays nil-graceful for genuinely
                    // unresolvable days.
                    return NextWorkout(
                        dateString: ymd,
                        day: sessionDisplayTemplate(forDateString: ymd,
                                                    allowScheduleInference: true))
                }
                // A COMPLETED future session (e.g. pre-logged via MCP) is
                // intentionally NOT surfaced as the "next workout" — it's
                // already done. The calendar still shows it as completed;
                // "next workout" means the next thing left to DO. Skipped
                // is likewise not upcoming.
                continue
            case .rest, .none:
                continue
            }
        }
        return nil
    }

    /// Friendly relative label for an upcoming `YYYY-MM-DD`:
    /// "Tomorrow", a weekday name ("Wed") within the week, else a date.
    func relativeLabel(for ymd: String) -> String {
        guard let target = CalendarProjection.date(from: ymd),
              let today = CalendarProjection.date(from: todayString) else { return ymd }
        let days = CalendarProjection.calendar
            .dateComponents([.day], from: today, to: target).day ?? 0
        if days == 1 { return "Tomorrow" }
        if days >= 2 && days <= 6 {
            let f = DateFormatter()
            f.calendar = CalendarProjection.calendar
            f.locale = Locale(identifier: "en_US_POSIX")
            f.dateFormat = "EEEE"
            return f.string(from: target)
        }
        let f = DateFormatter()
        f.calendar = CalendarProjection.calendar
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "EEE d MMM"
        return f.string(from: target)
    }

    /// Start the guided workout for the template TODAY resolves to (via
    /// `todayResolvedDay`, i.e. the SAME CalendarProjection the calendar
    /// uses). Reuses the EXISTING session-start path verbatim.
    func startToday() {
        if let id = todayResolvedDay?.id { selectedDayID = id }
        startWorkout()
    }

    /// Start a guided workout for an explicitly chosen day template — the
    /// "train a different day" OVERRIDE. Reuses the EXISTING session-start
    /// path verbatim (set `selectedDayID`, then `startWorkout()`); the
    /// session row is created lazily on the first logged set. This is a
    /// one-off `sessions` write only — it never touches `plans.meta.schedule`.
    func startOverride(dayID: String) {
        selectedDayID = dayID
        startWorkout()
    }

    /// Plan day for a template id (agenda exercise targets).
    func dayTemplate(id: String?) -> DayTemplate? {
        guard let id else { return nil }
        return plan?.days.first { $0.id == id }
    }

    /// Logged working + warmup sets for a session (agenda "completed").
    func setsForSession(_ sessionID: String) -> [SetLog] {
        sets.filter { $0.session_id == sessionID && $0.deleted_at == nil }
            .sorted {
                $0.exercise_id == $1.exercise_id
                    ? $0.set_index < $1.set_index
                    : $0.logged_at < $1.logged_at
            }
    }

    private func handle(_ error: Error) {
        if case let APIError.http(code, _) = error, code == 401 {
            auth.invalidate()
        } else {
            loadError = error.localizedDescription
        }
    }
}
