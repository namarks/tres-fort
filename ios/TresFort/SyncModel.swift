import Combine
import SwiftUI

private struct SessionWriteConflictPayload: Decodable {
    let error: String
    let current_session: SessionRow
}

/// Process-local ownership for ActivityKit and the single rest notification.
/// The durable checkpoint is value-based, so a replacement model can resume
/// to an identical value; this token closes that in-process ABA gap.
@MainActor
enum RunnerArtifactOwnership {
    private struct Key: Hashable {
        let defaults: ObjectIdentifier
        let userID: String
    }

    final class Owner {
        weak var defaults: LocalPersistence?
        let id: UUID
        let featureSessionEpoch: UInt64

        init(defaults: LocalPersistence, id: UUID, featureSessionEpoch: UInt64) {
            self.defaults = defaults
            self.id = id
            self.featureSessionEpoch = featureSessionEpoch
        }

        func permitsClaim(featureSessionEpoch: UInt64, defaults: LocalPersistence) -> Bool {
            // ObjectIdentifier can be reused after the old namespace dies.
            // Its epoch fences only that live namespace, never a new object
            // that happens to occupy the same address.
            guard let currentDefaults = self.defaults else { return true }
            return currentDefaults === defaults && self.featureSessionEpoch <= featureSessionEpoch
        }
    }

    private static var owners: [Key: Owner] = [:]

    static func claim(
        _ owner: UUID,
        featureSessionEpoch: UInt64,
        userID: String?,
        defaults: LocalPersistence
    ) {
        guard let userID else { return }
        let key = Key(defaults: ObjectIdentifier(defaults), userID: userID)
        guard owners[key]?.permitsClaim(
            featureSessionEpoch: featureSessionEpoch, defaults: defaults) != false else {
            return
        }
        owners[key] = Owner(
            defaults: defaults,
            id: owner,
            featureSessionEpoch: featureSessionEpoch)
    }

    static func isOwned(
        by owner: UUID,
        featureSessionEpoch: UInt64,
        userID: String?,
        defaults: LocalPersistence
    ) -> Bool {
        guard let userID else { return false }
        guard let current = owners[Key(
            defaults: ObjectIdentifier(defaults), userID: userID)],
              current.defaults === defaults
        else { return false }
        return current.id == owner
            && current.featureSessionEpoch == featureSessionEpoch
    }

    static func isOwnedByOther(
        than owner: UUID,
        featureSessionEpoch: UInt64,
        userID: String?,
        defaults: LocalPersistence
    ) -> Bool {
        guard let userID,
              let current = owners[Key(
                  defaults: ObjectIdentifier(defaults), userID: userID)],
              current.defaults === defaults
        else { return false }
        return current.featureSessionEpoch > featureSessionEpoch
            || (current.featureSessionEpoch == featureSessionEpoch
                && current.id != owner)
    }

    static func release(
        _ owner: UUID,
        featureSessionEpoch: UInt64,
        userID: String?,
        defaults: LocalPersistence
    ) {
        guard let userID else { return }
        let key = Key(defaults: ObjectIdentifier(defaults), userID: userID)
        if let current = owners[key],
           current.defaults === defaults,
           current.id == owner,
           current.featureSessionEpoch == featureSessionEpoch {
            owners.removeValue(forKey: key)
        }
    }
}

/// Exact workout identity visible when a terminal UI action is rendered or a
/// destructive confirmation opens. The token prevents a queued SwiftUI Task
/// from retargeting itself to a replacement session attempt before it runs.
struct WorkoutTerminalActionTarget: Equatable {
    let featureSessionEpoch: UInt64
    let date: String
    let sessionID: String?
    let sessionAttempt: Int?
    let nilBoundRunnerCheckpoint: WorkoutRunnerCheckpoint?
    let restartDiscardedAttempt: Int?
}

@MainActor
final class SyncModel: ObservableObject {
    @Published private(set) var summaryRevision: UInt64 = 0
    @Published private(set) var summaryErrors: [String: String] = [:]
    @Published private var completionSummaries: [String: WorkoutSummary] = [:]
    private var completionSummaryRevisions: [String: UInt64] = [:]
    @Published private(set) var recentPlanHistory: PlanHistoryResponse?
    @Published private(set) var planChangesError: String?
    @Published private var planDismissalRevision = 0
    private var planHistoryRequest = UUID()
    @Published var plan: PlanTree?
    @Published var sets: [SetLog] = [] { didSet { invalidateHistory() } }
    @Published var sessions: [SessionRow] = [] { didSet { invalidateHistory() } }
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
    @Published var catalog: [ExerciseCatalog] = [] { didSet { invalidateHistory() } }
    @Published var todaySession: SessionRow?
    @Published var selectedDayID: String?
    @Published var loadError: String?
    @Published var isLoading = false
    /// Only an accepted live state read can establish an empty account. An
    /// absent plan in a cold model or cached snapshot is not creation authority.
    @Published private(set) var hasVerifiedPlanState = false
    var canCreateRoutine: Bool {
        canInitiateBoundFeatureAction && plan == nil && hasVerifiedPlanState
            && !isUsingCachedState && !isLoading && loadError == nil
    }
    /// True after a target PATCH is acknowledged until a bound live-state
    /// response reconciles the workout editor's cached prescription values.
    @Published private(set) var workoutEditorRefreshNeeded = false
    /// True while the visible plan/calendar came from the last successful
    /// account-scoped snapshot rather than a live `/api/state` response.
    @Published private(set) var isUsingCachedState = false
    /// A persisted runner becomes actionable only after a live state pull
    /// confirms that today's server session is still in progress.
    @Published private(set) var resumableCheckpoint: WorkoutRunnerCheckpoint?
    /// Durable set intents are separate from acknowledged `sets`. Publishing
    /// the account queue makes relaunch state visible on Today even when the
    /// workout runner is not mounted.
    @Published private(set) var setCorrections: [PendingSetCorrection]
    @Published private(set) var sendingCorrectionIDs: Set<String> = []
    @Published private(set) var correctionRefreshNeeded = false
    private var ownedCorrectionIDs: Set<String>
    @Published private(set) var setOutbox: SetOutbox
    /// Finish/discard intents share the same account boundary as set intents.
    /// An acknowledged discard remains here as a local barrier until the user
    /// explicitly starts that date again.
    @Published private(set) var terminalOutbox: WorkoutTerminalOutbox
    @Published private(set) var sendingSetIntentIDs: Set<String> = []
    @Published private(set) var setSlotsInFlight: Set<String> = []
    @Published private(set) var isTerminalMutationInFlight = false
    @Published private(set) var isReopeningSkippedWorkout = false
    @Published private(set) var isRoutineMutationInFlight = false
    private var routineMutationWaiters: [CheckedContinuation<Void, Never>] = []

    // Rest timer (local Live Activity arrives in milestone g).
    private(set) var restControlID: String?
    private(set) var timedControlID: String?
    private var timedCueGeneration: Int?
    @Published var restEndDate: Date?
    @Published var restExercise: String = ""
    @Published var restTotal: Int = 0

    // Guided workout runner.
    @Published var running = false
    @Published var finished = false
    @Published private(set) var workoutFeedback: WorkoutFeedback?
    @Published var exerciseIndex = 0
    @Published var weight: Double = 0
    @Published var reps: Int = 0
    @Published var rpe: Double?
    @Published var holdDurationSeconds: Int = 30
    /// PLAN SLOT ids (template_exercise_id) the user explicitly skipped this
    /// session. Keyed by slot, not exercise_id, to match the slot-keyed
    /// completion path: the same movement in two slots skips independently
    /// (#3). A skip is honored for the rest of the workout — the slot is NOT
    /// requeued. In-memory + per-session: cleared on startWorkout; logging a
    /// set for a skipped slot un-skips it (you came back and did it).
    @Published var skipped: Set<String> = []

    // Timers.
    @Published var workoutStart: Date?      // whole-session stopwatch
    var workoutElapsedSeconds: Int {
        guard let workoutStart else { return 0 }
        return max(0, Int(now().timeIntervalSince(workoutStart)))
    }
    @Published var timedActive = false      // a timed exercise is running
    @Published var timedEndDate: Date?
    @Published var timedStartDate: Date?    // wall-clock start of the hold

    private let setWriteAPI: any SetWriteAPI
    private let terminalAPI: any WorkoutTerminalAPI
    private let catalogAPI: any ExerciseCatalogAPI
    private let planEditingAPI: any PlanEditingAPI
    private let routineEditingAPI: any RoutineEditingAPI
    private unowned let auth: AuthModel
    private let accountID: String?
    private let featureSessionEpoch: UInt64
    private let defaults: LocalPersistence
    private let uuidFactory: () -> UUID
    private let now: () -> Date
    private let runnerArtifactOwnerID = UUID()
    private let restActivityUpdater: (Date, String) -> Void
    private let restActivityEnder: () -> Void
    private let restNotificationCanceller: @MainActor () -> Void
    /// Identity of the exact rendered hold the user started. Automatic timer
    /// completion is a new local write, so unlike settlement callbacks it may
    /// not cross a feature-session epoch or follow selection to another slot.
    private struct TimedSetAttempt: Equatable {
        let featureSessionEpoch: UInt64
        let slotID: String
        let exerciseID: String
        let setNumber: Int
        let reservedSetIDs: Set<String>
        let groupContext: RunnerGroupContext?
        let holdSeconds: Int
        let prescribedHoldSeconds: Int
        let rpe: Double?
        let weight: Double
        let isWarmup: Bool
        let startedAt: Date
        let endDate: Date
    }
    private struct RunnerExecutionIdentity: Equatable {
        let slotID: String
        let exerciseID: String
        let isWarmup: Bool
        let isTimed: Bool
        let isBodyweight: Bool
    }
    private struct RunnerGroupContext: Equatable {
        let id: String
        let memberIDs: [String]
        let rounds: Int
        let roundRest: Int?
        let transitionRest: Int?
    }
    private var observedGroupProgress: [String: GroupRunnerProgress] = [:]
    private var runnerFocus = RunnerFocusState()
    private var deferredGroupRepair: RunnerGroupRepair?
    private var timedSetAttempt: TimedSetAttempt?
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
    /// A server can recover while `NWPathMonitor` remains satisfied, so an
    /// unsent idempotent write cannot rely only on launch/foreground/path
    /// transitions. Production enables this short capped retry loop; tests opt
    /// in explicitly so transient-failure fixtures remain deterministic.
    private let automaticWorkoutWriteRetryEnabled: Bool
    private let workoutWriteRetryDelaysNanoseconds: [UInt64]
    private let workoutWriteRetrySleeper: (UInt64) async throws -> Void
    private var workoutWriteRetryTask: Task<Void, Never>?
    private var workoutWriteRetryAttempt = 0
    /// Minimum delay requested by the transient response that stopped the
    /// current drain (for example Retry-After on a 429/503).
    private var workoutWriteRetryMinimumDelayNanoseconds: UInt64?
    /// Absolute server-directed floor shared by automatic, lifecycle, network,
    /// and manual triggers. A foreground transition must not turn Retry-After
    /// into an immediate retry.
    private var workoutWriteRetryNotBefore: Date?
    /// A malformed or hostile header must not overflow nanosecond conversion or
    /// suspend an offline-first workout queue indefinitely. The Worker uses a
    /// five-second floor; one day still accommodates legitimate rate limiting.
    private static let maximumRetryAfterSeconds: TimeInterval = 24 * 60 * 60
    /// State refresh belongs to the account-scoped model, not to the
    /// SwiftUI task that happened to request it. Pull-to-refresh may cancel
    /// its view task as the scroll hierarchy changes; keeping one unstructured
    /// model-owned task lets that already-started validation finish, and
    /// coalesces only equivalent state requests. A mutation or bearer
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
    private var authBoundaryObserverID: UUID?
    /// Loading presentation is tracked separately from state freshness:
    /// account-scoped snapshot tickets own freshness, while an outbox
    /// reconciliation can supersede a load without owning its spinner.
    private var loadGeneration = 0
    private var statePlanVersion = 0
    private var stateServerTime = 0
    private var stateManualActivityCursorCapable = false
    private var stateExternalSyncCursorsVersion: Int?

    init(
        auth: AuthModel,
        setWriteAPI: any SetWriteAPI = APIClient(),
        terminalAPI: any WorkoutTerminalAPI = APIClient(),
        catalogAPI: any ExerciseCatalogAPI = APIClient(),
        planEditingAPI: any PlanEditingAPI = APIClient(),
        routineEditingAPI: any RoutineEditingAPI = APIClient(),
        defaults: LocalPersistence = .standard,
        uuidFactory: @escaping () -> UUID = UUID.init,
        now: @escaping () -> Date = Date.init,
        automaticWorkoutWriteRetryEnabled: Bool = false,
        workoutWriteRetryDelaysNanoseconds: [UInt64] = [
            2_000_000_000,
            5_000_000_000,
            15_000_000_000,
            30_000_000_000,
            60_000_000_000,
        ],
        workoutWriteRetrySleeper: @escaping (UInt64) async throws -> Void = {
            try await Task.sleep(nanoseconds: $0)
        },
        restActivityUpdater: @escaping (Date, String) -> Void = {
            endDate, upNext in
            RestLiveActivity.update(endDate: endDate, upNext: upNext)
        },
        restActivityEnder: @escaping () -> Void = {
            RestLiveActivity.endNow()
        },
        restNotificationCanceller: @escaping @MainActor () -> Void = {
            RestCue.cancelNotification()
        }
    ) {
        self.auth = auth
        self.accountID = auth.userID
        self.featureSessionEpoch = auth.featureSessionEpoch
        self.setWriteAPI = setWriteAPI
        self.terminalAPI = terminalAPI
        self.catalogAPI = catalogAPI
        self.planEditingAPI = planEditingAPI
        self.routineEditingAPI = routineEditingAPI
        self.defaults = defaults
        self.uuidFactory = uuidFactory
        self.now = now
        self.automaticWorkoutWriteRetryEnabled =
            automaticWorkoutWriteRetryEnabled
        self.workoutWriteRetryDelaysNanoseconds =
            workoutWriteRetryDelaysNanoseconds
        self.workoutWriteRetrySleeper = workoutWriteRetrySleeper
        self.restActivityUpdater = restActivityUpdater
        self.restActivityEnder = restActivityEnder
        self.restNotificationCanceller = restNotificationCanceller
        let persistedCheckpoint = WorkoutRunnerCheckpointStore.load(
            userID: auth.userID, defaults: defaults)
        self.persistedRunnerCheckpoint = persistedCheckpoint
        self.workoutFeedback = persistedCheckpoint?.feedback
        self.runnerFocus = persistedCheckpoint?.focus ?? RunnerFocusState()
        self.deferredGroupRepair = persistedCheckpoint?.deferredGroupRepair
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
        for intent in persistedTerminals.intents where intent.action == .discard {
            SetCorrectionOutboxStore.remove(date: intent.date, userID: auth.userID, defaults: defaults)
        }
        let corrections = SetCorrectionOutboxStore.load(userID: auth.userID, defaults: defaults)
        self.setCorrections = corrections
        self.ownedCorrectionIDs = Set(corrections.map(\.id))
        self.setOutbox = persistedSets
        self.terminalOutbox = persistedTerminals
        self.ownedSetIntentIDs = Set(persistedSets.pending.map(\.id))
        self.ownedTerminalIntentIDs = Set(
            persistedTerminals.intents.map(\.id))
        if !persistedSets.isEmpty || !persistedTerminals.intents.isEmpty || !corrections.isEmpty {
            self.workoutWriteRetryNotBefore =
                WorkoutWriteRetryDeadlineStore.load(
                    userID: auth.userID, defaults: defaults)
        } else if let userID = auth.userID {
            WorkoutWriteRetryDeadlineStore.clear(
                userID: userID, defaults: defaults)
        }
        for intent in persistedTerminals.intents where intent.action == .discard {
            SetOutboxStore.remove(
                date: intent.date, userID: auth.userID, defaults: defaults)
        }
        // A relaunch of the same account resumes its persisted cursors. Moving
        // between accounts keeps each cache isolated but deliberately clears
        // the destination cursor so its first authenticated pull is complete.
        if StateSyncAccountStore.activate(
            userID: auth.userID, defaults: defaults)
        {
            _ = StateSnapshotStore.requireFullReload(
                userID: auth.userID, defaults: defaults)
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
        authBoundaryObserverID = auth.observeFeatureSessionBoundary {
            [weak self] in
            guard let self else { return false }
            self.prepareForFeatureSessionBoundary()
            return true
        }
    }

    /// Bind every request to the account that created this model. An old
    /// MainTab task may finish after AuthModel switches users; it must never
    /// continue using the replacement account's bearer.
    var exerciseDemoJWT: String? { currentJWT }

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
        return !auth.accountDeletionPending && !defaults.hasFailure(userID: accountID)
    }

    /// New user choices belong to the feature session that rendered them.
    /// Already-durable writes intentionally settle through the broader
    /// account guard above after same-account reauthentication.
    private var canInitiateBoundFeatureAction: Bool {
        canMutateBoundSetAccount
            && auth.featureSessionEpoch == featureSessionEpoch
    }

    private var canControlSharedRestArtifacts: Bool {
        canInitiateBoundFeatureAction
            && RunnerArtifactOwnership.isOwned(
                by: runnerArtifactOwnerID,
                featureSessionEpoch: featureSessionEpoch,
                userID: accountID,
                defaults: defaults)
    }

    private var runnerArtifactsOwnedByOther: Bool {
        RunnerArtifactOwnership.isOwnedByOther(
            than: runnerArtifactOwnerID,
            featureSessionEpoch: featureSessionEpoch,
            userID: accountID,
            defaults: defaults)
    }

    var todayString: String {
        let f = DateFormatter()
        f.calendar = Calendar(identifier: .gregorian)
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = .current
        f.dateFormat = "yyyy-MM-dd"
        return f.string(from: now())
    }

    var selectedDay: Workout? {
        guard let plan else { return nil }
        return plan.workouts.first { $0.id == selectedDayID } ?? plan.workouts.first
    }

    var terminalActionTarget: WorkoutTerminalActionTarget? {
        guard canInitiateBoundFeatureAction else { return nil }
        let date = todaySession?.date ?? todayString
        return WorkoutTerminalActionTarget(
            featureSessionEpoch: featureSessionEpoch,
            date: date,
            sessionID: todaySession?.id,
            sessionAttempt: todaySession?.attempt,
            nilBoundRunnerCheckpoint:
                todaySession == nil ? persistedRunnerCheckpoint : nil,
            restartDiscardedAttempt: runnerRestartDiscardedAttempt)
    }

    private func matchesTerminalActionTarget(
        _ target: WorkoutTerminalActionTarget
    ) -> Bool {
        guard canInitiateBoundFeatureAction,
              target.featureSessionEpoch == featureSessionEpoch,
              target.date == (todaySession?.date ?? todayString),
              target.sessionID == todaySession?.id,
              target.sessionAttempt == todaySession?.attempt,
              target.restartDiscardedAttempt == runnerRestartDiscardedAttempt
        else { return false }
        if target.sessionID == nil {
            return target.nilBoundRunnerCheckpoint == persistedRunnerCheckpoint
        }
        return true
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
        isLoading = true
        defer {
            if thisLoadGeneration == loadGeneration { isLoading = false }
        }
        while true {
            guard isCurrentAccount, canMutateBoundSetAccount,
                  key.featureSessionEpoch == featureSessionEpoch,
                  key.featureSessionEpoch == auth.featureSessionEpoch,
                  key.freshnessGeneration == stateFreshnessGeneration
            else { return }
            guard let snapshotTicket = StateSnapshotStore.reserveStateRequest(
                userID: accountID, defaults: defaults)
            else {
                loadError = "Couldn't reserve local sync state."
                return
            }
            do {
                let state = try await setWriteAPI.getState(
                    jwt: jwt,
                    watermarks: snapshotTicket.watermarks)
                guard isCurrentAccount, canMutateBoundSetAccount,
                      key.featureSessionEpoch == featureSessionEpoch,
                      key.featureSessionEpoch == auth.featureSessionEpoch,
                      key.freshnessGeneration == stateFreshnessGeneration
                else { return }
                if !StateSnapshotStore.isCurrent(
                    snapshotTicket, defaults: defaults)
                {
                    // Retry only when an accepted mutation advanced this exact
                    // latest request. Another state reservation owns a
                    // newer request and must keep newest-request-wins ordering.
                    if StateSnapshotStore.wasSupersededByMutation(
                        snapshotTicket, defaults: defaults)
                    {
                        continue
                    }
                    return
                }
                guard applyLiveStateResponse(
                    state,
                    ticket: snapshotTicket
                ) else {
                    loadError = "Couldn't save the latest sync state."
                    return
                }
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
                return
            } catch {
                guard StateSnapshotStore.isCurrent(
                          snapshotTicket, defaults: defaults),
                      isCurrentAccount, canMutateBoundSetAccount,
                      key.featureSessionEpoch == featureSessionEpoch,
                      key.featureSessionEpoch == auth.featureSessionEpoch,
                      key.freshnessGeneration == stateFreshnessGeneration
                else { return }
                let isUnauthorized =
                    (error as? APIError)?.httpStatus == 401
                if isCurrentAccount, plan != nil,
                   !(error is CancellationError),
                   !isUnauthorized
                {
                    isUsingCachedState = true
                }
                handle(error, jwt: jwt)
                return
            }
        }
    }

    /// Apply a complete `/api/state` response atomically at the cache boundary.
    /// Direct applications are fixtures or mutation compatibility paths and
    /// therefore intentionally reserve explicit zero watermarks.
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

    /// Single freshness gate for every fetched state response. Keeping the
    /// check immediately beside the shared apply/persist boundary prevents a
    /// future caller from updating presentation but forgetting the snapshot (or
    /// vice versa).
    @discardableResult
    private func applyLiveStateResponse(
        _ state: StateResponse,
        ticket: StateSnapshotTicket,
        preferredTodaySessionID: String? = nil
    ) -> Bool {
        guard canInitiateBoundFeatureAction,
              StateSnapshotStore.isCurrent(ticket, defaults: defaults) else { return false }
        retainGroupDeletionObservations()
        guard let committed = StateSnapshotStore.commitStateResponse(
                  state, ticket: ticket, defaults: defaults)
        else { return false }
        var provenDeletedSetIDs = Set(state.sets.filter { $0.deleted_at != nil }.map(\.id))
        if ticket.watermarks.setsSince == 0 {
            // Only a full set collection can prove absence. A changed
            // execution class is not evidence of an acknowledged deletion.
            let returnedIDs = Set(state.sets.map(\.id))
            provenDeletedSetIDs.formUnion(setCorrections.filter {
                $0.isDelete && !returnedIDs.contains($0.setID)
            }.map(\.setID))
        }
        applyState(
            committed.state,
            preferredTodaySessionID: preferredTodaySessionID,
            isLiveResponse: true,
            provenDeletedSetIDs: provenDeletedSetIDs)
        workoutEditorRefreshNeeded = false
        hasVerifiedPlanState = true
        return true
    }

    private func applyState(
        _ state: StateResponse,
        preferredTodaySessionID: String?,
        isLiveResponse: Bool,
        provenDeletedSetIDs: Set<String> = []
    ) {
        let previousSelectedDayID = selectedDayID
        let runnerWasActive = running
        let activeSlotID = activeRunnerSlotID()
        let previousExecutionIdentity = activeRunnerExecutionIdentity()
        let previousPrescription = currentExercise.map(RunnerPrescription.init)
        let previousGroupProgress = observedGroupProgress
        let previousGroupID = currentExercise?.group_id
        let previousDeletionGroups: [String: String] = Dictionary(uniqueKeysWithValues: setCorrections.compactMap { intent in
            groupDeletionObservation(intent).map { (intent.id, $0) }
        })
        let runnerCheckpointBeforeState = persistedRunnerCheckpoint
        let previousSkippedExecutionState =
            skippedExecutionStateForCurrentPlan()
        statePlanVersion = state.plan_version
        stateServerTime = state.server_time
        stateManualActivityCursorCapable =
            state.manualActivityCursorCapable
        stateExternalSyncCursorsVersion =
            state.externalSyncCursorsVersion
        plan = state.plan
        if isLiveResponse {
            summaryRevision &+= 1
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
        // Raw tombstones must reach reconciliation so a deleted UUID retires a
        // doomed idempotent retry. They are never published as live workout
        // data after that ordering boundary.
        sets.removeAll { $0.deleted_at != nil }
        // The snapshot store has already applied any delta tombstones. Keep the
        // presentation boundary defensive for legacy/full payloads too.
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
        if isLiveResponse {
            preflightMountedRunnerOwnership(
                checkpointBeforeState: runnerCheckpointBeforeState)
        }
        reconcileSelection(
            previousSelectedDayID: previousSelectedDayID,
            activeSlotID: activeSlotID,
            runnerWasActive: runnerWasActive && running)
        if isLiveResponse {
            reconcileInheritedSkips(
                previousExecutionIdentities:
                    previousSkippedExecutionState.identities,
                unverifiedSlotIDs: previousSkippedExecutionState.unverified)
            let executionIdentityChanged = runnerWasActive
                && running
                && previousExecutionIdentity != activeRunnerExecutionIdentity()
            if executionIdentityChanged {
                clearTimedSet()
            }
            if runnerWasActive && (executionIdentityChanged || previousGroupID != currentExercise?.group_id) {
                runnerFocus.isExplicit = false
            }
            if let repair = deferredGroupRepair,
               plan?.workouts.first(where: { $0.id == repair.dayID })
                .flatMap({ RunnerGroupRepair(groupID: repair.groupID, day: $0) }) != repair {
                deferredGroupRepair = nil
            }
            let preservedFocusGroups = Set(setCorrections.compactMap { intent -> String? in
                guard provenDeletedSetIDs.contains(intent.setID),
                      !state.sets.contains(where: { $0.id == intent.setID && $0.deleted_at == nil }) else { return nil }
                return supersededDeletionGroupID(intent)
            })
            normalizeMountedRunnerProgress(
                for: todaySession?.date ?? todayString,
                reseedCurrent: executionIdentityChanged
                    || (runnerWasActive && previousPrescription != currentExercise.map(RunnerPrescription.init)),
                preservingFocusIn: preservedFocusGroups)
            // A live read can prove a queued deletion before its HTTP ACK.
            // Use the progress observed before this read, so normalization
            // cannot erase eligibility. The later ACK then sees no new change.
            for intent in setCorrections where intent.isDelete
                && provenDeletedSetIDs.contains(intent.setID)
                && !state.sets.contains(where: { $0.id == intent.setID && $0.deleted_at == nil }) {
                let observedID = previousDeletionGroups[intent.id] ?? previousGroupProgress.values.first(where: {
                    $0.members.contains { $0.completedIDs.contains(intent.setID) }
                })?.id ?? groupDeletionObservation(intent)
                if let observedID { repairGroupAfterDeletedSet(intent, observedGroupID: observedID) }
            }
            isUsingCachedState = false
            correctionRefreshNeeded = false
            validatePersistedRunnerCheckpoint(preservingFocusIn: preservedFocusGroups)
        }
    }

    /// Reject a mounted checkpoint against the response's attempt/status
    /// before any progress normalization can persist it with newer server
    /// identity. The complete validator still runs afterward for inactive
    /// resume eligibility and normalized checkpoint shape.
    private func preflightMountedRunnerOwnership(
        checkpointBeforeState checkpoint: WorkoutRunnerCheckpoint?
    ) {
        guard running, let checkpoint else { return }
        let serverSession = checkpoint.sessionID.flatMap { boundSessionID in
            sessions.first { $0.id == boundSessionID }
        } ?? sessions.first { $0.date == checkpoint.date }
        guard let serverSession else { return }
        if !checkpointAttemptMatches(checkpoint, serverSession: serverSession) {
            stopRunnerForStateChange()
            return
        }
        if checkpoint.sessionID == nil,
           serverSession.status == "discarded",
           checkpoint.restartDiscardedAttempt == serverSession.attempt
        {
            return
        }
        guard serverSession.status == "planned"
                || serverSession.status == "in_progress"
        else {
            stopRunnerForStateChange()
            return
        }
    }

    /// Migration 0032 assigns generation zero to legacy rows. A checkpoint
    /// missing its local attempt therefore means attempt 0, not "adopt
    /// whichever generation is current." The sole exception is an explicit
    /// restart, whose marker names the discarded generation and therefore
    /// expects the next one once the server revives the date.
    private func checkpointAttemptMatches(
        _ checkpoint: WorkoutRunnerCheckpoint,
        serverSession: SessionRow
    ) -> Bool {
        if checkpoint.sessionID == nil,
           serverSession.status == "discarded",
           checkpoint.restartDiscardedAttempt == serverSession.attempt
        {
            return true
        }
        guard let serverAttempt = serverSession.attempt else { return true }
        let expectedAttempt = checkpoint.sessionAttempt
            ?? checkpoint.restartDiscardedAttempt.map { $0 + 1 }
            ?? 0
        return expectedAttempt == serverAttempt
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
            server_time: stateServerTime,
            manualActivityCursorCapable:
                stateManualActivityCursorCapable,
            externalSyncCursorsVersion:
                stateExternalSyncCursorsVersion)
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
    ) -> StateSnapshotValue? {
        guard canMutateBoundSetAccount else { return nil }
        let acknowledgedSession = Self.sessionAcknowledgedBySet(
            result, submittedSession: submittedSession)
        let snapshot = StateSnapshotStore.load(
            userID: accountID, defaults: defaults)
        let decision = Self.setAcknowledgementMergeDecision(
            acceptedSet: result.set,
            snapshot: snapshot)
        if decision.requiresFullReload {
            guard StateSnapshotStore.requireFullReload(
                userID: accountID, defaults: defaults)
            else { return nil }
        }
        return StateSnapshotStore.mergeAcknowledgement(
            userID: accountID,
            fallback: currentStateResponse(),
            defaults: defaults
        ) { newest in
            Self.mergingSetAcknowledgement(
                into: newest,
                acceptedSet: result.set,
                acknowledgedSession: acknowledgedSession,
                includeAcceptedSet: decision.includeAcceptedSet)
        }
    }

    private func persistTerminalAcknowledgement(
        _ response: SessionRow,
        action: WorkoutTerminalAction
    ) -> StateSnapshotValue? {
        guard canMutateBoundSetAccount else { return nil }
        return StateSnapshotStore.mergeAcknowledgement(
            userID: accountID,
            fallback: currentStateResponse(),
            defaults: defaults
        ) { newest in
            Self.mergingTerminalAcknowledgement(
                into: newest, response: response, action: action)
        }
    }

    /// Session creation/revival is itself an attempt mutation. Merge it into
    /// the shared snapshot before any later await or durable intent binding so
    /// a state request that started before the create cannot overwrite the
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
            // attempt and was handled above. Once both observations are already
            // discarded, normal timestamp/tie rules protect later plan remaps.
            if current.status != "discarded" {
                return response.status == "discarded"
            }
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
            if responseTS != currentTS { return responseTS > currentTS }
            return sessionStatusAdvances(
                from: current.status, to: response.status)
        case (nil, _?):
            return true
        case (_?, nil):
            return false
        case (nil, nil):
            // Incomparable rolling-old responses may advance an explicit state
            // machine transition, but never rewrite equal semantic state (and
            // with it a newer plan-remapped workout_id).
            return sessionStatusAdvances(
                from: current.status, to: response.status)
        }
    }

    private static func sessionStatusAdvances(
        from current: String,
        to response: String
    ) -> Bool {
        if current == "planned", response == "in_progress" { return true }
        if ["planned", "in_progress"].contains(current),
           ["completed", "skipped", "discarded"].contains(response)
        {
            return true
        }
        return response == "discarded" && current != "discarded"
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
            notes: submittedSession.notes, perceived_fatigue: submittedSession.perceived_fatigue,
            id: result.set.session_id,
            date: submittedSession.date,
            status: "in_progress",
            workout_id: submittedSession.workout_id,
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
        acknowledgedSession: SessionRow,
        includeAcceptedSet: Bool = true
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
            notes: source.notes, perceived_fatigue: source.perceived_fatigue,
            id: acceptedSet.session_id,
            date: acknowledgedSession.date,
            status: source.status,
            workout_id: source.workout_id,
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
            // Retain the newest raw tombstone in the snapshot. `applyState`
            // exposes it to outbox reconciliation, then removes it before
            // publishing live workout data.
            if includeAcceptedSet,
               let index = sets.firstIndex(where: { $0.id == acceptedSet.id })
            {
                if setResponseCanReplace(sets[index], with: acceptedSet) {
                    sets[index] = acceptedSet
                }
            } else if includeAcceptedSet {
                sets.append(acceptedSet)
            }
        } else if let index = sets.firstIndex(where: { $0.id == acceptedSet.id }) {
            if includeAcceptedSet,
               sets[index].deleted_at == nil,
               setResponseCanReplace(sets[index], with: acceptedSet)
            {
                sets[index] = acceptedSet
            }
        } else if includeAcceptedSet {
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
            server_time: state.server_time,
            manualActivityCursorCapable:
                state.manualActivityCursorCapable,
            externalSyncCursorsVersion:
                state.externalSyncCursorsVersion)
    }

    private struct SetAcknowledgementMergeDecision {
        let includeAcceptedSet: Bool
        let requiresFullReload: Bool
    }

    /// Decide whether a mutation response may add a row that the latest state
    /// snapshot did not contain. `updated_at` and the request-start horizon are
    /// server-owned; client `logged_at` never participates in causality.
    private static func setAcknowledgementMergeDecision(
        acceptedSet: SetLog,
        snapshot: StateSnapshotValue?
    ) -> SetAcknowledgementMergeDecision {
        guard let snapshot else {
            return SetAcknowledgementMergeDecision(
                includeAcceptedSet: false,
                requiresFullReload: true)
        }
        if let current = snapshot.state.sets.first(where: {
            $0.id == acceptedSet.id
        }) {
            guard current.updated_at != nil, acceptedSet.updated_at != nil else {
                return SetAcknowledgementMergeDecision(
                    includeAcceptedSet: false, requiresFullReload: true)
            }
            // Idempotent UUIDs never resurrect. A newer live correction or
            // template detach likewise outranks an older delayed POST body.
            return SetAcknowledgementMergeDecision(
                includeAcceptedSet: setResponseCanReplace(
                    current, with: acceptedSet)
                    && (current.deleted_at == nil
                        || acceptedSet.deleted_at != nil),
                requiresFullReload: false)
        }
        guard let responseVersion = acceptedSet.updated_at,
              let committedThrough = snapshot.setsCommittedThrough
        else {
            return SetAcknowledgementMergeDecision(
                includeAcceptedSet: false,
                requiresFullReload: true)
        }
        return SetAcknowledgementMergeDecision(
            includeAcceptedSet: acceptedSet.deleted_at != nil
                || responseVersion > committedThrough,
            requiresFullReload: false)
    }

    private static func setResponseCanReplace(
        _ current: SetLog,
        with response: SetLog
    ) -> Bool {
        guard let currentVersion = current.updated_at,
              let responseVersion = response.updated_at
        else { return false }
        // Equality is not causality: two server mutations may share one
        // millisecond, and the committed snapshot wins any such tie.
        return responseVersion > currentVersion
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
            server_time: state.server_time,
            manualActivityCursorCapable:
                state.manualActivityCursorCapable,
            externalSyncCursorsVersion:
                state.externalSyncCursorsVersion)
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
            notes: source.notes, perceived_fatigue: source.perceived_fatigue,
            id: response.id,
            date: response.date,
            status: source.status,
            workout_id: source.workout_id ?? response.workout_id,
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
            server_time: state.server_time,
            manualActivityCursorCapable:
                state.manualActivityCursorCapable,
            externalSyncCursorsVersion:
                state.externalSyncCursorsVersion)
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
                guard let row, row.status == "completed",
                      intent.feedback?.matches(row) != false else { continue }
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
        observedGroupProgress = [:]
        runnerFocus = RunnerFocusState()
        deferredGroupRepair = nil
        running = false
        finished = false
        workoutFeedback = nil
        workoutStart = nil
        clearTimedSet()
        skipped = []
        _ = clearRunnerCheckpointAndSharedRest()
    }

    private func validatePersistedRunnerCheckpoint(preservingFocusIn groups: Set<String> = []) {
        guard let checkpoint = persistedRunnerCheckpoint else {
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
                if !checkpointAttemptMatches(
                    checkpoint, serverSession: serverSession)
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
                if checkpoint.sessionID == nil {
                    bindRunnerCheckpoint(to: serverSession)
                    guard running else { return }
                }
            }
            persistRunnerCheckpoint()
            return
        }
        let checkpointSession = checkpoint.sessionID.flatMap { sessionID in
            sessions.first { $0.id == sessionID }
        } ?? sessions.first { $0.date == checkpoint.date }
        if let checkpointSession,
           !checkpointAttemptMatches(
               checkpoint, serverSession: checkpointSession)
        {
            _ = clearRunnerCheckpointAndSharedRest()
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
        let unstartedFeedback = canResumeUnstartedFeedback(checkpoint, session: checkpointSession)
        let serverSession = checkpointSession?.status == "discarded" ? nil : checkpointSession
        guard checkpoint.date == todayString,
              terminalOutbox.intent(for: checkpoint.date) == nil,
              serverSession?.status == "in_progress" || unstartedFeedback,
              let day = plan?.workouts.first(where: {
                  $0.id == checkpoint.selectedDayID
              }),
              !day.exercises.isEmpty,
              checkpoint.workoutStartedAtMS > 0,
              let currentSlotID = checkpoint.currentSlotID,
              let currentIndex = day.exercises.firstIndex(where: {
                  $0.id == currentSlotID
              })
        else {
            _ = clearRunnerCheckpointAndSharedRest()
            return
        }

        let liveSlotIDs = Set(day.exercises.map(\.id))
        let normalizedSkipped = checkpoint.skippedSlotIDs
            .filter { liveSlotIDs.contains($0) }
            .sorted()
        let skippedIDs = Set(normalizedSkipped)
        func checkpointSetIDs(_ slot: TemplateExercise) -> Set<String> {
            let accepted = serverSession.map {
                Set(slotSets(slot, sessionID: $0.id, dayExercises: day.exercises).map(\.id))
            } ?? []
            guard slot.group_id != nil else { return accepted }
            return accepted.union(setOutbox.pending.filter {
                $0.deliveryState == .queued && setIntent($0, matches: slot, on: checkpoint.date)
            }.map(\.id))
        }
        func checkpointGroup(_ slot: TemplateExercise) -> GroupRunnerProgress? {
            guard let id = slot.group_id else { return nil }
            return GroupRunnerProgress(id: id, members: day.exercises.filter { $0.group_id == id }.map {
                .init(id: $0.id, target: $0.target_sets, completedIDs: checkpointSetIDs($0), skipped: skippedIDs.contains($0.id))
            })
        }
        let unresolvedIndices = Set(day.exercises.indices.filter { index in
            let slot = day.exercises[index]
            return !skippedIDs.contains(slot.id) && checkpointSetIDs(slot).count < slot.target_sets
        })
        let normalizedFinished = unresolvedIndices.isEmpty
        let normalizedCurrentSlotID: String
        let currentGroup = checkpointGroup(day.exercises[currentIndex])
        let preserveFocus = currentGroup.map { groups.contains($0.id) } ?? false
        let deferredProgress = checkpoint.deferredGroupRepair.flatMap { repair -> GroupRunnerProgress? in
            guard RunnerGroupRepair(groupID: repair.groupID, day: day) == repair,
                  let slot = day.exercises.first(where: { $0.group_id == repair.groupID }) else { return nil }
            return checkpointGroup(slot)
        }
        if let nextID = deferredProgress?.nextMemberID {
            normalizedCurrentSlotID = nextID
        } else if !normalizedFinished, let group = currentGroup,
           !preserveFocus, group != checkpoint.groupProgress, let nextID = group.nextMemberID {
            normalizedCurrentSlotID = nextID
        } else if preserveFocus || normalizedFinished || unresolvedIndices.contains(currentIndex)
                    || (currentGroup != nil && currentGroup == checkpoint.groupProgress) {
            normalizedCurrentSlotID = currentSlotID
        } else {
            // Mirror the mounted runner's wrapped next-unresolved rule. This
            // advances a checkpoint left behind while its set request awaited
            // the network and lands an all-resolved workout on FinishedView.
            let nextIndex = (1...day.exercises.count)
                .map { (currentIndex + $0) % day.exercises.count }
                .first(where: unresolvedIndices.contains)!
            normalizedCurrentSlotID = checkpointGroup(day.exercises[nextIndex])?.nextMemberID ?? day.exercises[nextIndex].id
        }
        var normalizedFocus = checkpoint.focus
        if normalizedCurrentSlotID != currentSlotID
            || (normalizedFinished && !checkpoint.finished) || deferredProgress != nil {
            normalizedFocus?.isExplicit = false
        }
        let normalized = WorkoutRunnerCheckpoint(
            date: checkpoint.date,
            sessionID: serverSession?.id,
            selectedDayID: checkpoint.selectedDayID,
            currentSlotID: normalizedCurrentSlotID,
            skippedSlotIDs: normalizedSkipped,
            workoutStartedAtMS: checkpoint.workoutStartedAtMS,
            finished: normalizedFinished,
            sessionAttempt: serverSession?.attempt ?? checkpoint.sessionAttempt,
            restartDiscardedAttempt: serverSession == nil ? checkpoint.restartDiscardedAttempt : nil,
            input: checkpoint.input, inputsBySlot: checkpoint.inputsBySlot, groupProgress: day.exercises.first(where: { $0.id == normalizedCurrentSlotID }).flatMap(checkpointGroup),
            focus: normalizedFocus, feedback: checkpoint.feedback)
        if normalized != checkpoint {
            guard replaceRunnerCheckpoint(
                normalized, ifCurrent: checkpoint)
            else {
                relinquishStaleRunnerCheckpoint()
                return
            }
        }
        persistedRunnerCheckpoint = normalized
        deferredGroupRepair = nil
        runnerFocus = normalized.focus ?? RunnerFocusState()
        runnerRestartDiscardedAttempt = normalized.restartDiscardedAttempt
        // A recovered explicit override can legitimately differ from the
        // server session's immutable day pin. Align Today and its Resume CTA to
        // the validated checkpoint before mounting the runner.
        selectedDayID = normalized.selectedDayID
        resumableCheckpoint = normalized
    }

    /// An explicit feedback save is durable even before the first set creates
    /// a session. A live read must still prove the original attempt is safe.
    private func canResumeUnstartedFeedback(_ checkpoint: WorkoutRunnerCheckpoint, session: SessionRow?) -> Bool {
        guard checkpoint.feedback != nil else { return false }
        guard let session else { return checkpoint.sessionID == nil }
        guard checkpointAttemptMatches(checkpoint, serverSession: session) else { return false }
        return session.status == "planned" || (checkpoint.sessionID == nil
            && session.status == "discarded" && checkpoint.restartDiscardedAttempt == session.attempt
            && checkpoint.restartDiscardedAttempt != nil)
    }

    @discardableResult
    private func persistRunnerCheckpoint() -> Bool {
        guard !defaults.hasFailure(userID: accountID) else {
            restoreRunnerAfterSaveFailure()
            return false
        }
        guard canInitiateBoundFeatureAction,
              !runnerArtifactsOwnedByOther,
              running,
              let selectedDayID,
              let workoutStart,
              let currentSlotID = activeRunnerSlotID()
        else { return false }
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
            restartDiscardedAttempt: runnerRestartDiscardedAttempt,
            input: currentInputState, inputsBySlot: runnerInputsForCheckpoint(), groupProgress: currentExercise.flatMap { groupProgress(for: $0) }, focus: runnerFocus, deferredGroupRepair: deferredGroupRepair, feedback: workoutFeedback)
        let expected = persistedRunnerCheckpoint
        guard replaceRunnerCheckpoint(checkpoint, ifCurrent: expected) else {
            relinquishStaleRunnerCheckpoint()
            return false
        }
        persistedRunnerCheckpoint = checkpoint
        resumableCheckpoint = nil
        RunnerArtifactOwnership.claim(
            runnerArtifactOwnerID,
            featureSessionEpoch: featureSessionEpoch,
            userID: accountID,
            defaults: defaults)
        return true
    }

    /// Session creation and the first set write are separate requests. Bind the
    /// durable runner checkpoint as soon as creation succeeds so a transient
    /// first-set failure cannot strand a nil-session checkpoint on relaunch.
    private func bindRunnerCheckpoint(to session: SessionRow) {
        guard canInitiateBoundFeatureAction,
              !runnerArtifactsOwnedByOther,
              let checkpoint = persistedRunnerCheckpoint,
              checkpoint.date == session.date,
              checkpoint.sessionID != session.id
                || (checkpoint.sessionAttempt == nil && session.attempt != nil),
              checkpointAttemptMatches(
                  checkpoint, serverSession: session)
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
            restartDiscardedAttempt: nil,
            input: checkpoint.input, inputsBySlot: checkpoint.inputsBySlot, groupProgress: checkpoint.groupProgress, focus: checkpoint.focus, deferredGroupRepair: checkpoint.deferredGroupRepair, feedback: checkpoint.feedback)
        guard replaceRunnerCheckpoint(bound, ifCurrent: checkpoint) else {
            relinquishStaleRunnerCheckpoint()
            return
        }
        persistedRunnerCheckpoint = bound
        if running {
            RunnerArtifactOwnership.claim(
                runnerArtifactOwnerID,
                featureSessionEpoch: featureSessionEpoch,
                userID: accountID,
                defaults: defaults)
        }
        runnerRestartDiscardedAttempt = nil
        resumableCheckpoint = nil
    }

    @discardableResult
    private func clearRunnerCheckpoint() -> Bool {
        let expected = persistedRunnerCheckpoint
        persistedRunnerCheckpoint = nil
        runnerRestartDiscardedAttempt = nil
        resumableCheckpoint = nil
        guard canInitiateBoundFeatureAction,
              !RunnerArtifactOwnership.isOwnedByOther(
            than: runnerArtifactOwnerID,
            featureSessionEpoch: featureSessionEpoch,
            userID: accountID,
            defaults: defaults)
        else { return false }
        let cleared = WorkoutRunnerCheckpointStore.clear(
            ifCurrent: expected,
            userID: accountID,
            defaults: defaults)
        if cleared {
            // A newer feature epoch may clear an inherited checkpoint owned by
            // the retired epoch. Claim the shared artifacts long enough for
            // the caller's terminal teardown (or the next explicit start).
            RunnerArtifactOwnership.claim(
                runnerArtifactOwnerID,
                featureSessionEpoch: featureSessionEpoch,
                userID: accountID,
                defaults: defaults)
        }
        return cleared
    }

    /// Retire a checkpoint from the current auth epoch together with the
    /// process-shared rest artifacts it owns. A stale model can clear only its
    /// local task; the replacement owner keeps its Live Activity and cue.
    @discardableResult
    private func clearRunnerCheckpointAndSharedRest() -> Bool {
        let shouldTearDownSharedRest =
            persistedRunnerCheckpoint != nil || canControlSharedRestArtifacts
        guard clearRunnerCheckpoint() else {
            relinquishLocalRest()
            return false
        }
        if shouldTearDownSharedRest {
            skipRest()
        } else {
            relinquishLocalRest()
        }
        releaseRunnerArtifactOwnership()
        return true
    }

    /// End account-visible rest UI before AuthModel invalidates this feature
    /// epoch. The durable runner checkpoint remains available for a safe,
    /// live-validated resume after reauthentication; only its current exact
    /// owner may touch the process-shared ActivityKit/notification pair.
    private func prepareForFeatureSessionBoundary() {
        planHistoryRequest = UUID()
        recentPlanHistory = nil
        planChangesError = nil
        workoutWriteDrainRequested = false
        // Stop this model's task, but preserve the account-scoped server floor
        // for the replacement model that inherits the durable outbox.
        cancelWorkoutWriteRetry(
            resetAttempt: true, clearServerDeadline: false)
        guard canControlSharedRestArtifacts else {
            relinquishLocalRest()
            return
        }
        skipRest()
        releaseRunnerArtifactOwnership()
    }

    private func releaseRunnerArtifactOwnership() {
        RunnerArtifactOwnership.release(
            runnerArtifactOwnerID,
            featureSessionEpoch: featureSessionEpoch,
            userID: accountID,
            defaults: defaults)
    }

    private func replaceRunnerCheckpoint(
        _ checkpoint: WorkoutRunnerCheckpoint,
        ifCurrent expected: WorkoutRunnerCheckpoint?
    ) -> Bool {
        guard !runnerArtifactsOwnedByOther else { return false }
        if WorkoutRunnerCheckpointStore.replace(
            checkpoint,
            ifCurrent: expected,
            userID: accountID,
            defaults: defaults)
        {
            return true
        }
        guard !defaults.hasFailure(userID: accountID) else { return false }
        // Two models can independently normalize to an identical checkpoint;
        // accepting that exact stored value is equivalent to a successful CAS.
        return WorkoutRunnerCheckpointStore.load(
            userID: accountID, defaults: defaults) == checkpoint
    }

    /// Stop only this stale model. Cancel its in-process rest task, but do not
    /// clear the durable checkpoint or shared rest artifacts: a newer
    /// same-account model owns them now.
    private func relinquishStaleRunnerCheckpoint() {
        if defaults.hasFailure(userID: accountID) {
            restoreRunnerAfterSaveFailure()
            return
        }
        observedGroupProgress = [:]
        runnerFocus = RunnerFocusState()
        deferredGroupRepair = nil
        persistedRunnerCheckpoint = nil
        resumableCheckpoint = nil
        running = false
        finished = false
        workoutStart = nil
        clearTimedSet()
        skipped = []
        relinquishLocalRest()
        loadError = "This workout continued in another app view. Refresh to continue."
    }

    /// Failed checkpoint changes are rejected immediately. Storage retry only
    /// proves the files can be read/written; it must not appear to undo an
    /// accepted skip, selection or input when RootView remounts the models.
    /// Keep the durable checkpoint and server/outbox state untouched.
    private func restoreRunnerAfterSaveFailure() {
        clearTimedSet()
        observedGroupProgress = [:]
        guard let checkpoint = persistedRunnerCheckpoint,
              let day = plan?.workouts.first(where: { $0.id == checkpoint.selectedDayID }),
              let index = day.exercises.firstIndex(where: { $0.id == checkpoint.currentSlotID })
        else {
            // A first checkpoint could not be saved, or the live plan no
            // longer contains it. Do not present unsaved runner progress.
            running = false
            finished = false
            workoutStart = nil
            skipped = []
            workoutFeedback = nil
            runnerFocus = RunnerFocusState()
            deferredGroupRepair = nil
            loadError = "Couldn't save this workout on your iPhone. Retry saved data to continue."
            return
        }
        selectedDayID = day.id
        exerciseIndex = index
        skipped = Set(checkpoint.skippedSlotIDs)
        workoutStart = Date(timeIntervalSince1970: TimeInterval(checkpoint.workoutStartedAtMS) / 1_000)
        finished = checkpoint.finished
        workoutFeedback = checkpoint.feedback
        runnerFocus = checkpoint.focus ?? RunnerFocusState()
        deferredGroupRepair = checkpoint.deferredGroupRepair
        runnerRestartDiscardedAttempt = checkpoint.restartDiscardedAttempt
        seedInputs()
        rememberGroupProgress()
        loadError = "Couldn't save this change. Your last saved workout is restored. Retry saved data, then try again."
    }

    /// The runner's current physical slot without `selectedDay`'s first-day
    /// fallback. A missing day or out-of-range index is invalid runner state.
    private func activeRunnerSlotID() -> String? {
        guard running,
              let selectedDayID,
              let day = plan?.workouts.first(where: { $0.id == selectedDayID }),
              day.exercises.indices.contains(exerciseIndex)
        else { return nil }
        return day.exercises[exerciseIndex].id
    }

    private func executionIdentity(
        for ex: TemplateExercise
    ) -> RunnerExecutionIdentity {
        RunnerExecutionIdentity(
            slotID: ex.id,
            exerciseID: ex.exercise_id,
            isWarmup: ex.isWarmup,
            isTimed: ex.isTimed,
            isBodyweight: ex.isBodyweight)
    }

    /// Capture the executable identity behind every durable/in-memory skip
    /// before a live plan replacement. Slot UUID alone is insufficient: an
    /// editor can replace the movement in place, and the new work must not
    /// inherit the old movement's user choice.
    private func skippedExecutionStateForCurrentPlan()
        -> (
            identities: [String: RunnerExecutionIdentity],
            unverified: Set<String>
        )
    {
        var skippedSlotIDs = skipped
        if let checkpoint = persistedRunnerCheckpoint {
            skippedSlotIDs.formUnion(checkpoint.skippedSlotIDs)
        }
        var identities: [String: RunnerExecutionIdentity] = [:]
        for ex in plan?.workouts.flatMap(\.exercises) ?? []
        where skippedSlotIDs.contains(ex.id) {
            identities[ex.id] = executionIdentity(for: ex)
        }
        return (identities, skippedSlotIDs.subtracting(identities.keys))
    }

    /// Drop skips whose stable slot now describes different executable work,
    /// and update the durable checkpoint before resume validation. This covers
    /// both mounted non-active slots and cold-launch checkpoints restored from
    /// an older cached plan.
    private func reconcileInheritedSkips(
        previousExecutionIdentities: [String: RunnerExecutionIdentity],
        unverifiedSlotIDs: Set<String>
    ) {
        var currentIdentities: [String: RunnerExecutionIdentity] = [:]
        for ex in plan?.workouts.flatMap(\.exercises) ?? [] {
            currentIdentities[ex.id] = executionIdentity(for: ex)
        }
        let changedSlotIDs = unverifiedSlotIDs.union(
            previousExecutionIdentities.compactMap {
            slotID, identity in
            currentIdentities[slotID] == identity ? nil : slotID
            })
        guard !changedSlotIDs.isEmpty else { return }
        skipped.subtract(changedSlotIDs)

        guard let checkpoint = persistedRunnerCheckpoint else { return }
        let retainedSkipped = checkpoint.skippedSlotIDs.filter {
            !changedSlotIDs.contains($0)
        }
        guard retainedSkipped != checkpoint.skippedSlotIDs else { return }
        let normalized = WorkoutRunnerCheckpoint(
            date: checkpoint.date,
            sessionID: checkpoint.sessionID,
            selectedDayID: checkpoint.selectedDayID,
            currentSlotID: checkpoint.currentSlotID,
            skippedSlotIDs: retainedSkipped,
            workoutStartedAtMS: checkpoint.workoutStartedAtMS,
            finished: checkpoint.finished,
            sessionAttempt: checkpoint.sessionAttempt,
            restartDiscardedAttempt: checkpoint.restartDiscardedAttempt,
            input: checkpoint.input, inputsBySlot: checkpoint.inputsBySlot, groupProgress: checkpoint.groupProgress, focus: checkpoint.focus, deferredGroupRepair: checkpoint.deferredGroupRepair, feedback: checkpoint.feedback)
        guard replaceRunnerCheckpoint(normalized, ifCurrent: checkpoint) else {
            relinquishStaleRunnerCheckpoint()
            return
        }
        persistedRunnerCheckpoint = normalized
        if running {
            RunnerArtifactOwnership.claim(
                runnerArtifactOwnerID,
                featureSessionEpoch: featureSessionEpoch,
                userID: accountID,
                defaults: defaults)
        }
        if resumableCheckpoint == checkpoint { resumableCheckpoint = normalized }
    }

    private func activeRunnerExecutionIdentity() -> RunnerExecutionIdentity? {
        guard activeRunnerSlotID() != nil, let ex = currentExercise else {
            return nil
        }
        return executionIdentity(for: ex)
    }

    /// Inactive state prefers the real session's remapped day. An active
    /// explicit override retains its valid day; otherwise it falls back to the
    /// remapped session day. The runner continues only when its physical slot
    /// still exists on the resolved day.
    private func reconcileSelection(previousSelectedDayID: String?, activeSlotID: String?,
                                    runnerWasActive: Bool) {
        let days = plan?.workouts ?? []
        let sessionDayID = todaySession?.workout_id
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
        // A live plan/set refresh may retain the runner while changing the
        // slot or displayed set that an active hold was bound to. Fail closed
        // immediately instead of letting the old deadline write its successor.
        if timedActive { _ = validatedTimedSetAttempt() }
    }

    /// Stop only local execution state; the already-logged server data stays.
    private func stopRunnerForStateChange() {
        observedGroupProgress = [:]
        runnerFocus = RunnerFocusState()
        deferredGroupRepair = nil
        exerciseIndex = 0
        running = false
        finished = false
        workoutStart = nil
        clearTimedSet()
        skipped = []
        _ = clearRunnerCheckpointAndSharedRest()
    }

    /// Adopt a successful aliased write when the follow-up sync pull is
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
            notes: staleSession.notes, perceived_fatigue: staleSession.perceived_fatigue,
            id: committedSet.session_id,
            date: staleSession.date,
            status: staleSession.status,
            workout_id: staleSession.workout_id,
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
        historyIndex.workingSetsByExercise[exerciseID] ?? []
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
            $0.exercise_id == ex.exercise_id
                && ($0.isWarmup ? 1 : 0) == warm
                && $0.isTimed == ex.isTimed
        }.count == 1
        return sets.filter { s in
            guard s.session_id == sessionID, s.deleted_at == nil else { return false }
            // The per-set flag is authoritative after migration 0024. Legacy
            // rows intentionally fall back to catalog modality: duration is
            // not reliable because older rep sets can carry incidental timing.
            // Never infer from today's slot, which would let a later mode edit
            // inherit completion across rep/timed work.
            let setIsTimed = isTimedSet(s)
            guard setIsTimed == ex.isTimed else { return false }
            // Slot-linked set: attribute to this slot ONLY when the movement AND
            // the warm-up/timed classes also match. The slot id alone is not
            // trusted — a stale link after a swap or mode flip must never count
            // toward, or complete, the replacement slot.
            if let teid = s.template_exercise_id {
                return teid == ex.id && s.exercise_id == ex.exercise_id && s.is_warmup == warm
            }
            return unique && s.exercise_id == ex.exercise_id && s.is_warmup == warm
        }
        .sorted { $0.set_index < $1.set_index }
    }

    func exerciseName(_ id: String) -> String {
        catalogRow(id)?.name ?? id
    }

    /// Catalog row for an exercise id, or nil if unknown. Used by the demo
    /// sheet to render the primary muscle/load-mode badges without a second
    /// lookup table.
    func catalogRow(_ id: String) -> ExerciseCatalog? {
        historyIndex.catalogByID[id]
    }

    /// How many physical sides a logged set covers — 2 for unilateral
    /// exercises (Bulgarian split squat, lunge, one-arm row; reps logged
    /// per-side), 1 for everything else. Used by rollups to convert
    /// logged-rep-count → physical-rep-count and tonnage → real tonnage.
    /// Defaults to 1 when the catalog row is unknown.
    func sides(for exerciseID: String) -> Int {
        catalogRow(exerciseID)?.laterality == "unilateral" ? 2 : 1
    }

    /// How many separately loaded implements a logged weight represents — 2
    /// for `per_hand` exercises, 1 otherwise. This is independent of
    /// laterality: a unilateral, per-hand movement counts both dimensions.
    /// Defaults to 1 when the catalog row is unknown.
    func implements(for exerciseID: String) -> Int {
        catalogRow(exerciseID)?.load_mode == "per_hand" ? 2 : 1
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

    func metricCohorts(for sets: [SetLog]) -> [ExerciseMetricCohort] {
        ExerciseMetrics.cohorts(sets, catalog: catalog)
    }

    func bestHoldSeconds(for sets: [SetLog]) -> Int? {
        let holds = metricCohorts(for: sets).filter { $0.key.timed }
        return holds.count == 1 ? holds[0].bestHoldSeconds : nil
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
        catalogRow(exerciseID)?.modality == "timed"
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
        catalogRow(exerciseID)?.modality == "bw"
    }

    // MARK: history read model

    typealias SessionStat = TrainingHistoryIndex.SessionStat
    private var cachedHistoryIndex: TrainingHistoryIndex?
    private var cachedHistory: [String: [SessionStat]] = [:]
    private var cachedLatestHistory: [String: [SessionStat]] = [:]

    private func invalidateHistory() {
        cachedHistoryIndex = nil
        cachedHistory.removeAll(keepingCapacity: true)
        cachedLatestHistory.removeAll(keepingCapacity: true)
    }

    private var historyIndex: TrainingHistoryIndex {
        if let cachedHistoryIndex { return cachedHistoryIndex }
        let index = TrainingHistoryIndex(sessions: sessions, sets: sets, catalog: catalog)
        cachedHistoryIndex = index
        return index
    }

    var loggedExerciseIDs: [String] { historyIndex.loggedExerciseIDs }

    func history(for exerciseID: String) -> [SessionStat] {
        if let cached = cachedHistory[exerciseID] { return cached }
        let stats = historyIndex.history(for: exerciseID)
        cachedHistory[exerciseID] = stats
        return stats
    }

    /// List rows need one session summary, not every historical cohort/chart.
    func latestHistory(for exerciseID: String) -> SessionStat? {
        if let cached = cachedLatestHistory[exerciseID] { return cached.first }
        let stats = historyIndex.history(for: exerciseID, latestOnly: true)
        cachedLatestHistory[exerciseID] = stats
        return stats.first
    }

    /// Only sessions with a timed hold duration (including the legacy reps
    /// fallback) belong on this trend. Mixed rep/hold histories must not
    /// synthesize 0-second points for rep-only sessions.
    func durationHistory(for exerciseID: String) -> [SessionStat] {
        history(for: exerciseID).filter {
            $0.hasTimedSets && $0.avgDuration > 0
        }
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

    /// LocalPersistence is the same-account coordination boundary across multiple
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
        setCorrections = SetCorrectionOutboxStore.load(userID: accountID, defaults: defaults)
        ownedCorrectionIDs.formIntersection(setCorrections.map(\.id))
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

    private func setIntent(
        _ intent: PendingSetIntent,
        matches ex: TemplateExercise,
        on date: String
    ) -> Bool {
        intent.date == date
            && intent.slotID == ex.id
            && intent.body.exercise_id == ex.exercise_id
            && intent.body.is_warmup == ex.isWarmup
            && intent.body.is_timed == ex.isTimed
    }

    func pendingSetIntents(for ex: TemplateExercise) -> [PendingSetIntent] {
        let date = todaySession?.date ?? todayString
        return setOutbox.pending.filter { setIntent($0, matches: ex, on: date) }
    }

    func isSetEntryBlocked(_ ex: TemplateExercise) -> Bool {
        if hasPendingTerminalIntentForCurrentWorkout || isTerminalMutationInFlight {
            return true
        }
        if setSlotsInFlight.contains(ex.id) { return true }
        let date = todaySession?.date ?? todayString
        return setOutbox.pending.contains {
            setIntent($0, matches: ex, on: date)
                && $0.deliveryState == .failed
        }
    }

    /// Terminal workout mutations are P1, but P0 must not let an acknowledged
    /// discard/finish erase the session context that queued set retries need.
    var hasPendingSetsForCurrentWorkout: Bool {
        let date = todaySession?.date ?? todayString
        return setOutbox.pending.contains { $0.date == date }
            || setCorrections.contains { $0.date == date }
    }

    private func persistEnqueuedSetIntent(_ intent: PendingSetIntent) -> Bool {
        guard canMutateBoundSetAccount,
              SetOutboxStore.enqueue(intent, userID: accountID, defaults: defaults)
        else { return false }
        ownedSetIntentIDs.insert(intent.id)
        return true
    }

    @discardableResult
    private func persistReplacedSetIntent(_ intent: PendingSetIntent) -> Bool {
        guard canMutateBoundSetAccount,
              SetOutboxStore.replace(intent, userID: accountID, defaults: defaults)
        else {
            setOutbox = SetOutboxStore.load(userID: accountID, defaults: defaults)
            loadError = "The set change could not be saved on this iPhone. Retry saved data before continuing."
            return false
        }
        return true
    }

    private func persistRemovedSetIntentIDs(_ ids: Set<String>) {
        guard canMutateBoundSetAccount else { return }
        SetOutboxStore.remove(
            ids: ids, userID: accountID, defaults: defaults)
        ownedSetIntentIDs.subtract(ids)
    }

    private func persistEnqueuedTerminalIntent(_ intent: WorkoutTerminalIntent) -> Bool {
        guard canMutateBoundSetAccount,
              WorkoutTerminalOutboxStore.enqueue(intent, userID: accountID, defaults: defaults)
        else { return false }
        if WorkoutTerminalOutboxStore.load(
            userID: accountID, defaults: defaults
        ).intent(for: intent.date)?.id == intent.id {
            ownedTerminalIntentIDs.insert(intent.id)
            return true
        }
        return false
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

    /// A state pull is also authoritative acknowledgement of an exact
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
        // applyState remaps the active stable slot after the plan assignment,
        // then performs one authoritative runner normalization. Normalizing
        // here would interpret the old numeric index against a newly reordered
        // plan and could clear a valid timed attempt.
    }

    /// Explicitly re-arm one permanent 4xx failure. The request body remains
    /// byte-for-byte equivalent under Codable and retains its original UUID.
    func retrySetIntent(id: String) async {
        guard canInitiateBoundFeatureAction,
              var intent = setOutbox.pending.first(where: { $0.id == id }),
              intent.deliveryState == .failed
        else { return }
        intent.deliveryState = .queued
        intent.failedHTTPStatus = nil
        guard persistReplacedSetIntent(intent) else { return }
        setOutbox.replace(intent)
        normalizeMountedRunnerProgress(for: intent.date)
        await drainSetOutbox()
    }

    func retryFailedSetIntents() async {
        guard canInitiateBoundFeatureAction else { return }
        var changed = false
        var rearmedDates: Set<String> = []
        for var intent in setOutbox.pending where intent.deliveryState == .failed {
            intent.deliveryState = .queued
            intent.failedHTTPStatus = nil
            guard persistReplacedSetIntent(intent) else { return }
            setOutbox.replace(intent)
            rearmedDates.insert(intent.date)
            changed = true
        }
        guard changed else { return }
        for date in rearmedDates {
            normalizeMountedRunnerProgress(for: date)
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
            && sets.contains(where: {
                $0.id == intent.id && $0.deleted_at == nil
            })
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
        durationOverride: Int?,
        rpe: Double? = nil
    ) -> PendingSetIntent? {
        let workoutDate = todaySession?.date ?? todayString
        guard canInitiateBoundFeatureAction,
              currentJWT != nil, canMutateBoundSetAccount,
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
        let nextIndex = nextReservedSetIndex(for: ex)
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
            is_timed: ex.isTimed, rpe: rpe,
            prescription: selectedDayID.flatMap { dayID in
                plan.map { SetPrescriptionContext(plan_id: $0.id, version: $0.version, day_id: dayID) }
            })
        let intent = PendingSetIntent(
            body: body,
            date: workoutDate,
            workoutID: selectedDay?.id,
            resolvedSessionID: todaySession?.id,
            deliveryState: .queued,
            failedHTTPStatus: nil,
            expectedAttempt: todaySession?.attempt,
            restartDiscardedAttempt: runnerRestartDiscardedAttempt)

        // No network await may occur above this save. A failed/lost session
        // create therefore leaves the complete intent available on relaunch.
        setOutbox.enqueue(intent)
        guard persistEnqueuedSetIntent(intent) else {
            setOutbox = SetOutboxStore.load(userID: accountID, defaults: defaults)
            setSlotsInFlight.remove(ex.id)
            loadError = "Couldn't save this set on your iPhone. Retry saved data before logging it again."
            return nil
        }
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
        durationOverride: Int? = nil,
        rpe: Double? = nil
    ) -> Bool {
        let groupBeforeCommit = groupProgress(for: ex)
        guard let intent = enqueueSetIntent(
            ex, weight: weight, reps: reps, durationOverride: durationOverride, rpe: rpe
        ) else { return false }
        runnerFocus.isExplicit = false

        if running {
            if let group = groupBeforeCommit {
                let completedRound = (groupProgress(for: ex)?.completedRounds ?? group.completedRounds) > group.completedRounds
                normalizeMountedRunnerAfterLocalCommit(for: intent.date)
                let seconds = completedRound
                    ? ex.group_rest_seconds ?? ex.rest_seconds : ex.group_transition_seconds ?? 0
                if seconds > 0 { startRest(seconds: seconds, name: ex.exercise_name) }
                else if restEndDate != nil { skipRest() }
            } else {
                startRest(seconds: ex.rest_seconds, name: ex.exercise_name)
            }
        }
        // The cursor can stay on the same member with uneven progress. Its
        // new physical commit still durably ends explicit-focus protection.
        persistRunnerCheckpoint()
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
        case acknowledged(
            setID: String,
            canonicalSessionID: String,
            date: String,
            baselineProvedAcknowledgement: Bool)
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
        guard currentJWT != nil, canInitiateBoundFeatureAction else { return }
        await loadAfterMutation()
        guard currentJWT != nil, canInitiateBoundFeatureAction else { return }
        await drainWorkoutWriteOutboxes()
    }

    /// All launch/foreground/connectivity/tap triggers converge here. A second
    /// caller waits for the active drain instead of starting a competing set or
    /// terminal request. This is the ordering boundary that makes discard the
    /// final client mutation even when it is requested during another await.
    func drainWorkoutWriteOutboxes() async {
        // Local backoff may be superseded by an explicit recovery signal, but a
        // server Retry-After floor applies to every trigger. Keep the existing
        // scheduled owner alive instead of turning foreground/manual recovery
        // into an early resend.
        adoptPersistedWorkoutWriteRetryDeadline()
        if let notBefore = workoutWriteRetryNotBefore {
            let remaining = notBefore.timeIntervalSince(now())
            if remaining > 0 {
                workoutWriteRetryMinimumDelayNanoseconds = max(
                    workoutWriteRetryMinimumDelayNanoseconds ?? 0,
                    retryDelayNanoseconds(seconds: remaining))
                scheduleWorkoutWriteRetry()
                return
            }
            WorkoutWriteRetryDeadlineStore.clear(
                through: notBefore, userID: accountID, defaults: defaults)
            workoutWriteRetryNotBefore = nil
        }
        cancelWorkoutWriteRetry(resetAttempt: false)
        guard currentJWT != nil, canInitiateBoundFeatureAction,
              !setOutbox.isEmpty || !terminalOutbox.intents.isEmpty || !setCorrections.isEmpty
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
        workoutWriteRetryMinimumDelayNanoseconds = nil
        // An intent can be persisted while this owner is awaiting the final
        // reconciliation pull. Re-check the queue before releasing waiters so
        // that trigger coalesces into this same serialized drain instead of
        // being stranded until some later lifecycle/network event.
        var stoppedForRetryableFailure = false
        while canInitiateBoundFeatureAction, currentJWT != nil {
            workoutWriteDrainRequested = false
            stoppedForRetryableFailure = await performWorkoutWriteDrain()
            if stoppedForRetryableFailure,
               workoutWriteRetryNotBefore != nil
                    || !workoutWriteDrainRequested
            {
                break
            }
            guard hasImmediatelyDeliverableWorkoutWrite else { break }
        }
        isDrainingWorkoutWrites = false
        let waiters = workoutWriteDrainWaiters
        workoutWriteDrainWaiters.removeAll()
        waiters.forEach { $0.resume() }
        if stoppedForRetryableFailure && hasImmediatelyDeliverableWorkoutWrite {
            scheduleWorkoutWriteRetry()
        } else if !hasImmediatelyDeliverableWorkoutWrite {
            let durableQueuesAreEmpty = SetOutboxStore.load(
                userID: accountID, defaults: defaults).isEmpty
                && WorkoutTerminalOutboxStore.load(
                    userID: accountID, defaults: defaults).intents.isEmpty
                && SetCorrectionOutboxStore.load(userID: accountID, defaults: defaults).isEmpty
            cancelWorkoutWriteRetry(
                resetAttempt: true,
                clearServerDeadline: durableQueuesAreEmpty)
        }
    }

    private func scheduleWorkoutWriteRetry() {
        // Another same-account generation can finish an older in-flight 503
        // while this model is handling a different transient result. Re-read
        // the shared floor immediately before choosing any new send time.
        adoptPersistedWorkoutWriteRetryDeadline()
        if let notBefore = workoutWriteRetryNotBefore {
            let remaining = notBefore.timeIntervalSince(now())
            if remaining > 0 {
                workoutWriteRetryMinimumDelayNanoseconds = max(
                    workoutWriteRetryMinimumDelayNanoseconds ?? 0,
                    retryDelayNanoseconds(seconds: remaining))
            }
        }
        guard automaticWorkoutWriteRetryEnabled,
              workoutWriteRetryTask == nil,
              currentJWT != nil,
              canInitiateBoundFeatureAction,
              hasImmediatelyDeliverableWorkoutWrite,
              !workoutWriteRetryDelaysNanoseconds.isEmpty
        else { return }

        let delayIndex = min(
            workoutWriteRetryAttempt,
            workoutWriteRetryDelaysNanoseconds.count - 1)
        let delay = max(
            workoutWriteRetryDelaysNanoseconds[delayIndex],
            workoutWriteRetryMinimumDelayNanoseconds ?? 0)
        let scheduledServerDeadline = workoutWriteRetryNotBefore
        if workoutWriteRetryAttempt < workoutWriteRetryDelaysNanoseconds.count - 1 {
            workoutWriteRetryAttempt += 1
        }
        workoutWriteRetryTask = Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                try await self.workoutWriteRetrySleeper(delay)
            } catch {
                return
            }
            guard !Task.isCancelled,
                  self.currentJWT != nil,
                  self.canInitiateBoundFeatureAction
            else {
                self.workoutWriteRetryTask = nil
                return
            }
            self.workoutWriteRetryTask = nil
            // This task slept for the max of local backoff and Retry-After.
            // Clearing the floor here lets its own drain proceed even when an
            // injected test clock is fixed.
            if let scheduledServerDeadline {
                WorkoutWriteRetryDeadlineStore.clear(
                    through: scheduledServerDeadline,
                    userID: self.accountID,
                    defaults: self.defaults)
            }
            self.workoutWriteRetryNotBefore = nil
            self.workoutWriteRetryMinimumDelayNanoseconds = nil
            await self.drainWorkoutWriteOutboxes()
        }
    }

    private func cancelWorkoutWriteRetry(
        resetAttempt: Bool,
        clearServerDeadline: Bool = false
    ) {
        workoutWriteRetryTask?.cancel()
        workoutWriteRetryTask = nil
        if resetAttempt {
            workoutWriteRetryAttempt = 0
            workoutWriteRetryMinimumDelayNanoseconds = nil
            workoutWriteRetryNotBefore = nil
            if clearServerDeadline, let accountID {
                WorkoutWriteRetryDeadlineStore.clear(
                    userID: accountID, defaults: defaults)
            }
        }
    }

    private func adoptPersistedWorkoutWriteRetryDeadline() {
        if let persisted = WorkoutWriteRetryDeadlineStore.load(
            userID: accountID, defaults: defaults),
           persisted > (workoutWriteRetryNotBefore ?? .distantPast)
        {
            workoutWriteRetryNotBefore = persisted
        }
    }

    private var hasImmediatelyDeliverableWorkoutWrite: Bool {
        if setOutbox.pending.contains(where: {
            $0.deliveryState == .queued && ownedSetIntentIDs.contains($0.id)
        }) {
            return true
        }
        if setCorrections.contains(where: { correction in
            correction.deliveryState == .queued && ownedCorrectionIDs.contains(correction.id)
                && !setOutbox.pending.contains(where: { $0.id == correction.setID })
        }) { return true }
        return terminalOutbox.intents.contains { intent in
            guard ownedTerminalIntentIDs.contains(intent.id),
                  intent.deliveryState == .queued
            else { return false }
            if intent.action == .discard { return true }
            return !setOutbox.pending.contains { $0.date == intent.date }
                && !setCorrections.contains { $0.date == intent.date }
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
            SetCorrectionOutboxStore.remove(date: date, userID: accountID, defaults: defaults)
            setCorrections.removeAll { $0.date == date }
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
        if await performSetCorrectionDrain() { return true }
        supersedeSetIntentsForDiscardBarriers()

        guard canInitiateBoundFeatureAction else { return true }

        guard let terminal = terminalOutbox.intents.first(where: { intent in
            guard ownedTerminalIntentIDs.contains(intent.id),
                  intent.deliveryState == .queued
            else { return false }
            if intent.action == .discard { return true }
            return !setOutbox.pending.contains { $0.date == intent.date }
                && !setCorrections.contains { $0.date == intent.date }
        }) else { return false }
        return await sendPersistedTerminalIntent(terminal)
    }

    /// Returns true only when another immediate pass would repeat a transient
    /// failure (or would cross an account boundary). A normal empty-queue exit
    /// returns false so the owner can coalesce work that arrived during its
    /// reconciliation await.
    private func performSetOutboxDrain() async -> Bool {
        var acknowledgements: [(
            setID: String,
            baselineProvedAcknowledgement: Bool
        )] = []
        var preferredSessionID: String?
        var stoppedForRetryableFailure = false

        while canInitiateBoundFeatureAction,
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
            case let .acknowledged(
                setID,
                canonicalSessionID,
                date,
                baselineProvedAcknowledgement):
                acknowledgements.append((
                    setID: setID,
                    baselineProvedAcknowledgement:
                        baselineProvedAcknowledgement))
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

        guard !acknowledgements.isEmpty,
              canMutateBoundSetAccount,
              let jwt = currentJWT
        else { return stoppedForRetryableFailure }
        guard let snapshotTicket = StateSnapshotStore.reserveStateRequest(
            userID: accountID, defaults: defaults)
        else {
            loadError = "Couldn't reserve local reconciliation state."
            return true
        }
        do {
            let state = try await setWriteAPI.getState(
                jwt: jwt,
                watermarks: snapshotTicket.watermarks)
            guard canMutateBoundSetAccount else { return true }
            guard StateSnapshotStore.isCurrent(
                snapshotTicket, defaults: defaults)
            else {
                return stoppedForRetryableFailure
            }
            let returnedIDs = Set(state.sets.map(\.id))
            let incrementalSetPull = snapshotTicket.watermarks.setsSince > 0
            let missingAcknowledgedIDs = Set(
                acknowledgements.compactMap { acknowledgement in
                    let baselineAlreadyProvesSet = incrementalSetPull
                        && acknowledgement.baselineProvedAcknowledgement
                    return !baselineAlreadyProvesSet
                            && !returnedIDs.contains(acknowledgement.setID)
                        ? acknowledgement.setID
                        : nil
                })
            guard missingAcknowledgedIDs.isEmpty else {
                // The successful POST is the mutation boundary. An incomplete
                // delta cannot revoke that acknowledged result or invite a
                // duplicate retry; retain every ACK merge and clear only the
                // cursors so the next pull is an explicit full reload.
                _ = StateSnapshotStore.requireFullReload(
                    userID: accountID, defaults: defaults)
                loadError = acknowledgements.count == 1
                    ? "Set was saved, but the latest sync response was incomplete. A full refresh will reconcile it."
                    : "Sets were saved, but the latest sync response was incomplete. A full refresh will reconcile them."
                return stoppedForRetryableFailure
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
            // reflected locally. A later delta (or safety full reload) will
            // reconcile the cache.
            handle(error, jwt: jwt)
        }
        return stoppedForRetryableFailure
    }

    /// Returns true only for a retryable/account-boundary stop. Permanent 4xx
    /// failures remain visible but do not block recovery work for other dates.
    private func sendPersistedTerminalIntent(
        _ original: WorkoutTerminalIntent
    ) async -> Bool {
        guard canInitiateBoundFeatureAction, currentJWT != nil else { return true }
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
                    workoutID: intent.workoutID,
                    expectedAttempt: intent.expectedAttempt ?? 0,
                    restartDiscardedAttempt: intent.restartDiscardedAttempt,
                    jwt: jwt)
            } catch {
                // Match set recovery: update_plan can invalidate the optional
                // day UUID while this terminal choice is offline. Retry the
                // existing date-level endpoint without that stale association.
                guard intent.workoutID != nil,
                      isPermanentSetClientError(error),
                      canInitiateBoundFeatureAction,
                      let fallbackJWT = currentJWT
                else {
                    return classifyTerminalIntentFailure(
                        original, error: error, attemptedJWT: jwt)
                }
                do {
                    session = try await setWriteAPI.createSession(
                        date: intent.date,
                        workoutID: nil,
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
        guard canInitiateBoundFeatureAction,
              let durable = durableTerminalIntent(matching: intent)
        else {
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
                }), !setCorrections.contains(where: { $0.date == intent.date }) else { return false }
                response = try await terminalAPI.completeSession(
                    sessionId: sessionID,
                    expectedAttempt: intent.expectedAttempt,
                    feedback: intent.feedback,
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
                  intent.action != .finish || intent.feedback?.matches(response) != false,
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
                guard let persisted = persistTerminalAcknowledgement(
                    response, action: .finish)
                else {
                    loadError = "Workout finished on the server, but its local recovery snapshot couldn't be saved. It will retry safely."
                    return true
                }
                applyState(
                    persisted.state,
                    preferredTodaySessionID: persisted.state.sessions.first {
                        $0.date == response.date
                    }?.id,
                    isLiveResponse: false)
                terminalOutbox.remove(id: intent.id)
                persistRemovedTerminalIntent(id: intent.id)
                summaryRevision &+= 1
                if let summary = response.summary, summary.version == 1, summary.final,
                   summary.session_id == response.id, summary.attempt == (response.attempt ?? 0) {
                    completionSummaries[response.id] = summary
                    completionSummaryRevisions[response.id] = summaryRevision
                }
                if applied, intent.date == todayString {
                    stopRunnerAfterTerminalAck()
                }
            case .discard:
                summaryRevision &+= 1
                applyTerminalAcknowledgementLocally(response, action: .discard)
                applyLocalDiscardMask()
                guard let persisted = persistTerminalAcknowledgement(
                    response, action: .discard)
                else {
                    loadError = "Workout was discarded on the server, but its local recovery snapshot couldn't be saved. It will retry safely."
                    return true
                }
                applyState(
                    persisted.state,
                    preferredTodaySessionID: nil,
                    isLiveResponse: false)
                applyLocalDiscardMask()
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
        if let apiError = error as? APIError, apiError.httpStatus == 409,
           let data = apiError.httpBody?.data(using: .utf8),
           let conflict = try? JSONDecoder().decode(SessionWriteConflictPayload.self, from: data),
           conflict.error == "session_feedback_conflict", current.action == .finish,
           conflict.current_session.date == current.date,
           conflict.current_session.attempt == current.expectedAttempt {
            // The authenticated Worker can resolve the submitted alias to
            // its canonical session. Date and attempt bind the same workout.
            current.resolvedSessionID = conflict.current_session.id
            current.deliveryState = .failed
            current.failedHTTPStatus = 409
            current.feedbackConflict = WorkoutFeedbackBaseline(notes: conflict.current_session.notes,
                perceivedFatigue: conflict.current_session.perceived_fatigue)
            terminalOutbox.replace(current)
            persistReplacedTerminalIntent(current)
            adoptSessionWriteConflict(conflict.current_session)
            loadError = "Feedback changed elsewhere. Review both versions before finishing."
            return false
        }
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
           let code = (error as? APIError)?.httpStatus {
            current.deliveryState = .failed
            current.failedHTTPStatus = code
            terminalOutbox.replace(current)
            persistReplacedTerminalIntent(current)
            loadError = "Workout \(current.action == .finish ? "finish" : "discard") wasn't saved because the server rejected it (HTTP \(code))."
            return false
        }
        recordRetryAfter(from: error)
        handle(error, jwt: attemptedJWT)
        if (error as? APIError)?.httpStatus == 401,
           let latestJWT = currentJWT,
           latestJWT != attemptedJWT {
            return false
        }
        return true
    }

    private func sendPersistedSetIntent(_ original: PendingSetIntent) async -> SetSendOutcome {
        guard canInitiateBoundFeatureAction, currentJWT != nil else {
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
                    workout_id: intent.workoutID)
        } else {
            guard let jwt = currentJWT else { return .staleAccount }
            let createdSession: SessionRow
            do {
                createdSession = try await setWriteAPI.createSession(
                    date: intent.date,
                    workoutID: intent.workoutID,
                    expectedAttempt: intent.expectedAttempt ?? 0,
                    restartDiscardedAttempt: intent.restartDiscardedAttempt,
                    jwt: jwt)
            } catch {
                // update_plan may rebuild every day UUID while this offline
                // intent is unresolved. A rejected persisted association must
                // not poison the FIFO forever: clear only that stale optional
                // FK, persist before the fallback await, and let the date's
                // canonical session preserve the set itself.
                guard intent.workoutID != nil,
                      isPermanentSetClientError(error),
                      canInitiateBoundFeatureAction,
                      currentJWT != nil,
                      durableSetIntent(matching: intent) != nil
                else {
                    return classifySetIntentFailure(
                        intentID: intent.id,
                        error: error,
                        attemptedJWT: jwt)
                }
                intent.workoutID = nil
                guard persistReplacedSetIntent(intent),
                      canInitiateBoundFeatureAction,
                      let fallbackJWT = currentJWT else { return .staleAccount }
                setOutbox.replace(intent)
                do {
                    createdSession = try await setWriteAPI.createSession(
                        date: intent.date,
                        workoutID: nil,
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
            guard canInitiateBoundFeatureAction else { return .staleAccount }
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
            guard persistReplacedSetIntent(intent) else { return .staleAccount }
            setOutbox.replace(intent)
            guard let durable = durableSetIntent(matching: intent) else {
                return .superseded
            }
            intent = durable
        }

        // Creation and fallback creation are awaits. Confirm that the exact
        // durable set still exists and no discard barrier has superseded it
        // immediately before logging. If another model already resolved the
        // session, adopt that canonical id as well.
        guard canInitiateBoundFeatureAction,
              let durable = durableSetIntent(matching: intent)
        else {
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
                    workout_id: intent.workoutID)
        } else {
            return .superseded
        }

        // Queues written by an older app build may already have a resolved
        // session id but no generation. Migration 0032 assigns them attempt
        // zero; binding to a currently-observed later attempt would retarget
        // stale work across another device's discard/restart.
        if intent.expectedAttempt == nil {
            intent.expectedAttempt = 0
            guard persistReplacedSetIntent(intent) else { return .staleAccount }
            setOutbox.replace(intent)
            guard let rebound = durableSetIntent(matching: intent) else {
                return .superseded
            }
            intent = rebound
        }

        bindRunnerCheckpoint(to: writeSession)

        // The original body was persisted before session creation, and the
        // resolved session id is persisted above before this POST await.
        guard canInitiateBoundFeatureAction,
              let jwt = currentJWT
        else { return .staleAccount }
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
                    date: intent.date,
                    baselineProvedAcknowledgement: true)
            }
            let baselineRow = StateSnapshotStore.load(
                    userID: accountID,
                    defaults: defaults
                )?.state.sets.first { $0.id == result.set.id }
            let baselineProvedAcknowledgement: Bool
            if let baselineVersion = baselineRow?.updated_at,
               let responseVersion = result.set.updated_at
            {
                // A baseline at least as new as the POST body already proves
                // this UUID even when an incremental overlap legitimately
                // omits it. A newer correction/delete must still appear.
                baselineProvedAcknowledgement =
                    baselineVersion >= responseVersion
            } else {
                baselineProvedAcknowledgement = false
            }
            summaryRevision &+= 1
            applySetAcknowledgement(
                result,
                intent: intent,
                submittedSession: writeSession)
            guard let persisted = persistSetAcknowledgement(
                result, submittedSession: writeSession)
            else {
                loadError = "Set was saved on the server, but its local recovery snapshot couldn't be saved. It will retry safely."
                return .transientFailure(
                    attemptedJWT: jwt, wasUnauthorized: false)
            }
            // The shared snapshot may contain a newer tombstone/correction than
            // this delayed POST body. Re-adopt its ordered result before the
            // durable intent is retired so stale live data is never published.
            applyState(
                persisted.state,
                preferredTodaySessionID: result.set.session_id,
                isLiveResponse: false)
            setOutbox.remove(id: intent.id)
            persistRemovedSetIntentIDs(Set([intent.id]))
            normalizeMountedRunnerProgress(for: intent.date)
            return .acknowledged(
                setID: result.set.id,
                canonicalSessionID: result.set.session_id,
                date: intent.date,
                baselineProvedAcknowledgement:
                    baselineProvedAcknowledgement)
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
           let code = (error as? APIError)?.httpStatus {
            if var intent = setOutbox.pending.first(where: { $0.id == intentID }) {
                intent.deliveryState = .failed
                intent.failedHTTPStatus = code
                guard persistReplacedSetIntent(intent) else { return .staleAccount }
                setOutbox.replace(intent)
                reopenMountedRunner(for: intent)
            }
            loadError = "Set wasn't saved because the server rejected it (HTTP \(code))."
            return .permanentFailure
        }
        recordRetryAfter(from: error)
        handle(error, jwt: attemptedJWT)
        let unauthorized = (error as? APIError)?.httpStatus == 401
        return .transientFailure(
            attemptedJWT: attemptedJWT,
            wasUnauthorized: unauthorized)
    }

    private func isPermanentSetClientError(_ error: Error) -> Bool {
        guard let code = (error as? APIError)?.httpStatus else { return false }
        return (400..<500).contains(code) && ![401, 408, 429].contains(code)
    }

    private func retryDelayNanoseconds(seconds: TimeInterval) -> UInt64 {
        let bounded = min(
            max(seconds, 0), Self.maximumRetryAfterSeconds)
        return UInt64((bounded * 1_000_000_000).rounded(.up))
    }

    private func retryAfterDelay(
        from error: Error
    ) -> (seconds: TimeInterval, nanoseconds: UInt64)? {
        guard let seconds = (error as? APIError)?.retryAfter,
              seconds.isFinite,
              seconds >= 0
        else { return nil }
        let bounded = min(seconds, Self.maximumRetryAfterSeconds)
        return (bounded, retryDelayNanoseconds(seconds: bounded))
    }

    private func recordRetryAfter(from error: Error) {
        guard let retryAfter = retryAfterDelay(from: error) else {
            workoutWriteRetryMinimumDelayNanoseconds = nil
            workoutWriteRetryNotBefore = nil
            return
        }
        workoutWriteRetryMinimumDelayNanoseconds = retryAfter.nanoseconds
        let proposed = now().addingTimeInterval(retryAfter.seconds)
        workoutWriteRetryNotBefore = WorkoutWriteRetryDeadlineStore.extend(
            to: proposed, userID: accountID, defaults: defaults)
    }

    private func sessionWriteConflict(
        from error: Error
    ) -> SessionWriteConflictPayload? {
        guard let apiError = error as? APIError,
              apiError.httpStatus == 409,
              let body = apiError.httpBody,
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
            // A later committed state owns the session fields. The set itself
            // is still an accepted immutable fact unless that newer state is
            // a discard, handled above.
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
    private func normalizeMountedRunnerProgress(
        for date: String,
        reseedCurrent: Bool = false,
        forceGroupSelection: Bool = false,
        preservingFocusIn groups: Set<String> = []
    ) {
        if running {
            preflightMountedRunnerOwnership(
                checkpointBeforeState: persistedRunnerCheckpoint)
        }
        guard running, date == todayString, !exercises.isEmpty else { return }
        defer { rememberGroupProgress() }
        // An ACK may remove a previous set while another physical hold is in
        // progress. Its selection repair waits for that hold's local commit.
        if timedActive && !reseedCurrent { return }
        let group = currentExercise.flatMap { groupProgress(for: $0) }
        let groupChanged = group.map { !groups.contains($0.id) && observedGroupProgress[$0.id] != $0 } ?? false
        var groupSelectionChanged = false
        if let group, forceGroupSelection || groupChanged,
           let nextID = group.nextMemberID,
           let next = exercises.firstIndex(where: { $0.id == nextID }), next != exerciseIndex {
            exerciseIndex = next
            groupSelectionChanged = true
        }
        let unresolved = exercises.indices.filter {
            !isRunnerResolved(exercises[$0])
        }
        guard !unresolved.isEmpty else {
            if !finished {
                finished = true
                runnerFocus.isExplicit = false
                persistRunnerCheckpoint()
            }
            updateRestActivityAfterRunnerNormalization()
            return
        }

        let wasFinished = finished
        var selectionChanged = groupSelectionChanged
        if !unresolved.contains(exerciseIndex), group == nil || groupChanged || forceGroupSelection {
            let n = exercises.count
            let next = (1...n)
                .map { (exerciseIndex + $0) % n }
                .first(where: unresolved.contains) ?? unresolved[0]
            exerciseIndex = next
            if let nextGroup = currentExercise.flatMap({ groupProgress(for: $0) }),
               let memberID = nextGroup.nextMemberID,
               let memberIndex = exercises.firstIndex(where: { $0.id == memberID }) {
                exerciseIndex = memberIndex
            }
            selectionChanged = true
        }
        finished = false
        // Reopening a finished workout is bookkeeping, not a new selection.
        // This also covers a cold ACK absorbed before its next live read.
        if selectionChanged { runnerFocus.isExplicit = false }
        if reseedCurrent || selectionChanged || wasFinished {
            seedInputs()
        }
        if reseedCurrent || selectionChanged || wasFinished {
            persistRunnerCheckpoint()
        }
        updateRestActivityAfterRunnerNormalization()
    }

    private func currentExerciseMatchesRenderedAction(
        _ expected: TemplateExercise,
        current: TemplateExercise
    ) -> Bool {
        RunnerPrescription(expected) == RunnerPrescription(current)
            && expected.group_id == current.group_id
            && expected.group_rest_seconds == current.group_rest_seconds
            && expected.group_transition_seconds == current.group_transition_seconds
            && (expected.group_id == nil || expected.target_sets == current.target_sets)
    }

    // MARK: runner

    var exercises: [TemplateExercise] { selectedDay?.exercises ?? [] }
    var currentExercise: TemplateExercise? {
        exercises.indices.contains(exerciseIndex) ? exercises[exerciseIndex] : nil
    }
    /// 1-based number of the set about to be performed for the current exercise.
    var currentSetNumber: Int {
        guard let ex = currentExercise else { return 1 }
        return groupProgress(for: ex)?.round ?? (runnerSetsDone(ex) + 1)
    }

    /// Tap identity stays slot-specific even when manual navigation selects a
    /// member ahead of the group's displayed round.
    var currentPhysicalSetNumber: Int {
        currentExercise.map { nextReservedSetIndex(for: $0) } ?? 1
    }

    /// Stable write index for the next physical set. Failed intents remain in
    /// the outbox and keep reserving their original index even though the
    /// presentation count reopens them for retry.
    private func nextReservedSetIndex(for ex: TemplateExercise) -> Int {
        todaySlotSets(ex).count + pendingSetIntents(for: ex).count + 1
    }

    /// Runner progress counts every locally durable set exactly once. Pending
    /// rows share their eventual server id, so the set union avoids a transient
    /// double count while an acknowledgement is being folded into the cache.
    private func runnerSetIDs(_ ex: TemplateExercise) -> Set<String> {
        Set(todaySlotSets(ex).map(\.id))
            .union(pendingSetIntents(for: ex).lazy.filter {
                $0.deliveryState == .queued
            }.map(\.id))
    }

    func runnerSetsDone(_ ex: TemplateExercise) -> Int { runnerSetIDs(ex).count }

    private func reservedSetIDs(for ex: TemplateExercise) -> Set<String> {
        Set(todaySlotSets(ex).map(\.id)).union(pendingSetIntents(for: ex).map(\.id))
    }

    private func groupProgress(for ex: TemplateExercise) -> GroupRunnerProgress? {
        guard let id = ex.group_id else { return nil }
        return GroupRunnerProgress(id: id, members: exercises.filter { $0.group_id == id }.map {
            .init(id: $0.id, target: $0.target_sets, completedIDs: runnerSetIDs($0), skipped: skipped.contains($0.id))
        })
    }

    private func groupContext(for ex: TemplateExercise) -> RunnerGroupContext? {
        guard let id = ex.group_id else { return nil }
        return RunnerGroupContext(id: id, memberIDs: exercises.filter { $0.group_id == id }.map(\.id),
            rounds: ex.target_sets, roundRest: ex.group_rest_seconds, transitionRest: ex.group_transition_seconds)
    }

    private func rememberGroupProgress() {
        observedGroupProgress = [:]
        for ex in exercises where ex.group_id != nil {
            if let progress = groupProgress(for: ex) { observedGroupProgress[progress.id] = progress }
        }
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
        if current.group_id != nil {
            normalizeMountedRunnerProgress(for: date, forceGroupSelection: true)
            return
        }
        if isRunnerComplete(current) {
            if let next = nextRunnerIncompleteIndex {
                selectRunnerExercise(at: next)
            } else {
                finished = true
                persistRunnerCheckpoint()
            }
        }
        if currentExercise?.group_id != nil {
            normalizeMountedRunnerProgress(for: date, forceGroupSelection: true)
        }
        updateRestActivityAfterRunnerNormalization()
    }

    /// Correction causality survives enqueue, ACK/live-read reordering, and
    /// cold recovery. A later manual choice owns focus until a physical commit
    /// or skip; a new correction initiated after that choice remains eligible.
    private func supersededDeletionGroupID(_ intent: PendingSetCorrection) -> String? {
        guard intent.isDelete, runnerFocus.isExplicit,
              (intent.runnerFocusRevision ?? 0) < runnerFocus.revision,
              let checkpoint = persistedRunnerCheckpoint,
              intent.date == checkpoint.date, intent.date == todayString,
              intent.expectedAttempt == (todaySession?.attempt ?? checkpoint.sessionAttempt ?? 0),
              let day = plan?.workouts.first(where: { $0.id == checkpoint.selectedDayID }),
              let slot = day.exercises.first(where: { $0.id == intent.slotID && $0.exercise_id == intent.exerciseID })
        else { return nil }
        return slot.group_id
    }

    private func absorbSupersededDeletion(_ intent: PendingSetCorrection) -> Bool {
        if running {
            rememberGroupProgress()
            return persistRunnerCheckpoint()
        }
        // A cold ACK must update the observed UUIDs without certifying a live
        // resume. Otherwise the next live validation would replay this change.
        guard let checkpoint = persistedRunnerCheckpoint,
              let progress = checkpoint.groupProgress else { return true }
        let updated = GroupRunnerProgress(id: progress.id, members: progress.members.map {
            .init(id: $0.id, target: $0.target, completedIDs: $0.completedIDs.subtracting([intent.setID]), skipped: $0.skipped)
        })
        return persistRunnerObservation(updated)
    }

    @discardableResult
    private func persistRunnerObservation(_ progress: GroupRunnerProgress?, selecting slotID: String? = nil) -> Bool {
        guard let checkpoint = persistedRunnerCheckpoint else { return true }
        let replacement = WorkoutRunnerCheckpoint(date: checkpoint.date, sessionID: checkpoint.sessionID,
            selectedDayID: checkpoint.selectedDayID, currentSlotID: slotID ?? checkpoint.currentSlotID,
            skippedSlotIDs: checkpoint.skippedSlotIDs, workoutStartedAtMS: checkpoint.workoutStartedAtMS,
            finished: slotID == nil ? checkpoint.finished : false, sessionAttempt: checkpoint.sessionAttempt,
            restartDiscardedAttempt: checkpoint.restartDiscardedAttempt,
            input: checkpoint.input, inputsBySlot: checkpoint.inputsBySlot, groupProgress: progress, focus: runnerFocus, deferredGroupRepair: deferredGroupRepair, feedback: checkpoint.feedback)
        guard replaceRunnerCheckpoint(replacement, ifCurrent: checkpoint) else { return false }
        persistedRunnerCheckpoint = replacement
        if resumableCheckpoint == checkpoint { resumableCheckpoint = replacement }
        return true
    }

    private func groupDeletionObservation(_ intent: PendingSetCorrection) -> String? {
        observedGroupRepair(for: intent)?.groupID
    }

    private func observedGroupRepair(for intent: PendingSetCorrection) -> RunnerGroupRepair? {
        guard intent.isDelete, let checkpoint = persistedRunnerCheckpoint,
              checkpoint.date == intent.date, intent.date == todayString,
              intent.expectedAttempt == (todaySession?.attempt ?? checkpoint.sessionAttempt ?? 0),
              let day = plan?.workouts.first(where: { $0.id == checkpoint.selectedDayID }),
              let sessionID = todaySession?.id ?? checkpoint.sessionID,
              let slot = day.exercises.first(where: { $0.id == intent.slotID && $0.exercise_id == intent.exerciseID }),
              let id = slot.group_id,
              let repair = RunnerGroupRepair(groupID: id, day: day),
              intent.runnerGroupRepair == nil || intent.runnerGroupRepair == repair,
              intent.runnerGroupRepair == repair
                || slotSets(slot, sessionID: sessionID, dayExercises: day.exercises).contains(where: { $0.id == intent.setID })
                || setOutbox.pending.contains(where: { $0.id == intent.setID && $0.deliveryState == .queued
                    && setIntent($0, matches: slot, on: intent.date) })
        else { return nil }
        return repair
    }

    /// Backfill older durable intents before any snapshot can erase their
    /// counted UUID. The immutable evidence lets a new owner finish recovery.
    private func retainGroupDeletionObservations() {
        for var intent in setCorrections where intent.runnerGroupRepair == nil {
            guard let repair = observedGroupRepair(for: intent) else { continue }
            intent.runnerGroupRepair = repair
            SetCorrectionOutboxStore.replace(intent, userID: accountID, defaults: defaults)
        }
        adoptDurableWorkoutWriteOutboxes()
    }

    @discardableResult
    private func repairGroupAfterDeletedSet(_ intent: PendingSetCorrection, observedGroupID: String? = nil) -> Bool {
        if intent.runnerGroupRepair != nil {
            // A missing local plan/checkpoint is not evidence that a prepared
            // repair became obsolete. An invalidated cache or retired model
            // must leave this receipt for live validation/the current owner.
            let durable = WorkoutRunnerCheckpointStore.load(userID: accountID, defaults: defaults)
            guard durable != nil else { return true }
            guard persistedRunnerCheckpoint == durable, plan != nil else { return false }
        }
        guard supersededDeletionGroupID(intent) == nil,
              intent.date == todayString,
              let checkpoint = persistedRunnerCheckpoint, checkpoint.date == intent.date,
              let sessionID = intent.sessionID,
              sessionID == (todaySession?.id ?? checkpoint.sessionID),
              checkpoint.sessionID == nil || checkpoint.sessionID == sessionID,
              intent.expectedAttempt == (todaySession?.attempt ?? checkpoint.sessionAttempt ?? 0),
              let day = plan?.workouts.first(where: { $0.id == checkpoint.selectedDayID }),
              let slot = day.exercises.first(where: { $0.id == intent.slotID && $0.exercise_id == intent.exerciseID }),
              let id = slot.group_id,
              intent.runnerGroupRepair == nil || intent.runnerGroupRepair == RunnerGroupRepair(groupID: id, day: day),
              observedGroupID == id || observedGroupProgress[id]?.members.contains(where: { $0.completedIDs.contains(intent.setID) }) == true,
              !sets.contains(where: { $0.id == intent.setID && $0.deleted_at == nil })
        else { return true }
        guard canInitiateBoundFeatureAction, !runnerArtifactsOwnedByOther else { return false }
        runnerFocus.isExplicit = false
        if !running {
            // The deletion was initiated after the latest explicit choice.
            // Its group owns recovery even if that choice was in another group
            // or an ordinary slot. Persist the cursor without certifying resume;
            // the existing live validator still owns date/attempt/status proof.
            let progress = GroupRunnerProgress(id: id, members: day.exercises.filter { $0.group_id == id }.map { member in
                let completedIDs = Set(slotSets(member, sessionID: sessionID, dayExercises: day.exercises).map(\.id))
                    .union(setOutbox.pending.filter {
                        $0.deliveryState == .queued && setIntent($0, matches: member, on: intent.date)
                    }.map(\.id))
                return .init(id: member.id, target: member.target_sets, completedIDs: completedIDs,
                             skipped: checkpoint.skippedSlotIDs.contains(member.id))
            })
            if let nextID = progress.nextMemberID {
                deferredGroupRepair = nil
                return persistRunnerObservation(progress, selecting: nextID)
            } else {
                return persistRunnerObservation(checkpoint.groupProgress)
            }
        }
        deferredGroupRepair = RunnerGroupRepair(groupID: id, day: day)
        guard persistRunnerCheckpoint() else { return false }
        repairDeferredGroupSelection()
        return true
    }

    private func repairDeferredGroupSelection() {
        guard running, !timedActive, let repair = deferredGroupRepair else { return }
        deferredGroupRepair = nil
        defer { persistRunnerCheckpoint() }
        guard let day = selectedDay, RunnerGroupRepair(groupID: repair.groupID, day: day) == repair,
              let slot = exercises.first(where: { $0.group_id == repair.groupID }),
              let progress = groupProgress(for: slot), let nextID = progress.nextMemberID,
              let next = exercises.firstIndex(where: { $0.id == nextID })
        else { return }
        finished = false
        if exerciseIndex != next { exerciseIndex = next; seedInputs() }
        rememberGroupProgress()
        persistRunnerCheckpoint()
        updateRestActivityAfterRunnerNormalization()
    }

    private func reopenFailedRunnerIntentIfStable(for date: String) {
        guard !timedActive,
              let failed = setOutbox.pending.first(where: { intent in
                  intent.date == date
                      && intent.deliveryState == .failed
                      && exercises.contains(where: {
                          setIntent(intent, matches: $0, on: date)
                      })
              })
        else { return }
        reopenMountedRunner(for: failed)
    }

    private func reopenMountedRunner(for failedIntent: PendingSetIntent) {
        guard running, failedIntent.date == todayString,
              let index = exercises.firstIndex(where: {
                  setIntent(failedIntent, matches: $0, on: todayString)
              }) else { return }
        // A delayed rejection must not abort a later physical timed set. The
        // failed intent stays durable and visible; commitTimedSet reopens it as
        // soon as that in-progress timer reaches its stable commit boundary.
        guard !timedActive else { return }
        finished = false
        if exerciseIndex != index { runnerFocus.isExplicit = false }
        exerciseIndex = index
        seedInputs()
        weight = failedIntent.body.weight
        reps = failedIntent.body.reps
        rpe = failedIntent.body.rpe
        rememberGroupProgress()
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
        guard canInitiateBoundFeatureAction,
              let checkpoint = persistedRunnerCheckpoint,
              WorkoutRunnerCheckpointStore.load(
                  userID: accountID, defaults: defaults) == checkpoint,
              RunnerArtifactOwnership.isOwned(
                  by: runnerArtifactOwnerID,
                  featureSessionEpoch: featureSessionEpoch,
                  userID: accountID,
                  defaults: defaults)
        else {
            relinquishStaleRunnerCheckpoint()
            return
        }
        restActivityUpdater(end, restActivityCurrentStepName)
    }

    private func allowNewWorkoutStart() -> Bool {
        guard !isRoutineMutationInFlight else {
            loadError = "Wait for the routine change to finish before starting your workout."
            return false
        }
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
        guard canInitiateBoundFeatureAction, currentJWT != nil else { return }
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
        guard clearRunnerCheckpointAndSharedRest() else {
            loadError = "This workout is already active in another app view. Refresh to continue."
            return
        }
        runnerRestartDiscardedAttempt = restartDiscardedAttempt
        workoutFeedback = nil
        runnerFocus = RunnerFocusState()
        deferredGroupRepair = nil
        running = true
        finished = false
        exerciseIndex = 0
        skipped = []
        workoutStart = now()
        seedInputs()
        persistRunnerCheckpoint()
        if currentExercise?.group_id != nil {
            normalizeMountedRunnerProgress(for: todayString, forceGroupSelection: true)
        } else { rememberGroupProgress() }
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
        guard canInitiateBoundFeatureAction, currentJWT != nil else { return }
        let candidate = resumableCheckpoint.flatMap { checkpoint in
            sessions.first { $0.date == checkpoint.date }
        }
        guard !running,
              let checkpoint = resumableCheckpoint,
              (candidate?.id == checkpoint.sessionID && candidate?.status == "in_progress")
                || canResumeUnstartedFeedback(checkpoint, session: candidate),
              let day = plan?.workouts.first(where: {
                  $0.id == checkpoint.selectedDayID
              }),
              let currentSlotID = checkpoint.currentSlotID,
              let index = day.exercises.firstIndex(where: {
                  $0.id == currentSlotID
              })
        else {
            _ = clearRunnerCheckpointAndSharedRest()
            return
        }

        let liveSlotIDs = Set(day.exercises.map(\.id))
        todaySession = candidate?.status == "discarded" ? nil : candidate
        runnerRestartDiscardedAttempt = checkpoint.restartDiscardedAttempt
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
        workoutFeedback = checkpoint.feedback
        runnerFocus = checkpoint.focus ?? RunnerFocusState()
        deferredGroupRepair = checkpoint.deferredGroupRepair
        seedInputs()
        rememberGroupProgress()
        // Resume is the explicit same-epoch ownership handoff. A second model
        // may have loaded the exact same checkpoint value, so claim before the
        // value-based persistence CAS can otherwise look like an ABA success.
        RunnerArtifactOwnership.claim(
            runnerArtifactOwnerID,
            featureSessionEpoch: featureSessionEpoch,
            userID: accountID,
            defaults: defaults)
        persistRunnerCheckpoint()
        guard running,
              RunnerArtifactOwnership.isOwned(
                  by: runnerArtifactOwnerID,
                  featureSessionEpoch: featureSessionEpoch,
                  userID: accountID,
                  defaults: defaults)
        else { return }
        skipRest()
    }

    /// Keep only drafts for the same slot and current prescription. This map
    /// inherits the checkpoint's account, date, session, attempt and CAS fence.
    private func runnerInputsForCheckpoint() -> [String: RunnerInputState] {
        var inputs = persistedRunnerCheckpoint?.inputsBySlot ?? [:]
        if let legacy = persistedRunnerCheckpoint?.input {
            inputs[legacy.prescription.slotID] = legacy
        }
        inputs = inputs.filter { id, input in
            exercises.contains { $0.id == id && input.prescription.matches(current: RunnerPrescription($0)) }
        }
        if let currentInputState { inputs[currentInputState.prescription.slotID] = currentInputState }
        return inputs
    }

    var currentInputState: RunnerInputState? {
        guard let ex = currentExercise else { return nil }
        return RunnerInputState(prescription: RunnerPrescription(ex), weight: weight,
                                reps: reps, rpe: rpe, durationSeconds: holdDurationSeconds)
    }

    func comparablePreviousSets(for ex: TemplateExercise) -> [SetLog] {
        let history = RunnerInputPolicy.comparableSets(ex, sets: sets, sessions: sessions,
            currentSessionID: todaySession?.id, dayExercises: exercises, dayID: selectedDayID)
        guard let lastSessionID = history.last?.session_id else { return [] }
        return history.filter { $0.session_id == lastSessionID }
    }

    private func seedInputs() {
        clearTimedSet()
        guard let ex = currentExercise else { return }
        let input = RunnerInputPolicy.seed(ex,
            previous: comparablePreviousSets(for: ex).last,
            draft: persistedRunnerCheckpoint?.inputsBySlot?[ex.id] ?? persistedRunnerCheckpoint?.input)
        weight = input.weight
        reps = input.reps
        rpe = input.rpe
        holdDurationSeconds = input.durationSeconds
    }

    // MARK: timed exercises (plank, holds)

    func startTimedSet(
        expected renderedExercise: TemplateExercise,
        expectedSetNumber: Int,
        at start: Date? = nil
    ) {
        guard canInitiateBoundFeatureAction,
              currentJWT != nil,
              running,
              !finished,
              let ex = currentExercise,
              currentExerciseMatchesRenderedAction(renderedExercise, current: ex),
              currentPhysicalSetNumber == expectedSetNumber,
              ex.isTimed,
              !timedActive,
              !isRunnerComplete(ex),
              !isTerminalMutationInFlight,
              !hasPendingTerminalIntentForCurrentWorkout,
              !isSetEntryBlocked(ex)
        else { return }
        if restEndDate != nil { skipRest() }
        skipped.remove(ex.id)
        timedControlID = UUID().uuidString
        registerTimerControls()
        timedActive = true
        let startedAt = start ?? now()
        let endDate = startedAt.addingTimeInterval(TimeInterval(holdDurationSeconds))
        timedStartDate = startedAt
        // Count down the prescribed hold (target_duration_s, fallback
        // target_reps) — not target_reps directly, which was 1s for slots
        // that never set a duration (the "plank ended instantly" bug).
        timedEndDate = endDate
        timedSetAttempt = TimedSetAttempt(
            featureSessionEpoch: featureSessionEpoch,
            slotID: ex.id,
            exerciseID: ex.exercise_id,
            setNumber: nextReservedSetIndex(for: ex),
            reservedSetIDs: reservedSetIDs(for: ex),
            groupContext: groupContext(for: ex),
            holdSeconds: holdDurationSeconds,
            prescribedHoldSeconds: ex.holdSeconds,
            rpe: rpe,
            weight: weight,
            isWarmup: ex.isWarmup,
            startedAt: startedAt,
            endDate: endDate)
        guard persistRunnerCheckpoint() else { return }
        RestLiveActivity.start(exercise: ex.exercise_name, endDate: endDate,
                               upNext: "\(holdDurationSeconds)s", timerKind: "set", controlID: timedControlID)
        timedCueGeneration = RestCue.scheduleTimedNotification(at: endDate)
        scheduleTimedSetCompletion()
    }

    /// Own completion in the model so navigation cannot cancel the set. iOS
    /// may suspend this task in the background; the foreground hook calls the
    /// same due-date check as a catch-up path.
    private func scheduleTimedSetCompletion() {
        timedSetCompletionTask?.cancel()
        guard let attempt = timedSetAttempt else { return }
        let delay = max(0, attempt.endDate.timeIntervalSince(now()))
        let maximumDelay = Double(UInt64.max / 1_000_000_000)
        let nanoseconds = UInt64(min(delay, maximumDelay) * 1_000_000_000)
        timedSetCompletionTask = Task { [weak self] in
            if nanoseconds > 0 {
                try? await Task.sleep(nanoseconds: nanoseconds)
            }
            guard !Task.isCancelled, let self else { return }
            guard self.timedSetAttempt == attempt else { return }
            // This task owns the expiry path now. Detach it from the model
            // before commit clears timer state so the network write does not
            // inherit a cancellation from cancelling itself.
            self.timedSetCompletionTask = nil
            await self.finishTimedSetIfDue(requiring: attempt)
        }
    }

    private func clearTimedSet(cancelCue: Bool = true) {
        if timedActive, canControlSharedRestArtifacts {
            if cancelCue { RestCue.cancelTimedNotification() }
            RestLiveActivity.endNow()
        }
        timedControlID = nil
        timedSetCompletionTask?.cancel()
        timedSetCompletionTask = nil
        timedActive = false
        timedEndDate = nil
        timedStartDate = nil
        timedSetAttempt = nil
    }

    /// Return the original hold only while every identity component still
    /// matches the rendered runner. Any mismatch invalidates the timer and
    /// clears it before it can enqueue a set.
    private func validatedTimedSetAttempt(
        requiring expected: TimedSetAttempt? = nil
    ) -> (attempt: TimedSetAttempt, exercise: TemplateExercise)? {
        guard timedActive,
              canInitiateBoundFeatureAction,
              currentJWT != nil,
              let attempt = timedSetAttempt,
              expected == nil || expected == attempt,
              attempt.featureSessionEpoch == featureSessionEpoch,
              auth.featureSessionEpoch == attempt.featureSessionEpoch,
              let ex = currentExercise,
              ex.id == attempt.slotID,
              ex.exercise_id == attempt.exerciseID,
              (ex.group_id == nil
                ? nextReservedSetIndex(for: ex) == attempt.setNumber
                : reservedSetIDs(for: ex).isSubset(of: attempt.reservedSetIDs)),
              groupContext(for: ex) == attempt.groupContext,
              ex.isTimed,
              !isRunnerComplete(ex),
              ex.holdSeconds == attempt.prescribedHoldSeconds,
              ex.isWarmup == attempt.isWarmup,
              timedStartDate == attempt.startedAt,
              timedEndDate == attempt.endDate
        else {
            clearTimedSet()
            return nil
        }
        return (attempt, ex)
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
        guard let validated = validatedTimedSetAttempt() else { return }
        await commitTimedSet(validated, held: validated.attempt.holdSeconds)
    }

    /// Complete only after the stored deadline. Called by both the model-owned
    /// task and foreground recovery after iOS resumes a suspended app.
    func finishTimedSetIfDue(at date: Date? = nil) async {
        guard let validated = validatedTimedSetAttempt(),
              (date ?? now()) >= validated.attempt.endDate
        else { return }
        await commitTimedSet(validated, held: validated.attempt.holdSeconds)
    }

    /// Model-owned completion additionally proves that the sleeping task still
    /// owns the attempt it captured before it detached itself from the model.
    private func finishTimedSetIfDue(requiring attempt: TimedSetAttempt) async {
        guard let validated = validatedTimedSetAttempt(requiring: attempt),
              now() >= validated.attempt.endDate
        else { return }
        await commitTimedSet(validated, held: validated.attempt.holdSeconds)
    }

    /// Manual STOP — logs the ACTUAL elapsed hold (capped at the prescribed
    /// target, which the auto-log would otherwise own). A reflexive tap in
    /// the first 2s — STOP sits where START just was — is NOT a real hold:
    /// it's ignored (the timer keeps running) so it can't log a junk "1s"
    /// set, the symptom in #55.
    func stopTimedSet() async {
        guard let validated = validatedTimedSetAttempt() else { return }
        let elapsed = timedElapsed
        guard elapsed >= 2 else { return }
        await commitTimedSet(
            validated, held: min(elapsed, validated.attempt.holdSeconds))
    }

    /// Single commit path for a timed set — logs reps=held, duration=held
    /// (≥1s) and advances. Both auto and manual completion route here.
    private func commitTimedSet(
        _ validated: (attempt: TimedSetAttempt, exercise: TemplateExercise),
        held: Int
    ) async {
        guard timedSetAttempt == validated.attempt, timedActive else { return }
        let cueGeneration = held >= validated.attempt.holdSeconds ? timedCueGeneration : nil
        let ex = validated.exercise
        clearTimedSet(cancelCue: cueGeneration == nil)
        skipped.remove(ex.id)   // logging work un-skips this slot
        persistRunnerCheckpoint()
        let secs = max(1, held)
        guard queueRunnerSet(
            ex,
            weight: validated.attempt.weight,
            reps: secs,
            durationOverride: secs, rpe: validated.attempt.rpe)
        else {
            persistRunnerCheckpoint()
            return
        }
        guard running, currentExercise != nil else { return }
        let date = todaySession?.date ?? todayString
        normalizeMountedRunnerAfterLocalCommit(for: date)
        reopenFailedRunnerIntentIfStable(for: date)
        repairDeferredGroupSelection()
        if let cueGeneration,
           let alreadyCued = await RestCue.finishTimedNotification(generation: cueGeneration),
           canInitiateBoundFeatureAction, !alreadyCued {
            RestCue.play(upNext: "", timedSet: true)
        }
    }

    func adjustWeight(_ delta: Double) { setWeight(weight + delta) }
    func setWeight(_ value: Double) {
        guard value.isFinite, !timedActive else { return }
        weight = currentExercise?.allowsAssistance == true ? value : max(0, value)
        persistRunnerCheckpoint()
    }
    func adjustReps(_ delta: Int) { setReps(reps + delta) }
    func setReps(_ value: Int) {
        reps = max(0, value)
        persistRunnerCheckpoint()
    }
    func setRPE(_ value: Double?) {
        guard value == nil || (value!.isFinite && (0...10).contains(value!)) else { return }
        rpe = value
        persistRunnerCheckpoint()
    }
    func setHoldDuration(_ seconds: Int) {
        guard !timedActive else { return }
        holdDurationSeconds = max(1, seconds)
        persistRunnerCheckpoint()
    }

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
            let slot = exercises[i]
            if slot.group_id == nil ? !isResolved(slot) : !isRunnerResolved(slot) { return i }
        }
        return nil
    }

    /// Final review may retain its cursor when a correction removes a set
    /// elsewhere. Resume unresolved work using durable runner progress, which
    /// includes queued sets and excludes skipped exercises.
    func reviewIncompleteExercises() {
        guard running, !hasPendingTerminalIntentForCurrentWorkout,
              !isTerminalMutationInFlight, let index = nextRunnerIncompleteIndex else { return }
        jump(to: index)
    }

    func jump(to index: Int) {
        guard exercises.indices.contains(index) else { return }
        // Returning from final review is an explicit runner selection too.
        // Persist the reopened state with the selected exercise below.
        finished = false
        // Explicit focus supersedes deferred repair and every older pending
        // deletion. A deletion initiated after this choice remains eligible.
        deferredGroupRepair = nil
        runnerFocus.revision &+= 1
        runnerFocus.isExplicit = true
        selectRunnerExercise(at: index)
    }

    /// Automatic advancement does not create a new explicit selection revision.
    private func selectRunnerExercise(at index: Int) {
        guard exercises.indices.contains(index) else { return }
        exerciseIndex = index
        seedInputs()
        rememberGroupProgress()
        persistRunnerCheckpoint()
    }

    func logCurrentSet(
        expected renderedExercise: TemplateExercise,
        expectedSetNumber: Int
    ) async {
        // A SwiftUI button action launches an unstructured Task. Bind that
        // work to the slot and set number visible at tap time so a queued
        // duplicate cannot run after the first tap advances the runner and
        // accidentally log the successor exercise.
        guard canInitiateBoundFeatureAction,
              running,
              !finished,
              let ex = currentExercise,
              currentExerciseMatchesRenderedAction(renderedExercise, current: ex),
              currentPhysicalSetNumber == expectedSetNumber,
              !isRunnerComplete(ex),
              !isSetEntryBlocked(ex)
        else { return }
        skipped.remove(ex.id)   // logging work un-skips this slot
        persistRunnerCheckpoint()
        guard queueRunnerSet(ex, weight: weight, reps: reps, rpe: rpe) else {
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
        // Skip is a terminal decision for the rendered hold even when there is
        // no next slot and `jump` therefore never calls `seedInputs`.
        clearTimedSet()
        runnerFocus.isExplicit = false
        let wasGrouped = currentExercise?.group_id != nil
        if let ex = currentExercise { skipped.insert(ex.id) }
        if wasGrouped {
            normalizeMountedRunnerProgress(for: todaySession?.date ?? todayString, forceGroupSelection: true)
        } else if let next = nextIncompleteIndex { selectRunnerExercise(at: next) } else { finished = true }
        repairDeferredGroupSelection()
        rememberGroupProgress()
        persistRunnerCheckpoint()
    }

    func previous() {
        guard exerciseIndex > 0 else { return }
        jump(to: exerciseIndex - 1)
    }

    /// Non-destructive forward navigation — move to the next exercise in order
    /// WITHOUT marking the current one skipped. Going "out of order" (stepping
    /// ahead to a later lift you'll come back to) must never strike out the
    /// ones you pass; only an explicit Skip does that (#3). Pairs with
    /// `previous()`; the jump strip still allows arbitrary jumps.
    func next() {
        guard exerciseIndex < exercises.count - 1 else { return }
        jump(to: exerciseIndex + 1)
    }

    var currentWorkoutFeedback: WorkoutFeedback? {
        if let workoutFeedback { return workoutFeedback }
        guard let session = todaySession else { return nil }
        let value = WorkoutFeedback(notes: session.notes, perceivedFatigue: session.perceived_fatigue)
        return value.isEmpty ? nil : value
    }

    /// Explicit save is local and synchronous, before the member finishes.
    /// The checkpoint CAS and editor baseline prevent a stale view from
    /// replacing a newer approved edit. Queued finish choices are immutable.
    @discardableResult
    func saveWorkoutFeedback(_ feedback: WorkoutFeedback,
                             expected target: WorkoutTerminalActionTarget,
                             previous: WorkoutFeedback?) -> Bool {
        guard (matchesTerminalActionTarget(target) || matchesFeedbackSessionBinding(target)), running,
              !hasPendingTerminalIntentForCurrentWorkout,
              currentWorkoutFeedback == previous,
              feedback.perceivedFatigue.map({ (1...10).contains($0) }) ?? true else { return false }
        let old = workoutFeedback
        var approved = feedback
        approved.expected = previous?.expected ?? WorkoutFeedbackBaseline(
            notes: todaySession?.notes, perceivedFatigue: todaySession?.perceived_fatigue)
        workoutFeedback = approved
        guard persistRunnerCheckpoint() else {
            workoutFeedback = old
            return false
        }
        return true
    }

    /// A first-set ACK may establish the session while this editor is open.
    /// Accept only that proven binding of the same checkpoint and attempt.
    private func matchesFeedbackSessionBinding(_ target: WorkoutTerminalActionTarget) -> Bool {
        guard canInitiateBoundFeatureAction, target.featureSessionEpoch == featureSessionEpoch,
              target.sessionID == nil, let original = target.nilBoundRunnerCheckpoint,
              original.sessionID == nil, let current = persistedRunnerCheckpoint,
              let session = todaySession, target.date == session.date,
              current.sessionID == session.id, current.date == original.date,
              current.workoutStartedAtMS == original.workoutStartedAtMS,
              current.selectedDayID == original.selectedDayID,
              session.attempt == (original.restartDiscardedAttempt.map { $0 + 1 } ?? 0),
              current.sessionAttempt == session.attempt,
              original.feedback == current.feedback else { return false }
        return true
    }

    func finishWorkout() async {
        guard canInitiateBoundFeatureAction, currentJWT != nil else { return }
        let date = todaySession?.date ?? todayString
        if terminalOutbox.intent(for: date) == nil {
            // A newer view can own a more recent approved edit. Refusing its
            // checkpoint must also refuse a new finish from this stale view.
            guard !runnerArtifactsOwnedByOther else { return }
            if running || workoutFeedback != nil {
                guard persistRunnerCheckpoint() else { return }
            }
            let intent = WorkoutTerminalIntent(
                id: uuidFactory().uuidString,
                action: .finish,
                date: date,
                workoutID: todaySession?.workout_id ?? selectedDay?.id,
                resolvedSessionID: todaySession?.id,
                deliveryState: .queued,
                failedHTTPStatus: nil,
                expectedAttempt: todaySession?.attempt,
                restartDiscardedAttempt: runnerRestartDiscardedAttempt,
                feedback: workoutFeedback)
            // The complete user choice is durable before the coordinator can
            // await set delivery, session resolution, or the terminal PATCH.
            terminalOutbox.enqueue(intent)
            guard persistEnqueuedTerminalIntent(intent) else {
                terminalOutbox = WorkoutTerminalOutboxStore.load(userID: accountID, defaults: defaults)
                loadError = "Couldn't save the finish request on your iPhone. Retry saved data, then finish again."
                return
            }
        }
        await drainWorkoutWriteOutboxes()
    }

    func finishWorkout(expected target: WorkoutTerminalActionTarget) async {
        guard matchesTerminalActionTarget(target) || matchesFeedbackSessionBinding(target) else { return }
        await finishWorkout()
    }

    /// FinishedView is rendered only after every slot resolves, but a live
    /// refresh may reopen work before SwiftUI removes that view. Revalidate
    /// the completion state at action time; the overflow menu intentionally
    /// keeps `finishWorkout()` as its explicit early-end path.
    var canFinishResolvedWorkout: Bool {
        running && finished && !exercises.isEmpty
            && exercises.allSatisfy { isRunnerResolved($0) }
    }

    func finishResolvedWorkout() async {
        guard canFinishResolvedWorkout else { return }
        await finishWorkout()
    }

    func finishResolvedWorkout(
        expected target: WorkoutTerminalActionTarget
    ) async {
        guard matchesTerminalActionTarget(target) else { return }
        await finishResolvedWorkout()
    }

    /// Discard today's session — "I didn't really do this." Throws the
    /// logged sets away and marks the session discarded server-side; the
    /// day VANISHES (reverts to its scheduled/rest projection) rather than
    /// recording a workout. Same local-state teardown as finishWorkout so
    /// the runner/Live Activity don't linger; `load()` then pulls the
    /// vanished state. Restarting the day creates a fresh session.
    func discardWorkout() async {
        guard canInitiateBoundFeatureAction, currentJWT != nil else { return }
        let date = todaySession?.date ?? todayString
        let intent = WorkoutTerminalIntent(
            id: uuidFactory().uuidString,
            action: .discard,
            date: date,
            workoutID: todaySession?.workout_id ?? selectedDay?.id,
            resolvedSessionID: todaySession?.id,
            deliveryState: .queued,
            failedHTTPStatus: nil,
            expectedAttempt: todaySession?.attempt,
            restartDiscardedAttempt: runnerRestartDiscardedAttempt)

        // Saving the discard first is the atomic semantic commit. If the app
        // dies before the following physical set-key cleanup, init observes
        // this barrier and performs the same supersession before any drain.
        terminalOutbox.enqueue(intent)
        guard persistEnqueuedTerminalIntent(intent) else {
            terminalOutbox = WorkoutTerminalOutboxStore.load(userID: accountID, defaults: defaults)
            loadError = "Couldn't save the discard request on your iPhone. Retry saved data, then discard again."
            return
        }
        supersedeSetIntentsForDiscardBarriers()
        applyLocalDiscardMask()
        await drainWorkoutWriteOutboxes()
    }

    func discardWorkout(expected target: WorkoutTerminalActionTarget) async {
        guard matchesTerminalActionTarget(target) else { return }
        await discardWorkout()
    }

    func resolveWorkoutFeedbackConflict(id: String, expected: WorkoutFeedbackBaseline, useMine: Bool) async {
        guard canInitiateBoundFeatureAction,
              let current = terminalOutbox.intents.first(where: { $0.id == id }),
              let conflict = current.feedbackConflict, conflict == expected,
              let durable = durableTerminalIntent(matching: current), durable.feedbackConflict == expected else { return }
        var feedback = useMine ? current.feedback : nil
        feedback?.expected = conflict
        let replacement = WorkoutTerminalIntent(id: uuidFactory().uuidString, action: .finish,
            date: current.date, workoutID: current.workoutID, resolvedSessionID: current.resolvedSessionID,
            deliveryState: .queued, failedHTTPStatus: nil, expectedAttempt: current.expectedAttempt,
            restartDiscardedAttempt: current.restartDiscardedAttempt, feedback: feedback)
        WorkoutTerminalOutboxStore.resolveFeedbackConflict(id: id, replacement: replacement,
            userID: accountID, defaults: defaults)
        guard WorkoutTerminalOutboxStore.load(userID: accountID, defaults: defaults).intent(for: current.date)?.id == replacement.id else { return }
        terminalOutbox.resolveFeedbackConflict(id: id, replacement: replacement)
        ownedTerminalIntentIDs.remove(id)
        ownedTerminalIntentIDs.insert(replacement.id)
        await drainWorkoutWriteOutboxes()
    }

    func retryTerminalIntent(id: String) async {
        guard canInitiateBoundFeatureAction,
              var intent = terminalOutbox.intents.first(where: { $0.id == id }),
              intent.deliveryState == .failed,
              intent.feedbackConflict == nil
        else { return }
        intent.deliveryState = .queued
        intent.failedHTTPStatus = nil
        terminalOutbox.replace(intent)
        persistReplacedTerminalIntent(intent)
        await drainWorkoutWriteOutboxes()
    }

    func retryFailedTerminalIntents() async {
        guard canInitiateBoundFeatureAction else { return }
        var changed = false
        for var intent in terminalOutbox.intents
        where intent.deliveryState == .failed && intent.feedbackConflict == nil {
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
    // current one) or remove the active slot itself. The live-state apply path
    // owns stable-slot remapping and only reseeds when executable identity
    // changes, preserving an in-flight timed hold across harmless edits.

    @discardableResult
    func addExerciseToDay(_ dayID: String, exercise: String, isWarmup: Bool,
                          targetSets: Int, targetReps: Int, targetRepsMax: Int?,
                          restSeconds: Int,
                          targetDurationS: Int?) async -> Bool {
        guard canInitiateBoundFeatureAction, let jwt = currentJWT else { return false }
        do {
            _ = try await planEditingAPI.addExercise(
                dayID: dayID, exercise: exercise, isWarmup: isWarmup,
                targetSets: targetSets, targetReps: targetReps,
                targetRepsMax: targetRepsMax,
                restSeconds: restSeconds, targetDurationS: targetDurationS, jwt: jwt)
            guard canInitiateBoundFeatureAction else {
                auth.noteAccountStatePersisted(for: accountID)
                return false
            }
            await loadAfterMutation()
            guard canInitiateBoundFeatureAction else {
                auth.noteAccountStatePersisted(for: accountID)
                return false
            }
            // The POST acknowledgement is the commit boundary. A failed
            // refresh leaves `loadError` visible, but returning false would
            // keep the add form open and let a retry insert a duplicate slot.
            return true
        } catch {
            handle(error, jwt: jwt)
            return false
        }
    }

    func deleteSlot(dayID: String, teID: String) async {
        guard canInitiateBoundFeatureAction, let jwt = currentJWT,
              !workoutEditorRefreshNeeded else { return }
        do {
            try await planEditingAPI.deleteExerciseSlot(
                dayID: dayID, teID: teID, jwt: jwt)
            guard canInitiateBoundFeatureAction else {
                auth.noteAccountStatePersisted(for: accountID)
                return
            }
            workoutEditorRefreshNeeded = true
            await loadAfterMutation()
            guard canInitiateBoundFeatureAction else {
                auth.noteAccountStatePersisted(for: accountID)
                return
            }
        } catch { handle(error, jwt: jwt) }
    }

    @discardableResult
    func replaceSlot(dayID: String, teID: String, exercise: String,
                     expectedVersion: Int) async -> Bool {
        guard canInitiateBoundFeatureAction, let jwt = currentJWT,
              !workoutEditorRefreshNeeded else { return false }
        do {
            _ = try await planEditingAPI.replaceExerciseSlot(
                dayID: dayID, teID: teID, exercise: exercise,
                expectedVersion: expectedVersion, jwt: jwt)
            guard canInitiateBoundFeatureAction else {
                auth.noteAccountStatePersisted(for: accountID)
                return false
            }
            workoutEditorRefreshNeeded = true
            await loadAfterMutation()
            guard canInitiateBoundFeatureAction else {
                auth.noteAccountStatePersisted(for: accountID)
                return false
            }
            // The swap is committed even if the following pull fails. Close
            // the picker and require a refresh before allowing further edits.
            return true
        } catch {
            guard canInitiateBoundFeatureAction else { return false }
            if case APIError.http(409, _) = error {
                workoutEditorRefreshNeeded = true
                await loadAfterMutation()
                guard canInitiateBoundFeatureAction else { return false }
                loadError = "Workout changed. Close and reopen Replace with… to review the latest targets."
            } else if case APIError.http(400, _) = error {
                loadError = "The saved targets cannot be used for this replacement. Edit the targets first or choose another exercise."
            } else {
                handle(error, jwt: jwt)
            }
            return false
        }
    }

    /// Move a slot to a new position. The backend densifies sibling
    /// order_index values around the requested destination.
    func moveSlot(dayID: String, teID: String, toIndex: Int) async {
        guard canInitiateBoundFeatureAction, let jwt = currentJWT,
              !workoutEditorRefreshNeeded else { return }
        do {
            _ = try await planEditingAPI.updateExerciseSlot(
                dayID: dayID, teID: teID, fields: ["order_index": toIndex], jwt: jwt)
            guard canInitiateBoundFeatureAction else {
                auth.noteAccountStatePersisted(for: accountID)
                return
            }
            workoutEditorRefreshNeeded = true
            await loadAfterMutation()
            guard canInitiateBoundFeatureAction else {
                auth.noteAccountStatePersisted(for: accountID)
                return
            }
        } catch { handle(error, jwt: jwt) }
    }

    @discardableResult
    func updateSlot(
        dayID: String,
        teID: String,
        isWarmup: Bool,
        targetSets: Int,
        targetReps: Int,
        targetRepsMax: Int?,
        restSeconds: Int,
        targetDurationS: Int?
    ) async -> Bool {
        guard canInitiateBoundFeatureAction, let jwt = currentJWT else { return false }
        var fields: [String: Any] = [
            "is_warmup": isWarmup,
            "target_sets": targetSets,
            "target_reps": targetReps,
            "rest_seconds": restSeconds,
        ]
        if plan?.workouts.first(where: { $0.id == dayID })?.exercises.first(where: { $0.id == teID })?.group_id != nil {
            fields.removeValue(forKey: "target_sets")
            fields.removeValue(forKey: "rest_seconds")
        }
        fields["target_reps_max"] = targetRepsMax.map { $0 as Any } ?? NSNull()
        fields["target_duration_s"] = targetDurationS.map { $0 as Any } ?? NSNull()
        do {
            _ = try await planEditingAPI.updateExerciseSlot(
                dayID: dayID, teID: teID, fields: fields, jwt: jwt)
            guard canInitiateBoundFeatureAction else {
                auth.noteAccountStatePersisted(for: accountID)
                return false
            }
            workoutEditorRefreshNeeded = true
            await loadAfterMutation()
            guard canInitiateBoundFeatureAction else {
                auth.noteAccountStatePersisted(for: accountID)
                return false
            }
            // The PATCH acknowledgement is the commit boundary. A failed
            // refresh leaves `loadError` visible, but returning false would
            // keep the form open and let a retry overwrite a newer edit.
            return true
        } catch {
            handle(error, jwt: jwt)
            return false
        }
    }

    @discardableResult
    func saveExerciseGroup(dayID: String, groupID: String, memberIDs: [String],
                           expectedVersion: Int, roundRest: Int, transitionRest: Int,
                           targetSets: Int, orderIndex: Int? = nil) async -> Bool {
        guard canInitiateBoundFeatureAction, let jwt = currentJWT,
              !workoutEditorRefreshNeeded else { return false }
        return await performExerciseGroupWrite(jwt: jwt) {
            try await self.planEditingAPI.setExerciseGroup(dayID: dayID, groupID: groupID,
                memberIDs: memberIDs, expectedVersion: expectedVersion, roundRest: roundRest,
                transitionRest: transitionRest, targetSets: targetSets, orderIndex: orderIndex, jwt: jwt)
        }
    }

    @discardableResult
    func clearExerciseGroup(dayID: String, groupID: String, expectedVersion: Int) async -> Bool {
        guard canInitiateBoundFeatureAction, let jwt = currentJWT,
              !workoutEditorRefreshNeeded else { return false }
        return await performExerciseGroupWrite(jwt: jwt) {
            try await self.planEditingAPI.clearExerciseGroup(dayID: dayID, groupID: groupID,
                expectedVersion: expectedVersion, jwt: jwt)
        }
    }

    private func performExerciseGroupWrite(jwt: String,
        operation: () async throws -> APIClient.ExerciseGroupAcknowledgement) async -> Bool {
        do {
            _ = try await operation()
            guard canInitiateBoundFeatureAction else {
                auth.noteAccountStatePersisted(for: accountID)
                return false
            }
            workoutEditorRefreshNeeded = true
            await loadAfterMutation()
            guard canInitiateBoundFeatureAction else {
                auth.noteAccountStatePersisted(for: accountID)
                return false
            }
            return true
        } catch {
            guard canInitiateBoundFeatureAction else { return false }
            if (error as? APIError)?.httpStatus == 409 {
                workoutEditorRefreshNeeded = true
                await loadAfterMutation()
                guard canInitiateBoundFeatureAction else { return false }
                loadError = "Workout changed. Reopen the group to review its current members and rounds."
            } else { handle(error, jwt: jwt) }
            return false
        }
    }

    // MARK: manual routine + calendar authoring

    var recentPlanChanges: [PlanHistoryItem] {
        guard canInitiateBoundFeatureAction, let plan,
              let history = recentPlanHistory, history.plan_id == plan.id,
              history.current_version == plan.version else { return [] }
        let through = PlanChangeDismissalStore.load(userID: accountID, planID: plan.id, defaults: defaults)
        return history.items.filter { $0.version > through }
    }

    func dismissRecentPlanChanges(through version: Int, planID: String) {
        guard canInitiateBoundFeatureAction, plan?.id == planID,
              recentPlanHistory?.plan_id == planID,
              recentPlanHistory?.items.contains(where: { $0.version == version }) == true else { return }
        PlanChangeDismissalStore.dismiss(through: version, userID: accountID,
                                        planID: planID, defaults: defaults)
        planDismissalRevision += 1
    }

    func refreshRecentPlanChanges() async {
        let request = UUID()
        planHistoryRequest = request
        planChangesError = nil
        guard canInitiateBoundFeatureAction, let jwt = currentJWT, let requestedPlan = plan else {
            recentPlanHistory = nil
            return
        }
        do {
            let response = try await routineEditingAPI.getPlanHistory(limit: 5, beforeVersion: nil, jwt: jwt)
            guard canInitiateBoundFeatureAction, !Task.isCancelled, planHistoryRequest == request,
                  plan?.id == requestedPlan.id, plan?.version == requestedPlan.version else { return }
            guard response.plan_id == requestedPlan.id, response.current_version == requestedPlan.version else {
                recentPlanHistory = nil
                planChangesError = "Your plan changed. Refresh to see recent changes."
                return
            }
            recentPlanHistory = response
        } catch {
            guard canInitiateBoundFeatureAction, !Task.isCancelled, planHistoryRequest == request,
                  plan?.id == requestedPlan.id, plan?.version == requestedPlan.version else { return }
            recentPlanHistory = nil
            planChangesError = "Recent changes are unavailable. Try again when connected."
            if (error as? APIError)?.httpStatus == 401 { handle(error, jwt: jwt) }
        }
    }

    func loadPlanHistory(limit: Int = 25, beforeVersion: Int? = nil) async -> PlanHistoryResponse? {
        guard canInitiateBoundFeatureAction, let jwt = currentJWT else { return nil }
        do {
            let result = try await routineEditingAPI.getPlanHistory(limit: limit, beforeVersion: beforeVersion, jwt: jwt)
            guard canInitiateBoundFeatureAction else { return nil }
            return result
        }
        catch { handle(error, jwt: jwt); return nil }
    }

    func comparePlanVersion(_ version: Int, toVersion: Int) async -> PlanComparisonResponse? {
        guard canInitiateBoundFeatureAction, let jwt = currentJWT else { return nil }
        do {
            let result = try await routineEditingAPI.comparePlanVersion(version, toVersion: toVersion, jwt: jwt)
            guard canInitiateBoundFeatureAction else { return nil }
            return result
        }
        catch { handle(error, jwt: jwt); return nil }
    }

    /// Returns true once the server acknowledges the restore. A following
    /// state refresh may fail, but that never turns the acknowledged mutation
    /// into a retry invitation; the existing sync error remains visible.
    func restorePlanVersion(
        _ snapshotVersion: Int,
        expectedPlanID: String,
        reviewedCurrentVersion: Int,
        reason: String?
    ) async -> Bool {
        guard canInitiateBoundFeatureAction else { return false }
        while isRoutineMutationInFlight {
            await withCheckedContinuation { routineMutationWaiters.append($0) }
            guard canInitiateBoundFeatureAction else { return false }
        }
        guard let jwt = currentJWT else { return false }
        isRoutineMutationInFlight = true
        defer {
            isRoutineMutationInFlight = false
            let waiters = routineMutationWaiters
            routineMutationWaiters.removeAll()
            waiters.forEach { $0.resume() }
        }
        do {
            _ = try await routineEditingAPI.restorePlanVersion(
                snapshotVersion, expectedPlanID: expectedPlanID,
                expectedVersion: reviewedCurrentVersion, reason: reason, jwt: jwt)
            guard canInitiateBoundFeatureAction else {
                auth.noteAccountStatePersisted(for: accountID)
                return true
            }
            await loadAfterMutation()
            return true
        } catch {
            if case let APIError.http(code, body) = error,
               Self.routineMutationNeedsReload(code: code, body: body) {
                await loadAfterMutation()
                if body.contains("active_workout") {
                    loadError = "Finish or discard the active workout before restoring a routine."
                } else if loadError == nil {
                    loadError = "The routine changed elsewhere. Latest version loaded — review and try again."
                }
            } else {
                handle(error, jwt: jwt)
            }
            return false
        }
    }

    private func performRoutineMutation<T>(
        _ operation: (any RoutineEditingAPI, String) async throws -> T
    ) async -> T? {
        guard canInitiateBoundFeatureAction else { return nil }
        // UI controls are disabled while this flag is set, but serializing
        // here also closes the tap-to-Task scheduling window. A second edit
        // waits and then reaches the server (where its captured version can
        // conflict) instead of being silently dropped.
        while isRoutineMutationInFlight {
            // Suspend until the active edit finishes. Task.yield() here was a
            // MainActor busy loop for the whole network timeout.
            await withCheckedContinuation { continuation in
                routineMutationWaiters.append(continuation)
            }
            guard canInitiateBoundFeatureAction else { return nil }
        }
        guard let jwt = currentJWT else { return nil }
        isRoutineMutationInFlight = true
        defer {
            isRoutineMutationInFlight = false
            let waiters = routineMutationWaiters
            routineMutationWaiters.removeAll()
            waiters.forEach { $0.resume() }
        }
        do {
            let result = try await operation(routineEditingAPI, jwt)
            guard canInitiateBoundFeatureAction else {
                auth.noteAccountStatePersisted(for: accountID)
                return nil
            }
            await loadAfterMutation()
            guard canInitiateBoundFeatureAction else {
                auth.noteAccountStatePersisted(for: accountID)
                return nil
            }
            // The write was acknowledged. A failed refresh remains visible in
            // loadError, but must not turn that acknowledgement into a retry.
            return result
        } catch {
            if case let APIError.http(code, body) = error,
               Self.routineMutationNeedsReload(code: code, body: body)
            {
                await loadAfterMutation()
                guard loadError == nil else { return nil }
                if canInitiateBoundFeatureAction {
                    if body.contains("day_in_progress") {
                        loadError = "Finish or discard the active workout before removing this workout day."
                    } else if body.contains("session_already_started") {
                        loadError = "A started workout cannot be reassigned to another day or rest."
                    } else {
                        loadError = "The routine changed elsewhere. Latest version loaded — review and try again."
                    }
                }
            } else {
                handle(error, jwt: jwt)
            }
            return nil
        }
    }

    private static func routineMutationNeedsReload(code: Int, body: String) -> Bool {
        if code == 409 { return true }
        if code == 404 {
            return body.contains("\"not_found\"")
                || body.contains("\"day_not_found\"")
        }
        if code == 400 {
            return body.contains("\"unknown_day_ref\"")
                || body.contains("\"no_active_plan\"")
        }
        return false
    }

    /// Returns the exact ensured identity/version. A concurrent coach/app
    /// winner is loaded without being replaced.
    func ensureRoutinePlan(name: String) async -> APIClient.EnsureActivePlanResult? {
        let clean = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !clean.isEmpty else { return nil }
        return await performRoutineMutation { api, jwt in
            try await api.ensureActivePlan(name: clean, jwt: jwt)
        }
    }

    func addWorkoutDay(
        name: String,
        expectedPlanID: String? = nil,
        expectedVersion: Int? = nil
    ) async -> String? {
        if case let .created(id) = await createLibraryWorkout(name: name,
            expectedPlanID: expectedPlanID, expectedVersion: expectedVersion) { return id }
        return nil
    }

    enum WorkoutCreationOutcome: Equatable { case created(String), needsReview, retrySameRequest }

    func createLibraryWorkout(
        name: String,
        expectedPlanID: String? = nil,
        expectedVersion: Int? = nil
    ) async -> WorkoutCreationOutcome {
        guard let currentPlan = plan else { return .retrySameRequest }
        let planID = expectedPlanID ?? currentPlan.id
        let version = expectedVersion ?? currentPlan.version
        let clean = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !clean.isEmpty else { return .needsReview }
        var definitiveConflict = false
        let result = await performRoutineMutation { api, jwt in
            do {
                return try await api.addWorkout(name: clean, expectedPlanID: planID,
                    expectedVersion: version, jwt: jwt)
            } catch {
                if (error as? APIError)?.httpStatus == 409 { definitiveConflict = true }
                throw error
            }
        }
        if let result { return .created(result.id) }
        return definitiveConflict ? .needsReview : .retrySameRequest
    }

    func renameWorkoutDay(dayID: String, name: String) async {
        guard let version = plan?.version else { return }
        let clean = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !clean.isEmpty else { return }
        _ = await performRoutineMutation { api, jwt in
            try await api.updateWorkout(
                dayID: dayID, fields: ["name": clean],
                expectedVersion: version, jwt: jwt)
        } as APIClient.WorkoutIDRow?
    }

    func moveWorkoutDay(dayID: String, toIndex: Int) async {
        guard let version = plan?.version else { return }
        _ = await performRoutineMutation { api, jwt in
            try await api.updateWorkout(
                dayID: dayID, fields: ["order_index": toIndex],
                expectedVersion: version, jwt: jwt)
        } as APIClient.WorkoutIDRow?
    }

    private func runnerProtectsWorkoutDay(_ dayID: String) -> Bool {
        (running && selectedDayID == dayID)
            || persistedRunnerCheckpoint?.selectedDayID == dayID
    }

    private func runnerProtectsCalendarDate(_ date: String) -> Bool {
        (running && date == todayString)
            || persistedRunnerCheckpoint?.date == date
    }

    func deleteWorkoutDay(dayID: String) async {
        guard !runnerProtectsWorkoutDay(dayID) else {
            loadError = "Finish or discard the active workout before removing this workout day."
            return
        }
        guard let version = plan?.version else { return }
        _ = await performRoutineMutation { api, jwt in
            try await api.deleteWorkout(
                dayID: dayID, expectedVersion: version, jwt: jwt)
        } as APIClient.DeleteWorkoutResult?
    }

    func saveRecurringSchedule(_ week: [String: String]) async {
        guard let currentPlan = plan else { return }
        _ = await performRoutineMutation { api, jwt in
            try await api.setSchedule(
                week,
                expectedPlanID: currentPlan.id,
                expectedVersion: currentPlan.version,
                jwt: jwt)
        } as APIClient.ScheduleWriteResult?
    }

    func unscheduleWorkout(workoutID: String) async {
        guard let currentPlan = plan,
              WorkoutLibraryPolicy.isScheduled(workoutID: workoutID, plan: currentPlan) else { return }
        let week = WorkoutLibraryPolicy.unscheduling(workoutID: workoutID, plan: currentPlan)
        _ = await performRoutineMutation { api, jwt in
            try await api.setSchedule(week, expectedPlanID: currentPlan.id,
                                      expectedVersion: currentPlan.version, jwt: jwt)
        } as APIClient.ScheduleWriteResult?
    }

    /// Shared by the library, agenda and the actual mutation. A sheet kept open
    /// across midnight or a state refresh must recheck before sending a write.
    func calendarAssignmentUnavailableReason(date: String, today: String? = nil) -> String? {
        let today = today ?? todayString
        if date < today { return "Choose today or a future date." }
        if runnerProtectsCalendarDate(date) {
            return "Finish or discard the active workout before changing today's assignment."
        }
        if projection(for: date, today: today).suppressesScheduleAndEndurance {
            return "This date is unavailable while the hard travel blackout is active."
        }
        if let session = sessionsByDate[date], ["in_progress", "completed"].contains(session.status) {
            return "A started workout cannot be reassigned to another day or rest."
        }
        return nil
    }

    @discardableResult
    func setCalendarOverride(date: String, dayID: String?) async -> Bool {
        if let reason = calendarAssignmentUnavailableReason(date: date) {
            loadError = reason
            return false
        }
        // Zero is the explicit CAS token for "no assignment row observed".
        // The Worker persists the first choice as attempt one, so two clients
        // creating different overrides from the same empty view cannot both win.
        let expectedAttempt = sessionsByDate[date]?.attempt ?? 0
        let result = await performRoutineMutation { api, jwt in
            try await api.setCalendarDate(
                date, dayID: dayID, expectedAttempt: expectedAttempt, jwt: jwt)
        } as APIClient.CalendarWriteResult?
        return result != nil
    }

    func calendarMoveUnavailableReason(from: String, to: String, workoutID: String) -> String? {
        if from == to { return "Choose a different date." }
        if let reason = calendarAssignmentUnavailableReason(date: from) { return reason }
        if let reason = calendarAssignmentUnavailableReason(date: to) { return reason }
        if previewWorkout(forDateString: from)?.id != workoutID { return "The original workout changed. Reopen the date to review it." }
        if previewWorkout(forDateString: to) != nil { return "This date already has a workout. Choose an empty date." }
        return nil
    }

    func calendarMoveRequest(from: String, to: String, workoutID: String) -> APIClient.CalendarMoveRequest? {
        guard let plan, calendarMoveUnavailableReason(from: from, to: to, workoutID: workoutID) == nil else { return nil }
        return .init(id: UUID().uuidString, fromDate: from, toDate: to, today: todayString,
                     workoutID: workoutID, planID: plan.id, planVersion: plan.version,
                     fromAttempt: sessionsByDate[from]?.attempt ?? 0,
                     toAttempt: sessionsByDate[to]?.attempt ?? 0)
    }

    enum CalendarMoveOutcome: Equatable { case acknowledged, needsReview, retrySameRequest }

    func moveCalendarWorkout(_ request: APIClient.CalendarMoveRequest) async -> CalendarMoveOutcome {
        // Retry uses the same request and receipt id, even after a lost response.
        // Local runners and the civil-day boundary remain current action gates.
        guard request.fromDate >= todayString, request.toDate >= todayString,
              !runnerProtectsCalendarDate(request.fromDate), !runnerProtectsCalendarDate(request.toDate) else {
            loadError = "This move is no longer available. Reopen Calendar to review both dates."
            return .needsReview
        }
        var definitiveConflict = false
        let result = await performRoutineMutation { api, jwt in
            // Another edit can finish while this request waits for the shared
            // mutation slot. Check runner ownership and the date again here.
            guard request.fromDate >= self.todayString, request.toDate >= self.todayString,
                  !self.runnerProtectsCalendarDate(request.fromDate),
                  !self.runnerProtectsCalendarDate(request.toDate) else {
                definitiveConflict = true
                throw APIError.http(409, "calendar_move_unavailable")
            }
            do {
                return try await api.moveCalendarWorkout(request, jwt: jwt)
            } catch {
                // A 409 acknowledges rejection, so a refreshed choice needs a
                // new request. Network/server failures keep the original receipt.
                if (error as? APIError)?.httpStatus == 409 { definitiveConflict = true }
                throw error
            }
        } as APIClient.CalendarMoveResult?
        if result != nil { return .acknowledged }
        return definitiveConflict ? .needsReview : .retrySameRequest
    }

    // MARK: rest timer

    /// Name of the next not-complete exercise (for the rest screen's UP NEXT).
    var upNextName: String {
        if let i = nextRunnerIncompleteIndex { return exercises[i].exercise_name }
        return "Done"
    }

    func removeSet(_ set: SetLog) async {
        enqueueCorrection(set: set, values: nil)
        await drainWorkoutWriteOutboxes()
    }

    /// Fires the "rest's up" audio cue exactly when the current rest elapses.
    /// Cancelled/rescheduled whenever the rest changes (+15 / −15 / DONE / a
    /// new set's rest), so it never double-fires or fires for a stale timer.
    private var restCueTask: Task<Void, Never>?

    func startRest(seconds: Int, name: String) {
        guard canControlSharedRestArtifacts else {
            relinquishStaleRunnerCheckpoint()
            return
        }
        restExercise = name
        restTotal = seconds
        let end = Date().addingTimeInterval(TimeInterval(seconds))
        restEndDate = end
        restControlID = UUID().uuidString
        registerTimerControls()
        RestLiveActivity.start(exercise: name, endDate: end, upNext: restActivityCurrentStepName, controlID: restControlID)
        scheduleRestCue(for: end)
        RestCue.scheduleNotification(at: end)
    }
    func addRest(_ seconds: Int) {
        guard canControlSharedRestArtifacts, let end = restEndDate else {
            if restEndDate != nil { relinquishStaleRunnerCheckpoint() }
            return
        }
        let newEnd = end.addingTimeInterval(TimeInterval(seconds))
        restEndDate = newEnd
        RestLiveActivity.update(endDate: newEnd, upNext: restActivityCurrentStepName)
        scheduleRestCue(for: newEnd)
        RestCue.scheduleNotification(at: newEnd)
    }
    func skipRest() {
        guard canControlSharedRestArtifacts else {
            relinquishStaleRunnerCheckpoint()
            return
        }
        relinquishLocalRest()
        restActivityEnder()
        restNotificationCanceller()
    }

    /// Cancel only this model's local rest state. A stale same-account model
    /// that loses the runner-checkpoint CAS must not end the replacement
    /// model's process-global Live Activity or notification.
    private func relinquishLocalRest() {
        restControlID = nil
        restEndDate = nil
        restCueTask?.cancel()
        restCueTask = nil
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
        guard canControlSharedRestArtifacts else {
            relinquishStaleRunnerCheckpoint()
            return
        }
        restCueTask?.cancel()
        restCueTask = Task { [weak self] in
            while !Task.isCancelled {
                guard let self, self.restEndDate == end else { return }
                guard self.canControlSharedRestArtifacts else {
                    self.relinquishStaleRunnerCheckpoint()
                    return
                }
                if Date() >= end { break }
                try? await Task.sleep(nanoseconds: 250_000_000)
            }
            if Task.isCancelled { return }
            guard let self, self.restEndDate == end else { return }
            guard self.canControlSharedRestArtifacts else {
                self.relinquishStaleRunnerCheckpoint()
                return
            }
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
            guard self.canControlSharedRestArtifacts else {
                self.relinquishStaleRunnerCheckpoint()
                return
            }
            if !alreadyCued {
                RestCue.play(upNext: self.restCueLift)
            }
            RestCue.cancelNotification()
        }
    }

    // MARK: calendar projection (read-only future calendar)

    /// Plan day_template ids (for dangling-schedule detection).
    var planTemplateIDs: Set<String> {
        Set(plan?.workouts.map(\.id) ?? [])
    }

    /// Real cached sessions keyed by YYYY-MM-DD. If multiple sessions share
    /// a date, prefer the most "advanced" one (completed > in_progress >
    /// planned > skipped) so the calendar shows the strongest signal.
    var sessionsByDate: [String: SessionRow] {
        historyIndex.sessionsByDate
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
        return historyIndex.setsBySession[sid]?.count ?? 0
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
    /// A real session can BE a workout while its `workout_id` is
    /// null (server-side `getOrCreateSession` ignores the passed template
    /// id for an existing same-date row). Fallback order so the workout
    /// still renders sensibly:
    ///   1. the session's own `workout_id` (if populated), else
    ///   2. today's scheduled template (the SAME projection/schedule the
    ///      calendar uses — derived from `meta.schedule`, no fork), else
    ///   3. `selectedDay` (whatever the runner last targeted), else
    ///   4. the first plan day.
    /// Returns nil ONLY when today is genuinely not a workout.
    var todayResolvedDay: Workout? {
        // Single-clock: capture `todayString` ONCE and derive the
        // projection ONCE from it, instead of touching the computed clock
        // multiple times (workout test + template switch +
        // `sessionDisplayTemplate(todayString)`). At a midnight rollover
        // those independent reads could otherwise resolve against
        // different civil days within this one property evaluation (the
        // workout-guard sees day N, the template switch day N+1, etc.).
        let today = todayString
        // Live validation can recover approved feedback before the first set
        // creates a session, including an explicit workout on a rest day.
        if let checkpoint = resumableCheckpoint,
           checkpoint.date == today,
           let checkpointDay = workout(id: checkpoint.selectedDayID) {
            return checkpointDay
        }
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
        switch proj {
        case .projected(let tid):
            // Schedule projection: the template id IS the schedule's.
            return workout(id: tid) ?? selectedDay ?? plan?.workouts.first
        case .session(_, let hardBlackoutTripType):
            // Real workout-status session. Outside a hard blackout, the
            // shared session→schedule inference preserves the existing
            // null-template fallback. During a hard blackout the schedule is
            // suppressed on both platforms, so only an explicit session day
            // is eligible before the selected/first display fallback.
            return sessionDisplayTemplate(
                forDateString: today,
                allowScheduleInference: hardBlackoutTripType == nil)
                ?? selectedDay ?? plan?.workouts.first
        case .rest, .none, .unavailable, .light:
            return nil   // unreachable (guarded by isWorkout)
        }
    }

    /// Identity for preview/edit navigation. Display fallbacks used by legacy
    /// runners are not authority to open an unrelated saved workout's editor.
    var todayPreviewWorkout: Workout? {
        let today = todayString
        if let checkpoint = resumableCheckpoint, checkpoint.date == today {
            return workout(id: checkpoint.selectedDayID)
        }
        return previewWorkout(forDateString: today, today: today)
    }

    func previewWorkout(forDateString date: String, today: String? = nil) -> Workout? {
        let today = today ?? todayString
        switch projection(for: date, today: today) {
        case .projected(let id): return workout(id: id)
        case .session(let status, let blackout):
            guard Self.isWorkoutStatus(status) else { return nil }
            if let explicitID = sessionsByDate[date]?.workout_id { return workout(id: explicitID) }
            return sessionDisplayTemplate(forDateString: date,
                                          allowScheduleInference: blackout == nil && date >= today && status != "completed")
        case .rest, .none, .unavailable, .light: return nil
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
    /// `workout_id` (server `getOrCreateSession` drops it for an
    /// existing same-date row). Read-only — never writes the schedule.
    func scheduledTemplate(forDateString ymd: String) -> Workout? {
        guard let key = CalendarProjection.weekdayKey(forDateString: ymd),
              let tid = plan?.schedule?.templateID(forWeekdayKey: key)
        else { return nil }
        return workout(id: tid)
    }

    /// The template to DISPLAY for a real session on `ymd`, regardless of
    /// whether its `workout_id` is populated: session's own id →
    /// scheduled-by-weekday fallback. No `selectedDay`/first-day fallback
    /// here (callers that need a guaranteed non-nil add their own). Shared
    /// by Today and the calendar's `dayLabel` so the inference is identical.
    ///
    /// `allowScheduleInference` (default `true`) gates ONLY the
    /// schedule-by-weekday fallback (step 2). The session's own
    /// `workout_id` (step 1) is ALWAYS honoured. Pass `false` for
    /// HISTORICAL dates: the *current* `meta.schedule` must not relabel a
    /// past completed session (a schedule edit would otherwise rewrite its
    /// A/B), so a null-`workout_id` past session resolves to nil
    /// (glyph-only, no possibly-wrong label) rather than today's mapping.
    /// `true` is REQUIRED for today/future (the BLOCKER fix:
    /// `todayResolvedDay` must still infer today's template) — the valid
    /// inference window is exactly `ymd >= today`, the same civil-date
    /// boundary `CalendarProjection.project` uses (`dateString < today`),
    /// not a forked date rule. Callers pass `ymd >= todayString`.
    func sessionDisplayTemplate(forDateString ymd: String,
                                allowScheduleInference: Bool = true) -> Workout? {
        if let day = workout(id: sessionsByDate[ymd]?.workout_id) {
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
    struct NextWorkout { let dateString: String; let day: Workout? }

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
                return NextWorkout(dateString: ymd, day: workout(id: tid))
            case .session(let status, let hardBlackoutTripType):
                if status == "planned" || status == "in_progress" {
                    // Use the SHARED session→schedule resolver (the same one
                    // Today/calendar use), not a bare workout_id read:
                    // a real planned/in_progress session with a null
                    // workout_id normally resolves via the weekly
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
            Task {
                await reopenSkippedWorkoutAndStart(
                    skipped, requestedDayID: dayID)
            }
            return
        }
        startWorkout()
    }

    private func reopenSkippedWorkoutAndStart(
        _ skipped: SessionRow,
        requestedDayID: String
    ) async {
        defer { isReopeningSkippedWorkout = false }
        guard canInitiateBoundFeatureAction, let jwt = currentJWT else { return }
        do {
            let response = try await setWriteAPI.reopenSkippedSession(
                sessionId: skipped.id,
                workoutID: requestedDayID,
                expectedAttempt: skipped.attempt ?? 0,
                jwt: jwt)
            guard canMutateBoundSetAccount,
                  response.id == skipped.id,
                  response.date == skipped.date,
                  response.status == "planned",
                  response.workout_id == requestedDayID,
                  response.attempt == nil
                    || response.attempt == (skipped.attempt ?? 0) + 1,
                  let accepted = acceptSessionResolution(response),
                  accepted.status == "planned",
                  accepted.workout_id == requestedDayID
            else {
                throw APIError.decoding(
                    "Skipped-session reopen did not advance the workout")
            }
            guard canInitiateBoundFeatureAction else {
                // The account still owns the accepted server mutation, but
                // this model no longer owns the feature session that rendered
                // the choice. Wake the replacement model instead of mounting
                // a stale runner or overwriting its checkpoint.
                auth.noteAccountStatePersisted(for: accountID)
                return
            }
            loadError = nil
            selectedDayID = requestedDayID
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
                guard canInitiateBoundFeatureAction else {
                    auth.noteAccountStatePersisted(for: accountID)
                    return
                }
                loadError = "Today's session changed elsewhere. Review it before starting."
                return
            }
            handle(error, jwt: jwt)
        }
    }

    /// Plan day for a template id (agenda exercise targets).
    func workout(id: String?) -> Workout? {
        guard let id else { return nil }
        return plan?.workouts.first { $0.id == id }
    }

    /// Logged working + warmup sets for a session (agenda "completed").
    func setsForSession(_ sessionID: String) -> [SetLog] {
        (historyIndex.setsBySession[sessionID] ?? [])
            .sorted {
                $0.exercise_id == $1.exercise_id
                    ? $0.set_index < $1.set_index
                    : $0.logged_at < $1.logged_at
            }
    }

    private func handle(_ error: Error, jwt: String) {
        if (error as? APIError)?.httpStatus == 401 {
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
            deleted_at: deleted_at,
            updated_at: updated_at)
    }
}

// MARK: - Durable set corrections

extension SyncModel {
    func refreshTimerCues() {
        guard canInitiateBoundFeatureAction, canControlSharedRestArtifacts else { return }
        if !RestCue.enabled {
            RestCue.cancelNotification()
            RestCue.cancelTimedNotification()
        } else if timedActive, let end = timedEndDate, end > now() {
            timedCueGeneration = RestCue.scheduleTimedNotification(at: end)
        } else if let end = restEndDate, end > now() {
            RestCue.scheduleNotification(at: end)
        }
    }

    private func registerTimerControls() {
        WorkoutTimerControl.handler = { [weak self] id, action in
            await self?.controlTimer(id: id, action: action) ?? false
        }
    }

    func controlTimer(id: String, action: String) async -> Bool {
        guard canInitiateBoundFeatureAction, canControlSharedRestArtifacts else { return false }
        if id == restControlID, restEndDate != nil {
            if action == "extend" { addRest(15); return true }
            if action == "stop" { skipRest(); return true }
        }
        if id == timedControlID, timedActive, action == "stop", timedElapsed >= 2 {
            await stopTimedSet()
            return true
        }
        return false
    }

    func setRunnerValues(_ values: SetCorrectionValues, expected: RunnerPrescription) -> Bool {
        guard canInitiateBoundFeatureAction, !timedActive, values.isValid,
              currentExercise.map(RunnerPrescription.init) == expected else { return false }
        setWeight(values.weight)
        setReps(values.reps)
        setRPE(values.rpe)
        if let duration = values.durationSeconds { setHoldDuration(duration) }
        return true
    }

    func correction(for setID: String) -> PendingSetCorrection? {
        setCorrections.first { $0.setID == setID }
    }

    @discardableResult
    func enqueueCorrection(set: SetLog, values: SetCorrectionValues?) -> Bool {
        guard canInitiateBoundFeatureAction, values?.isValid != false,
              let session = sessions.first(where: { $0.id == set.session_id }),
              !["discarded", "skipped"].contains(session.status),
              sets.contains(where: { $0.id == set.id && $0.session_id == set.session_id }),
              set.deleted_at == nil
        else { return false }
        return saveCorrection(PendingSetCorrection(
            id: uuidFactory().uuidString, setID: set.id, date: session.date,
            slotID: set.template_exercise_id, exerciseID: set.exercise_id,
            sessionID: set.session_id, expectedAttempt: session.attempt ?? 0,
            expectedUpdatedAt: set.updated_at ?? set.logged_at, values: values))
    }

    @discardableResult
    func enqueueCorrection(pending: PendingSetIntent, values: SetCorrectionValues?) -> Bool {
        guard canInitiateBoundFeatureAction, values?.isValid != false,
              durableSetIntent(matching: pending)?.body == pending.body
        else { return false }
        return saveCorrection(PendingSetCorrection(
            id: uuidFactory().uuidString, setID: pending.id, date: pending.date,
            slotID: pending.slotID, exerciseID: pending.body.exercise_id,
            sessionID: pending.resolvedSessionID, expectedAttempt: pending.expectedAttempt,
            expectedUpdatedAt: nil, values: values))
    }

    private func saveCorrection(_ intent: PendingSetCorrection) -> Bool {
        adoptDurableWorkoutWriteOutboxes()
        guard !setCorrections.contains(where: { $0.setID == intent.setID }),
              terminalOutbox.intent(for: intent.date) == nil
        else { return false }
        var intent = intent
        intent.runnerFocusRevision = runnerFocus.revision
        intent.runnerGroupRepair = observedGroupRepair(for: intent)
        guard SetCorrectionOutboxStore.enqueue(intent, userID: accountID, defaults: defaults) else {
            loadError = "Couldn't save this correction on your iPhone. Retry saved data, then try again."
            return false
        }
        ownedCorrectionIDs.insert(intent.id)
        adoptDurableWorkoutWriteOutboxes()
        guard setCorrections.contains(where: { $0.id == intent.id }) else { return false }
        Task { await drainWorkoutWriteOutboxes() }
        return true
    }

    func retryCorrection(id: String) async {
        guard canInitiateBoundFeatureAction else { return }
        adoptDurableWorkoutWriteOutboxes()
        guard var intent = setCorrections.first(where: { $0.id == id }),
              !sendingCorrectionIDs.contains(id)
        else { return }
        // Retain the revision even for a 409. Retrying never overwrites a
        // remote correction the member has not reviewed.
        intent.deliveryState = .queued
        intent.failedHTTPStatus = nil
        SetCorrectionOutboxStore.replace(intent, userID: accountID, defaults: defaults)
        adoptDurableWorkoutWriteOutboxes()
        await drainWorkoutWriteOutboxes()
    }

    /// Permanent rejection proves this request was not accepted. Clearing it
    /// permits a fresh review of the server row; queued/time-out operations
    /// cannot be abandoned while their acknowledgement is uncertain.
    func dismissRejectedCorrection(id: String) async {
        guard canInitiateBoundFeatureAction else { return }
        adoptDurableWorkoutWriteOutboxes()
        guard let intent = setCorrections.first(where: { $0.id == id }),
              intent.deliveryState == .failed, !sendingCorrectionIDs.contains(id)
        else { return }
        SetCorrectionOutboxStore.remove(id: id, userID: accountID, defaults: defaults)
        adoptDurableWorkoutWriteOutboxes()
        await loadAfterMutation()
    }

    private func performSetCorrectionDrain() async -> Bool {
        adoptDurableWorkoutWriteOutboxes()
        while canInitiateBoundFeatureAction,
              var intent = setCorrections.first(where: { correction in
                  correction.deliveryState == .queued && ownedCorrectionIDs.contains(correction.id)
                      && !setOutbox.pending.contains(where: { $0.id == correction.setID })
              }), let jwt = currentJWT {
            guard !discardBarrierDates.contains(intent.date) else {
                supersedeSetIntentsForDiscardBarriers()
                continue
            }
            if intent.expectedUpdatedAt == nil {
                // Only an acknowledged original UUID can bind an offline
                // correction. Never create another set to stand in for it.
                guard let set = sets.first(where: { $0.id == intent.setID }),
                      let session = sessions.first(where: { $0.id == set.session_id }),
                      session.date == intent.date, set.exercise_id == intent.exerciseID,
                      set.template_exercise_id == intent.slotID || set.template_exercise_id == nil,
                      intent.expectedAttempt == nil || intent.expectedAttempt == (session.attempt ?? 0)
                else {
                    failCorrection(&intent, status: 409)
                    continue
                }
                intent.sessionID = session.id
                intent.slotID = set.template_exercise_id
                intent.expectedAttempt = session.attempt ?? 0
                intent.expectedUpdatedAt = set.updated_at ?? set.logged_at
                SetCorrectionOutboxStore.replace(intent, userID: accountID, defaults: defaults)
                adoptDurableWorkoutWriteOutboxes()
                guard let bound = setCorrections.first(where: { $0.id == intent.id }) else { continue }
                intent = bound
            }
            retainGroupDeletionObservations()
            if let retained = setCorrections.first(where: { $0.id == intent.id }) { intent = retained }
            sendingCorrectionIDs.insert(intent.id)
            do {
                let result = try await setWriteAPI.correctSet(intent, jwt: jwt)
                sendingCorrectionIDs.remove(intent.id)
                guard canMutateBoundSetAccount else { return true }
                adoptDurableWorkoutWriteOutboxes()
                guard setCorrections.contains(where: { $0.id == intent.id }),
                      !discardBarrierDates.contains(intent.date)
                else { continue }
                guard result.set.id == intent.setID,
                      result.set.session_id == intent.sessionID,
                      result.set.exercise_id == intent.exerciseID,
                      result.set.template_exercise_id == intent.slotID || result.set.template_exercise_id == nil,
                      result.session.id == intent.sessionID,
                      result.session.date == intent.date,
                      result.session.attempt == intent.expectedAttempt
                else { throw APIError.decoding("Correction acknowledgement changed its identity") }
                summaryRevision &+= 1
                retainGroupDeletionObservations()
                if let retained = setCorrections.first(where: { $0.id == intent.id }) { intent = retained }
                let observedDeletionGroupID = groupDeletionObservation(intent)
                let merged = StateSnapshotStore.mergeAcknowledgement(
                    userID: accountID, fallback: currentStateResponse(), defaults: defaults
                ) { state in
                    Self.mergingSetAcknowledgement(into: state, acceptedSet: result.set,
                                                  acknowledgedSession: result.session)
                }
                // ACK is the mutation boundary. Before retiring its durable
                // intent, preserve either the merged rows or a small durable
                // invalidation marker. Repacking the same oversized snapshot
                // merely to clear its cursors can fail again.
                let recoveryCommitted = merged != nil || StateSnapshotStore.invalidate(
                    userID: accountID, defaults: defaults)
                let durableRunner = WorkoutRunnerCheckpointStore.load(userID: accountID, defaults: defaults)
                let needsRunnerRecovery = result.set.deleted_at != nil
                    && (observedDeletionGroupID != nil || intent.runnerGroupRepair != nil)
                    && durableRunner.map {
                        $0.date == intent.date
                            && ($0.sessionID == nil || $0.sessionID == intent.sessionID)
                            && ($0.sessionAttempt == nil || $0.sessionAttempt == intent.expectedAttempt)
                    } == true
                var runnerRecoveryCommitted = !needsRunnerRecovery
                if canInitiateBoundFeatureAction && (!needsRunnerRecovery
                    || (!runnerArtifactsOwnedByOther && persistedRunnerCheckpoint == durableRunner)) {
                    let state = merged?.state ?? Self.mergingSetAcknowledgement(
                        into: currentStateResponse(), acceptedSet: result.set,
                        acknowledgedSession: result.session)
                    applyState(state, preferredTodaySessionID: todaySession?.id, isLiveResponse: false)
                    // Value-only corrections preserve focus/review/rest. An
                    // accepted group deletion repairs the derived round at a
                    // stable physical-set boundary without emitting another rest.
                    if needsRunnerRecovery {
                        if supersededDeletionGroupID(intent) != nil {
                            runnerRecoveryCommitted = absorbSupersededDeletion(intent)
                        } else {
                            runnerRecoveryCommitted = repairGroupAfterDeletedSet(intent, observedGroupID: observedDeletionGroupID)
                        }
                    }
                    persistRunnerCheckpoint()
                    correctionRefreshNeeded = merged == nil
                    if merged == nil {
                        loadError = "Correction saved. Refresh to update the recovery cache."
                    }
                } else if recoveryCommitted {
                    auth.noteAccountStatePersisted(for: accountID)
                }
                if recoveryCommitted && runnerRecoveryCommitted {
                    SetCorrectionOutboxStore.remove(id: intent.id, userID: accountID, defaults: defaults)
                    adoptDurableWorkoutWriteOutboxes()
                } else {
                    // The snapshot may already contain the tombstone. Keep the
                    // correction and its counted-group evidence until the current
                    // checkpoint owner can durably settle selection or deferral.
                    if !canInitiateBoundFeatureAction || runnerArtifactsOwnedByOther
                        || WorkoutRunnerCheckpointStore.load(userID: accountID, defaults: defaults) != persistedRunnerCheckpoint {
                        ownedCorrectionIDs.remove(intent.id)
                    }
                    return true
                }
            } catch {
                sendingCorrectionIDs.remove(intent.id)
                guard canMutateBoundSetAccount else { return true }
                adoptDurableWorkoutWriteOutboxes()
                guard setCorrections.contains(where: { $0.id == intent.id }) else { continue }
                if isPermanentSetClientError(error) {
                    failCorrection(&intent, status: (error as? APIError)?.httpStatus ?? 400)
                    continue
                }
                recordRetryAfter(from: error)
                handle(error, jwt: jwt)
                return true
            }
            adoptDurableWorkoutWriteOutboxes()
        }
        return false
    }

    private func failCorrection(_ intent: inout PendingSetCorrection, status: Int) {
        intent.deliveryState = .failed
        intent.failedHTTPStatus = status
        SetCorrectionOutboxStore.replace(intent, userID: accountID, defaults: defaults)
        adoptDurableWorkoutWriteOutboxes()
    }
}


extension SyncModel {
    func completionSummary(for sessionID: String) -> WorkoutSummary? {
        guard completionSummaryRevisions[sessionID] == summaryRevision else { return nil }
        return completionSummaries[sessionID]
    }

    func loadCompletionSummary(sessionID: String) async {
        guard canInitiateBoundFeatureAction, let jwt = currentJWT,
              let session = sessions.first(where: { $0.id == sessionID && $0.status == "completed" }),
              completionSummary(for: sessionID) == nil else { return }
        let revision = summaryRevision
        do {
            let summary = try await setWriteAPI.getWorkoutSummary(sessionID: sessionID, jwt: jwt)
            guard canInitiateBoundFeatureAction, summaryRevision == revision,
                  summary.version == 1, summary.final, summary.session_id == sessionID,
                  summary.attempt == (session.attempt ?? 0),
                  sessions.contains(where: { $0.id == sessionID && $0.status == "completed"
                      && ($0.attempt ?? 0) == summary.attempt }) else { return }
            completionSummaries[sessionID] = summary
            completionSummaryRevisions[sessionID] = revision
            summaryErrors[sessionID] = nil
        } catch {
            guard canInitiateBoundFeatureAction, summaryRevision == revision else { return }
            summaryErrors[sessionID] = "Summary unavailable until the next successful sync."
            if (error as? APIError)?.httpStatus == 401 { handle(error, jwt: jwt) }
        }
    }
}
