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
        defaults: UserDefaults = .standard
    ) -> Bool {
        guard let userID else { return true }
        let previous = defaults.string(forKey: activeAccountKey)
        defaults.set(userID, forKey: activeAccountKey)
        return previous != userID
    }

    static func clearIfActive(
        userID: String,
        defaults: UserDefaults = .standard
    ) {
        guard defaults.string(forKey: activeAccountKey) == userID else { return }
        defaults.removeObject(forKey: activeAccountKey)
    }
}

/// Last authoritative account state: normally the merge of a `/api/state`
/// response into the prior snapshot, and synchronously advanced by an accepted
/// set/terminal response before its durable intent is removed. It renders
/// useful read-only data while the first live pull is unavailable; outbox
/// acknowledgement and runner resume still never trust this cache.
struct StateSnapshotTicket: Equatable {
    fileprivate let userID: String
    fileprivate let revision: UInt64
    fileprivate let mutationGeneration: UInt64
    let watermarks: StateSyncWatermarks
}

struct StateSnapshotValue {
    let revision: UInt64
    let state: StateResponse
    let watermarks: StateSyncWatermarks?
    let setsCommittedThrough: Int?
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
        /// Revision of the newest full-state reservation. ACK/invalidation
        /// revisions preserve this value so a superseded request can tell a
        /// mutation apart from a genuinely newer full pull.
        let latestFullRequestRevision: UInt64?
        let mutationGeneration: UInt64?
        /// Nil on legacy, invalidated, and explicitly full-reload snapshots.
        /// The state may still be retained for offline presentation.
        let watermarks: StateSyncWatermarks?
        /// Request-start server horizon through which the last committed state
        /// pull authoritatively observed set mutations.
        let setsCommittedThrough: Int?
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
        return StateSnapshotValue(
            revision: stored.revision,
            state: state,
            watermarks: stored.watermarks,
            setsCommittedThrough: stored.setsCommittedThrough)
    }

    /// Reserve ordering before a state request starts. Reserving retains
    /// the prior snapshot for offline presentation but invalidates every older
    /// request ticket, even if this newer request later fails.
    static func reserveStateRequest(
        userID: String?,
        defaults: UserDefaults = .standard
    ) -> StateSnapshotTicket? {
        guard let userID else { return nil }
        let current = storedSnapshot(userID: userID, defaults: defaults)
            ?? StoredStateSnapshot(
                revision: 0, state: nil, invalidated: false,
                latestFullRequestRevision: nil,
                mutationGeneration: 0,
                watermarks: nil,
                setsCommittedThrough: nil)
        let watermarks = current.invalidated == true || current.state == nil
            ? .fullReload
            : current.watermarks ?? .fullReload
        return reserveStateRequest(
            userID: userID,
            current: current,
            watermarks: watermarks,
            defaults: defaults)
    }

    /// Direct applications and compatibility tests intentionally represent a
    /// complete server snapshot, regardless of any stored cursor.
    static func reserveFullStateRequest(
        userID: String?,
        defaults: UserDefaults = .standard
    ) -> StateSnapshotTicket? {
        guard let userID else { return nil }
        let current = storedSnapshot(userID: userID, defaults: defaults)
            ?? StoredStateSnapshot(
                revision: 0, state: nil, invalidated: false,
                latestFullRequestRevision: nil,
                mutationGeneration: 0,
                watermarks: nil,
                setsCommittedThrough: nil)
        return reserveStateRequest(
            userID: userID,
            current: current,
            watermarks: .fullReload,
            defaults: defaults)
    }

    private static func reserveStateRequest(
        userID: String,
        current: StoredStateSnapshot,
        watermarks: StateSyncWatermarks,
        defaults: UserDefaults
    ) -> StateSnapshotTicket? {
        guard current.revision < UInt64.max else { return nil }
        let reserved = StoredStateSnapshot(
            revision: current.revision + 1,
            state: current.state,
            invalidated: current.invalidated,
            latestFullRequestRevision: current.revision + 1,
            mutationGeneration: current.mutationGeneration ?? 0,
            watermarks: current.watermarks,
            setsCommittedThrough: current.setsCommittedThrough)
        guard write(reserved, userID: userID, defaults: defaults) else {
            return nil
        }
        return StateSnapshotTicket(
            userID: userID,
            revision: reserved.revision,
            mutationGeneration: reserved.mutationGeneration ?? 0,
            watermarks: watermarks)
    }

    static func isCurrent(
        _ ticket: StateSnapshotTicket,
        defaults: UserDefaults = .standard
    ) -> Bool {
        storedSnapshot(userID: ticket.userID, defaults: defaults)?.revision
            == ticket.revision
    }

    /// True only when an ACK/invalidation advanced this exact latest full
    /// request. A later full-state reservation is different: newest request
    /// wins, and the older caller must not issue a trailing pull that can
    /// overtake it.
    static func wasSupersededByMutation(
        _ ticket: StateSnapshotTicket,
        defaults: UserDefaults = .standard
    ) -> Bool {
        guard let current = storedSnapshot(
            userID: ticket.userID, defaults: defaults)
        else { return false }
        return (current.mutationGeneration ?? 0) > ticket.mutationGeneration
            && current.latestFullRequestRevision == ticket.revision
    }

    /// A response may replace the snapshot only while its request ticket
    /// still owns the account revision. `server_time` is the backend's
    /// request-start watermark for future cursors, while ticket ordering remains
    /// the authoritative client-side newest-request-wins boundary.
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
        _ response: StateResponse,
        ticket: StateSnapshotTicket,
        defaults: UserDefaults = .standard
    ) -> StateSnapshotValue? {
        guard ticket.watermarks == .fullReload else { return nil }
        return commitStateResponse(
            response, ticket: ticket, defaults: defaults)
    }

    /// Atomically merge a state response and advance every cursor. A delta can
    /// commit only against the exact snapshot from which its request cursors
    /// were reserved; acknowledgement/invalidation/newer-pull revisions reject
    /// it before either data or watermarks move.
    @discardableResult
    static func commitStateResponse(
        _ response: StateResponse,
        ticket: StateSnapshotTicket,
        defaults: UserDefaults = .standard
    ) -> StateSnapshotValue? {
        guard isCurrent(ticket, defaults: defaults),
              let current = storedSnapshot(
                  userID: ticket.userID, defaults: defaults),
              let state = mergedState(
                  current: current.state,
                  response: response,
                  watermarks: ticket.watermarks)
        else { return nil }
        let nextWatermarks = StateSyncWatermarks.next(after: response)
        let stored = StoredStateSnapshot(
            revision: ticket.revision,
            state: state,
            invalidated: false,
            latestFullRequestRevision: ticket.revision,
            mutationGeneration: ticket.mutationGeneration,
            watermarks: nextWatermarks,
            setsCommittedThrough: response.server_time)
        guard write(stored, userID: ticket.userID, defaults: defaults) else {
            return nil
        }
        return StateSnapshotValue(
            revision: ticket.revision,
            state: state,
            watermarks: nextWatermarks,
            setsCommittedThrough: response.server_time)
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
                revision: 0, state: nil, invalidated: false,
                latestFullRequestRevision: nil,
                mutationGeneration: 0,
                watermarks: nil,
                setsCommittedThrough: nil)
        // A successful mutation such as set deletion can prove that every
        // cached full state is stale without returning enough data to rebuild
        // it. Until a new full response commits, never let a delayed ACK
        // recreate that invalidated cache from its model-local fallback.
        guard current.invalidated != true || current.state != nil else {
            return nil
        }
        let mutationGeneration = current.mutationGeneration ?? 0
        guard current.revision < UInt64.max,
              mutationGeneration < UInt64.max
        else { return nil }
        let state = transform(current.state ?? fallback)
        let stored = StoredStateSnapshot(
            revision: current.revision + 1,
            state: state,
            invalidated: false,
            latestFullRequestRevision: current.latestFullRequestRevision,
            mutationGeneration: mutationGeneration + 1,
            watermarks: current.watermarks,
            setsCommittedThrough: current.setsCommittedThrough)
        guard write(stored, userID: userID, defaults: defaults) else {
            return nil
        }
        return StateSnapshotValue(
            revision: stored.revision,
            state: state,
            watermarks: stored.watermarks,
            setsCommittedThrough: stored.setsCommittedThrough)
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
                revision: 0, state: nil, invalidated: false,
                latestFullRequestRevision: nil,
                mutationGeneration: 0,
                watermarks: nil,
                setsCommittedThrough: nil)
        let mutationGeneration = current.mutationGeneration ?? 0
        guard current.revision < UInt64.max,
              mutationGeneration < UInt64.max
        else { return false }
        return write(
            StoredStateSnapshot(
                revision: current.revision + 1,
                state: nil,
                invalidated: true,
                latestFullRequestRevision: current.latestFullRequestRevision,
                mutationGeneration: mutationGeneration + 1,
                watermarks: nil,
                setsCommittedThrough: nil),
            userID: userID,
            defaults: defaults)
    }

    /// Retain browse-only data across an account switch while ensuring the next
    /// authenticated pull sends explicit zero cursors. Advancing the mutation
    /// generation also invalidates a request that crossed the boundary.
    @discardableResult
    static func requireFullReload(
        userID: String?,
        defaults: UserDefaults = .standard
    ) -> Bool {
        guard let userID,
              let current = storedSnapshot(userID: userID, defaults: defaults)
        else { return true }
        let mutationGeneration = current.mutationGeneration ?? 0
        guard current.revision < UInt64.max,
              mutationGeneration < UInt64.max
        else { return false }
        return write(
            StoredStateSnapshot(
                revision: current.revision + 1,
                state: current.state,
                invalidated: current.invalidated,
                latestFullRequestRevision: current.latestFullRequestRevision,
                mutationGeneration: mutationGeneration + 1,
                watermarks: nil,
                setsCommittedThrough: current.setsCommittedThrough),
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
                revision: 0, state: legacy, invalidated: false,
                latestFullRequestRevision: nil,
                mutationGeneration: 0,
                watermarks: nil,
                setsCommittedThrough: nil)
        }
        return nil
    }

    private static func mergedState(
        current: StateResponse?,
        response: StateResponse,
        watermarks: StateSyncWatermarks
    ) -> StateResponse? {
        let isComplete = watermarks == .fullReload
        guard isComplete || current != nil else { return nil }
        let baseline = current ?? response
        let plan = watermarks.planVersion == 0
            ? response.plan
            : response.plan ?? baseline.plan
        let sessions = watermarks.setsSince == 0
            ? response.sessions
            : mergeRows(baseline.sessions, response.sessions, id: { $0.id })
        let sets = mergeRows(
            watermarks.setsSince == 0 ? [] : baseline.sets,
            response.sets,
            id: { $0.id },
            isTombstone: { $0.deleted_at != nil },
            retainTombstones: true)
        let events = mergeRows(
            watermarks.eventsSince == 0 ? [] : baseline.external_events,
            response.external_events,
            id: { $0.id },
            isTombstone: { $0.deleted_at != nil })
        let externalActivities = mergeRows(
            watermarks.activitiesSince == 0
                ? [] : baseline.external_activities,
            response.external_activities,
            id: { $0.id },
            isTombstone: { $0.deleted_at != nil })
        let activities = mergeRows(
            watermarks.logSince == 0 ? [] : baseline.activities,
            response.activities,
            id: { $0.id },
            isTombstone: { $0.deleted_at != nil })
        return StateResponse(
            plan: plan,
            plan_version: response.plan_version,
            sessions: sessions,
            sets: sets,
            external_events: events,
            external_activities: externalActivities,
            activities: activities,
            server_time: response.server_time,
            manualActivityCursorCapable:
                response.manualActivityCursorCapable,
            externalSyncCursorsVersion:
                response.externalSyncCursorsVersion)
    }

    /// Stable id-based upsert. Replaying an overlap response replaces the same
    /// slot in place. Most collections consume tombstones as removals; set logs
    /// retain their newest raw tombstone so delayed live ACKs can be ordered
    /// safely across relaunches before the presentation layer filters them.
    private static func mergeRows<Row, ID: Hashable>(
        _ current: [Row],
        _ delta: [Row],
        id: (Row) -> ID,
        isTombstone: (Row) -> Bool = { _ in false },
        retainTombstones: Bool = false
    ) -> [Row] {
        // Normalize any legacy/corrupt duplicate IDs while preserving the
        // first-observed order and newest value. This keeps a recoverable cache
        // from becoming a process-crashing precondition for delta sync.
        var rows: [Row] = []
        var indexes: [ID: Int] = [:]
        for row in current {
            let rowID = id(row)
            if let index = indexes[rowID] {
                rows[index] = row
            } else {
                indexes[rowID] = rows.count
                rows.append(row)
            }
        }
        for row in delta {
            let rowID = id(row)
            if isTombstone(row) {
                if retainTombstones, let index = indexes[rowID] {
                    rows[index] = row
                } else if retainTombstones {
                    indexes[rowID] = rows.count
                    rows.append(row)
                } else if let index = indexes[rowID] {
                    rows.remove(at: index)
                    indexes.removeAll(keepingCapacity: true)
                    for (offset, remaining) in rows.enumerated() {
                        indexes[id(remaining)] = offset
                    }
                }
            } else if let index = indexes[rowID] {
                rows[index] = row
            } else {
                indexes[rowID] = rows.count
                rows.append(row)
            }
        }
        return rows
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
