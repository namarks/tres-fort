import Foundation

struct RunnerFocusState: Codable, Equatable {
    var revision: UInt64 = 0
    var isExplicit: Bool = false
}

/// The counted group a local deletion can reopen. The containing correction
/// or checkpoint supplies its account, civil date, session and attempt scope.
struct RunnerGroupRepair: Codable, Equatable {
    struct Member: Codable, Equatable {
        let slotID: String
        let exerciseID: String
        let warmup: Bool
        let timed: Bool
    }
    let dayID: String
    let groupID: String
    let members: [Member]

    init?(groupID: String, day: Workout) {
        let slots = day.exercises.filter { $0.group_id == groupID }
        guard slots.count >= 2 else { return nil }
        dayID = day.id
        self.groupID = groupID
        // Order and round targets come from current progress, not this proof.
        members = slots.sorted { $0.id < $1.id }.map { .init(slotID: $0.id, exerciseID: $0.exercise_id,
            warmup: $0.isWarmup, timed: $0.isTimed) }
    }
}

/// The smallest piece of runner UI state needed to recover after process
/// death. Server state remains authoritative: SyncModel exposes this as a
/// resume option only after a live pull confirms that this civil-date session
/// is still `in_progress`.
struct WorkoutRunnerCheckpoint: Codable, Equatable {
    let date: String
    let sessionID: String?
    /// Attempt generation for the reused (user,date) session row. Optional
    /// only for checkpoints written before migration 0032 / rolling servers.
    let sessionAttempt: Int?
    /// Prior discarded generation captured only when the user explicitly
    /// starts the date again. It remains until session creation consumes it.
    let restartDiscardedAttempt: Int?
    let selectedDayID: String
    let currentSlotID: String?
    let skippedSlotIDs: [String]
    let workoutStartedAtMS: Int
    let finished: Bool
    let input: RunnerInputState?
    /// Per-slot workout drafts survive alternating rounds and navigation.
    /// Optional for checkpoints created before per-exercise input recovery.
    let inputsBySlot: [String: RunnerInputState]?
    /// Progress observed when this exact focus was chosen; nil on legacy checkpoints.
    let groupProgress: GroupRunnerProgress?
    /// A newer explicit selection supersedes older pending correction actions.
    let focus: RunnerFocusState?
    /// An acknowledged repair waiting for the active physical hold's boundary.
    let deferredGroupRepair: RunnerGroupRepair?
    let feedback: WorkoutFeedback?

    init(
        date: String,
        sessionID: String?,
        selectedDayID: String,
        currentSlotID: String?,
        skippedSlotIDs: [String],
        workoutStartedAtMS: Int,
        finished: Bool,
        sessionAttempt: Int? = nil,
        restartDiscardedAttempt: Int? = nil,
        input: RunnerInputState? = nil,
        inputsBySlot: [String: RunnerInputState]? = nil,
        groupProgress: GroupRunnerProgress? = nil,
        focus: RunnerFocusState? = nil,
        deferredGroupRepair: RunnerGroupRepair? = nil,
        feedback: WorkoutFeedback? = nil
    ) {
        self.date = date
        self.sessionID = sessionID
        self.sessionAttempt = sessionAttempt
        self.restartDiscardedAttempt = restartDiscardedAttempt
        self.selectedDayID = selectedDayID
        self.currentSlotID = currentSlotID
        self.skippedSlotIDs = skippedSlotIDs
        self.workoutStartedAtMS = workoutStartedAtMS
        self.finished = finished
        self.input = input
        self.inputsBySlot = inputsBySlot
        self.groupProgress = groupProgress
        self.focus = focus
        self.deferredGroupRepair = deferredGroupRepair
        self.feedback = feedback
    }
}

enum WorkoutRunnerCheckpointStore {
    static func scopedKey(userID: String) -> String {
        "com.nmarkspdx.liftcoach.workout-runner-checkpoint.v1.\(userID)"
    }

    static func load(
        userID: String?,
        defaults: LocalPersistence = .standard
    ) -> WorkoutRunnerCheckpoint? {
        guard let userID,
              let data = defaults.data(forKey: scopedKey(userID: userID))
        else { return nil }
        do { return try JSONDecoder().decode(WorkoutRunnerCheckpoint.self, from: data) }
        catch {
            defaults.recordInvalidData(data, forKey: scopedKey(userID: userID))
            return nil
        }
    }

    static func save(
        _ checkpoint: WorkoutRunnerCheckpoint,
        userID: String?,
        defaults: LocalPersistence = .standard
    ) {
        guard let userID,
              let data = try? JSONEncoder().encode(checkpoint)
        else { return }
        defaults.set(data, forKey: scopedKey(userID: userID))
    }

    /// Compare-and-set update used by live SyncModel instances. A same-account
    /// replacement model may already own a newer runner checkpoint; an older
    /// model must not overwrite it after a delayed validation or callback.
    @discardableResult
    static func replace(
        _ checkpoint: WorkoutRunnerCheckpoint,
        ifCurrent expected: WorkoutRunnerCheckpoint?,
        userID: String?,
        defaults: LocalPersistence = .standard
    ) -> Bool {
        guard let userID,
              load(userID: userID, defaults: defaults) == expected,
              let data = try? JSONEncoder().encode(checkpoint)
        else { return false }
        return defaults.set(data, forKey: scopedKey(userID: userID))
    }

    /// Conditional clear pairs with `replace`: validation performed by an old
    /// model can clear only the exact checkpoint that model originally read.
    @discardableResult
    static func clear(
        ifCurrent expected: WorkoutRunnerCheckpoint?,
        userID: String?,
        defaults: LocalPersistence = .standard
    ) -> Bool {
        guard let userID,
              load(userID: userID, defaults: defaults) == expected,
              !defaults.hasFailure(forKey: scopedKey(userID: userID))
        else { return false }
        return defaults.removeObject(forKey: scopedKey(userID: userID))
    }

    static func clear(userID: String, defaults: LocalPersistence = .standard) {
        defaults.removeObject(forKey: scopedKey(userID: userID))
    }
}

/// Every cursor accepted by `/api/state`. The plan uses its monotonic document
/// version; sessions/sets, external caches, and manual activities use the server
/// clock as their device-skew-safe watermark. External cursors activate only
/// when a P2 Worker explicitly declares version 2 change-cursor semantics and
/// every returned row has a comparable server timestamp. An active cursor
/// always uses a fixed overlap so rows committed at the edge are harmlessly
/// redelivered rather than lost.
struct StateSyncWatermarks: Codable, Equatable {
    static let overlapMilliseconds = 60_000
    static let fullReload = StateSyncWatermarks(
        planVersion: 0,
        setsSince: 0,
        eventsSince: 0,
        activitiesSince: 0,
        logSince: 0)

    let planVersion: Int
    let setsSince: Int
    let eventsSince: Int
    let activitiesSince: Int
    let logSince: Int

    static func next(after response: StateResponse) -> StateSyncWatermarks {
        let serverTime = max(0, response.server_time)
        let overlappedTime = serverTime >= overlapMilliseconds
            ? serverTime - overlapMilliseconds
            : 0
        let hasComparableSetVersions = response.sessions.allSatisfy {
            $0.updated_at != nil
        } && response.sets.allSatisfy { $0.updated_at != nil }
        let hasComparableActivityVersions =
            response.manualActivityCursorCapable
            && response.activities.allSatisfy { $0.updated_at != nil }
        let externalCursorsCapable =
            (response.externalSyncCursorsVersion ?? 0)
            >= StateResponse.externalSyncCursorsCapabilityVersion
        let hasComparableEventVersions = externalCursorsCapable
            && response.external_events.allSatisfy { $0.synced_at != nil }
        let hasComparableExternalActivityVersions = externalCursorsCapable
            && response.external_activities.allSatisfy {
                $0.synced_at != nil
            }
        return StateSyncWatermarks(
            planVersion: max(0, response.plan_version),
            setsSince: hasComparableSetVersions ? overlappedTime : 0,
            eventsSince: hasComparableEventVersions ? overlappedTime : 0,
            activitiesSince: hasComparableExternalActivityVersions
                ? overlappedTime : 0,
            logSince: hasComparableActivityVersions ? overlappedTime : 0)
    }
}

/// Process-persistent identity of the account whose sync cursor was most
/// recently active. Per-account snapshots remain isolated, but crossing from
/// one account to another deliberately forces a full reload before that
/// account resumes incremental pulls. Relaunching the same account keeps its
/// cursor.
enum StateSyncAccountStore {
    static let activeAccountKey =
        "com.nmarkspdx.liftcoach.state-sync-active-account.v1"

    @discardableResult
    static func activate(
        userID: String?,
        defaults: LocalPersistence = .standard
    ) -> Bool {
        guard let userID else { return true }
        let previous = defaults.string(forKey: activeAccountKey)
        defaults.set(userID, forKey: activeAccountKey)
        return previous != userID
    }

    static func clearIfActive(
        userID: String,
        defaults: LocalPersistence = .standard
    ) {
        guard defaults.string(forKey: activeAccountKey) == userID else { return }
        defaults.removeObject(forKey: activeAccountKey)
    }
}

/// Exercise metadata is a separate read model from `/api/state`, but History
/// needs it to interpret cached sets (bodyweight, unilateral, and per-hand
/// volume) after a cold offline launch. A successful live catalog response
/// replaces this account-scoped snapshot; failures leave the last good rows
/// intact for presentation.
enum ExerciseCatalogSnapshotStore {
    static func scopedKey(userID: String) -> String {
        "com.nmarkspdx.liftcoach.exercise-catalog-snapshot.v1.\(userID)"
    }

    static func load(
        userID: String?,
        defaults: LocalPersistence = .standard
    ) -> [ExerciseCatalog]? {
        guard let userID,
              let data = defaults.data(forKey: scopedKey(userID: userID))
        else { return nil }
        return try? JSONDecoder().decode([ExerciseCatalog].self, from: data)
    }

    static func save(
        _ catalog: [ExerciseCatalog],
        userID: String?,
        defaults: LocalPersistence = .standard
    ) {
        guard let userID,
              let data = try? JSONEncoder().encode(catalog)
        else { return }
        defaults.set(data, forKey: scopedKey(userID: userID))
    }

    static func clear(userID: String, defaults: LocalPersistence = .standard) {
        defaults.removeObject(forKey: scopedKey(userID: userID))
    }
}
