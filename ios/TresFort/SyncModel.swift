import SwiftUI

@MainActor
final class SyncModel: ObservableObject {
    @Published var plan: PlanTree?
    @Published var sets: [SetLog] = []
    @Published var sessions: [SessionRow] = []
    /// Read-only ride overlay (intervals.icu etc). Already filtered to
    /// non-deleted events — the rest of the app never sees tombstones.
    @Published var rides: [ExternalEvent] = []
    /// Read-only COMPLETED endurance activities (intervals.icu actuals),
    /// shown as "workouts completed". Already filtered to non-deleted.
    @Published var activities: [ExternalActivity] = []
    /// User-authored manual activities (Pilates / walk / "lift elsewhere"
    /// …) logged from the app or MCP. Personal log — surfaces on the
    /// calendar regardless of group membership. Already filtered to
    /// non-deleted at the cache boundary.
    @Published var manualActivities: [ActivityRow] = []
    @Published var catalog: [ExerciseCatalog] = []
    @Published var todaySession: SessionRow?
    @Published var selectedDayID: String?
    @Published var loadError: String?
    @Published var isLoading = false
    /// Durable set intents are separate from acknowledged `sets`. Publishing
    /// the account queue makes relaunch state visible on Today even when the
    /// workout runner is not mounted.
    @Published private(set) var setOutbox: SetOutbox
    /// Finish/discard intents share the same account boundary as set intents.
    /// An acknowledged discard remains here as a local barrier until the user
    /// explicitly starts that date again.
    @Published private(set) var terminalOutbox: WorkoutTerminalOutbox
    @Published private(set) var sendingSetIntentIDs: Set<String> = []
    @Published private(set) var setSlotsInFlight: Set<String> = []
    @Published private(set) var isTerminalMutationInFlight = false

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
    /// PLAN SLOT ids (template_exercise_id) the user explicitly skipped this
    /// session. Keyed by slot, not exercise_id, to match the slot-keyed
    /// completion path: the same movement in two slots skips independently
    /// (#3). A skip is honored for the rest of the workout — the slot is NOT
    /// requeued. In-memory + per-session: cleared on startWorkout; logging a
    /// set for a skipped slot un-skips it (you came back and did it).
    @Published var skipped: Set<String> = []

    // Timers.
    @Published var workoutStart: Date?      // whole-session stopwatch
    @Published var timedActive = false      // a timed exercise is running
    @Published var timedEndDate: Date?
    @Published var timedStartDate: Date?    // wall-clock start of the hold

    private let api = APIClient()
    private let setWriteAPI: any SetWriteAPI
    private let terminalAPI: any WorkoutTerminalAPI
    private unowned let auth: AuthModel
    private let accountID: String?
    private let defaults: UserDefaults
    private let uuidFactory: () -> UUID
    private let now: () -> Date
    private var sendingTerminalIntentID: String?
    private var isDrainingWorkoutWrites = false
    private var workoutWriteDrainRequested = false
    private var workoutWriteDrainWaiters: [CheckedContinuation<Void, Never>] = []

    init(
        auth: AuthModel,
        setWriteAPI: any SetWriteAPI = APIClient(),
        terminalAPI: any WorkoutTerminalAPI = APIClient(),
        defaults: UserDefaults = .standard,
        uuidFactory: @escaping () -> UUID = UUID.init,
        now: @escaping () -> Date = Date.init
    ) {
        self.auth = auth
        self.accountID = auth.userID
        self.setWriteAPI = setWriteAPI
        self.terminalAPI = terminalAPI
        self.defaults = defaults
        self.uuidFactory = uuidFactory
        self.now = now
        var persistedSets = SetOutboxStore.load(
            userID: auth.userID, defaults: defaults)
        let persistedTerminals = WorkoutTerminalOutboxStore.load(
            userID: auth.userID, defaults: defaults)
        // A durable discard is the semantic commit point. If the process died
        // after saving it but before pruning the older set queue, discard still
        // wins on the next construction before any network recovery begins.
        for intent in persistedTerminals.intents where intent.action == .discard {
            persistedSets.remove(date: intent.date)
        }
        self.setOutbox = persistedSets
        self.terminalOutbox = persistedTerminals
        for intent in persistedTerminals.intents where intent.action == .discard {
            SetOutboxStore.remove(
                date: intent.date, userID: auth.userID, defaults: defaults)
        }
    }

    /// Bind every request to the account that created this model. An old
    /// MainTab task may finish after AuthModel switches users; it must never
    /// continue using the replacement account's bearer.
    private var currentJWT: String? {
        guard let accountID, auth.userID == accountID else { return nil }
        return auth.featureJWT
    }

    private func isCurrentAccount(using jwt: String) -> Bool {
        guard let accountID, auth.userID == accountID else { return false }
        return auth.featureJWT == jwt
    }

    /// Set callbacks may complete after a same-account token renewal, so JWT
    /// equality is intentionally not part of this generation check. Account
    /// switch, sign-out, and deletion do invalidate it and must never recreate
    /// the old account's cleared queue.
    private var canMutateBoundSetAccount: Bool {
        guard let accountID, auth.userID == accountID else { return false }
        return !auth.accountDeletionPending
    }

    var todayString: String {
        let f = DateFormatter()
        f.calendar = Calendar(identifier: .gregorian)
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = .current
        f.dateFormat = "yyyy-MM-dd"
        return f.string(from: now())
    }

    var selectedDay: DayTemplate? {
        guard let plan else { return nil }
        return plan.days.first { $0.id == selectedDayID } ?? plan.days.first
    }

    func load() async {
        guard let jwt = currentJWT else { return }
        isLoading = true
        defer { isLoading = false }
        do {
            let state = try await api.getState(jwt: jwt)
            replaceState(with: state)
            if catalog.isEmpty {
                catalog = (try? await api.getExercises(jwt: jwt)) ?? []
            }
            loadError = nil
        } catch {
            handle(error, jwt: jwt)
        }
    }

    /// Apply a full `/api/state` response atomically at the cache boundary.
    /// `getState` always uses zero watermarks, so every collection is a full
    /// replacement rather than a delta merge.
    func replaceState(with state: StateResponse, preferredTodaySessionID: String? = nil) {
        let previousSelectedDayID = selectedDayID
        let runnerWasActive = running
        let activeSlotID = activeRunnerSlotID()
        plan = state.plan
        reconcileTerminalOutbox(with: state.sessions)
        let maskedDates = discardBarrierDates
        let maskedSessionIDs = Set(state.sessions.lazy.filter {
            maskedDates.contains($0.date)
        }.map(\.id))
        sessions = state.sessions.filter { !maskedDates.contains($0.date) }
        sets = state.sets.filter { !maskedSessionIDs.contains($0.session_id) }
        reconcileSetOutboxWithServerSets()
        // The server returns the full current non-deleted external_events set;
        // defensively drop any tombstones so calendar surfaces never see them.
        rides = state.external_events.filter { !$0.isDeleted }
        activities = state.external_activities.filter { !$0.isDeleted }
        manualActivities = state.activities.filter { $0.deleted_at == nil }
        // Alias recovery knows the canonical session id from the logged set.
        // Prefer it over date-ordering so runner progress immediately keys on
        // the same session as the returned set.
        // Keep discarded history in `sessions` so calendar projection can
        // apply its existing vanish rule, but never reuse that terminal row as
        // the runner's live write target. This matters immediately after an
        // explicit restart clears the acknowledged local discard barrier: a
        // foreground refresh can still observe the server's discarded row
        // until the first new write calls the date-level create endpoint and
        // revives it. Binding that stale id here would skip createSession and
        // make the backend correctly reject the new attempt.
        todaySession = preferredTodaySessionID.flatMap { preferredID in
            sessions.first { $0.id == preferredID && $0.status != "discarded" }
        } ?? sessions.first {
            $0.date == todayString && $0.status != "discarded"
        }
        reconcileSelection(
            previousSelectedDayID: previousSelectedDayID,
            activeSlotID: activeSlotID,
            runnerWasActive: runnerWasActive)
    }

    /// Full state is an independent acknowledgement path for commit-then-
    /// timeout. It also detects the only operation that can intentionally
    /// revive a discarded date (a later explicit restart); until the local
    /// user clears the acknowledged barrier, an unexpected revival requeues
    /// discard and stays masked.
    private func reconcileTerminalOutbox(with serverSessions: [SessionRow]) {
        guard canMutateBoundSetAccount else { return }
        for var intent in terminalOutbox.intents {
            let row = intent.resolvedSessionID.flatMap { id in
                serverSessions.first { $0.id == id }
            } ?? serverSessions.first { $0.date == intent.date }
            switch intent.action {
            case .finish:
                guard row?.status == "completed" else { continue }
                terminalOutbox.remove(id: intent.id)
                persistRemovedTerminalIntent(id: intent.id)
                if intent.date == todayString { stopRunnerAfterTerminalAck() }
            case .discard:
                if row?.status == "discarded" {
                    guard intent.deliveryState != .acknowledged else { continue }
                    intent.deliveryState = .acknowledged
                    intent.failedHTTPStatus = nil
                    intent.resolvedSessionID = row?.id ?? intent.resolvedSessionID
                    terminalOutbox.replace(intent)
                    persistReplacedTerminalIntent(intent)
                } else if intent.deliveryState == .acknowledged, row != nil {
                    // A stale pre-discard create reached the server after the
                    // acknowledgement. Keep it invisible and reassert the
                    // existing idempotent discard endpoint on this lifecycle.
                    guard let revivedSessionID = row?.id else { continue }
                    terminalOutbox.requeueAcknowledgedDiscard(
                        date: intent.date,
                        resolvedSessionID: revivedSessionID)
                    WorkoutTerminalOutboxStore.requeueAcknowledgedDiscard(
                        date: intent.date,
                        resolvedSessionID: revivedSessionID,
                        userID: accountID,
                        defaults: defaults)
                }
            }
        }
        applyLocalDiscardMask()
    }

    private func applyLocalDiscardMask() {
        let dates = discardBarrierDates
        guard !dates.isEmpty else { return }
        let sessionIDs = Set(sessions.lazy.filter {
            dates.contains($0.date)
        }.map(\.id))
        sessions.removeAll { dates.contains($0.date) }
        sets.removeAll { sessionIDs.contains($0.session_id) }
        if let todaySession, dates.contains(todaySession.date) {
            self.todaySession = nil
        }
        if dates.contains(todayString) {
            stopRunnerAfterTerminalAck()
        }
    }

    private func stopRunnerAfterTerminalAck() {
        running = false
        finished = false
        workoutStart = nil
        timedActive = false
        timedEndDate = nil
        timedStartDate = nil
        skipped = []
        skipRest()
    }

    /// The runner's current physical slot without `selectedDay`'s first-day
    /// fallback. A missing day or out-of-range index is invalid runner state.
    private func activeRunnerSlotID() -> String? {
        guard running,
              let selectedDayID,
              let day = plan?.days.first(where: { $0.id == selectedDayID }),
              day.exercises.indices.contains(exerciseIndex)
        else { return nil }
        return day.exercises[exerciseIndex].id
    }

    /// Inactive state prefers the real session's remapped day. An active
    /// explicit override retains its valid day; otherwise it falls back to the
    /// remapped session day. The runner continues only when its physical slot
    /// still exists on the resolved day.
    private func reconcileSelection(previousSelectedDayID: String?, activeSlotID: String?,
                                    runnerWasActive: Bool) {
        let days = plan?.days ?? []
        let sessionDayID = todaySession?.day_template_id
        let resolvedSessionDayID = sessionDayID.flatMap { id in
            days.contains(where: { $0.id == id }) ? id : nil
        }
        let retainedDayID = previousSelectedDayID.flatMap { id in
            days.contains(where: { $0.id == id }) ? id : nil
        }
        // A running explicit "train a different day" override owns its still-
        // valid selection. The session day is the recovery target only when
        // that prior day disappeared (for example, update_plan rebuilt ids).
        selectedDayID = runnerWasActive
            ? retainedDayID ?? resolvedSessionDayID ?? days.first?.id
            : resolvedSessionDayID ?? retainedDayID ?? days.first?.id

        guard runnerWasActive else { return }
        guard sessionDayID == nil || resolvedSessionDayID != nil,
              let activeSlotID,
              let selectedDayID,
              let day = days.first(where: { $0.id == selectedDayID })
        else {
            stopRunnerForStateChange()
            return
        }
        if let newIndex = day.exercises.firstIndex(where: { $0.id == activeSlotID }) {
            exerciseIndex = newIndex
        } else if previousSelectedDayID == selectedDayID, !day.exercises.isEmpty {
            // Same valid day, active slot removed by an in-app edit: retain
            // the existing documented behavior and clamp to the next slot.
            exerciseIndex = min(exerciseIndex, day.exercises.count - 1)
        } else {
            stopRunnerForStateChange()
        }
    }

    /// Stop only local execution state; the already-logged server data stays.
    private func stopRunnerForStateChange() {
        exerciseIndex = 0
        running = false
        finished = false
        workoutStart = nil
        timedActive = false
        timedEndDate = nil
        timedStartDate = nil
        skipped = []
        skipRest()
    }

    /// Adopt a successful aliased write when the follow-up full refresh is
    /// unavailable. All cached same-date session/set aliases collapse onto the
    /// canonical id returned by the POST, so the committed set remains visible
    /// and a retry cannot create a second physical set.
    private func adoptSessionAliasLocally(
        staleSession: SessionRow,
        committedSet: SetLog,
        submittedSlotID: String
    ) {
        let previousSelectedDayID = selectedDayID
        let runnerWasActive = running
        let activeSlotID = activeRunnerSlotID()
        var aliasedSessionIDs = Set(
            sessions.filter { $0.date == staleSession.date }.map(\.id))
        aliasedSessionIDs.insert(staleSession.id)
        let canonicalSession = SessionRow(
            id: committedSet.session_id,
            date: staleSession.date,
            status: staleSession.status,
            day_template_id: staleSession.day_template_id)

        sessions.removeAll { $0.date == staleSession.date }
        sessions.append(canonicalSession)
        sets = sets.map { row in
            aliasedSessionIDs.contains(row.session_id)
                ? row.replacingSessionID(with: committedSet.session_id)
                : row
        }
        if let i = sets.firstIndex(where: { $0.id == committedSet.id }) {
            sets[i] = committedSet
        } else {
            sets.append(committedSet)
        }
        if staleSession.date == todayString {
            todaySession = canonicalSession
            reconcileSelection(
                previousSelectedDayID: previousSelectedDayID,
                activeSlotID: activeSlotID,
                runnerWasActive: runnerWasActive)
            // A missing/different echoed slot means update_plan rebuilt or
            // removed today's submitted slot. A past-date outbox drain must
            // not disturb the currently running workout.
            if committedSet.template_exercise_id != submittedSlotID {
                stopRunnerForStateChange()
            }
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

    /// Live sets logged for a specific PLAN SLOT in today's session — the
    /// completion unit for the runner. Keys on template_exercise_id (the slot),
    /// exercise_id (the movement), AND is_warmup (the slot's class) so the SAME
    /// movement in two slots, sets logged out of order, a stale link to a
    /// since-swapped slot, or a warm-up set mis-pointed at a working slot of the
    /// same movement never cross-attribute completion (#3). A warm-up slot's
    /// sets ARE is_warmup (the backend inherits the flag from the slot), so the
    /// parity check still lets a warm-up slot complete from its own sets — it
    /// only excludes a set whose class disagrees with the slot's. Sets with no
    /// slot link (Claude/MCP, or pre-this-build) fall back to matching
    /// exercise_id + warm-up parity so they still count toward the right slot.
    func todaySlotSets(_ ex: TemplateExercise) -> [SetLog] {
        guard let sid = todaySession?.id else { return [] }
        let warm = ex.isWarmup ? 1 : 0
        // Sets carrying a template_exercise_id attribute to that slot exactly.
        // The exercise_id + warm-up *fallback* (for slot-less sets — MCP-,
        // pre-this-build-, or detached-by-delete-logged) only fires when this
        // is the sole slot for that movement+warm-up today; with duplicates a
        // slot-less set is ambiguous, so an explicit slot id is required.
        //
        // KNOWN LIMITATION: deleting an already-logged slot detaches its sets
        // (deleteTemplateExercise nulls template_exercise_id); if the same
        // movement is then re-added as the only such slot in the same session,
        // those detached sets attribute to the fresh slot. Telling a detached
        // set apart from a legitimate slot-less MCP/legacy log needs a backend
        // discriminator we've deliberately not added — gating on source='ios'
        // instead wrongly dropped legacy iOS sets that never had a slot id. The
        // iOS logger always sends a slot id now, so this only affects that
        // specific delete-then-re-add edit path.
        let unique = exercises.filter {
            $0.exercise_id == ex.exercise_id && ($0.isWarmup ? 1 : 0) == warm
        }.count == 1
        return sets.filter { s in
            guard s.session_id == sid, s.deleted_at == nil else { return false }
            // Slot-linked set: attribute to this slot ONLY when the movement AND
            // the warm-up class also match. The slot id alone is not trusted — a
            // stale/swapped link (slot since changed to a different exercise) or
            // a warm-up set mis-pointed at a working slot of the same movement
            // must never count toward, or complete, this slot. This cross-check
            // is the completion invariant; the backend write-guards (log_set,
            // update_plan remap) are belt-and-suspenders over it.
            if let teid = s.template_exercise_id {
                return teid == ex.id && s.exercise_id == ex.exercise_id && s.is_warmup == warm
            }
            return unique && s.exercise_id == ex.exercise_id && s.is_warmup == warm
        }
        .sorted { $0.set_index < $1.set_index }
    }

    func exerciseName(_ id: String) -> String {
        catalog.first { $0.id == id }?.name ?? id
    }

    /// Catalog row for an exercise id, or nil if unknown. Used by the demo
    /// sheet to render the primary muscle/load-mode badges without a second
    /// lookup table.
    func catalogRow(_ id: String) -> ExerciseCatalog? {
        catalog.first { $0.id == id }
    }

    /// How many physical sides a logged set covers — 2 for unilateral
    /// exercises (Bulgarian split squat, lunge, one-arm row; reps logged
    /// per-side), 1 for everything else. Used by rollups to convert
    /// logged-rep-count → physical-rep-count and tonnage → real tonnage.
    /// Defaults to 1 when the catalog row is unknown.
    func sides(for exerciseID: String) -> Int {
        catalog.first { $0.id == exerciseID }?.laterality == "unilateral" ? 2 : 1
    }

    /// How many separately loaded implements a logged weight represents — 2
    /// for `per_hand` exercises, 1 otherwise. This is independent of
    /// laterality: a unilateral, per-hand movement counts both dimensions.
    /// Defaults to 1 when the catalog row is unknown.
    func implements(for exerciseID: String) -> Int {
        catalog.first { $0.id == exerciseID }?.load_mode == "per_hand" ? 2 : 1
    }

    /// Physical reps represented by one logged set. Unilateral movements are
    /// logged per side, so the rollup counts both sides.
    func effectiveReps(for set: SetLog) -> Int {
        set.reps * sides(for: set.exercise_id)
    }

    /// Effective tonnage represented by one logged set. Side count and
    /// per-hand implement count are independent multipliers; total-load,
    /// bilateral exercises therefore retain their original 1x behavior.
    func tonnage(for set: SetLog) -> Double {
        set.weight * Double(effectiveReps(for: set))
            * Double(implements(for: set.exercise_id))
    }

    /// True when the catalog row is a timed modality (planks/holds) — the only
    /// sets whose logged value is seconds, not reps. Logged sets carry no
    /// modality, so resolve it from the catalog. Defaults to false (rep set)
    /// when the catalog row is unknown. #30
    func isTimedExercise(_ exerciseID: String) -> Bool {
        catalog.first { $0.id == exerciseID }?.modality == "timed"
    }

    /// Whether a LOGGED set is a timed hold. Prefers the set's own
    /// authoritative is_timed flag (backend migration 0024) so a
    /// duration-pinned hold on a non-timed exercise still renders as "Ns";
    /// falls back to catalog modality for sets from a pre-0024 server (nil).
    func isTimedSet(_ s: SetLog) -> Bool {
        if let t = s.is_timed { return t == 1 }
        return isTimedExercise(s.exercise_id)
    }

    /// True when the catalog row is a bodyweight modality — these render
    /// "BW × reps". Keyed off modality (not weight == 0) so a weighted lift
    /// logged at 0 load isn't mislabeled as bodyweight. Defaults to false
    /// when the catalog row is unknown. #30
    func isBodyweightExercise(_ exerciseID: String) -> Bool {
        catalog.first { $0.id == exerciseID }?.modality == "bw"
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
        // Volume accounts independently for reps logged per-side and weights
        // logged per hand.
        // topReps + est-1RM stay per-side: those represent per-leg/per-arm
        // strength, which is what the lifter actually displaced in one rep.
        return grouped.compactMap { sid, rows -> SessionStat? in
            guard let date = dateBySession[sid], !rows.isEmpty else { return nil }
            let top = rows.max { epley($0.weight, $0.reps) < epley($1.weight, $1.reps) }!
            let durs = rows.compactMap(\.duration_s)
            return SessionStat(
                id: sid, date: date,
                est1RM: epley(top.weight, top.reps).rounded(),
                topWeight: top.weight, topReps: top.reps,
                volume: rows.reduce(0) { $0 + tonnage(for: $1) },
                setCount: rows.count,
                avgDuration: durs.isEmpty ? 0 : durs.reduce(0, +) / durs.count)
        }
        .sorted { $0.date < $1.date }
    }

    var pendingSetIntentCount: Int { setOutbox.count }
    var failedSetIntentCount: Int {
        setOutbox.pending.filter { $0.deliveryState == .failed }.count
    }
    var queuedSetIntentCount: Int {
        setOutbox.pending.filter {
            $0.deliveryState == .queued && !sendingSetIntentIDs.contains($0.id)
        }.count
    }
    var sendingSetIntentCount: Int { sendingSetIntentIDs.count }

    var pendingTerminalIntentCount: Int {
        terminalOutbox.intents.filter { $0.deliveryState != .acknowledged }.count
    }
    var failedTerminalIntentCount: Int {
        terminalOutbox.intents.filter { $0.deliveryState == .failed }.count
    }
    var queuedTerminalIntentCount: Int {
        terminalOutbox.intents.filter {
            $0.deliveryState == .queued && $0.id != sendingTerminalIntentID
        }.count
    }
    var sendingTerminalIntentCount: Int { sendingTerminalIntentID == nil ? 0 : 1 }

    var currentTerminalIntent: WorkoutTerminalIntent? {
        terminalOutbox.intent(for: todaySession?.date ?? todayString)
    }

    var hasPendingTerminalIntentForCurrentWorkout: Bool {
        guard let intent = currentTerminalIntent else { return false }
        return intent.deliveryState != .acknowledged
    }

    var hasDiscardIntentForCurrentWorkout: Bool {
        currentTerminalIntent?.action == .discard
    }

    var visibleTerminalIntent: WorkoutTerminalIntent? {
        terminalOutbox.intents.first { $0.deliveryState != .acknowledged }
    }

    var hasUnacknowledgedDiscardForToday: Bool {
        guard let intent = terminalOutbox.intent(for: todayString) else { return false }
        return intent.action == .discard && intent.deliveryState != .acknowledged
    }

    private var discardBarrierDates: Set<String> {
        Set(terminalOutbox.intents.lazy.filter {
            $0.action == .discard
        }.map(\.date))
    }

    func pendingSetIntents(for ex: TemplateExercise) -> [PendingSetIntent] {
        let date = todaySession?.date ?? todayString
        return setOutbox.pending.filter {
            $0.date == date && $0.slotID == ex.id
        }
    }

    func isSetSending(slotID: String) -> Bool {
        if hasPendingTerminalIntentForCurrentWorkout || isTerminalMutationInFlight {
            return true
        }
        if setSlotsInFlight.contains(slotID) { return true }
        return setOutbox.pending.contains {
            $0.slotID == slotID && sendingSetIntentIDs.contains($0.id)
        }
    }

    /// Terminal workout mutations are P1, but P0 must not let an acknowledged
    /// discard/finish erase the session context that queued set retries need.
    var hasPendingSetsForCurrentWorkout: Bool {
        let date = todaySession?.date ?? todayString
        return setOutbox.pending.contains { $0.date == date }
    }

    private func persistEnqueuedSetIntent(_ intent: PendingSetIntent) {
        guard canMutateBoundSetAccount else { return }
        SetOutboxStore.enqueue(
            intent, userID: accountID, defaults: defaults)
    }

    private func persistReplacedSetIntent(_ intent: PendingSetIntent) {
        guard canMutateBoundSetAccount else { return }
        SetOutboxStore.replace(
            intent, userID: accountID, defaults: defaults)
    }

    private func persistRemovedSetIntentIDs(_ ids: Set<String>) {
        guard canMutateBoundSetAccount else { return }
        SetOutboxStore.remove(
            ids: ids, userID: accountID, defaults: defaults)
    }

    private func persistEnqueuedTerminalIntent(_ intent: WorkoutTerminalIntent) {
        guard canMutateBoundSetAccount else { return }
        WorkoutTerminalOutboxStore.enqueue(
            intent, userID: accountID, defaults: defaults)
    }

    private func persistReplacedTerminalIntent(_ intent: WorkoutTerminalIntent) {
        guard canMutateBoundSetAccount else { return }
        WorkoutTerminalOutboxStore.replace(
            intent, userID: accountID, defaults: defaults)
    }

    private func persistRemovedTerminalIntent(id: String) {
        guard canMutateBoundSetAccount else { return }
        WorkoutTerminalOutboxStore.remove(
            id: id, userID: accountID, defaults: defaults)
    }

    /// A full state pull is also authoritative acknowledgement of an exact
    /// client UUID. This closes the commit-then-timeout window when an ordinary
    /// refresh wins the race with the retry drain and prevents double-counting
    /// one physical set as both completed and pending.
    private func reconcileSetOutboxWithServerSets() {
        guard canMutateBoundSetAccount else { return }
        let serverIDs = Set(sets.map(\.id))
        let acknowledgedPendingIDs = Set(
            setOutbox.pending.lazy.map(\.id).filter(serverIDs.contains))
        guard !acknowledgedPendingIDs.isEmpty else { return }
        for id in acknowledgedPendingIDs { setOutbox.remove(id: id) }
        persistRemovedSetIntentIDs(acknowledgedPendingIDs)
    }

    /// Explicitly re-arm one permanent 4xx failure. The request body remains
    /// byte-for-byte equivalent under Codable and retains its original UUID.
    func retrySetIntent(id: String) async {
        guard canMutateBoundSetAccount,
              var intent = setOutbox.pending.first(where: { $0.id == id }),
              intent.deliveryState == .failed
        else { return }
        intent.deliveryState = .queued
        intent.failedHTTPStatus = nil
        setOutbox.replace(intent)
        persistReplacedSetIntent(intent)
        await drainSetOutbox()
    }

    func retryFailedSetIntents() async {
        guard canMutateBoundSetAccount else { return }
        var changed = false
        for var intent in setOutbox.pending where intent.deliveryState == .failed {
            intent.deliveryState = .queued
            intent.failedHTTPStatus = nil
            setOutbox.replace(intent)
            persistReplacedSetIntent(intent)
            changed = true
        }
        guard changed else { return }
        await drainSetOutbox()
    }

    @discardableResult
    func logSet(_ ex: TemplateExercise, weight: Double, reps: Int,
                durationOverride: Int? = nil) async -> Bool {
        let workoutDate = todaySession?.date ?? todayString
        guard currentJWT != nil, canMutateBoundSetAccount,
              !isTerminalMutationInFlight,
              terminalOutbox.intent(for: workoutDate) == nil,
              !setSlotsInFlight.contains(ex.id)
        else { return false }

        // This guard is published before the first await, so two Tasks created
        // by a rapid double tap cannot both mint intents for the same slot.
        setSlotsInFlight.insert(ex.id)
        defer { setSlotsInFlight.remove(ex.id) }

        // Index per SLOT. Pending (queued OR visibly failed) intents reserve
        // their index so intentional offline sets remain distinct; completion
        // still counts acknowledged `SetLog` rows only.
        let nextIndex = todaySlotSets(ex).count + pendingSetIntents(for: ex).count + 1
        let body = SetRequestBody(
            id: uuidFactory().uuidString,
            exercise_id: ex.exercise_id,
            template_exercise_id: ex.id,
            set_index: nextIndex,
            weight: weight,
            reps: reps,
            is_warmup: ex.isWarmup,
            logged_at: Int((now().timeIntervalSince1970 * 1_000).rounded(.down)),
            duration_s: durationOverride,
            is_timed: ex.isTimed)
        let intent = PendingSetIntent(
            body: body,
            date: workoutDate,
            dayTemplateID: selectedDay?.id,
            resolvedSessionID: todaySession?.id,
            deliveryState: .queued,
            failedHTTPStatus: nil)

        // No network await may occur above this save. A failed/lost session
        // create therefore leaves the complete intent available on relaunch.
        setOutbox.enqueue(intent)
        persistEnqueuedSetIntent(intent)

        await drainSetOutbox()
        guard canMutateBoundSetAccount else { return false }
        let acknowledged = !setOutbox.pending.contains(where: { $0.id == body.id })
            && sets.contains(where: { $0.id == body.id })
        if acknowledged && running {
            startRest(seconds: ex.rest_seconds, name: ex.exercise_name)
        }
        return acknowledged
    }

    private enum SetSendOutcome {
        case acknowledged(setID: String, canonicalSessionID: String, date: String)
        case permanentFailure
        case transientFailure(attemptedJWT: String, wasUnauthorized: Bool)
        case staleAccount
    }

    /// Backward-compatible entry point used by P0 tests and existing lifecycle
    /// hooks. P1 routes both queues through one serialized owner.
    func drainSetOutbox() async {
        await drainWorkoutWriteOutboxes()
    }

    /// Lifecycle/network recovery brackets a fresh state pull with the same
    /// serialized writer. The first pass delivers ordinary offline work; the
    /// pull acknowledges commit-then-timeout results or detects a stale
    /// post-discard revival; the second pass immediately settles anything the
    /// reconciliation requeued.
    func recoverWorkoutWrites() async {
        await drainWorkoutWriteOutboxes()
        guard currentJWT != nil, canMutateBoundSetAccount else { return }
        await load()
        guard currentJWT != nil, canMutateBoundSetAccount else { return }
        await drainWorkoutWriteOutboxes()
    }

    /// All launch/foreground/connectivity/tap triggers converge here. A second
    /// caller waits for the active drain instead of starting a competing set or
    /// terminal request. This is the ordering boundary that makes discard the
    /// final client mutation even when it is requested during another await.
    func drainWorkoutWriteOutboxes() async {
        guard currentJWT != nil, canMutateBoundSetAccount,
              !setOutbox.isEmpty || !terminalOutbox.intents.isEmpty
        else {
            return
        }
        if isDrainingWorkoutWrites {
            // Remember the trigger, not just its waiter. If the active request
            // is about to report a transient failure, this may be the launch,
            // foreground, or connectivity recovery signal that makes one more
            // immediate pass worthwhile.
            workoutWriteDrainRequested = true
            await withCheckedContinuation { continuation in
                workoutWriteDrainWaiters.append(continuation)
            }
            return
        }

        isDrainingWorkoutWrites = true
        // An intent can be persisted while this owner is awaiting the final
        // reconciliation pull. Re-check the queue before releasing waiters so
        // that trigger coalesces into this same serialized drain instead of
        // being stranded until some later lifecycle/network event.
        while canMutateBoundSetAccount, currentJWT != nil {
            workoutWriteDrainRequested = false
            let stoppedForRetryableFailure = await performWorkoutWriteDrain()
            if stoppedForRetryableFailure && !workoutWriteDrainRequested { break }
            guard hasImmediatelyDeliverableWorkoutWrite else { break }
        }
        isDrainingWorkoutWrites = false
        let waiters = workoutWriteDrainWaiters
        workoutWriteDrainWaiters.removeAll()
        waiters.forEach { $0.resume() }
    }

    private var hasImmediatelyDeliverableWorkoutWrite: Bool {
        if setOutbox.pending.contains(where: { $0.deliveryState == .queued }) {
            return true
        }
        return terminalOutbox.intents.contains { intent in
            guard intent.deliveryState == .queued else { return false }
            if intent.action == .discard { return true }
            return !setOutbox.pending.contains { $0.date == intent.date }
        }
    }

    /// Persisted discard dominates both queued and visibly-failed sets. This
    /// method is intentionally safe to repeat: it also closes the crash window
    /// between saving the terminal barrier and pruning the older set key.
    private func supersedeSetIntentsForDiscardBarriers() {
        guard canMutateBoundSetAccount else { return }
        for date in discardBarrierDates {
            guard setOutbox.pending.contains(where: { $0.date == date }) else {
                continue
            }
            setOutbox.remove(date: date)
            SetOutboxStore.remove(
                date: date, userID: accountID, defaults: defaults)
        }
        applyLocalDiscardMask()
    }

    /// One serialized pass: discards first, then sets, then finishes whose
    /// exact workout has no queued or failed set left. A finish therefore
    /// cannot overtake its data, while discard never waits on data it erases.
    private func performWorkoutWriteDrain() async -> Bool {
        supersedeSetIntentsForDiscardBarriers()
        if let discard = terminalOutbox.intents.first(where: {
            $0.action == .discard && $0.deliveryState == .queued
        }) {
            return await sendPersistedTerminalIntent(discard)
        }

        let setStopped = await performSetOutboxDrain()
        if setStopped { return true }
        supersedeSetIntentsForDiscardBarriers()

        guard let terminal = terminalOutbox.intents.first(where: { intent in
            guard intent.deliveryState == .queued else { return false }
            if intent.action == .discard { return true }
            return !setOutbox.pending.contains { $0.date == intent.date }
        }) else { return false }
        return await sendPersistedTerminalIntent(terminal)
    }

    /// Returns true only when another immediate pass would repeat a transient
    /// failure (or would cross an account boundary). A normal empty-queue exit
    /// returns false so the owner can coalesce work that arrived during its
    /// reconciliation await.
    private func performSetOutboxDrain() async -> Bool {
        var acknowledgedIDs: [String] = []
        var preferredSessionID: String?
        var stoppedForRetryableFailure = false

        while canMutateBoundSetAccount,
              let intent = setOutbox.pending.first(where: {
                  $0.deliveryState == .queued
              }) {
            supersedeSetIntentsForDiscardBarriers()
            guard setOutbox.pending.contains(where: { $0.id == intent.id }) else {
                continue
            }
            let outcome = await sendPersistedSetIntent(intent)
            supersedeSetIntentsForDiscardBarriers()
            switch outcome {
            case let .acknowledged(setID, canonicalSessionID, date):
                acknowledgedIDs.append(setID)
                if date == todayString { preferredSessionID = canonicalSessionID }
            case .permanentFailure:
                // Keep the failed row visible and continue with later FIFO
                // entries; retrying it later still reuses its exact body.
                continue
            case let .transientFailure(attemptedJWT, wasUnauthorized):
                // A stale-token 401 can race same-account renewal. If renewal
                // already installed a replacement token, retry immediately;
                // otherwise stop and retain every queued intent.
                if wasUnauthorized,
                   let latestJWT = currentJWT,
                   latestJWT != attemptedJWT,
                   canMutateBoundSetAccount {
                    continue
                }
                stoppedForRetryableFailure = true
                break
            case .staleAccount:
                stoppedForRetryableFailure = true
                break
            }

            if case .transientFailure = outcome { break }
            if case .staleAccount = outcome { break }
        }

        guard !acknowledgedIDs.isEmpty,
              canMutateBoundSetAccount,
              let jwt = currentJWT
        else { return stoppedForRetryableFailure }
        do {
            let state = try await setWriteAPI.getState(jwt: jwt)
            guard canMutateBoundSetAccount else { return true }
            let returnedIDs = Set(state.sets.map(\.id))
            guard acknowledgedIDs.allSatisfy(returnedIDs.contains) else {
                throw APIError.decoding(
                    "Acknowledged set was missing from the reconciliation state")
            }
            replaceState(
                with: state,
                preferredTodaySessionID: preferredSessionID)
            loadError = nil
        } catch {
            guard canMutateBoundSetAccount else { return true }
            // The acknowledgement itself remains authoritative and is already
            // reflected locally. A later full sync will reconcile the cache.
            handle(error, jwt: jwt)
        }
        return stoppedForRetryableFailure
    }

    /// Returns true only for a retryable/account-boundary stop. Permanent 4xx
    /// failures remain visible but do not block recovery work for other dates.
    private func sendPersistedTerminalIntent(
        _ original: WorkoutTerminalIntent
    ) async -> Bool {
        guard canMutateBoundSetAccount, currentJWT != nil,
              terminalOutbox.intent(for: original.date)?.id == original.id
        else { return true }

        sendingTerminalIntentID = original.id
        isTerminalMutationInFlight = true
        defer {
            if sendingTerminalIntentID == original.id {
                sendingTerminalIntentID = nil
            }
            isTerminalMutationInFlight = sendingTerminalIntentID != nil
        }

        var intent = original
        if intent.resolvedSessionID == nil {
            guard let jwt = currentJWT else { return true }
            let session: SessionRow
            do {
                session = try await setWriteAPI.createSession(
                    date: intent.date,
                    dayTemplateID: intent.dayTemplateID,
                    jwt: jwt)
            } catch {
                // Match set recovery: update_plan can invalidate the optional
                // day UUID while this terminal choice is offline. Retry the
                // existing date-level endpoint without that stale association.
                guard intent.dayTemplateID != nil,
                      isPermanentSetClientError(error),
                      canMutateBoundSetAccount,
                      let fallbackJWT = currentJWT
                else {
                    return classifyTerminalIntentFailure(
                        original, error: error, attemptedJWT: jwt)
                }
                do {
                    session = try await setWriteAPI.createSession(
                        date: intent.date, dayTemplateID: nil, jwt: fallbackJWT)
                } catch {
                    return classifyTerminalIntentFailure(
                        original, error: error, attemptedJWT: fallbackJWT)
                }
            }

            guard canMutateBoundSetAccount,
                  terminalOutbox.intent(for: intent.date)?.id == intent.id
            else { return false }
            guard session.date == intent.date else {
                return classifyTerminalIntentFailure(
                    intent,
                    error: APIError.decoding(
                        "Session resolution did not match the terminal date"),
                    attemptedJWT: jwt)
            }
            intent.resolvedSessionID = session.id
            terminalOutbox.replace(intent)
            persistReplacedTerminalIntent(intent)
            upsertSessionAfterCreate(session)
        }

        guard let sessionID = intent.resolvedSessionID,
              let jwt = currentJWT
        else { return true }
        do {
            let response: SessionRow
            switch intent.action {
            case .finish:
                // A failed set remains in the queue and is just as unsettled
                // as a queued one; the caller excludes both before reaching us.
                guard !setOutbox.pending.contains(where: {
                    $0.date == intent.date
                }) else { return false }
                response = try await terminalAPI.completeSession(
                    sessionId: sessionID, jwt: jwt)
            case .discard:
                response = try await terminalAPI.discardSession(
                    sessionId: sessionID, jwt: jwt)
            }

            guard canMutateBoundSetAccount else { return true }
            // Discard may have replaced an in-flight finish. Its response is
            // real server history, but the stale callback cannot touch the
            // newer local intent; the coordinator will send discard next.
            guard terminalOutbox.intent(for: intent.date)?.id == intent.id else {
                return false
            }
            let expectedStatus = intent.action == .finish ? "completed" : "discarded"
            guard response.date == intent.date,
                  response.status == expectedStatus
            else {
                throw APIError.decoding(
                    "Terminal acknowledgement did not match the persisted intent")
            }

            switch intent.action {
            case .finish:
                terminalOutbox.remove(id: intent.id)
                persistRemovedTerminalIntent(id: intent.id)
                upsertSessionAfterCreate(response)
                if intent.date == todayString { stopRunnerAfterTerminalAck() }
            case .discard:
                intent.resolvedSessionID = response.id
                intent.deliveryState = .acknowledged
                intent.failedHTTPStatus = nil
                terminalOutbox.replace(intent)
                persistReplacedTerminalIntent(intent)
                applyLocalDiscardMask()
            }
            loadError = nil
            return false
        } catch {
            return classifyTerminalIntentFailure(
                intent, error: error, attemptedJWT: jwt)
        }
    }

    private func classifyTerminalIntentFailure(
        _ attempted: WorkoutTerminalIntent,
        error: Error,
        attemptedJWT: String
    ) -> Bool {
        guard canMutateBoundSetAccount else { return true }
        // A newer discard superseded this callback while its request was in
        // flight. Never recreate or overwrite that newer durable choice.
        guard var current = terminalOutbox.intent(for: attempted.date),
              current.id == attempted.id
        else { return false }
        if isPermanentSetClientError(error),
           case let APIError.http(code, _) = error {
            current.deliveryState = .failed
            current.failedHTTPStatus = code
            terminalOutbox.replace(current)
            persistReplacedTerminalIntent(current)
            loadError = "Workout \(current.action == .finish ? "finish" : "discard") wasn't saved because the server rejected it (HTTP \(code))."
            return false
        }
        handle(error, jwt: attemptedJWT)
        if case let APIError.http(code, _) = error,
           code == 401,
           let latestJWT = currentJWT,
           latestJWT != attemptedJWT {
            return false
        }
        return true
    }

    private func sendPersistedSetIntent(_ original: PendingSetIntent) async -> SetSendOutcome {
        guard canMutateBoundSetAccount, currentJWT != nil else {
            return .staleAccount
        }
        sendingSetIntentIDs.insert(original.id)
        defer { sendingSetIntentIDs.remove(original.id) }

        var intent = original
        let session: SessionRow
        if let sessionID = intent.resolvedSessionID {
            session = sessions.first(where: { $0.id == sessionID })
                ?? SessionRow(
                    id: sessionID,
                    date: intent.date,
                    status: "in_progress",
                    day_template_id: intent.dayTemplateID)
        } else {
            guard let jwt = currentJWT else { return .staleAccount }
            let createdSession: SessionRow
            do {
                createdSession = try await setWriteAPI.createSession(
                    date: intent.date,
                    dayTemplateID: intent.dayTemplateID,
                    jwt: jwt)
            } catch {
                // update_plan may rebuild every day UUID while this offline
                // intent is unresolved. A rejected persisted association must
                // not poison the FIFO forever: clear only that stale optional
                // FK, persist before the fallback await, and let the date's
                // canonical session preserve the set itself.
                guard intent.dayTemplateID != nil,
                      isPermanentSetClientError(error),
                      canMutateBoundSetAccount,
                      let fallbackJWT = currentJWT
                else {
                    return classifySetIntentFailure(
                        intentID: intent.id,
                        error: error,
                        attemptedJWT: jwt)
                }
                intent.dayTemplateID = nil
                setOutbox.replace(intent)
                persistReplacedSetIntent(intent)
                do {
                    createdSession = try await setWriteAPI.createSession(
                        date: intent.date,
                        dayTemplateID: nil,
                        jwt: fallbackJWT)
                } catch {
                    return classifySetIntentFailure(
                        intentID: intent.id,
                        error: error,
                        attemptedJWT: fallbackJWT)
                }
            }
            guard canMutateBoundSetAccount else { return .staleAccount }
            session = createdSession
            intent.resolvedSessionID = session.id
            setOutbox.replace(intent)
            persistReplacedSetIntent(intent)
            upsertSessionAfterCreate(session)
        }

        // The original body was persisted before session creation, and the
        // resolved session id is persisted above before this POST await.
        guard let jwt = currentJWT else { return .staleAccount }
        do {
            let result = try await setWriteAPI.logSet(
                sessionId: session.id,
                body: intent.body,
                jwt: jwt)
            guard canMutateBoundSetAccount else { return .staleAccount }
            guard result.set.id == intent.id else {
                throw APIError.decoding(
                    "Set acknowledgement did not match the persisted intent")
            }
            applySetAcknowledgement(
                result,
                intent: intent,
                submittedSession: session)
            setOutbox.remove(id: intent.id)
            persistRemovedSetIntentIDs(Set([intent.id]))
            return .acknowledged(
                setID: result.set.id,
                canonicalSessionID: result.set.session_id,
                date: intent.date)
        } catch {
            return classifySetIntentFailure(
                intentID: intent.id, error: error, attemptedJWT: jwt)
        }
    }

    private func classifySetIntentFailure(
        intentID: String,
        error: Error,
        attemptedJWT: String
    ) -> SetSendOutcome {
        guard canMutateBoundSetAccount else { return .staleAccount }
        if isPermanentSetClientError(error),
           case let APIError.http(code, _) = error {
            if var intent = setOutbox.pending.first(where: { $0.id == intentID }) {
                intent.deliveryState = .failed
                intent.failedHTTPStatus = code
                setOutbox.replace(intent)
                persistReplacedSetIntent(intent)
            }
            loadError = "Set wasn't saved because the server rejected it (HTTP \(code))."
            return .permanentFailure
        }
        handle(error, jwt: attemptedJWT)
        let unauthorized: Bool
        if case let APIError.http(code, _) = error { unauthorized = code == 401 }
        else { unauthorized = false }
        return .transientFailure(
            attemptedJWT: attemptedJWT,
            wasUnauthorized: unauthorized)
    }

    private func isPermanentSetClientError(_ error: Error) -> Bool {
        guard case let APIError.http(code, _) = error else { return false }
        return (400..<500).contains(code) && ![401, 408, 429].contains(code)
    }

    private func upsertSessionAfterCreate(_ session: SessionRow) {
        guard canMutateBoundSetAccount else { return }
        if let index = sessions.firstIndex(where: { $0.id == session.id }) {
            sessions[index] = session
        } else {
            sessions.append(session)
        }
        if session.date == todayString { todaySession = session }
    }

    private func applySetAcknowledgement(
        _ result: APIClient.SetLogResult,
        intent: PendingSetIntent,
        submittedSession: SessionRow
    ) {
        if result.set.session_id == submittedSession.id {
            upsertSessionAfterCreate(submittedSession)
            if let index = sets.firstIndex(where: { $0.id == result.set.id }) {
                sets[index] = result.set
            } else {
                sets.append(result.set)
            }
        } else {
            // Preserve migration-0029 alias healing even when reconciliation
            // later fails: collapse the stale local session immediately onto
            // the canonical id echoed by the acknowledged set.
            adoptSessionAliasLocally(
                staleSession: submittedSession,
                committedSet: result.set,
                submittedSlotID: intent.slotID)
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
        return todaySlotSets(ex).count + pendingSetIntents(for: ex).count + 1
    }

    func startWorkout() {
        let date = todaySession?.date ?? todayString
        if let terminal = terminalOutbox.intent(for: date) {
            guard terminal.action == .discard,
                  terminal.deliveryState == .acknowledged
            else {
                loadError = "This workout still has a finish or discard waiting to sync."
                return
            }
            terminalOutbox.clearAcknowledgedDiscard(date: date)
            WorkoutTerminalOutboxStore.clearAcknowledgedDiscard(
                date: date, userID: accountID, defaults: defaults)
        }
        running = true
        finished = false
        exerciseIndex = 0
        skipped = []
        workoutStart = Date()
        seedInputs()
    }

    /// Seed weight/reps from last time → plan target → default.
    private func seedInputs() {
        timedActive = false
        timedEndDate = nil
        timedStartDate = nil
        guard let ex = currentExercise else { return }
        let last = lastWorkingSet(ex.exercise_id)
        // Bodyweight exercises have no weight input (#2); the field is
        // hidden and uneditable, so always seed 0 — never carry a prior
        // (possibly mis-logged) non-zero load forward where the user can't
        // see or fix it mid-workout.
        weight = ex.isBodyweight ? 0 : (last?.weight ?? ex.target_weight ?? 45)
        reps = last?.reps ?? ex.target_reps
    }

    // MARK: timed exercises (plank, holds)

    func startTimedSet() {
        guard let ex = currentExercise, ex.isTimed,
              !isTerminalMutationInFlight,
              !hasPendingTerminalIntentForCurrentWorkout,
              !isSetSending(slotID: ex.id)
        else { return }
        timedActive = true
        let now = Date()
        timedStartDate = now
        // Count down the prescribed hold (target_duration_s, fallback
        // target_reps) — not target_reps directly, which was 1s for slots
        // that never set a duration (the "plank ended instantly" bug).
        timedEndDate = now.addingTimeInterval(TimeInterval(ex.holdSeconds))
    }

    /// Whole seconds held so far in the running timed set (0 when idle).
    /// FLOORED, not rounded: a tap at 1.6s is a 1s hold, so it must stay
    /// below the `>= 2` STOP guard (rounding would bump it to 2 and log a
    /// junk set — the exact thing the guard exists to prevent).
    var timedElapsed: Int {
        guard let start = timedStartDate else { return 0 }
        return max(0, Int(Date().timeIntervalSince(start)))
    }

    /// The prescribed hold completed (countdown reached the end) — logs the
    /// FULL target hold. Driven by the runner's poll loop so it fires
    /// reliably "at the end of a timed exercise" (#55), even if a single
    /// long sleep was suspended/cancelled.
    func finishTimedSetAuto() async {
        guard let ex = currentExercise else { return }
        await commitTimedSet(held: ex.holdSeconds)
    }

    /// Manual STOP — logs the ACTUAL elapsed hold (capped at the prescribed
    /// target, which the auto-log would otherwise own). A reflexive tap in
    /// the first 2s — STOP sits where START just was — is NOT a real hold:
    /// it's ignored (the timer keeps running) so it can't log a junk "1s"
    /// set, the symptom in #55.
    func stopTimedSet() async {
        guard let ex = currentExercise else { return }
        let elapsed = timedElapsed
        guard elapsed >= 2 else { return }
        await commitTimedSet(held: min(elapsed, ex.holdSeconds))
    }

    /// Single commit path for a timed set — logs reps=held, duration=held
    /// (≥1s) and advances. Both auto and manual completion route here.
    private func commitTimedSet(held: Int) async {
        guard let ex = currentExercise, timedActive else { return }
        timedActive = false
        timedEndDate = nil
        timedStartDate = nil
        skipped.remove(ex.id)   // logging work un-skips this slot
        let secs = max(1, held)
        guard await logSet(ex, weight: 0, reps: secs, durationOverride: secs) else { return }
        guard running, let current = currentExercise else { return }
        if isComplete(current) {
            if let next = nextIncompleteIndex { jump(to: next) } else { finished = true }
        }
    }

    func adjustWeight(_ delta: Double) { weight = max(0, weight + delta) }
    /// Direct-set the working weight (tap-to-edit on the runner). Same
    /// non-negative clamp as `adjustWeight` so weird-increment machines
    /// (14.3 lb plate stack) can be entered exactly without making the
    /// stepper row carry every possible delta button.
    func setWeight(_ value: Double) { weight = max(0, value) }
    func adjustReps(_ delta: Int) { reps = max(0, reps + delta) }

    func setsDone(_ ex: TemplateExercise) -> Int { todaySlotSets(ex).count }
    func isComplete(_ ex: TemplateExercise) -> Bool { setsDone(ex) >= ex.target_sets }
    func isSkipped(_ ex: TemplateExercise) -> Bool { skipped.contains(ex.id) }
    /// "Resolved" = nothing left to do here: either completed or skipped.
    /// Drives requeue/finish so a skipped exercise is never auto-represented.
    func isResolved(_ ex: TemplateExercise) -> Bool { isComplete(ex) || isSkipped(ex) }
    var allComplete: Bool { !exercises.isEmpty && exercises.allSatisfy { isComplete($0) } }

    /// First UNRESOLVED exercise after the current one (wraps), so a
    /// completed-or-skipped lift never traps you and order is flexible.
    /// Skipped exercises are excluded — they do not requeue (#3).
    var nextIncompleteIndex: Int? {
        let n = exercises.count
        guard n > 0 else { return nil }
        for offset in 1...n {
            let i = (exerciseIndex + offset) % n
            if !isResolved(exercises[i]) { return i }
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
        skipped.remove(ex.id)   // logging work un-skips this slot
        guard await logSet(ex, weight: weight, reps: reps) else { return } // also starts rest timer
        guard running, let current = currentExercise else { return }
        if isComplete(current) {
            if let next = nextIncompleteIndex { jump(to: next) }
            else { finished = true }
        }
    }

    /// Manual "move on" — marks the current exercise skipped for this
    /// session (so it is NOT requeued, #3) and advances to the next
    /// unresolved exercise; ends the workout if none remain.
    func skip() {
        if let ex = currentExercise { skipped.insert(ex.id) }
        if let next = nextIncompleteIndex { jump(to: next) } else { finished = true }
    }

    func previous() {
        guard exerciseIndex > 0 else { return }
        exerciseIndex -= 1
        seedInputs()
    }

    /// Non-destructive forward navigation — move to the next exercise in order
    /// WITHOUT marking the current one skipped. Going "out of order" (stepping
    /// ahead to a later lift you'll come back to) must never strike out the
    /// ones you pass; only an explicit Skip does that (#3). Pairs with
    /// `previous()`; the jump strip still allows arbitrary jumps.
    func next() {
        guard exerciseIndex < exercises.count - 1 else { return }
        exerciseIndex += 1
        seedInputs()
    }

    func finishWorkout() async {
        guard canMutateBoundSetAccount, currentJWT != nil else { return }
        let date = todaySession?.date ?? todayString
        if terminalOutbox.intent(for: date) == nil {
            let intent = WorkoutTerminalIntent(
                id: uuidFactory().uuidString,
                action: .finish,
                date: date,
                dayTemplateID: todaySession?.day_template_id ?? selectedDay?.id,
                resolvedSessionID: todaySession?.id,
                deliveryState: .queued,
                failedHTTPStatus: nil)
            // The complete user choice is durable before the coordinator can
            // await set delivery, session resolution, or the terminal PATCH.
            terminalOutbox.enqueue(intent)
            persistEnqueuedTerminalIntent(intent)
        }
        await drainWorkoutWriteOutboxes()
    }

    /// Discard today's session — "I didn't really do this." Throws the
    /// logged sets away and marks the session discarded server-side; the
    /// day VANISHES (reverts to its scheduled/rest projection) rather than
    /// recording a workout. Same local-state teardown as finishWorkout so
    /// the runner/Live Activity don't linger; `load()` then pulls the
    /// vanished state. Restarting the day creates a fresh session.
    func discardWorkout() async {
        guard canMutateBoundSetAccount, currentJWT != nil else { return }
        let date = todaySession?.date ?? todayString
        let intent = WorkoutTerminalIntent(
            id: uuidFactory().uuidString,
            action: .discard,
            date: date,
            dayTemplateID: todaySession?.day_template_id ?? selectedDay?.id,
            resolvedSessionID: todaySession?.id,
            deliveryState: .queued,
            failedHTTPStatus: nil)

        // Saving the discard first is the atomic semantic commit. If the app
        // dies before the following physical set-key cleanup, init observes
        // this barrier and performs the same supersession before any drain.
        terminalOutbox.enqueue(intent)
        persistEnqueuedTerminalIntent(intent)
        supersedeSetIntentsForDiscardBarriers()
        applyLocalDiscardMask()
        await drainWorkoutWriteOutboxes()
    }

    func retryTerminalIntent(id: String) async {
        guard canMutateBoundSetAccount,
              var intent = terminalOutbox.intents.first(where: { $0.id == id }),
              intent.deliveryState == .failed
        else { return }
        intent.deliveryState = .queued
        intent.failedHTTPStatus = nil
        terminalOutbox.replace(intent)
        persistReplacedTerminalIntent(intent)
        await drainWorkoutWriteOutboxes()
    }

    func retryFailedTerminalIntents() async {
        guard canMutateBoundSetAccount else { return }
        var changed = false
        for var intent in terminalOutbox.intents
        where intent.deliveryState == .failed {
            intent.deliveryState = .queued
            intent.failedHTTPStatus = nil
            terminalOutbox.replace(intent)
            persistReplacedTerminalIntent(intent)
            changed = true
        }
        guard changed else { return }
        await drainWorkoutWriteOutboxes()
    }

    // MARK: in-app workout editing
    //
    // Direct edits to the active plan's day template from the app — the
    // "Claude is the brain, the app is the executor, but I can still tweak
    // today's workout" loop (#1/#2). These mutate the versioned plan tree via
    // the REST editor endpoints (thin wrappers over the same updateExercise /
    // deleteTemplateExercise the MCP tools use) and reload so the change is
    // reflected immediately. Editing the DAY TEMPLATE (not a per-session
    // override) keeps one source of truth and mirrors how Claude edits — an
    // added erg warm-up recurs on that day, which is what you want for a
    // warm-up. Any edit can shift slot indices (add/delete/reorder before the
    // current one) or remove the active slot itself, so after a reload we pin
    // the runner back to the same physical slot by id — capture it before
    // load(), restore it after.

    func addExerciseToDay(_ dayID: String, exercise: String, isWarmup: Bool,
                          targetSets: Int, targetReps: Int, restSeconds: Int,
                          targetDurationS: Int?) async {
        guard let jwt = currentJWT else { return }
        let activeSlotID = currentExercise?.id
        do {
            _ = try await api.addExercise(
                dayID: dayID, exercise: exercise, isWarmup: isWarmup,
                targetSets: targetSets, targetReps: targetReps,
                restSeconds: restSeconds, targetDurationS: targetDurationS, jwt: jwt)
            await load()
            restoreActiveSlot(activeSlotID)
        } catch { handle(error, jwt: jwt) }
    }

    func deleteSlot(dayID: String, teID: String) async {
        guard let jwt = currentJWT else { return }
        let activeSlotID = currentExercise?.id
        do {
            try await api.deleteExerciseSlot(dayID: dayID, teID: teID, jwt: jwt)
            await load()
            restoreActiveSlot(activeSlotID)
        } catch { handle(error, jwt: jwt) }
    }

    /// Move a slot to a new position. The backend densifies sibling
    /// order_index values around the requested destination.
    func moveSlot(dayID: String, teID: String, toIndex: Int) async {
        guard let jwt = currentJWT else { return }
        let activeSlotID = currentExercise?.id
        do {
            _ = try await api.updateExerciseSlot(
                dayID: dayID, teID: teID, fields: ["order_index": toIndex], jwt: jwt)
            await load()
            restoreActiveSlot(activeSlotID)
        } catch { handle(error, jwt: jwt) }
    }

    /// After an edit reloads the plan, keep the runner on the same physical
    /// slot it was executing. Re-find the slot by its stable
    /// TemplateExercise.id, since a numeric exerciseIndex silently points at a
    /// different lift once a slot before it is added/removed/reordered. If the
    /// active slot itself was deleted (id gone), keep the index — it now lands
    /// on the slot that followed the deletion — and clamp it into bounds.
    private func restoreActiveSlot(_ previousID: String?) {
        guard running else { return }
        // The editor just removed the last slot mid-workout — nothing left to
        // run. Stop the runner non-destructively (logged sets are kept; no
        // completeSession) so the user lands back on Today instead of a blank
        // RunnerView (currentExercise nil); re-entering the day resumes. Mirror
        // finishWorkout's local teardown so the rest cue / Live Activity don't
        // linger.
        if exercises.isEmpty {
            exerciseIndex = 0
            running = false
            finished = false
            workoutStart = nil
            skipRest()
            return
        }
        if let previousID, let i = exercises.firstIndex(where: { $0.id == previousID }) {
            exerciseIndex = i
        } else if exerciseIndex >= exercises.count {
            exerciseIndex = exercises.count - 1
        }
        seedInputs()
    }

    // MARK: rest timer

    /// Name of the next not-complete exercise (for the rest screen's UP NEXT).
    var upNextName: String {
        if let i = nextIncompleteIndex { return exercises[i].exercise_name }
        return "Done"
    }

    func removeSet(_ set: SetLog) async {
        guard let jwt = currentJWT else { return }
        do {
            try await api.deleteSet(setId: set.id, jwt: jwt)
            sets.removeAll { $0.id == set.id }
        } catch { handle(error, jwt: jwt) }
    }

    /// Fires the "rest's up" audio cue exactly when the current rest elapses.
    /// Cancelled/rescheduled whenever the rest changes (+15 / −15 / DONE / a
    /// new set's rest), so it never double-fires or fires for a stale timer.
    private var restCueTask: Task<Void, Never>?

    func startRest(seconds: Int, name: String) {
        restExercise = name
        restTotal = seconds
        let end = Date().addingTimeInterval(TimeInterval(seconds))
        restEndDate = end
        RestLiveActivity.start(exercise: name, endDate: end, upNext: upNextName)
        scheduleRestCue(for: end)
        RestCue.scheduleNotification(at: end)
    }
    func addRest(_ seconds: Int) {
        guard let end = restEndDate else { return }
        let newEnd = end.addingTimeInterval(TimeInterval(seconds))
        restEndDate = newEnd
        RestLiveActivity.update(endDate: newEnd, upNext: upNextName)
        scheduleRestCue(for: newEnd)
        RestCue.scheduleNotification(at: newEnd)
    }
    func skipRest() {
        restEndDate = nil
        restCueTask?.cancel()
        restCueTask = nil
        RestLiveActivity.endNow()
        RestCue.cancelNotification()
    }

    /// The lift to name in the rest cue: the one the runner is ON when rest
    /// ends — same value the foreground cue computes at fire time, but resolved
    /// up front for the scheduled notification. The index has already advanced
    /// by the time rest starts (logCurrentSet jumps only when the slot
    /// completed), so currentExercise is the SAME exercise mid-sets, the next
    /// one when it's done, and empty ("workout complete") when finished.
    private var restCueLift: String {
        finished ? "" : (currentExercise?.exercise_name ?? "")
    }

    /// Poll-to-fire (250ms ticks) rather than one long sleep so the cue lands
    /// reliably "at the end of rest" even if a single sleep is suspended — the
    /// same robustness the timed-set runner needed (#55). The cue only sounds
    /// if this is still the same, still-active rest when the deadline arrives.
    private func scheduleRestCue(for end: Date) {
        restCueTask?.cancel()
        restCueTask = Task { [weak self] in
            while !Task.isCancelled {
                guard let self, self.restEndDate == end else { return }
                if Date() >= end { break }
                try? await Task.sleep(nanoseconds: 250_000_000)
            }
            if Task.isCancelled { return }
            guard let self, self.restEndDate == end else { return }
            // Announce the exercise the runner is actually ON when rest ends —
            // NOT upNextName, which returns the next DIFFERENT exercise. By the
            // time rest ends the index has already advanced (logCurrentSet jumps
            // only when the slot completed), so currentExercise is the next set's
            // lift: the SAME exercise mid-sets, the next one when it's done.
            // Empty when the workout finished → RestCue says "workout complete".
            //
            // Exactly-once across the foreground/background boundary: if the app
            // was locked/backgrounded across `end`, this Task was suspended and
            // the scheduled local notification already cued the user. Detect that
            // authoritatively via the OS delivered list (iOS suppresses the
            // notification while we're foreground, so a delivered one means we
            // were genuinely backgrounded) and skip the in-app replay — rather
            // than guessing from how late this resumed tick is, which double-cues
            // when the user taps the notification within the lateness window.
            let alreadyCued = await RestCue.notificationWasDelivered()
            if Task.isCancelled || self.restEndDate != end { return }
            if !alreadyCued {
                RestCue.play(upNext: self.restCueLift)
            }
            RestCue.cancelNotification()
        }
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

    /// Non-deleted COMPLETED activities for a `YYYY-MM-DD` date (read-only).
    func activities(on dateString: String) -> [ExternalActivity] {
        activities.filter { !$0.isDeleted && $0.date == dateString }
    }

    /// Non-deleted manual activities (Pilates / walk / …) the user logged
    /// for a `YYYY-MM-DD` date. Newest-logged first so the most recent
    /// entry sits on top when several share a day.
    func manualActivities(on dateString: String) -> [ActivityRow] {
        manualActivities
            .filter { $0.deleted_at == nil && $0.date == dateString }
            .sorted { $0.logged_at > $1.logged_at }
    }

    /// The endurance "noun" for a date — "Bike" / "Run" / "Swim" / "Active"
    /// — drawn from BOTH completed activities and planned rides, or nil when
    /// the date carries no cycling/endurance at all. A no-lift day with
    /// endurance is a "<noun> day", NOT a rest day; a lift day with endurance
    /// is "lift + <noun>". Cycling wins when several kinds coexist (the
    /// athlete is primarily a cyclist).
    func enduranceNoun(on dateString: String) -> String? {
        let kinds = activities(on: dateString).map(\.kind)
            + rides(on: dateString).map(\.kind)
        guard !kinds.isEmpty else { return nil }
        if kinds.contains("ride") { return "Bike" }
        if kinds.contains("run")  { return "Run" }
        if kinds.contains("swim") { return "Swim" }
        return "Active"
    }

    /// The headline noun for a NO-LIFT day — what the day "is" when no lift
    /// is scheduled or logged. Endurance (Bike/Run/Swim/Active, from
    /// intervals actuals + planned rides) wins; otherwise a user-logged
    /// manual activity makes it a "<kind> day" (e.g. "Pilates"/"Walk"/
    /// "Run", or "Active" for the generic/mixed cases); nil = a true rest
    /// day. SEPARATE from `enduranceNoun` on purpose: enduranceNoun also
    /// feeds the lift-day "+ BIKE" cross-training suffix, where folding a
    /// Pilates log in would wrongly read "PUSH + ACTIVE". This helper is
    /// only for the no-lift title/note/cell classification.
    func noLiftDayNoun(on dateString: String) -> String? {
        if let endurance = enduranceNoun(on: dateString) { return endurance }
        let kinds = Set(manualActivities(on: dateString).map(\.type))
        guard !kinds.isEmpty else { return nil }
        // A single, nameable kind reads nicely as "PILATES DAY" / "WALK DAY".
        // "other"/"lift" (→ "Lift (other)") and mixed kinds fall back to the
        // generic "Active" — the activity card(s) below carry the specifics.
        if kinds.count == 1, let only = kinds.first,
           only != "other", only != "lift" {
            return PendingActivity.label(for: only)
        }
        return "Active"
    }

    /// Count of live (non-deleted) logged sets for the session on `ymd`, 0
    /// when there is no session or all its sets were deleted. An
    /// `in_progress` session with 0 here is a PHANTOM — sets were logged
    /// then removed — and should be presented as the planned workout, not as
    /// an active in-progress one (it records no work).
    func loggedSetCount(forDate ymd: String) -> Int {
        guard let sid = sessionsByDate[ymd]?.id else { return 0 }
        return setsForSession(sid).count
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
            templateIDs: planTemplateIDs,
            trips: plan?.trips ?? [])
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
    /// contract, so the two sites cannot literally share one symbol; a new
    /// NON-workout status must be reflected here.
    ///
    /// `"discarded"` is the second non-workout status (a thrown-away
    /// session). Unlike `"skipped"`, it does NOT flow through the `kind`
    /// switch: `CalendarProjection.project` drops a discarded session up
    /// front (treats it as if absent — the byte-for-byte mirror of the
    /// backend `projectCalendar` `discarded` carve-out), so a discarded
    /// date never resolves to `.session(...)` at all. This predicate still
    /// excludes it defensively for the paths that read a raw session
    /// status directly (e.g. today's row arriving via the /api/state delta
    /// before any restart/revival).
    static func isWorkoutStatus(_ status: String) -> Bool {
        status != "skipped" && status != "discarded"
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
        // M4 (multisport) — a trip day is not a scheduled strength workout
        // (unavailable = blacked out; light = unstructured travel training).
        case .rest, .none, .unavailable, .light: isWorkout = false
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
        case .rest, .none, .unavailable, .light:
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
            // M4 (multisport) — trip days are not the next strength workout
            // (unavailable = blacked out; light = unstructured travel). Skip.
            case .rest, .none, .unavailable, .light:
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

    private func handle(_ error: Error, jwt: String) {
        if case let APIError.http(code, _) = error, code == 401 {
            if isCurrentAccount(using: jwt) {
                auth.requireReauthentication()
            }
        } else {
            loadError = error.localizedDescription
        }
    }
}

private extension SetLog {
    func replacingSessionID(with sessionID: String) -> SetLog {
        SetLog(
            id: id,
            session_id: sessionID,
            exercise_id: exercise_id,
            template_exercise_id: template_exercise_id,
            set_index: set_index,
            weight: weight,
            reps: reps,
            rpe: rpe,
            is_warmup: is_warmup,
            logged_at: logged_at,
            duration_s: duration_s,
            is_timed: is_timed,
            deleted_at: deleted_at)
    }
}
