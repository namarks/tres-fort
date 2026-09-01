import Foundation

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

    init(
        date: String,
        sessionID: String?,
        selectedDayID: String,
        currentSlotID: String?,
        skippedSlotIDs: [String],
        workoutStartedAtMS: Int,
        finished: Bool,
        sessionAttempt: Int? = nil,
        restartDiscardedAttempt: Int? = nil
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
    }
}

enum WorkoutRunnerCheckpointStore {
    static func scopedKey(userID: String) -> String {
        "com.nmarkspdx.liftcoach.workout-runner-checkpoint.v1.\(userID)"
    }

    static func load(
        userID: String?,
        defaults: UserDefaults = .standard
    ) -> WorkoutRunnerCheckpoint? {
        guard let userID,
              let data = defaults.data(forKey: scopedKey(userID: userID))
        else { return nil }
        return try? JSONDecoder().decode(WorkoutRunnerCheckpoint.self, from: data)
    }

    static func save(
        _ checkpoint: WorkoutRunnerCheckpoint,
        userID: String?,
        defaults: UserDefaults = .standard
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
        defaults: UserDefaults = .standard
    ) -> Bool {
        guard let userID,
              load(userID: userID, defaults: defaults) == expected,
              let data = try? JSONEncoder().encode(checkpoint)
        else { return false }
        defaults.set(data, forKey: scopedKey(userID: userID))
        return true
    }

    /// Conditional clear pairs with `replace`: validation performed by an old
    /// model can clear only the exact checkpoint that model originally read.
    @discardableResult
    static func clear(
        ifCurrent expected: WorkoutRunnerCheckpoint?,
        userID: String?,
        defaults: UserDefaults = .standard
    ) -> Bool {
        guard let userID,
              load(userID: userID, defaults: defaults) == expected
        else { return false }
        defaults.removeObject(forKey: scopedKey(userID: userID))
        return true
    }

    static func clear(userID: String, defaults: UserDefaults = .standard) {
        defaults.removeObject(forKey: scopedKey(userID: userID))
    }
}

/// Last authoritative account state: normally a full `/api/state` response,
/// and synchronously advanced by an accepted set/terminal response before its
/// durable intent is removed. It renders useful read-only data while the first
/// live pull is unavailable; outbox acknowledgement and runner resume still
/// never trust this cache.
struct StateSnapshotTicket: Equatable {
    fileprivate let userID: String
    fileprivate let revision: UInt64
}

struct StateSnapshotValue {
    let revision: UInt64
    let state: StateResponse
}

/// Main-actor serialization is the cross-model ordering boundary. Multiple
/// SyncModel instances for one signed-in account share this envelope, so an
/// old model cannot overwrite a newer model's cache after reauthentication.
@MainActor
enum StateSnapshotStore {
    private struct StoredStateSnapshot: Codable {
        let revision: UInt64
        let state: StateResponse?
        let invalidated: Bool?
    }

    static func scopedKey(userID: String) -> String {
        "com.nmarkspdx.liftcoach.state-snapshot.v1.\(userID)"
    }

    static func load(
        userID: String?,
        defaults: UserDefaults = .standard
    ) -> StateSnapshotValue? {
        guard let userID,
              let stored = storedSnapshot(userID: userID, defaults: defaults),
              let state = stored.state
        else { return nil }
        return StateSnapshotValue(revision: stored.revision, state: state)
    }

    /// Reserve ordering before a full-state request starts. Reserving retains
    /// the prior snapshot for offline presentation but invalidates every older
    /// request ticket, even if this newer request later fails.
    static func reserveFullStateRequest(
        userID: String?,
        defaults: UserDefaults = .standard
    ) -> StateSnapshotTicket? {
        guard let userID else { return nil }
        let current = storedSnapshot(userID: userID, defaults: defaults)
            ?? StoredStateSnapshot(
                revision: 0, state: nil, invalidated: false)
        guard current.revision < UInt64.max else { return nil }
        let reserved = StoredStateSnapshot(
            revision: current.revision + 1,
            state: current.state,
            invalidated: current.invalidated)
        guard write(reserved, userID: userID, defaults: defaults) else {
            return nil
        }
        return StateSnapshotTicket(
            userID: userID, revision: reserved.revision)
    }

    static func isCurrent(
        _ ticket: StateSnapshotTicket,
        defaults: UserDefaults = .standard
    ) -> Bool {
        storedSnapshot(userID: ticket.userID, defaults: defaults)?.revision
            == ticket.revision
    }

    /// A full response may replace the snapshot only while its request ticket
    /// still owns the account revision. `server_time` is payload metadata, not
    /// an ordering token: the backend stamps it after sequential reads.
    static func save(
        _ state: StateResponse,
        userID: String?,
        defaults: UserDefaults = .standard
    ) {
        guard let ticket = reserveFullStateRequest(
            userID: userID, defaults: defaults)
        else { return }
        _ = commitFullState(state, ticket: ticket, defaults: defaults)
    }

    @discardableResult
    static func commitFullState(
        _ state: StateResponse,
        ticket: StateSnapshotTicket,
        defaults: UserDefaults = .standard
    ) -> StateSnapshotValue? {
        guard isCurrent(ticket, defaults: defaults) else { return nil }
        let stored = StoredStateSnapshot(
            revision: ticket.revision, state: state, invalidated: false)
        guard write(stored, userID: ticket.userID, defaults: defaults) else {
            return nil
        }
        return StateSnapshotValue(revision: ticket.revision, state: state)
    }

    /// Accepted mutation responses have no full-state ticket. Advance the
    /// shared revision and transform the newest stored snapshot (not the
    /// calling model's potentially stale projection) in one main-actor turn.
    @discardableResult
    static func mergeAcknowledgement(
        userID: String?,
        fallback: StateResponse,
        defaults: UserDefaults = .standard,
        transform: (StateResponse) -> StateResponse
    ) -> StateSnapshotValue? {
        guard let userID else { return nil }
        let current = storedSnapshot(userID: userID, defaults: defaults)
            ?? StoredStateSnapshot(
                revision: 0, state: nil, invalidated: false)
        // A successful mutation such as set deletion can prove that every
        // cached full state is stale without returning enough data to rebuild
        // it. Until a new full response commits, never let a delayed ACK
        // recreate that invalidated cache from its model-local fallback.
        guard current.invalidated != true || current.state != nil else {
            return nil
        }
        guard current.revision < UInt64.max else { return nil }
        let state = transform(current.state ?? fallback)
        let stored = StoredStateSnapshot(
            revision: current.revision + 1,
            state: state,
            invalidated: false)
        guard write(stored, userID: userID, defaults: defaults) else {
            return nil
        }
        return StateSnapshotValue(revision: stored.revision, state: state)
    }

    /// Advance the shared ordering revision while removing presentation data.
    /// Outstanding full pulls and delayed ACK fallbacks are both rejected.
    @discardableResult
    static func invalidate(
        userID: String?,
        defaults: UserDefaults = .standard
    ) -> Bool {
        guard let userID else { return false }
        let current = storedSnapshot(userID: userID, defaults: defaults)
            ?? StoredStateSnapshot(
                revision: 0, state: nil, invalidated: false)
        guard current.revision < UInt64.max else { return false }
        return write(
            StoredStateSnapshot(
                revision: current.revision + 1,
                state: nil,
                invalidated: true),
            userID: userID,
            defaults: defaults)
    }

    static func clear(userID: String, defaults: UserDefaults = .standard) {
        defaults.removeObject(forKey: scopedKey(userID: userID))
    }

    private static func storedSnapshot(
        userID: String,
        defaults: UserDefaults
    ) -> StoredStateSnapshot? {
        guard let data = defaults.data(forKey: scopedKey(userID: userID)) else {
            return nil
        }
        if let stored = try? JSONDecoder().decode(
            StoredStateSnapshot.self, from: data)
        {
            return stored
        }
        // In-place v1 migration: the previous implementation stored a raw
        // StateResponse at this same account-scoped key.
        if let legacy = try? JSONDecoder().decode(StateResponse.self, from: data) {
            return StoredStateSnapshot(
                revision: 0, state: legacy, invalidated: false)
        }
        return nil
    }

    private static func write(
        _ stored: StoredStateSnapshot,
        userID: String,
        defaults: UserDefaults
    ) -> Bool {
        guard let data = try? JSONEncoder().encode(stored) else { return false }
        defaults.set(data, forKey: scopedKey(userID: userID))
        return true
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
        defaults: UserDefaults = .standard
    ) -> [ExerciseCatalog]? {
        guard let userID,
              let data = defaults.data(forKey: scopedKey(userID: userID))
        else { return nil }
        return try? JSONDecoder().decode([ExerciseCatalog].self, from: data)
    }

    static func save(
        _ catalog: [ExerciseCatalog],
        userID: String?,
        defaults: UserDefaults = .standard
    ) {
        guard let userID,
              let data = try? JSONEncoder().encode(catalog)
        else { return }
        defaults.set(data, forKey: scopedKey(userID: userID))
    }

    static func clear(userID: String, defaults: UserDefaults = .standard) {
        defaults.removeObject(forKey: scopedKey(userID: userID))
    }
}
