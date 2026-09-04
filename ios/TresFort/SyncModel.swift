import Combine
import SwiftUI

private struct SessionWriteConflictPayload: Decodable {
    let error: String
    let current_session: SessionRow
}

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
    /// True while the visible plan/calendar came from the last successful
    /// account-scoped snapshot rather than a live `/api/state` response.
    @Published private(set) var isUsingCachedState = false
    /// A persisted runner becomes actionable only after a live state pull
    /// confirms that today's server session is still in progress.
    @Published private(set) var resumableCheckpoint: WorkoutRunnerCheckpoint?
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
    @Published private(set) var isReopeningSkippedWorkout = false

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
    private let catalogAPI: any ExerciseCatalogAPI
    private unowned let auth: AuthModel
    private let accountID: String?
    private let featureSessionEpoch: UInt64
    private let defaults: UserDefaults
    private let uuidFactory: () -> UUID
    private let now: () -> Date
    private let restActivityUpdater: (Date, String) -> Void
    private var timedSetCompletionTask: Task<Void, Never>?
    private var persistedRunnerCheckpoint: WorkoutRunnerCheckpoint?
    /// Restart authorization belongs to the mounted runner, not a generic
    /// date-level create. It is persisted in the checkpoint until creation
    /// binds the new session attempt.
    private var runnerRestartDiscardedAttempt: Int?
    /// Durable queues are shared for truthful presentation, but each model
    /// sends only intents it loaded at construction or enqueued itself. An old
    /// reauthentication model must not become a second sender for work created
    /// by its replacement.
    private var ownedSetIntentIDs: Set<String>
    private var ownedTerminalIntentIDs: Set<String>
    private var sendingTerminalIntentID: String?
    private var isDrainingWorkoutWrites = false
    private var workoutWriteDrainRequested = false
    private var workoutWriteDrainWaiters: [CheckedContinuation<Void, Never>] = []
    /// Full-state refresh belongs to the account-scoped model, not to the
    /// SwiftUI task that happened to request it. Pull-to-refresh may cancel
    /// its view task as the scroll hierarchy changes; keeping one unstructured
    /// model-owned task lets that already-started validation finish, and
    /// coalesces only equivalent full-state requests. A mutation or bearer
    /// change waits for an older task and then owns one trailing fresh pull.
    private struct StateLoadKey: Equatable {
        let bearer: String
        let freshnessGeneration: UInt64
        let featureSessionEpoch: UInt64
    }
    private var stateLoadTask: Task<Void, Never>?
    private var stateLoadTaskID: UUID?
    private var stateLoadKey: StateLoadKey?
    private var stateFreshnessGeneration: UInt64 = 0
    private var activityPersistenceCancellable: AnyCancellable?
    /// Loading presentation is tracked separately from full-state freshness:
    /// account-scoped snapshot tickets own freshness, while an outbox
    /// reconciliation can supersede a load without owning its spinner.
    private var loadGeneration = 0
    private var statePlanVersion = 0
    private var stateServerTime = 0

    init(
        auth: AuthModel,
        setWriteAPI: any SetWriteAPI = APIClient(),
        terminalAPI: any WorkoutTerminalAPI = APIClient(),
        catalogAPI: any ExerciseCatalogAPI = APIClient(),
        defaults: UserDefaults = .standard,
        uuidFactory: @escaping () -> UUID = UUID.init,
        now: @escaping () -> Date = Date.init,
        restActivityUpdater: @escaping (Date, String) -> Void = {
            endDate, upNext in
            RestLiveActivity.update(endDate: endDate, upNext: upNext)
        }
    ) {
        self.auth = auth
        self.accountID = auth.userID
        self.featureSessionEpoch = auth.featureSessionEpoch
        self.setWriteAPI = setWriteAPI
        self.terminalAPI = terminalAPI
        self.catalogAPI = catalogAPI
        self.defaults = defaults
        self.uuidFactory = uuidFactory
        self.now = now
        self.restActivityUpdater = restActivityUpdater
        let persistedCheckpoint = WorkoutRunnerCheckpointStore.load(
            userID: auth.userID, defaults: defaults)
        self.persistedRunnerCheckpoint = persistedCheckpoint
        self.runnerRestartDiscardedAttempt =
            persistedCheckpoint?.restartDiscardedAttempt
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
        self.ownedSetIntentIDs = Set(persistedSets.pending.map(\.id))
        self.ownedTerminalIntentIDs = Set(
            persistedTerminals.intents.map(\.id))
        for intent in persistedTerminals.intents where intent.action == .discard {
            SetOutboxStore.remove(
                date: intent.date, userID: auth.userID, defaults: defaults)
        }
        self.catalog = ExerciseCatalogSnapshotStore.load(
            userID: auth.userID, defaults: defaults) ?? []
        // Cache is presentation-only. It must not acknowledge an outbox or
        // make a runner resumable; both decisions wait for a live pull.
        if let cached = StateSnapshotStore.load(
            userID: auth.userID, defaults: defaults)
        {
            replaceState(with: cached.state, isLiveResponse: false)
            isUsingCachedState = true
        }
        activityPersistenceCancellable = auth.$activityPersistenceGeneration
            .dropFirst()
            .sink { [weak self] _ in
                Task { @MainActor [weak self] in
                    await self?.loadAfterMutation()
                }
            }
    }

    /// Bind every request to the account that created this model. An old
    /// MainTab task may finish after AuthModel switches users; it must never
    /// continue using the replacement account's bearer.
    private var currentJWT: String? {
        guard let accountID, auth.userID == accountID else { return nil }
        return auth.featureJWT
    }

    /// Exact bearer identity is only relevant to a 401: an old request must
    /// never invalidate a newer bearer installed by same-account renewal.
    private func isCurrentBearer(_ jwt: String) -> Bool {
        guard let accountID, auth.userID == accountID else { return false }
        return auth.featureJWT == jwt
    }

    /// Successful reads remain valid across a bearer renewal for the same
    /// account. A different account, absent feature session, or deletion
    /// invalidates the response.
    private var isCurrentAccount: Bool {
        guard let accountID, auth.userID == accountID else { return false }
        return auth.featureJWT != nil && !auth.accountDeletionPending
    }

    /// Set callbacks may complete after same-account bearer renewal or
    /// recoverable reauthentication, so bearer and feature-session identity are
    /// intentionally not part of this check. Owned-intent and granular-store
    /// guards let the old callback settle its write without touching work
    /// created by the replacement model. Account switch and deletion remain
    /// invalidating boundaries.
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
        await load(requiringFreshness: stateFreshnessGeneration)
    }

    /// A successful server mutation needs a state request that starts after the
    /// mutation. It may wait behind an older pull, but it must never merely join
    /// that pull and mistake pre-mutation state for reconciliation.
    func loadAfterMutation() async {
        stateFreshnessGeneration &+= 1
        await load(requiringFreshness: stateFreshnessGeneration)
    }

    private func load(requiringFreshness requiredFreshness: UInt64) async {
        while let activeTask = stateLoadTask {
            let canJoin = stateLoadKey.map {
                $0.bearer == currentJWT
                    && $0.freshnessGeneration >= requiredFreshness
                    && $0.featureSessionEpoch == auth.featureSessionEpoch
            } ?? false
            await activeTask.value
            if canJoin { return }
        }
        guard auth.featureSessionEpoch == featureSessionEpoch,
              let jwt = currentJWT else { return }
        let taskID = UUID()
        let key = StateLoadKey(
            bearer: jwt,
            freshnessGeneration: stateFreshnessGeneration,
            featureSessionEpoch: featureSessionEpoch)
        stateLoadTaskID = taskID
        stateLoadKey = key
        let task = Task { @MainActor [weak self] in
            guard let self else { return }
            await self.performLoad(key: key)
            self.finishStateLoad(taskID: taskID)
        }
        stateLoadTask = task
        await task.value
    }

    private func finishStateLoad(taskID: UUID) {
        if stateLoadTaskID == taskID {
            stateLoadTask = nil
            stateLoadTaskID = nil
            stateLoadKey = nil
        }
    }

    private func performLoad(key: StateLoadKey) async {
        let jwt = key.bearer
        loadGeneration += 1
        let thisLoadGeneration = loadGeneration
        guard let snapshotTicket = StateSnapshotStore.reserveFullStateRequest(
            userID: accountID, defaults: defaults)
        else {
            loadError = "Couldn't reserve local sync state."
            return
        }
        isLoading = true
        defer {
            if thisLoadGeneration == loadGeneration { isLoading = false }
        }
        do {
            let state = try await setWriteAPI.getState(jwt: jwt)
            guard isCurrentAccount, canMutateBoundSetAccount,
                  key.featureSessionEpoch == featureSessionEpoch,
                  key.featureSessionEpoch == auth.featureSessionEpoch,
                  key.freshnessGeneration == stateFreshnessGeneration else { return }
            guard applyLiveStateResponse(
                state,
                ticket: snapshotTicket
            ) else { return }
            // A cached catalog is presentation-only too: always attempt a live
            // replacement after state succeeds so renamed exercises and changed
            // load semantics do not freeze forever. A catalog failure retains
            // the last successful rows, matching the pre-cache best-effort load.
            if let catalogJWT = currentJWT,
               let rows = try? await catalogAPI.getExercises(jwt: catalogJWT) {
                guard isCurrentAccount, canMutateBoundSetAccount,
                      key.featureSessionEpoch == featureSessionEpoch,
                      key.featureSessionEpoch == auth.featureSessionEpoch,
                      key.freshnessGeneration == stateFreshnessGeneration,
                      StateSnapshotStore.isCurrent(
                          snapshotTicket, defaults: defaults)
                else { return }
                catalog = rows
                ExerciseCatalogSnapshotStore.save(
                    rows, userID: accountID, defaults: defaults)
            }
            loadError = nil
        } catch {
            guard StateSnapshotStore.isCurrent(
                      snapshotTicket, defaults: defaults),
                  isCurrentAccount, canMutateBoundSetAccount,
                  key.featureSessionEpoch == featureSessionEpoch,
                  key.featureSessionEpoch == auth.featureSessionEpoch,
                  key.freshnessGeneration == stateFreshnessGeneration
            else { return }
            let isUnauthorized: Bool
            if case let APIError.http(code, _) = error {
                isUnauthorized = code == 401
            } else {
                isUnauthorized = false
            }
            if isCurrentAccount, plan != nil,
               !(error is CancellationError),
               !isUnauthorized
            {
                isUsingCachedState = true
            }
            handle(error, jwt: jwt)
        }
    }

    /// Apply a full `/api/state` response atomically at the cache boundary.
    /// `getState` always uses zero watermarks, so every collection is a full
    /// replacement rather than a delta merge.
    func replaceState(
        with state: StateResponse,
        preferredTodaySessionID: String? = nil,
        isLiveResponse: Bool = true
    ) {
        // Direct live applications are used by deterministic model tests. They
        // reserve the same account-scoped ticket as a network pull so they also
        // invalidate older responses from another SyncModel instance.
        if isLiveResponse {
            guard let ticket = StateSnapshotStore.reserveFullStateRequest(
                userID: accountID, defaults: defaults)
            else { return }
            _ = applyLiveStateResponse(
                state,
                ticket: ticket,
                preferredTodaySessionID: preferredTodaySessionID)
        } else {
            applyState(
                state,
                preferredTodaySessionID: preferredTodaySessionID,
                isLiveResponse: false)
        }
    }

    /// Single freshness gate for every fetched full-state response. Keeping the
    /// check immediately beside the shared apply/persist boundary prevents a
    /// future caller from updating presentation but forgetting the snapshot (or
    /// vice versa).
    @discardableResult
    private func applyLiveStateResponse(
        _ state: StateResponse,
        ticket: StateSnapshotTicket,
        preferredTodaySessionID: String? = nil
    ) -> Bool {
        guard canMutateBoundSetAccount,
              StateSnapshotStore.commitFullState(
                  state, ticket: ticket, defaults: defaults) != nil
        else { return false }
        applyState(
            state,
            preferredTodaySessionID: preferredTodaySessionID,
            isLiveResponse: true)
        return true
    }

    private func applyState(
        _ state: StateResponse,
        preferredTodaySessionID: String?,
        isLiveResponse: Bool
    ) {
        let previousSelectedDayID = selectedDayID
        let runnerWasActive = running
        let activeSlotID = activeRunnerSlotID()
        statePlanVersion = state.plan_version
        stateServerTime = state.server_time
        plan = state.plan
        if isLiveResponse {
            // A replacement model may have cleared or superseded this
            // instance's in-memory writes. Adopt the account store before a
            // live response is allowed to acknowledge or requeue anything.
            adoptDurableWorkoutWriteOutboxes()
            reconcileTerminalOutbox(with: state.sessions)
        }
        let maskedDates = discardBarrierDates
        let maskedSessionIDs = Set(state.sessions.lazy.filter {
            maskedDates.contains($0.date)
        }.map(\.id))
        sessions = state.sessions.filter { !maskedDates.contains($0.date) }
        sets = state.sets.filter { !maskedSessionIDs.contains($0.session_id) }
        if isLiveResponse { reconcileSetOutboxWithServerSets() }
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
        if isLiveResponse {
            isUsingCachedState = false
            validatePersistedRunnerCheckpoint()
        }
    }

    /// Fallback only for the first accepted mutation before this install has a
    /// snapshot. ACK persistence always transforms the newest account snapshot,
    /// never blindly overwrites it with this model's projection.
    private func currentStateResponse() -> StateResponse {
        StateResponse(
            plan: plan,
            plan_version: max(statePlanVersion, plan?.version ?? 0),
            sessions: sessions,
            sets: sets,
            external_events: rides,
            external_activities: activities,
            activities: manualActivities,
            // Mutation responses carry no replacement state watermark.
            server_time: stateServerTime)
    }

    /// Another same-account model removes an intent only after merging its ACK
    /// into the shared snapshot. When this model discovers that removal, adopt
    /// that snapshot immediately so the retained UI cannot offer a duplicate
    /// set or keep a runner mounted against a terminal session.
    @discardableResult
    private func adoptLatestAcknowledgedSnapshot(for date: String) -> Bool {
        guard let snapshot = StateSnapshotStore.load(
            userID: accountID, defaults: defaults)
        else { return false }
        let terminalStatuses = Set(["completed", "skipped", "discarded"])
        let terminal = snapshot.state.sessions.first {
            $0.date == date && terminalStatuses.contains($0.status)
        }
        applyState(
            snapshot.state,
            preferredTodaySessionID: nil,
            isLiveResponse: false)
        if terminal != nil,
           persistedRunnerCheckpoint?.date == date || (running && date == todayString)
        {
            stopRunnerForStateChange()
        } else {
            normalizeMountedRunnerProgress(for: date)
        }
        return true
    }

    private func persistSetAcknowledgement(
        _ result: APIClient.SetLogResult,
        submittedSession: SessionRow
    ) -> Bool {
        guard canMutateBoundSetAccount else { return false }
        let acknowledgedSession = Self.sessionAcknowledgedBySet(
            result, submittedSession: submittedSession)
        return StateSnapshotStore.mergeAcknowledgement(
            userID: accountID,
            fallback: currentStateResponse(),
            defaults: defaults
        ) { newest in
            Self.mergingSetAcknowledgement(
                into: newest,
                acceptedSet: result.set,
                acknowledgedSession: acknowledgedSession)
        } != nil
    }

    private func persistTerminalAcknowledgement(
        _ response: SessionRow,
        action: WorkoutTerminalAction
    ) -> Bool {
        guard canMutateBoundSetAccount else { return false }
        return StateSnapshotStore.mergeAcknowledgement(
            userID: accountID,
            fallback: currentStateResponse(),
            defaults: defaults
        ) { newest in
            Self.mergingTerminalAcknowledgement(
                into: newest, response: response, action: action)
        } != nil
    }

    /// Session creation/revival is itself an attempt mutation. Merge it into
    /// the shared snapshot before any later await or durable intent binding so
    /// a full-state request that started before the create cannot overwrite the
    /// new generation. Returns the newest same-attempt session from that merge.
    private func acceptSessionResolution(_ response: SessionRow) -> SessionRow? {
        guard canMutateBoundSetAccount,
              let merged = StateSnapshotStore.mergeAcknowledgement(
                userID: accountID,
                fallback: currentStateResponse(),
                defaults: defaults,
                transform: { newest in
                    Self.mergingSessionResolution(
                        into: newest, response: response)
                })
        else { return nil }
        guard let authoritative = Self.newestSession(
            in: merged.state.sessions.filter { $0.date == response.date }),
              authoritative.id == response.id,
              response.attempt == nil
                || authoritative.attempt == nil
                || authoritative.attempt == response.attempt
        else { return nil }
        applyState(
            merged.state,
            preferredTodaySessionID: authoritative.id,
            isLiveResponse: false)
        return authoritative
    }

    /// Merge only the facts proved by a set response into the newest account
    /// snapshot. Every unrelated plan/session/activity remains from that newest
    /// baseline, which may belong to a replacement SyncModel instance.
    private enum SessionResponseKind {
        case set
        case finish
        case discard
        case resolution
    }

    private static func responseCanReplaceSession(
        _ current: SessionRow,
        with response: SessionRow,
        kind: SessionResponseKind
    ) -> Bool {
        // Migration 0032 assigns every legacy row generation zero. Normalize
        // a rolling-old-Worker nil the same way before status precedence: an
        // explicit attempt 0 is not evidence that a same-generation terminal
        // observation may be demoted to planned.
        let currentAttempt = current.attempt ?? 0
        let responseAttempt = response.attempt ?? 0
        if currentAttempt != responseAttempt {
            return responseAttempt > currentAttempt
        }

        switch kind {
        case .set:
            if ["completed", "skipped", "discarded"].contains(current.status),
               current.status != response.status
            {
                return false
            }
        case .finish:
            if current.status == "discarded",
               response.status != "discarded"
            {
                return false
            }
        case .discard:
            // Within one attempt, discard is the sanctioned transition that
            // overrides every other status. A later restart has a greater
            // attempt and was handled above.
            return true
        case .resolution:
            // Date resolution and 409 current_session observations can be
            // captured before a later set/terminal acknowledgement reaches
            // the shared snapshot. Within one attempt they may advance state,
            // but never demote it merely because equal-millisecond timestamps
            // make the stale observation look tied.
            if ["completed", "skipped", "discarded"].contains(current.status),
               current.status != response.status
            {
                return false
            }
            if current.status == "in_progress", response.status == "planned" {
                return false
            }
        }

        switch (current.updated_at, response.updated_at) {
        case let (currentTS?, responseTS?):
            return responseTS >= currentTS
        case (nil, _?):
            return true
        case (_?, nil):
            return false
        case (nil, nil):
            // Rolling old Workers cannot prove causality. Preserve a terminal
            // observation; otherwise retain the pre-timestamp behavior.
            return !["completed", "skipped", "discarded"].contains(
                current.status)
        }
    }

    private static func sessionAcknowledgedBySet(
        _ result: APIClient.SetLogResult,
        submittedSession: SessionRow
    ) -> SessionRow {
        if let session = result.session { return session }
        // Rolling old Workers did not echo the session, but a successful set
        // ACK has always atomically promoted planned -> in_progress. Infer only
        // that one transition; merge precedence still protects any terminal
        // session already observed in the newest snapshot.
        guard submittedSession.status == "planned" else {
            return submittedSession
        }
        return SessionRow(
            id: result.set.session_id,
            date: submittedSession.date,
            status: "in_progress",
            day_template_id: submittedSession.day_template_id,
            updated_at: submittedSession.updated_at,
            attempt: submittedSession.attempt)
    }

    private static func newestSession(
        in rows: [SessionRow]
    ) -> SessionRow? {
        let terminalStatuses = Set(["completed", "skipped", "discarded"])
        return rows.max { lhs, rhs in
            let lhsTS = lhs.updated_at ?? Int.min
            let rhsTS = rhs.updated_at ?? Int.min
            if lhsTS != rhsTS { return lhsTS < rhsTS }
            return !terminalStatuses.contains(lhs.status)
                && terminalStatuses.contains(rhs.status)
        }
    }

    private static func mergingSetAcknowledgement(
        into state: StateResponse,
        acceptedSet: SetLog,
        acknowledgedSession: SessionRow
    ) -> StateResponse {
        var sessions = state.sessions
        var sets = state.sets
        let sameDateSessions = sessions.filter {
            $0.date == acknowledgedSession.date
        }
        let current = newestSession(in: sameDateSessions)
        let responseWins = current == nil
            || responseCanReplaceSession(
                current!, with: acknowledgedSession, kind: .set)
        let source = responseWins
            ? acknowledgedSession
            : current ?? acknowledgedSession
        var aliasIDs = Set(sameDateSessions.map(\.id))
        aliasIDs.insert(acknowledgedSession.id)
        aliasIDs.insert(acceptedSet.session_id)
        let canonical = SessionRow(
            id: acceptedSet.session_id,
            date: acknowledgedSession.date,
            status: source.status,
            day_template_id: source.day_template_id,
            updated_at: source.updated_at,
            attempt: source.attempt)
        sessions.removeAll { $0.date == acknowledgedSession.date }
        sessions.append(canonical)
        sets = sets.map { row in
            aliasIDs.contains(row.session_id)
                ? row.replacingSessionID(with: acceptedSet.session_id)
                : row
        }
        let effectiveDiscard = source.status == "discarded"
        if effectiveDiscard {
            // A newer/canonical discarded session proves the backend
            // tombstoned the whole workout, not only this exact retry.
            sets.removeAll { $0.session_id == acceptedSet.session_id }
        }

        if effectiveDiscard {
            // The session outcome owns visibility. A rolling/inconsistent live
            // set row must never resurrect work beneath a discarded session.
        } else if acceptedSet.deleted_at != nil {
            // An exact old-UUID retry can settle after discard/restart. Its
            // tombstone is authoritative for that UUID but is not live work in
            // the newer session generation.
            sets.removeAll { $0.id == acceptedSet.id }
        } else if let index = sets.firstIndex(where: { $0.id == acceptedSet.id }) {
            // A newer cached tombstone must not be resurrected by a delayed
            // deduped ACK from an older model.
            if sets[index].deleted_at == nil { sets[index] = acceptedSet }
        } else {
            sets.append(acceptedSet)
        }
        return StateResponse(
            plan: state.plan,
            plan_version: state.plan_version,
            sessions: sessions,
            sets: sets,
            external_events: state.external_events,
            external_activities: state.external_activities,
            activities: state.activities,
            server_time: state.server_time)
    }

    private static func mergingTerminalAcknowledgement(
        into state: StateResponse,
        response: SessionRow,
        action: WorkoutTerminalAction
    ) -> StateResponse {
        var sessions = state.sessions
        var sets = state.sets
        let sameDateSessions = sessions.filter { $0.date == response.date }
        if let current = newestSession(in: sameDateSessions),
           !responseCanReplaceSession(
               current,
               with: response,
               kind: action == .discard ? .discard : .finish)
        {
            return state
        }
        let sameDateSessionIDs = Set(
            sameDateSessions.map(\.id))
            .union([response.id])
        sessions.removeAll { $0.date == response.date }
        sessions.append(response)
        if action == .discard {
            sets.removeAll { sameDateSessionIDs.contains($0.session_id) }
        } else {
            sets = sets.map { row in
                sameDateSessionIDs.contains(row.session_id)
                    ? row.replacingSessionID(with: response.id)
                    : row
            }
        }
        return StateResponse(
            plan: state.plan,
            plan_version: state.plan_version,
            sessions: sessions,
            sets: sets,
            external_events: state.external_events,
            external_activities: state.external_activities,
            activities: state.activities,
            server_time: state.server_time)
    }

    /// Merge a date-level create/revive response without allowing its
    /// necessarily pre-write `planned` view to regress a same-attempt set or
    /// terminal acknowledgement. A greater attempt starts a clean generation;
    /// a lower attempt is stale; the same attempt preserves the newest status.
    private static func mergingSessionResolution(
        into state: StateResponse,
        response: SessionRow
    ) -> StateResponse {
        var sessions = state.sessions
        var sets = state.sets
        let sameDate = sessions.filter { $0.date == response.date }
        let current = newestSession(in: sameDate)
        if let currentAttempt = current?.attempt,
           let responseAttempt = response.attempt,
           responseAttempt < currentAttempt
        {
            return state
        }
        let advancesAttempt: Bool
        if let currentAttempt = current?.attempt,
           let responseAttempt = response.attempt
        {
            advancesAttempt = responseAttempt > currentAttempt
        } else {
            // Migration 0032 assigns every pre-attempt row generation zero.
            // A cached rolling-old-Worker row therefore means attempt 0, not
            // "unknown generation": an ordinary new-Worker create response at
            // attempt 0 must retain its already-acknowledged sets. Only a
            // positive response attempt proves an actual restart advance.
            advancesAttempt = current != nil && (response.attempt ?? 0) > 0
        }
        let responseWins = current == nil
            || responseCanReplaceSession(
                current!, with: response, kind: .resolution)
        let source = advancesAttempt || responseWins ? response : current!
        let canonical = SessionRow(
            id: response.id,
            date: response.date,
            status: source.status,
            day_template_id: source.day_template_id ?? response.day_template_id,
            updated_at: source.updated_at,
            attempt: source.attempt ?? response.attempt)
        let aliases = Set(sameDate.map(\.id)).union([response.id])
        sessions.removeAll { $0.date == response.date }
        sessions.append(canonical)
        if advancesAttempt {
            sets.removeAll { aliases.contains($0.session_id) }
        } else {
            sets = sets.map { row in
                aliases.contains(row.session_id)
                    ? row.replacingSessionID(with: response.id)
                    : row
            }
            if canonical.status == "discarded" {
                sets.removeAll { $0.session_id == response.id }
            }
        }
        return StateResponse(
            plan: state.plan,
            plan_version: state.plan_version,
            sessions: sessions,
            sets: sets,
            external_events: state.external_events,
            external_activities: state.external_activities,
            activities: state.activities,
            server_time: state.server_time)
    }

    /// Apply a terminal response to the mounted model using the same alias and
    /// date-scoped rules as snapshot persistence. This keeps the immediate
    /// completion recap correct even when a stale migration id resolves to the
    /// canonical session and no follow-up state pull succeeds.
    @discardableResult
    private func applyTerminalAcknowledgementLocally(
        _ response: SessionRow,
        action: WorkoutTerminalAction
    ) -> Bool {
        if let current = Self.newestSession(
            in: sessions.filter { $0.date == response.date }),
           !Self.responseCanReplaceSession(
               current,
               with: response,
               kind: action == .discard ? .discard : .finish)
        {
            return false
        }
        let sameDateSessionIDs = Set(
            sessions.lazy.filter { $0.date == response.date }.map(\.id))
            .union([response.id])
        sessions.removeAll { $0.date == response.date }
        sessions.append(response)
        if action == .discard {
            sets.removeAll { sameDateSessionIDs.contains($0.session_id) }
        } else {
            sets = sets.map { row in
                sameDateSessionIDs.contains(row.session_id)
                    ? row.replacingSessionID(with: response.id)
                    : row
            }
        }
        if response.date == todayString { todaySession = response }
        return true
    }

    /// Full state is an independent acknowledgement path for commit-then-
    /// timeout. It also detects the only operation that can intentionally
    /// revive a discarded date (a later explicit restart); until the local
    /// user clears the acknowledged barrier, an unexpected revival requeues
    /// discard and stays masked.
    private func reconcileTerminalOutbox(with serverSessions: [SessionRow]) {
        guard canMutateBoundSetAccount else { return }
        for var intent in terminalOutbox.intents
        where ownedTerminalIntentIDs.contains(intent.id) {
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
                if let row, row.status == "discarded" {
                    // The server outcome is authoritative even when another
                    // device discarded a later generation before this queued
                    // intent sent. Rebind the barrier to that exact attempt so
                    // the next explicit restart can advance it once.
                    terminalOutbox.acknowledgeDiscard(
                        id: intent.id,
                        resolvedSessionID: row.id,
                        expectedAttempt: row.attempt)
                    WorkoutTerminalOutboxStore.acknowledgeDiscard(
                        id: intent.id,
                        resolvedSessionID: row.id,
                        expectedAttempt: row.attempt,
                        userID: accountID,
                        defaults: defaults)
                } else if intent.deliveryState == .acknowledged, row != nil {
                    guard let revivedSession = row else { continue }
                    // A greater attempt is an explicit restart boundary. The
                    // old device's acknowledged barrier must not mask or
                    // discard a new workout created on another device.
                    if let revivedAttempt = revivedSession.attempt {
                        // Every pre-0032 barrier necessarily belongs to the
                        // migration-default attempt 0. A greater live attempt
                        // is therefore definitive restart evidence even when
                        // the decoded legacy intent has no stored token.
                        let barrierAttempt = intent.expectedAttempt ?? 0
                        if revivedAttempt > barrierAttempt {
                            terminalOutbox.clearAcknowledgedDiscard(
                                date: intent.date)
                            WorkoutTerminalOutboxStore.clearAcknowledgedDiscard(
                                date: intent.date,
                                userID: accountID,
                                defaults: defaults)
                            ownedTerminalIntentIDs.remove(intent.id)
                            continue
                        }
                        // A lower generation is stale evidence; retain the
                        // mask but do not send a mutation that will conflict.
                        if revivedAttempt < barrierAttempt { continue }
                    }
                    // Same-attempt (or rolling-version unknown) revival can
                    // only be a late pre-discard mutation. Reassert discard.
                    let revivedSessionID = revivedSession.id
                    terminalOutbox.requeueAcknowledgedDiscard(
                        date: intent.date,
                        resolvedSessionID: revivedSessionID,
                        expectedAttempt: revivedSession.attempt)
                    WorkoutTerminalOutboxStore.requeueAcknowledgedDiscard(
                        date: intent.date,
                        resolvedSessionID: revivedSessionID,
                        expectedAttempt: revivedSession.attempt,
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
        clearTimedSet()
        skipped = []
        clearRunnerCheckpoint()
        skipRest()
    }

    private func validatePersistedRunnerCheckpoint() {
        guard var checkpoint = persistedRunnerCheckpoint else {
            resumableCheckpoint = nil
            return
        }
        // The mounted runner already owns this checkpoint and must not expose
        // a second resume CTA. A live pull still owns terminal precedence:
        // once a bound server session is no longer planned/in progress, the
        // local runner cannot keep accepting sets into that completed,
        // skipped, or discarded attempt. A nil session id is the intentional
        // pre-first-write state (including an explicit restart after discard),
        // so there is no server attempt to validate yet.
        guard !running else {
            resumableCheckpoint = nil
            let serverSession = checkpoint.sessionID.flatMap { boundSessionID in
                sessions.first {
                    $0.id == boundSessionID
                }
            } ?? sessions.first { $0.date == checkpoint.date }
            if let serverSession {
                if let checkpointAttempt = checkpoint.sessionAttempt,
                   let serverAttempt = serverSession.attempt,
                   checkpointAttempt != serverAttempt
                {
                    stopRunnerForStateChange()
                    return
                }
                // A nil-bound runner plus a discarded row is the accepted
                // explicit-restart boundary: the new local attempt has not
                // written its first set yet, so the old discarded row remains
                // visible until date-level create revives it. Every other
                // terminal row wins immediately, including one created and
                // completed remotely after this runner started.
                if checkpoint.sessionID == nil,
                   serverSession.status == "discarded"
                {
                    if checkpoint.restartDiscardedAttempt != nil,
                       checkpoint.restartDiscardedAttempt
                        == serverSession.attempt
                    {
                        persistRunnerCheckpoint()
                        return
                    }
                    stopRunnerForStateChange()
                    return
                }
                guard serverSession.status == "planned"
                        || serverSession.status == "in_progress"
                else {
                    stopRunnerForStateChange()
                    return
                }
            }
            persistRunnerCheckpoint()
            return
        }
        let checkpointSession = checkpoint.sessionID.flatMap { sessionID in
            sessions.first { $0.id == sessionID }
        } ?? sessions.first { $0.date == checkpoint.date }
        if let checkpointAttempt = checkpoint.sessionAttempt,
           let serverAttempt = checkpointSession?.attempt,
           checkpointAttempt != serverAttempt
        {
            clearRunnerCheckpoint()
            return
        }
        let hasPendingFirstSet = setOutbox.pending.contains {
            $0.date == checkpoint.date
        }
        // A successfully-created session remains `planned` until its first set
        // lands. If that second request is still durable, preserve (and bind)
        // the runner checkpoint rather than mistaking `planned` for a remote
        // cancellation. It becomes resumable only after a later live pull sees
        // `in_progress`; until then the pending intent blocks alternate starts.
        if checkpoint.date == todayString,
           terminalOutbox.intent(for: checkpoint.date) == nil,
           (checkpointSession == nil
                || checkpointSession?.status == "planned"
                || (checkpoint.sessionID == nil
                    && checkpoint.restartDiscardedAttempt != nil
                    && checkpoint.restartDiscardedAttempt
                        == checkpointSession?.attempt
                    && checkpointSession?.status == "discarded")),
           hasPendingFirstSet
        {
            if let checkpointSession,
               checkpointSession.status != "discarded"
            {
                bindRunnerCheckpoint(to: checkpointSession)
            }
            resumableCheckpoint = nil
            return
        }
        guard checkpoint.date == todayString,
              terminalOutbox.intent(for: checkpoint.date) == nil,
              let serverSession = checkpointSession,
              serverSession.status == "in_progress",
              let day = plan?.days.first(where: {
                  $0.id == checkpoint.selectedDayID
              }),
              !day.exercises.isEmpty,
              checkpoint.workoutStartedAtMS > 0,
              let currentSlotID = checkpoint.currentSlotID,
              let currentIndex = day.exercises.firstIndex(where: {
                  $0.id == currentSlotID
              })
        else {
            clearRunnerCheckpoint()
            return
        }

        let liveSlotIDs = Set(day.exercises.map(\.id))
        let normalizedSkipped = checkpoint.skippedSlotIDs
            .filter { liveSlotIDs.contains($0) }
            .sorted()
        let skippedIDs = Set(normalizedSkipped)
        let unresolvedIndices = Set(day.exercises.indices.filter { index in
            let slot = day.exercises[index]
            return !skippedIDs.contains(slot.id)
                && slotSets(
                    slot,
                    sessionID: serverSession.id,
                    dayExercises: day.exercises
                ).count < slot.target_sets
        })
        let normalizedFinished = unresolvedIndices.isEmpty
        let normalizedCurrentSlotID: String
        if normalizedFinished || unresolvedIndices.contains(currentIndex) {
            normalizedCurrentSlotID = currentSlotID
        } else {
            // Mirror the mounted runner's wrapped next-unresolved rule. This
            // advances a checkpoint left behind while its set request awaited
            // the network and lands an all-resolved workout on FinishedView.
            let nextIndex = (1...day.exercises.count)
                .map { (currentIndex + $0) % day.exercises.count }
                .first(where: unresolvedIndices.contains)!
            normalizedCurrentSlotID = day.exercises[nextIndex].id
        }
        let normalized = WorkoutRunnerCheckpoint(
            date: checkpoint.date,
            sessionID: serverSession.id,
            selectedDayID: checkpoint.selectedDayID,
            currentSlotID: normalizedCurrentSlotID,
            skippedSlotIDs: normalizedSkipped,
            workoutStartedAtMS: checkpoint.workoutStartedAtMS,
            finished: normalizedFinished,
            sessionAttempt: serverSession.attempt ?? checkpoint.sessionAttempt,
            restartDiscardedAttempt: nil)
        if normalized != checkpoint {
            guard replaceRunnerCheckpoint(
                normalized, ifCurrent: checkpoint)
            else {
                relinquishStaleRunnerCheckpoint()
                return
            }
        }
        persistedRunnerCheckpoint = normalized
        runnerRestartDiscardedAttempt = nil
        // A recovered explicit override can legitimately differ from the
        // server session's immutable day pin. Align Today and its Resume CTA to
        // the validated checkpoint before mounting the runner.
        selectedDayID = normalized.selectedDayID
        resumableCheckpoint = normalized
    }

    private func persistRunnerCheckpoint() {
        guard canMutateBoundSetAccount,
              running,
              let selectedDayID,
              let workoutStart,
              let currentSlotID = activeRunnerSlotID()
        else { return }
        let checkpoint = WorkoutRunnerCheckpoint(
            date: todaySession?.date ?? todayString,
            sessionID: todaySession?.id,
            selectedDayID: selectedDayID,
            currentSlotID: currentSlotID,
            skippedSlotIDs: skipped.sorted(),
            workoutStartedAtMS: Int(
                (workoutStart.timeIntervalSince1970 * 1_000).rounded(.down)),
            finished: finished,
            sessionAttempt: todaySession?.attempt,
            restartDiscardedAttempt: runnerRestartDiscardedAttempt)
        let expected = persistedRunnerCheckpoint
        guard replaceRunnerCheckpoint(checkpoint, ifCurrent: expected) else {
            relinquishStaleRunnerCheckpoint()
            return
        }
        persistedRunnerCheckpoint = checkpoint
        resumableCheckpoint = nil
    }

    /// Session creation and the first set write are separate requests. Bind the
    /// durable runner checkpoint as soon as creation succeeds so a transient
    /// first-set failure cannot strand a nil-session checkpoint on relaunch.
    private func bindRunnerCheckpoint(to session: SessionRow) {
        guard canMutateBoundSetAccount,
              let checkpoint = persistedRunnerCheckpoint,
              checkpoint.date == session.date,
              checkpoint.sessionID != session.id
                || (checkpoint.sessionAttempt == nil && session.attempt != nil),
              checkpoint.sessionAttempt == nil
                || session.attempt == nil
                || checkpoint.sessionAttempt == session.attempt
        else { return }
        let bound = WorkoutRunnerCheckpoint(
            date: checkpoint.date,
            sessionID: session.id,
            selectedDayID: checkpoint.selectedDayID,
            currentSlotID: checkpoint.currentSlotID,
            skippedSlotIDs: checkpoint.skippedSlotIDs,
            workoutStartedAtMS: checkpoint.workoutStartedAtMS,
            finished: checkpoint.finished,
            sessionAttempt: session.attempt ?? checkpoint.sessionAttempt,
            restartDiscardedAttempt: nil)
        guard replaceRunnerCheckpoint(bound, ifCurrent: checkpoint) else {
            relinquishStaleRunnerCheckpoint()
            return
        }
        persistedRunnerCheckpoint = bound
        runnerRestartDiscardedAttempt = nil
        resumableCheckpoint = nil
    }

    @discardableResult
    private func clearRunnerCheckpoint() -> Bool {
        let expected = persistedRunnerCheckpoint
        persistedRunnerCheckpoint = nil
        runnerRestartDiscardedAttempt = nil
        resumableCheckpoint = nil
        return WorkoutRunnerCheckpointStore.clear(
            ifCurrent: expected,
            userID: accountID,
            defaults: defaults)
    }

    private func replaceRunnerCheckpoint(
        _ checkpoint: WorkoutRunnerCheckpoint,
        ifCurrent expected: WorkoutRunnerCheckpoint?
    ) -> Bool {
        if WorkoutRunnerCheckpointStore.replace(
            checkpoint,
            ifCurrent: expected,
            userID: accountID,
            defaults: defaults)
        {
            return true
        }
        // Two models can independently normalize to an identical checkpoint;
        // accepting that exact stored value is equivalent to a successful CAS.
        return WorkoutRunnerCheckpointStore.load(
            userID: accountID, defaults: defaults) == checkpoint
    }

    /// Stop only this stale model. Do not clear the durable checkpoint or rest
    /// cues: a newer same-account model owns them now.
    private func relinquishStaleRunnerCheckpoint() {
        persistedRunnerCheckpoint = nil
        resumableCheckpoint = nil
        running = false
        finished = false
        workoutStart = nil
        clearTimedSet()
        skipped = []
        loadError = "This workout continued in another app view. Refresh to continue."
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
        clearTimedSet()
        skipped = []
        clearRunnerCheckpoint()
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
            day_template_id: staleSession.day_template_id,
            updated_at: staleSession.updated_at,
            attempt: staleSession.attempt)

        sessions.removeAll { $0.date == staleSession.date }
        sessions.append(canonicalSession)
        sets = sets.map { row in
            aliasedSessionIDs.contains(row.session_id)
                ? row.replacingSessionID(with: committedSet.session_id)
                : row
        }
        if committedSet.deleted_at != nil {
            sets.removeAll { $0.id == committedSet.id }
        } else if let i = sets.firstIndex(where: { $0.id == committedSet.id }) {
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
        return slotSets(ex, sessionID: sid, dayExercises: exercises)
    }

    /// Slot attribution with explicit session/day inputs. Recovery uses the
    /// checkpoint's override day before `selectedDayID` is realigned, while the
    /// mounted runner delegates through `todaySlotSets` above.
    private func slotSets(
        _ ex: TemplateExercise,
        sessionID: String,
        dayExercises: [TemplateExercise]
    ) -> [SetLog] {
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
        let unique = dayExercises.filter {
            $0.exercise_id == ex.exercise_id && ($0.isWarmup ? 1 : 0) == warm
        }.count == 1
        return sets.filter { s in
            guard s.session_id == sessionID, s.deleted_at == nil else { return false }
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

    func totalReps(for sets: [SetLog]) -> Int {
        sets.filter { !isTimedSet($0) }.reduce(0) {
            $0 + effectiveReps(for: $1)
        }
    }

    func bestHoldSeconds(for sets: [SetLog]) -> Int? {
        sets.filter(isTimedSet).compactMap(\.duration_s).max()
    }

    /// Effective positive-load tonnage represented by one rep set. Strict
    /// bodyweight, assisted (negative-load), and timed work have no tonnage;
    /// their progress is represented by reps or hold duration instead.
    func tonnage(for set: SetLog) -> Double? {
        guard set.weight > 0, !isTimedSet(set) else { return nil }
        return set.weight * Double(effectiveReps(for: set))
            * Double(implements(for: set.exercise_id))
    }

    func totalTonnage(for sets: [SetLog]) -> Double? {
        let values = sets.compactMap { tonnage(for: $0) }
        return values.isEmpty ? nil : values.reduce(0, +)
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
        let est1RM: Double?
        let topWeight: Double
        let topReps: Int
        let totalReps: Int
        let volume: Double?
        let setCount: Int
        let bestHoldSeconds: Int?
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
        let bodyweight = isBodyweightExercise(exerciseID)
        return grouped.compactMap { sid, rows -> SessionStat? in
            guard let date = dateBySession[sid], !rows.isEmpty else { return nil }
            let timedRows = rows.filter(isTimedSet)
            let repRows = rows.filter { !isTimedSet($0) }
            let top: SetLog
            if bodyweight, let first = repRows.first {
                top = repRows.dropFirst().reduce(first) { best, row in
                    row.reps > best.reps
                        || (row.reps == best.reps && row.weight > best.weight)
                        ? row : best
                }
            } else if repRows.isEmpty, let first = timedRows.first {
                top = timedRows.dropFirst().reduce(first) { best, row in
                    (row.duration_s ?? 0) > (best.duration_s ?? 0) ? row : best
                }
            } else {
                top = repRows.max {
                    epley($0.weight, $0.reps) < epley($1.weight, $1.reps)
                } ?? rows[0]
            }
            let timedDurations = timedRows.compactMap(\.duration_s)
            return SessionStat(
                id: sid, date: date,
                est1RM: !isTimedSet(top) && top.weight > 0
                    ? epley(top.weight, top.reps).rounded()
                    : nil,
                topWeight: top.weight, topReps: top.reps,
                totalReps: totalReps(for: repRows),
                volume: totalTonnage(for: repRows),
                setCount: rows.count,
                bestHoldSeconds: timedDurations.max())
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

    /// UserDefaults is the same-account coordination boundary across multiple
    /// SyncModel instances. In-memory queues are presentation mirrors only;
    /// always adopt the granular durable stores before reconciliation or a
    /// network write so an older model cannot replay work a newer model
    /// cleared during discard/restart.
    private func adoptDurableWorkoutWriteOutboxes() {
        guard canMutateBoundSetAccount else { return }
        terminalOutbox = WorkoutTerminalOutboxStore.load(
            userID: accountID, defaults: defaults)
        setOutbox = SetOutboxStore.load(
            userID: accountID, defaults: defaults)
        ownedTerminalIntentIDs.formIntersection(
            terminalOutbox.intents.map(\.id))
        ownedSetIntentIDs.formIntersection(setOutbox.pending.map(\.id))
    }

    private func durableTerminalIntent(
        matching expected: WorkoutTerminalIntent
    ) -> WorkoutTerminalIntent? {
        guard canMutateBoundSetAccount,
              ownedTerminalIntentIDs.contains(expected.id)
        else { return nil }
        adoptDurableWorkoutWriteOutboxes()
        guard let current = terminalOutbox.intent(for: expected.date),
              current.id == expected.id
        else { return nil }
        return current
    }

    private func durableSetIntent(
        matching expected: PendingSetIntent
    ) -> PendingSetIntent? {
        guard canMutateBoundSetAccount,
              ownedSetIntentIDs.contains(expected.id)
        else { return nil }
        adoptDurableWorkoutWriteOutboxes()
        guard terminalOutbox.intent(for: expected.date)?.action != .discard,
              let current = setOutbox.pending.first(where: {
                  $0.id == expected.id
              })
        else { return nil }
        return current
    }

    func pendingSetIntents(for ex: TemplateExercise) -> [PendingSetIntent] {
        let date = todaySession?.date ?? todayString
        return setOutbox.pending.filter {
            $0.date == date && $0.slotID == ex.id
        }
    }

    func isSetEntryBlocked(slotID: String) -> Bool {
        if hasPendingTerminalIntentForCurrentWorkout || isTerminalMutationInFlight {
            return true
        }
        if setSlotsInFlight.contains(slotID) { return true }
        return setOutbox.pending.contains {
            $0.slotID == slotID && $0.deliveryState == .failed
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
        ownedSetIntentIDs.insert(intent.id)
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
        ownedSetIntentIDs.subtract(ids)
    }

    private func persistEnqueuedTerminalIntent(_ intent: WorkoutTerminalIntent) {
        guard canMutateBoundSetAccount else { return }
        WorkoutTerminalOutboxStore.enqueue(
            intent, userID: accountID, defaults: defaults)
        if WorkoutTerminalOutboxStore.load(
            userID: accountID, defaults: defaults
        ).intent(for: intent.date)?.id == intent.id {
            ownedTerminalIntentIDs.insert(intent.id)
        }
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
        ownedTerminalIntentIDs.remove(id)
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
        let acknowledgedDates = Set(setOutbox.pending.lazy.filter {
            acknowledgedPendingIDs.contains($0.id)
        }.map(\.date))
        for id in acknowledgedPendingIDs { setOutbox.remove(id: id) }
        persistRemovedSetIntentIDs(acknowledgedPendingIDs)
        for date in acknowledgedDates {
            normalizeMountedRunnerProgress(for: date)
        }
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
        normalizeMountedRunnerAfterLocalCommit(for: intent.date)
        await drainSetOutbox()
    }

    func retryFailedSetIntents() async {
        guard canMutateBoundSetAccount else { return }
        var changed = false
        var rearmedDates: Set<String> = []
        for var intent in setOutbox.pending where intent.deliveryState == .failed {
            intent.deliveryState = .queued
            intent.failedHTTPStatus = nil
            setOutbox.replace(intent)
            persistReplacedSetIntent(intent)
            rearmedDates.insert(intent.date)
            changed = true
        }
        guard changed else { return }
        for date in rearmedDates {
            normalizeMountedRunnerAfterLocalCommit(for: date)
        }
        await drainSetOutbox()
    }

    @discardableResult
    func logSet(_ ex: TemplateExercise, weight: Double, reps: Int,
                durationOverride: Int? = nil) async -> Bool {
        guard let intent = enqueueSetIntent(
            ex, weight: weight, reps: reps, durationOverride: durationOverride
        ) else { return false }
        defer { setSlotsInFlight.remove(ex.id) }

        await drainSetOutbox()
        guard canMutateBoundSetAccount else { return false }
        let acknowledged = !setOutbox.pending.contains(where: { $0.id == intent.id })
            && sets.contains(where: { $0.id == intent.id })
        if acknowledged && running {
            startRest(seconds: ex.rest_seconds, name: ex.exercise_name)
        }
        return acknowledged
    }

    /// Persist one complete, idempotent intent without waiting for the network.
    /// This is the offline-first commit boundary shared by the synchronous test
    /// helper above and the runner's optimistic UI path below.
    private func enqueueSetIntent(
        _ ex: TemplateExercise,
        weight: Double,
        reps: Int,
        durationOverride: Int?
    ) -> PendingSetIntent? {
        let workoutDate = todaySession?.date ?? todayString
        guard currentJWT != nil, canMutateBoundSetAccount,
              !isTerminalMutationInFlight,
              terminalOutbox.intent(for: workoutDate) == nil,
              !setSlotsInFlight.contains(ex.id)
        else { return nil }

        // Publish the guard before returning to the view task, so two button
        // Tasks created by a rapid double tap cannot both mint intents.
        setSlotsInFlight.insert(ex.id)

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
            failedHTTPStatus: nil,
            expectedAttempt: todaySession?.attempt,
            restartDiscardedAttempt: runnerRestartDiscardedAttempt)

        // No network await may occur above this save. A failed/lost session
        // create therefore leaves the complete intent available on relaunch.
        setOutbox.enqueue(intent)
        persistEnqueuedSetIntent(intent)
        return intent
    }

    /// The workout runner commits locally and advances immediately. Delivery
    /// is deliberately model-owned background work: a SwiftUI button task may
    /// disappear as the runner advances, but the durable intent must continue
    /// to send or remain visibly queued for a later retry.
    private func queueRunnerSet(
        _ ex: TemplateExercise,
        weight: Double,
        reps: Int,
        durationOverride: Int? = nil
    ) -> Bool {
        guard enqueueSetIntent(
            ex, weight: weight, reps: reps, durationOverride: durationOverride
        ) != nil else { return false }

        if running {
            startRest(seconds: ex.rest_seconds, name: ex.exercise_name)
        }
        let slotID = ex.id
        Task { @MainActor [weak self] in
            // Keep the same-turn double-tap guard through the immediate UI
            // transition, but do not make the next real set wait on transport.
            await Task.yield()
            guard let self else { return }
            self.setSlotsInFlight.remove(slotID)
            await self.drainSetOutbox()
        }
        return true
    }

    private enum SetSendOutcome {
        case acknowledged(setID: String, canonicalSessionID: String, date: String)
        case permanentFailure
        case transientFailure(attemptedJWT: String, wasUnauthorized: Bool)
        /// Another same-account model removed or superseded this exact intent.
        /// The current drain should adopt the durable queue and continue.
        case superseded
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
        await loadAfterMutation()
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
        if setOutbox.pending.contains(where: {
            $0.deliveryState == .queued && ownedSetIntentIDs.contains($0.id)
        }) {
            return true
        }
        return terminalOutbox.intents.contains { intent in
            guard ownedTerminalIntentIDs.contains(intent.id),
                  intent.deliveryState == .queued
            else { return false }
            if intent.action == .discard { return true }
            return !setOutbox.pending.contains { $0.date == intent.date }
        }
    }

    /// Persisted discard dominates both queued and visibly-failed sets. This
    /// method is intentionally safe to repeat: it also closes the crash window
    /// between saving the terminal barrier and pruning the older set key.
    private func supersedeSetIntentsForDiscardBarriers() {
        guard canMutateBoundSetAccount else { return }
        // Never let a stale in-memory acknowledged discard erase sets from an
        // explicit restart performed by a replacement model.
        adoptDurableWorkoutWriteOutboxes()
        for date in discardBarrierDates {
            guard setOutbox.pending.contains(where: { $0.date == date }) else {
                continue
            }
            setOutbox.remove(date: date)
            SetOutboxStore.remove(
                date: date, userID: accountID, defaults: defaults)
        }
        setOutbox = SetOutboxStore.load(
            userID: accountID, defaults: defaults)
        applyLocalDiscardMask()
    }

    /// One serialized pass: discards first, then sets, then finishes whose
    /// exact workout has no queued or failed set left. A finish therefore
    /// cannot overtake its data, while discard never waits on data it erases.
    private func performWorkoutWriteDrain() async -> Bool {
        supersedeSetIntentsForDiscardBarriers()
        if let discard = terminalOutbox.intents.first(where: {
            ownedTerminalIntentIDs.contains($0.id)
                && $0.action == .discard
                && $0.deliveryState == .queued
        }) {
            return await sendPersistedTerminalIntent(discard)
        }

        let setStopped = await performSetOutboxDrain()
        if setStopped { return true }
        supersedeSetIntentsForDiscardBarriers()

        guard let terminal = terminalOutbox.intents.first(where: { intent in
            guard ownedTerminalIntentIDs.contains(intent.id),
                  intent.deliveryState == .queued
            else { return false }
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
                  ownedSetIntentIDs.contains($0.id)
                      && $0.deliveryState == .queued
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
            case .superseded:
                // `sendPersistedSetIntent` already adopted the replacement
                // account queue. It may contain other immediately deliverable
                // work, so continue rather than treating this as sign-out.
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
        guard let snapshotTicket = StateSnapshotStore.reserveFullStateRequest(
            userID: accountID, defaults: defaults)
        else {
            loadError = "Couldn't reserve local reconciliation state."
            return true
        }
        do {
            let state = try await setWriteAPI.getState(jwt: jwt)
            guard canMutateBoundSetAccount else { return true }
            guard StateSnapshotStore.isCurrent(
                snapshotTicket, defaults: defaults)
            else {
                return stoppedForRetryableFailure
            }
            let returnedIDs = Set(state.sets.map(\.id))
            guard acknowledgedIDs.allSatisfy(returnedIDs.contains) else {
                throw APIError.decoding(
                    "Acknowledged set was missing from the reconciliation state")
            }
            guard applyLiveStateResponse(
                state,
                ticket: snapshotTicket,
                preferredTodaySessionID: preferredSessionID
            ) else { return stoppedForRetryableFailure }
            loadError = nil
        } catch {
            guard canMutateBoundSetAccount else { return true }
            guard StateSnapshotStore.isCurrent(
                snapshotTicket, defaults: defaults)
            else {
                return stoppedForRetryableFailure
            }
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
        guard canMutateBoundSetAccount, currentJWT != nil else { return true }
        guard var intent = durableTerminalIntent(matching: original) else {
            // The account remains valid, but a newer model owns (or cleared)
            // this date. The durable adoption above is the authoritative local
            // state; there is nothing for this stale sender to retry.
            _ = adoptLatestAcknowledgedSnapshot(for: original.date)
            return false
        }

        sendingTerminalIntentID = intent.id
        isTerminalMutationInFlight = true
        defer {
            if sendingTerminalIntentID == intent.id {
                sendingTerminalIntentID = nil
            }
            isTerminalMutationInFlight = sendingTerminalIntentID != nil
        }

        if intent.resolvedSessionID == nil {
            guard let jwt = currentJWT else { return true }
            let session: SessionRow
            do {
                session = try await setWriteAPI.createSession(
                    date: intent.date,
                    dayTemplateID: intent.dayTemplateID,
                    expectedAttempt: intent.expectedAttempt ?? 0,
                    restartDiscardedAttempt: intent.restartDiscardedAttempt,
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
                        date: intent.date,
                        dayTemplateID: nil,
                        expectedAttempt: intent.expectedAttempt ?? 0,
                        restartDiscardedAttempt: intent.restartDiscardedAttempt,
                        jwt: fallbackJWT)
                } catch {
                    return classifyTerminalIntentFailure(
                        original, error: error, attemptedJWT: fallbackJWT)
                }
            }

            guard durableTerminalIntent(matching: intent) != nil else {
                return false
            }
            guard session.date == intent.date else {
                return classifyTerminalIntentFailure(
                    intent,
                    error: APIError.decoding(
                        "Session resolution did not match the terminal date"),
                    attemptedJWT: jwt)
            }
            let createdAttempt = intent.restartDiscardedAttempt.map { $0 + 1 }
                ?? intent.expectedAttempt
                ?? 0
            guard session.attempt == nil || session.attempt == createdAttempt else {
                return classifyTerminalIntentFailure(
                    intent,
                    error: APIError.decoding(
                        "Session resolution crossed workout attempts"),
                    attemptedJWT: jwt)
            }
            guard let resolvedSession = acceptSessionResolution(session) else {
                return classifyTerminalIntentFailure(
                    intent,
                    error: APIError.decoding(
                        "Session resolution was superseded locally"),
                    attemptedJWT: jwt)
            }
            // Bind the runner before persisting the outbox resolution. A kill
            // before this point leaves the intent safely unresolved and the
            // create retry idempotent; after it, both durable records name the
            // same generation.
            bindRunnerCheckpoint(to: resolvedSession)
            intent.resolvedSessionID = resolvedSession.id
            intent.expectedAttempt = resolvedSession.attempt ?? createdAttempt
            terminalOutbox.replace(intent)
            persistReplacedTerminalIntent(intent)
            guard let durable = durableTerminalIntent(matching: intent) else {
                return false
            }
            intent = durable
        }

        // Session creation is an await too. Revalidate the exact account
        // intent immediately before the destructive/completing request; a
        // newer model may have discarded, restarted, or cleared it meanwhile.
        guard let durable = durableTerminalIntent(matching: intent) else {
            return false
        }
        guard let sessionID = durable.resolvedSessionID,
              let jwt = currentJWT
        else { return true }
        intent = durable
        if intent.expectedAttempt == nil {
            // Migration 0032 gives every preexisting session and durable
            // intent generation zero. Never retarget a decoded legacy intent
            // to the currently observed generation.
            intent.expectedAttempt = 0
            terminalOutbox.replace(intent)
            persistReplacedTerminalIntent(intent)
            guard let rebound = durableTerminalIntent(matching: intent) else {
                return false
            }
            intent = rebound
        }
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
                    sessionId: sessionID,
                    expectedAttempt: intent.expectedAttempt,
                    jwt: jwt)
            case .discard:
                response = try await terminalAPI.discardSession(
                    sessionId: sessionID,
                    expectedAttempt: intent.expectedAttempt,
                    jwt: jwt)
            }

            guard canMutateBoundSetAccount else { return true }
            // Another same-account model may have replaced this durable choice
            // while the request was in flight (most importantly finish →
            // discard). The account store, not this stale instance's in-memory
            // copy, decides whether the callback is still current.
            guard WorkoutTerminalOutboxStore.load(
                    userID: accountID, defaults: defaults
                  ).intent(for: intent.date)?.id == intent.id
            else {
                // This instance is no longer the owner. Drop only its stale
                // in-memory copy; the granular durable store already contains
                // either the replacement choice or no work at all. Adopting the
                // replacement here would create a second sender.
                terminalOutbox.remove(id: intent.id)
                _ = adoptLatestAcknowledgedSnapshot(for: intent.date)
                return false
            }
            // Discard may have replaced an in-flight finish. Its response is
            // real server history, but the stale callback cannot touch the
            // newer local intent; the coordinator will send discard next.
            guard terminalOutbox.intent(for: intent.date)?.id == intent.id else {
                return false
            }
            let expectedStatus = intent.action == .finish ? "completed" : "discarded"
            guard response.date == intent.date,
                  response.status == expectedStatus,
                  intent.expectedAttempt == nil
                    || response.attempt == nil
                    || response.attempt == intent.expectedAttempt
            else {
                throw APIError.decoding(
                    "Terminal acknowledgement did not match the persisted intent")
            }

            switch intent.action {
            case .finish:
                let applied = applyTerminalAcknowledgementLocally(
                    response, action: .finish)
                guard persistTerminalAcknowledgement(
                    response, action: .finish)
                else {
                    loadError = "Workout finished on the server, but its local recovery snapshot couldn't be saved. It will retry safely."
                    return true
                }
                terminalOutbox.remove(id: intent.id)
                persistRemovedTerminalIntent(id: intent.id)
                if applied, intent.date == todayString {
                    stopRunnerAfterTerminalAck()
                }
            case .discard:
                applyTerminalAcknowledgementLocally(response, action: .discard)
                applyLocalDiscardMask()
                guard persistTerminalAcknowledgement(
                    response, action: .discard)
                else {
                    loadError = "Workout was discarded on the server, but its local recovery snapshot couldn't be saved. It will retry safely."
                    return true
                }
                intent.resolvedSessionID = response.id
                intent.expectedAttempt = response.attempt
                intent.deliveryState = .acknowledged
                intent.failedHTTPStatus = nil
                terminalOutbox.replace(intent)
                persistReplacedTerminalIntent(intent)
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
        if let conflict = sessionWriteConflict(from: error),
           conflict.current_session.date == attempted.date
        {
            switch current.action {
            case .finish:
                terminalOutbox.remove(id: current.id)
                persistRemovedTerminalIntent(id: current.id)
            case .discard:
                terminalOutbox.retireSupersededDiscard(id: current.id)
                WorkoutTerminalOutboxStore.retireSupersededDiscard(
                    id: current.id,
                    userID: accountID,
                    defaults: defaults)
                ownedTerminalIntentIDs.remove(current.id)
            }
            adoptSessionWriteConflict(conflict.current_session)
            loadError = nil
            return false
        }
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
        guard var intent = durableSetIntent(matching: original) else {
            _ = adoptLatestAcknowledgedSnapshot(for: original.date)
            return .superseded
        }
        sendingSetIntentIDs.insert(intent.id)
        defer { sendingSetIntentIDs.remove(intent.id) }

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
                    expectedAttempt: intent.expectedAttempt ?? 0,
                    restartDiscardedAttempt: intent.restartDiscardedAttempt,
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
                      let fallbackJWT = currentJWT,
                      durableSetIntent(matching: intent) != nil
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
                        expectedAttempt: intent.expectedAttempt ?? 0,
                        restartDiscardedAttempt: intent.restartDiscardedAttempt,
                        jwt: fallbackJWT)
                } catch {
                    return classifySetIntentFailure(
                        intentID: intent.id,
                        error: error,
                        attemptedJWT: fallbackJWT)
                }
            }
            guard canMutateBoundSetAccount else { return .staleAccount }
            guard let durable = durableSetIntent(matching: intent) else {
                return .superseded
            }
            intent = durable
            let createdAttempt = intent.restartDiscardedAttempt.map { $0 + 1 }
                ?? intent.expectedAttempt
                ?? 0
            guard createdSession.attempt == nil
                    || createdSession.attempt == createdAttempt
            else {
                return classifySetIntentFailure(
                    intentID: intent.id,
                    error: APIError.decoding(
                        "Session resolution crossed workout attempts"),
                    attemptedJWT: jwt)
            }
            guard let resolvedSession = acceptSessionResolution(createdSession) else {
                return classifySetIntentFailure(
                    intentID: intent.id,
                    error: APIError.decoding(
                        "Session resolution was superseded locally"),
                    attemptedJWT: jwt)
            }
            bindRunnerCheckpoint(to: resolvedSession)
            session = resolvedSession
            intent.resolvedSessionID = resolvedSession.id
            intent.expectedAttempt = resolvedSession.attempt ?? createdAttempt
            setOutbox.replace(intent)
            persistReplacedSetIntent(intent)
            guard let durable = durableSetIntent(matching: intent) else {
                return .superseded
            }
            intent = durable
        }

        // Creation and fallback creation are awaits. Confirm that the exact
        // durable set still exists and no discard barrier has superseded it
        // immediately before logging. If another model already resolved the
        // session, adopt that canonical id as well.
        guard let durable = durableSetIntent(matching: intent) else {
            return .superseded
        }
        intent = durable
        let writeSession: SessionRow
        if durable.resolvedSessionID == session.id {
            writeSession = session
        } else if let resolvedSessionID = durable.resolvedSessionID {
            writeSession = sessions.first(where: { $0.id == resolvedSessionID })
                ?? SessionRow(
                    id: resolvedSessionID,
                    date: intent.date,
                    status: "in_progress",
                    day_template_id: intent.dayTemplateID)
        } else {
            return .superseded
        }

        // Queues written by an older app build may already have a resolved
        // session id but no generation. Migration 0032 assigns them attempt
        // zero; binding to a currently-observed later attempt would retarget
        // stale work across another device's discard/restart.
        if intent.expectedAttempt == nil {
            intent.expectedAttempt = 0
            setOutbox.replace(intent)
            persistReplacedSetIntent(intent)
            guard let rebound = durableSetIntent(matching: intent) else {
                return .superseded
            }
            intent = rebound
        }

        bindRunnerCheckpoint(to: writeSession)

        // The original body was persisted before session creation, and the
        // resolved session id is persisted above before this POST await.
        guard let jwt = currentJWT else { return .staleAccount }
        do {
            let result = try await setWriteAPI.logSet(
                sessionId: writeSession.id,
                body: intent.body,
                expectedAttempt: intent.expectedAttempt,
                jwt: jwt)
            guard canMutateBoundSetAccount else { return .staleAccount }
            guard result.set.id == intent.id else {
                throw APIError.decoding(
                    "Set acknowledgement did not match the persisted intent")
            }
            if let acknowledgedSession = result.session {
                let settlesSupersededAttempt = result.deduped
                    && result.set.deleted_at != nil
                    && intent.expectedAttempt != nil
                    && acknowledgedSession.attempt != nil
                    && acknowledgedSession.attempt! > intent.expectedAttempt!
                guard acknowledgedSession.id == result.set.session_id,
                      acknowledgedSession.date == intent.date,
                      intent.expectedAttempt == nil
                        || acknowledgedSession.attempt == nil
                        || acknowledgedSession.attempt == intent.expectedAttempt
                        || settlesSupersededAttempt
                else {
                    throw APIError.decoding(
                        "Set acknowledgement returned a mismatched session")
                }
            }
            let durableTerminal = WorkoutTerminalOutboxStore.load(
                userID: accountID, defaults: defaults).intent(for: intent.date)
            if durableTerminal?.action == .discard {
                // A newer discard barrier superseded this older callback. It
                // owns both cache visibility and eventual server ordering.
                adoptDurableWorkoutWriteOutboxes()
                return .superseded
            }
            let durableSets = SetOutboxStore.load(
                userID: accountID, defaults: defaults)
            guard durableSets.pending.contains(where: { $0.id == intent.id }) else {
                // A replacement model already settled this exact idempotent
                // write and persisted its ACK. Do not re-merge stale context.
                setOutbox.remove(id: intent.id)
                _ = adoptLatestAcknowledgedSnapshot(for: intent.date)
                return .acknowledged(
                    setID: result.set.id,
                    canonicalSessionID: result.set.session_id,
                    date: intent.date)
            }
            applySetAcknowledgement(
                result,
                intent: intent,
                submittedSession: writeSession)
            guard persistSetAcknowledgement(
                result, submittedSession: writeSession)
            else {
                loadError = "Set was saved on the server, but its local recovery snapshot couldn't be saved. It will retry safely."
                return .transientFailure(
                    attemptedJWT: jwt, wasUnauthorized: false)
            }
            setOutbox.remove(id: intent.id)
            persistRemovedSetIntentIDs(Set([intent.id]))
            normalizeMountedRunnerProgress(for: intent.date)
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
        if let intent = setOutbox.pending.first(where: { $0.id == intentID }),
           let conflict = sessionWriteConflict(from: error),
           conflict.current_session.date == intent.date
        {
            setOutbox.remove(id: intent.id)
            persistRemovedSetIntentIDs(Set([intent.id]))
            adoptSessionWriteConflict(conflict.current_session)
            loadError = nil
            return .superseded
        }
        if isPermanentSetClientError(error),
           case let APIError.http(code, _) = error {
            if var intent = setOutbox.pending.first(where: { $0.id == intentID }) {
                intent.deliveryState = .failed
                intent.failedHTTPStatus = code
                setOutbox.replace(intent)
                persistReplacedSetIntent(intent)
                reopenMountedRunner(for: intent)
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

    private func sessionWriteConflict(
        from error: Error
    ) -> SessionWriteConflictPayload? {
        guard case let APIError.http(code, body) = error,
              code == 409,
              let data = body.data(using: .utf8),
              let payload = try? JSONDecoder().decode(
                  SessionWriteConflictPayload.self, from: data),
              payload.error == "session_attempt_conflict"
                || payload.error == "session_discarded"
                || payload.error == "session_state_conflict"
        else { return nil }
        return payload
    }

    /// A 409 with `current_session` is authoritative proof that this durable
    /// write belongs to an obsolete workout attempt. Advance the shared cache
    /// before allowing another model/load to act, then mirror that state here.
    private func adoptSessionWriteConflict(_ session: SessionRow) {
        guard canMutateBoundSetAccount else { return }
        let transform: (StateResponse) -> StateResponse = { newest in
            if session.status == "discarded" {
                return Self.mergingTerminalAcknowledgement(
                    into: newest, response: session, action: .discard)
            }
            return Self.mergingSessionResolution(
                into: newest, response: session)
        }
        let persisted = StateSnapshotStore.mergeAcknowledgement(
            userID: accountID,
            fallback: currentStateResponse(),
            defaults: defaults,
            transform: transform)
        // Explicit cache invalidation deliberately makes the persistence
        // merge return nil. The 409 current_session is still authoritative
        // for this mounted model: apply it in memory and retire the obsolete
        // runner without recreating the invalidated snapshot.
        let resolvedState = persisted?.state
            ?? transform(currentStateResponse())
        applyState(
            resolvedState,
            preferredTodaySessionID: nil,
            isLiveResponse: false)
        if let checkpoint = persistedRunnerCheckpoint,
           checkpoint.date == session.date
        {
            // The rejected durable write belonged to this runner's date. A
            // nil attempt is legacy/unknown, not permission to join the newer
            // workout, so retire the runner regardless of whether both tokens
            // can be compared.
            stopRunnerForStateChange()
        } else if ["completed", "skipped", "discarded"].contains(session.status),
                  session.date == todayString
        {
            stopRunnerForStateChange()
        }
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
        // New Workers echo the canonical session/status. Rolling old Workers
        // still prove the narrow planned -> in_progress transition.
        let acknowledgedSession = Self.sessionAcknowledgedBySet(
            result, submittedSession: submittedSession)
        let current = Self.newestSession(in: sessions.filter {
            $0.date == acknowledgedSession.date
        })
        let responseWins = current == nil
            || Self.responseCanReplaceSession(
                current!, with: acknowledgedSession, kind: .set)
        let effectiveSession = responseWins
            ? acknowledgedSession
            : current ?? acknowledgedSession
        let effectiveDiscard = effectiveSession.status == "discarded"
        if result.set.deleted_at != nil {
            sets.removeAll { $0.id == result.set.id }
        }
        if effectiveDiscard {
            let sameDateSessionIDs = Set(
                sessions.lazy.filter {
                    $0.date == effectiveSession.date
                }.map(\.id))
                .union([
                    submittedSession.id,
                    acknowledgedSession.id,
                    result.set.session_id,
                ])
            sessions.removeAll { $0.date == effectiveSession.date }
            sessions.append(effectiveSession)
            sets.removeAll { sameDateSessionIDs.contains($0.session_id) }
            if effectiveSession.date == todayString {
                todaySession = effectiveSession
            }
        } else if result.set.deleted_at != nil {
            if responseWins { upsertSessionAfterCreate(effectiveSession) }
        } else if responseWins,
                  result.set.session_id == submittedSession.id
        {
            upsertSessionAfterCreate(effectiveSession)
            if let index = sets.firstIndex(where: { $0.id == result.set.id }) {
                sets[index] = result.set
            } else {
                sets.append(result.set)
            }
        } else if responseWins {
            // Preserve migration-0029 alias healing even when reconciliation
            // later fails: collapse the stale local session immediately onto
            // the canonical id echoed by the acknowledged set.
            adoptSessionAliasLocally(
                staleSession: effectiveSession,
                committedSet: result.set,
                submittedSlotID: intent.slotID)
        } else {
            // A later full state owns the session fields. The set itself is
            // still an accepted immutable fact unless that newer state is a
            // discard, handled above.
            if let index = sets.firstIndex(where: { $0.id == result.set.id }) {
                if sets[index].deleted_at == nil { sets[index] = result.set }
            } else {
                sets.append(result.set)
            }
        }
        if ["completed", "skipped", "discarded"].contains(
               effectiveSession.status),
           effectiveSession.date == todayString
        {
            // A deduped retry can reveal that another client already closed
            // the workout. Enforce terminal precedence now; reconciliation is
            // best effort and may fail while offline.
            stopRunnerForStateChange()
        }
    }

    /// A foreground recovery may settle a set after the original runner tap
    /// already returned false on timeout. Advance the mounted runner from the
    /// acknowledged set exactly as the original tap would have; the caller's
    /// post-await check is idempotent because it sees the new current slot (or
    /// the already-finished flag).
    private func normalizeMountedRunnerProgress(for date: String) {
        guard running,
              date == todayString,
              let current = currentExercise,
              isComplete(current)
        else { return }
        if let next = nextIncompleteIndex {
            jump(to: next)
        } else {
            finished = true
            persistRunnerCheckpoint()
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
        return runnerSetsDone(ex) + 1
    }

    /// Runner progress counts every locally durable set exactly once. Pending
    /// rows share their eventual server id, so the set union avoids a transient
    /// double count while an acknowledgement is being folded into the cache.
    func runnerSetsDone(_ ex: TemplateExercise) -> Int {
        Set(todaySlotSets(ex).map(\.id))
            .union(pendingSetIntents(for: ex).lazy.filter {
                $0.deliveryState == .queued
            }.map(\.id))
            .count
    }

    private func isRunnerComplete(_ ex: TemplateExercise) -> Bool {
        runnerSetsDone(ex) >= ex.target_sets
    }

    private func isRunnerResolved(_ ex: TemplateExercise) -> Bool {
        isRunnerComplete(ex) || isSkipped(ex)
    }

    private var nextRunnerIncompleteIndex: Int? {
        let n = exercises.count
        guard n > 0 else { return nil }
        for offset in 1...n {
            let i = (exerciseIndex + offset) % n
            if !isRunnerResolved(exercises[i]) { return i }
        }
        return nil
    }

    private func normalizeMountedRunnerAfterLocalCommit(for date: String) {
        guard running, date == todayString, let current = currentExercise else {
            return
        }
        if isRunnerComplete(current) {
            if let next = nextRunnerIncompleteIndex {
                jump(to: next)
            } else {
                finished = true
                persistRunnerCheckpoint()
            }
        }
        updateRestActivityAfterRunnerNormalization()
    }

    private func reopenFailedRunnerIntentIfStable(for date: String) {
        guard !timedActive,
              let failed = setOutbox.pending.first(where: {
                  $0.date == date && $0.deliveryState == .failed
              })
        else { return }
        reopenMountedRunner(for: failed)
    }

    private func reopenMountedRunner(for failedIntent: PendingSetIntent) {
        guard running, failedIntent.date == todayString,
              let index = exercises.firstIndex(where: {
                  $0.id == failedIntent.slotID
              }) else { return }
        // A delayed rejection must not abort a later physical timed set. The
        // failed intent stays durable and visible; commitTimedSet reopens it as
        // soon as that in-progress timer reaches its stable commit boundary.
        guard !timedActive else { return }
        finished = false
        exerciseIndex = index
        seedInputs()
        weight = failedIntent.body.weight
        reps = failedIntent.body.reps
        persistRunnerCheckpoint()
        updateRestActivityAfterRunnerNormalization()
    }

    /// After a local commit or rollback, the runner has already settled on the
    /// slot the user should perform when rest ends. Name that current slot—not
    /// the later distinct slot returned by `upNextName`.
    var restActivityCurrentStepName: String {
        finished ? "Done" : (currentExercise?.exercise_name ?? "Done")
    }

    private func updateRestActivityAfterRunnerNormalization() {
        guard let end = restEndDate else { return }
        restActivityUpdater(end, restActivityCurrentStepName)
    }

    private func allowNewWorkoutStart() -> Bool {
        guard !todayIsCompleted else {
            loadError = "Today's workout is already completed."
            return false
        }
        guard !blocksNewWorkoutStart else {
            if needsLiveWorkoutValidation {
                loadError = hasSavedRunnerAwaitingValidation
                    ? "Connect to validate and resume your saved workout before starting another."
                    : "Connect to verify today's in-progress workout before starting another."
            } else if hasRunnerAwaitingSetRecovery {
                loadError = "Your saved workout is still waiting for its first set to sync."
            } else {
                loadError = "Resume your saved workout before starting another."
            }
            return false
        }
        return true
    }

    func startWorkout() {
        guard allowNewWorkoutStart() else { return }
        let date = todaySession?.date ?? todayString
        var restartDiscardedAttempt = sessions.first(where: {
            $0.date == date && $0.status == "discarded"
        })?.attempt
        if let terminal = terminalOutbox.intent(for: date) {
            guard terminal.action == .discard,
                  terminal.deliveryState == .acknowledged
            else {
                loadError = "This workout still has a finish or discard waiting to sync."
                return
            }
            // A legacy acknowledged barrier belongs to migration-default
            // generation zero. Capture this authorization before clearing the
            // barrier so only the user's explicit start can revive the date.
            restartDiscardedAttempt = restartDiscardedAttempt
                ?? terminal.expectedAttempt
                ?? 0
            terminalOutbox.clearAcknowledgedDiscard(date: date)
            WorkoutTerminalOutboxStore.clearAcknowledgedDiscard(
                date: date, userID: accountID, defaults: defaults)
            ownedTerminalIntentIDs.remove(terminal.id)
        }
        guard clearRunnerCheckpoint() else {
            loadError = "This workout is already active in another app view. Refresh to continue."
            return
        }
        runnerRestartDiscardedAttempt = restartDiscardedAttempt
        running = true
        finished = false
        exerciseIndex = 0
        skipped = []
        workoutStart = now()
        seedInputs()
        persistRunnerCheckpoint()
    }

    var hasResumableWorkout: Bool { resumableCheckpoint != nil }
    private var hasSavedRunnerAwaitingValidation: Bool {
        persistedRunnerCheckpoint?.date == todayString
    }
    var needsLiveWorkoutValidation: Bool {
        // A disk snapshot is browse-only. Another device may have completed or
        // discarded the date, or rebuilt its slot IDs, since this payload was
        // saved. Every new start/override therefore waits for one live state.
        isUsingCachedState
    }
    private var hasRunnerAwaitingSetRecovery: Bool {
        guard hasSavedRunnerAwaitingValidation else { return false }
        return setOutbox.pending.contains { $0.date == todayString }
    }
    var canAbandonRecoveredWorkout: Bool {
        !running
            && !isUsingCachedState
            && hasRunnerAwaitingSetRecovery
            && setOutbox.pending.contains {
                $0.date == todayString && $0.deliveryState == .failed
            }
    }
    var blocksNewWorkoutStart: Bool {
        needsLiveWorkoutValidation
            || hasResumableWorkout
            || hasRunnerAwaitingSetRecovery
            || isReopeningSkippedWorkout
    }
    var liveWorkoutValidationActionTitle: String {
        hasSavedRunnerAwaitingValidation
            ? "CONNECT TO RESUME"
            : "CONNECT TO VERIFY"
    }
    var liveWorkoutValidationBlockTitle: String {
        hasSavedRunnerAwaitingValidation
            ? "Connect to resume first"
            : "Connect to verify workout first"
    }

    /// Restore only a checkpoint that a live `/api/state` response already
    /// validated against today's still-in-progress server session and current
    /// plan slot ids. Timed-set progress is intentionally not restored: the
    /// current slot restarts from its stable boundary.
    func resumeWorkout() {
        guard !running,
              let checkpoint = resumableCheckpoint,
              let session = sessions.first(where: {
                  $0.id == checkpoint.sessionID
                      && $0.date == checkpoint.date
                      && $0.status == "in_progress"
              }),
              let day = plan?.days.first(where: {
                  $0.id == checkpoint.selectedDayID
              }),
              let currentSlotID = checkpoint.currentSlotID,
              let index = day.exercises.firstIndex(where: {
                  $0.id == currentSlotID
              })
        else {
            clearRunnerCheckpoint()
            return
        }

        let liveSlotIDs = Set(day.exercises.map(\.id))
        todaySession = session
        runnerRestartDiscardedAttempt = nil
        selectedDayID = day.id
        exerciseIndex = index
        skipped = Set(checkpoint.skippedSlotIDs.filter {
            liveSlotIDs.contains($0)
        })
        workoutStart = Date(
            timeIntervalSince1970:
                TimeInterval(checkpoint.workoutStartedAtMS) / 1_000)
        running = true
        finished = checkpoint.finished
        skipRest()
        seedInputs()
        persistRunnerCheckpoint()
    }

    /// Seed weight/reps from last time → plan target → default.
    private func seedInputs() {
        clearTimedSet()
        guard let ex = currentExercise else { return }
        let last = lastWorkingSet(ex.exercise_id)
        // Bodyweight/timed load is relative to bodyweight: positive added
        // load, zero strict, negative assistance. It is visible and editable,
        // so carry the last/target value just like any other exercise.
        weight = last?.weight ?? ex.target_weight ?? (ex.isTimed || ex.isBodyweight ? 0 : 45)
        reps = last?.reps ?? ex.target_reps
    }

    // MARK: timed exercises (plank, holds)

    func startTimedSet(at start: Date? = nil) {
        guard let ex = currentExercise, ex.isTimed,
              !isTerminalMutationInFlight,
              !hasPendingTerminalIntentForCurrentWorkout,
              !isSetEntryBlocked(slotID: ex.id)
        else { return }
        timedActive = true
        let startedAt = start ?? now()
        timedStartDate = startedAt
        // Count down the prescribed hold (target_duration_s, fallback
        // target_reps) — not target_reps directly, which was 1s for slots
        // that never set a duration (the "plank ended instantly" bug).
        timedEndDate = startedAt.addingTimeInterval(TimeInterval(ex.holdSeconds))
        scheduleTimedSetCompletion()
    }

    /// Own completion in the model so navigation cannot cancel the set. iOS
    /// may suspend this task in the background; the foreground hook calls the
    /// same due-date check as a catch-up path.
    private func scheduleTimedSetCompletion() {
        timedSetCompletionTask?.cancel()
        guard let end = timedEndDate else { return }
        let delay = max(0, end.timeIntervalSince(now()))
        let maximumDelay = Double(UInt64.max / 1_000_000_000)
        let nanoseconds = UInt64(min(delay, maximumDelay) * 1_000_000_000)
        timedSetCompletionTask = Task { [weak self] in
            if nanoseconds > 0 {
                try? await Task.sleep(nanoseconds: nanoseconds)
            }
            guard !Task.isCancelled, let self else { return }
            // This task owns the expiry path now. Detach it from the model
            // before commit clears timer state so the network write does not
            // inherit a cancellation from cancelling itself.
            self.timedSetCompletionTask = nil
            await self.finishTimedSetIfDue()
        }
    }

    private func clearTimedSet() {
        timedSetCompletionTask?.cancel()
        timedSetCompletionTask = nil
        timedActive = false
        timedEndDate = nil
        timedStartDate = nil
    }

    /// Whole seconds held so far in the running timed set (0 when idle).
    /// FLOORED, not rounded: a tap at 1.6s is a 1s hold, so it must stay
    /// below the `>= 2` STOP guard (rounding would bump it to 2 and log a
    /// junk set — the exact thing the guard exists to prevent).
    var timedElapsed: Int {
        guard let start = timedStartDate else { return 0 }
        return max(0, Int(now().timeIntervalSince(start)))
    }

    /// The prescribed hold completed (countdown reached the end) — logs the
    /// FULL target hold. The model-owned deadline task calls this even when
    /// the runner view is no longer mounted.
    func finishTimedSetAuto() async {
        guard let ex = currentExercise else { return }
        await commitTimedSet(held: ex.holdSeconds)
    }

    /// Complete only after the stored deadline. Called by both the model-owned
    /// task and foreground recovery after iOS resumes a suspended app.
    func finishTimedSetIfDue(at date: Date? = nil) async {
        guard timedActive, let end = timedEndDate,
              (date ?? now()) >= end
        else { return }
        await finishTimedSetAuto()
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
        clearTimedSet()
        skipped.remove(ex.id)   // logging work un-skips this slot
        persistRunnerCheckpoint()
        let secs = max(1, held)
        guard queueRunnerSet(ex, weight: weight, reps: secs, durationOverride: secs) else {
            persistRunnerCheckpoint()
            return
        }
        guard running, currentExercise != nil else { return }
        let date = todaySession?.date ?? todayString
        normalizeMountedRunnerAfterLocalCommit(for: date)
        reopenFailedRunnerIntentIfStable(for: date)
    }

    func adjustWeight(_ delta: Double) {
        let candidate = weight + delta
        weight = currentExercise?.allowsAssistance == true
            ? candidate
            : max(0, candidate)
    }
    /// Direct-set the working load. Bodyweight and timed slots accept
    /// negative assistance; conventional loaded exercises remain nonnegative.
    func setWeight(_ value: Double) {
        weight = currentExercise?.allowsAssistance == true ? value : max(0, value)
    }
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
        persistRunnerCheckpoint()
    }

    func logCurrentSet(
        expectedSlotID: String,
        expectedSetNumber: Int
    ) async {
        // A SwiftUI button action launches an unstructured Task. Bind that
        // work to the slot and set number visible at tap time so a queued
        // duplicate cannot run after the first tap advances the runner and
        // accidentally log the successor exercise.
        guard let ex = currentExercise,
              ex.id == expectedSlotID,
              currentSetNumber == expectedSetNumber
        else { return }
        skipped.remove(ex.id)   // logging work un-skips this slot
        persistRunnerCheckpoint()
        guard queueRunnerSet(ex, weight: weight, reps: reps) else {
            persistRunnerCheckpoint()
            return
        } // starts rest immediately; delivery continues in the background
        guard running, currentExercise != nil else { return }
        normalizeMountedRunnerAfterLocalCommit(for: todaySession?.date ?? todayString)
    }

    /// Manual "move on" — marks the current exercise skipped for this
    /// session (so it is NOT requeued, #3) and advances to the next
    /// unresolved exercise; ends the workout if none remain.
    func skip() {
        if let ex = currentExercise { skipped.insert(ex.id) }
        if let next = nextIncompleteIndex { jump(to: next) } else { finished = true }
        persistRunnerCheckpoint()
    }

    func previous() {
        guard exerciseIndex > 0 else { return }
        exerciseIndex -= 1
        seedInputs()
        persistRunnerCheckpoint()
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
        persistRunnerCheckpoint()
    }

    func finishWorkout() async {
        guard canMutateBoundSetAccount, currentJWT != nil else { return }
        persistRunnerCheckpoint()
        let date = todaySession?.date ?? todayString
        if terminalOutbox.intent(for: date) == nil {
            let intent = WorkoutTerminalIntent(
                id: uuidFactory().uuidString,
                action: .finish,
                date: date,
                dayTemplateID: todaySession?.day_template_id ?? selectedDay?.id,
                resolvedSessionID: todaySession?.id,
                deliveryState: .queued,
                failedHTTPStatus: nil,
                expectedAttempt: todaySession?.attempt,
                restartDiscardedAttempt: runnerRestartDiscardedAttempt)
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
            failedHTTPStatus: nil,
            expectedAttempt: todaySession?.attempt,
            restartDiscardedAttempt: runnerRestartDiscardedAttempt)

        // Saving the discard first is the atomic semantic commit. If the app
        // dies before the following physical set-key cleanup, init observes
        // this barrier and performs the same supersession before any drain.
        terminalOutbox.enqueue(intent)
        persistEnqueuedTerminalIntent(intent)
        clearRunnerCheckpoint()
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
                          targetSets: Int, targetReps: Int, targetRepsMax: Int?,
                          restSeconds: Int,
                          targetDurationS: Int?) async {
        guard let jwt = currentJWT else { return }
        let activeSlotID = currentExercise?.id
        do {
            _ = try await api.addExercise(
                dayID: dayID, exercise: exercise, isWarmup: isWarmup,
                targetSets: targetSets, targetReps: targetReps,
                targetRepsMax: targetRepsMax,
                restSeconds: restSeconds, targetDurationS: targetDurationS, jwt: jwt)
            await loadAfterMutation()
            restoreActiveSlot(activeSlotID)
        } catch { handle(error, jwt: jwt) }
    }

    func deleteSlot(dayID: String, teID: String) async {
        guard let jwt = currentJWT else { return }
        let activeSlotID = currentExercise?.id
        do {
            try await api.deleteExerciseSlot(dayID: dayID, teID: teID, jwt: jwt)
            await loadAfterMutation()
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
            await loadAfterMutation()
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
            clearRunnerCheckpoint()
            skipRest()
            return
        }
        if let previousID, let i = exercises.firstIndex(where: { $0.id == previousID }) {
            exerciseIndex = i
        } else if exerciseIndex >= exercises.count {
            exerciseIndex = exercises.count - 1
        }
        seedInputs()
        persistRunnerCheckpoint()
    }

    // MARK: rest timer

    /// Name of the next not-complete exercise (for the rest screen's UP NEXT).
    var upNextName: String {
        if let i = nextRunnerIncompleteIndex { return exercises[i].exercise_name }
        return "Done"
    }

    func removeSet(_ set: SetLog) async {
        guard let jwt = currentJWT else { return }
        do {
            try await setWriteAPI.deleteSet(setId: set.id, jwt: jwt)
            sets.removeAll { $0.id == set.id }
            // The endpoint can also revert the last-set session to `planned`,
            // but it does not return that session. Invalidate rather than
            // guessing; a cold offline launch must never resurrect this set.
            if !StateSnapshotStore.invalidate(
                userID: accountID, defaults: defaults),
               let accountID
            {
                StateSnapshotStore.clear(
                    userID: accountID, defaults: defaults)
            }
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
            ridesOn: { [self] eventDate in
                projection(for: eventDate).suppressesScheduleAndEndurance
                    ? []
                    : rides(on: eventDate)
            })
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
        case .session(let s, _): isWorkout = Self.isWorkoutStatus(s)
        // M4 (multisport) — a trip day is not a scheduled strength workout
        // (unavailable = blacked out; light = unstructured travel training).
        case .rest, .none, .unavailable, .light: isWorkout = false
        }
        guard isWorkout else { return nil }
        if let checkpoint = resumableCheckpoint,
           checkpoint.date == today,
           let checkpointDay = dayTemplate(id: checkpoint.selectedDayID)
        {
            return checkpointDay
        }
        switch proj {
        case .projected(let tid):
            // Schedule projection: the template id IS the schedule's.
            return dayTemplate(id: tid) ?? selectedDay ?? plan?.days.first
        case .session(_, let hardBlackoutTripType):
            // Real workout-status session. Outside a hard blackout, the
            // shared session→schedule inference preserves the existing
            // null-template fallback. During a hard blackout the schedule is
            // suppressed on both platforms, so only an explicit session day
            // is eligible before the selected/first display fallback.
            return sessionDisplayTemplate(
                forDateString: today,
                allowScheduleInference: hardBlackoutTripType == nil)
                ?? selectedDay ?? plan?.days.first
        case .rest, .none, .unavailable, .light:
            return nil   // unreachable (guarded by isWorkout)
        }
    }

    /// Raw status of today's real session, if any (for the Today header /
    /// CTA wording — e.g. "completed" vs "in_progress"). nil ⇒ no real
    /// session today (pure schedule projection or rest).
    var todaySessionStatus: String? {
        if case .session(let s, _) = todayProjection { return s }
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
            case .session(let status, let hardBlackoutTripType):
                if status == "planned" || status == "in_progress" {
                    // Use the SHARED session→schedule resolver (the same one
                    // Today/calendar use), not a bare day_template_id read:
                    // a real planned/in_progress session with a null
                    // day_template_id normally resolves via the weekly
                    // schedule. A hard blackout is the one exception: its
                    // schedule is suppressed, so only the session's explicit
                    // template can be returned. Stays nil-graceful for a
                    // genuinely unresolvable day.
                    return NextWorkout(
                        dateString: ymd,
                        day: sessionDisplayTemplate(
                            forDateString: ymd,
                            allowScheduleInference: hardBlackoutTripType == nil))
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
        guard allowNewWorkoutStart() else { return }
        if let id = todayResolvedDay?.id { selectedDayID = id }
        startWorkout()
    }

    /// Start a guided workout for an explicitly chosen day template — the
    /// "train a different day" OVERRIDE. Reuses the EXISTING session-start
    /// path verbatim (set `selectedDayID`, then `startWorkout()`); the
    /// session row is created lazily on the first logged set. This is a
    /// one-off `sessions` write only — it never touches `plans.meta.schedule`.
    func startOverride(dayID: String) {
        guard allowNewWorkoutStart() else { return }
        selectedDayID = dayID
        if let skipped = todaySession, skipped.status == "skipped" {
            guard !isReopeningSkippedWorkout else { return }
            isReopeningSkippedWorkout = true
            Task { await reopenSkippedWorkoutAndStart(skipped) }
            return
        }
        startWorkout()
    }

    private func reopenSkippedWorkoutAndStart(_ skipped: SessionRow) async {
        defer { isReopeningSkippedWorkout = false }
        guard canMutateBoundSetAccount, let jwt = currentJWT else { return }
        do {
            let response = try await setWriteAPI.reopenSkippedSession(
                sessionId: skipped.id,
                dayTemplateID: selectedDayID,
                expectedAttempt: skipped.attempt ?? 0,
                jwt: jwt)
            guard canMutateBoundSetAccount,
                  response.id == skipped.id,
                  response.date == skipped.date,
                  response.status == "planned",
                  response.attempt == nil
                    || response.attempt == (skipped.attempt ?? 0) + 1,
                  let accepted = acceptSessionResolution(response),
                  accepted.status == "planned"
            else {
                throw APIError.decoding(
                    "Skipped-session reopen did not advance the workout")
            }
            loadError = nil
            // The network gate has completed; clear it before entering the
            // shared start guard, which intentionally blocks while a reopen
            // is still in flight.
            isReopeningSkippedWorkout = false
            startWorkout()
        } catch {
            if let conflict = sessionWriteConflict(from: error),
               conflict.current_session.date == skipped.date
            {
                adoptSessionWriteConflict(conflict.current_session)
                loadError = "Today's session changed elsewhere. Review it before starting."
                return
            }
            handle(error, jwt: jwt)
        }
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
            if isCurrentBearer(jwt) {
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
