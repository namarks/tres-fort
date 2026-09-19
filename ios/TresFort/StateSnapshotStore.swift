import Foundation

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

/// Last authoritative account state: normally the merge of a `/api/state`
/// response into the prior snapshot, and synchronously advanced by an accepted
/// set/terminal response before its durable intent is removed. It renders
/// useful read-only data while the first live pull is unavailable; outbox
/// acknowledgement and runner resume still never trust this cache.
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
        /// A current-ticket live response certified this exact stored plan.
        /// Absent on legacy caches, ACK-only fallbacks and invalidation markers.
        /// Keep separate from StateResponse's wire claim: decoding cached data
        /// must never upgrade a former sequential compatibility projection.
        var planGroupsVersion: Int? = nil
    }

    /// One live envelope, shared by models using the same defaults object.
    /// Always compare persisted bytes first: another defaults instance/process,
    /// deletion, corruption or a legacy writer must supersede this read cache.
    /// When packing exceeds the platform limit, rows stay here while `data`
    /// contains only the durable invalidation/ordering marker. This lets all
    /// mutation paths transform the latest live rows without trusting a stale
    /// model fallback. A cold process sees only the marker and must reload.
    /// Weak ownership and a single slot bound lifetime and account retention.
    private final class DecodedCache {
        weak var defaults: LocalPersistence?
        let userID: String
        let data: Data
        let stored: StoredStateSnapshot
        init(defaults: LocalPersistence, userID: String, data: Data, stored: StoredStateSnapshot) {
            self.defaults = defaults
            self.userID = userID
            self.data = data
            self.stored = stored
        }
    }
    private static var decodedCache: DecodedCache?

    // Preserve the shipped codec's bounded envelope and JSON schema during
    // the storage migration. Larger envelopes use a versioned lossless LZFSE
    // wrapper; legacy plain JSON remains readable.
    private static let compressionPrefix = Data("TFSS1\0".utf8)
    private static let maximumStoredBytes = 4 * 1_024 * 1_024

    static func encodedEnvelope(_ json: Data) -> Data? {
        if json.count < 256 * 1_024 { return json }
        guard let compressed = try? (json as NSData).compressed(using: .lzfse) as Data else { return nil }
        let wrapped = compressionPrefix + compressed
        guard wrapped.count < maximumStoredBytes else { return nil }
        return wrapped
    }

    static func decodedEnvelope(_ stored: Data) -> Data? {
        guard stored.starts(with: compressionPrefix) else { return stored }
        let compressed = Data(stored.dropFirst(compressionPrefix.count))
        return try? (compressed as NSData).decompressed(using: .lzfse) as Data
    }


    static func scopedKey(userID: String) -> String {
        "com.nmarkspdx.liftcoach.state-snapshot.v1.\(userID)"
    }

    static func load(
        userID: String?,
        defaults: LocalPersistence = .standard
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
        defaults: LocalPersistence = .standard
    ) -> StateSnapshotTicket? {
        guard let userID else { return nil }
        let current = storedSnapshot(userID: userID, defaults: defaults)
            ?? StoredStateSnapshot(
                revision: 0, state: nil, invalidated: false,
                latestFullRequestRevision: nil,
                mutationGeneration: 0,
                watermarks: nil,
                setsCommittedThrough: nil)
        let storedWatermarks: StateSyncWatermarks = current.invalidated == true || current.state == nil
            ? .fullReload
            : current.watermarks ?? .fullReload
        var watermarks = groupAwareWatermarks(
            storedWatermarks, certifiedVersion: current.planGroupsVersion)
        // A released app hid active freestyle sessions and their sets. A new
        // capability needs one complete session/set baseline, not a delta that
        // skips hidden rows behind the old cursor. Only a live response certifies it.
        if (current.state?.freestyleVersion ?? 0) < 1 {
            watermarks = StateSyncWatermarks(
                planVersion: watermarks.planVersion, setsSince: 0,
                eventsSince: watermarks.eventsSince, activitiesSince: watermarks.activitiesSince,
                logSince: watermarks.logSince)
        }
        // Older snapshots predate source attribution. Re-fetch this collection
        // once even when unchanged provider rows sit behind the delta cursor.
        if current.state?.external_activities.contains(where: { ($0.attribution_version ?? 0) < 1 }) == true {
            watermarks = StateSyncWatermarks(
                planVersion: watermarks.planVersion, setsSince: watermarks.setsSince,
                eventsSince: watermarks.eventsSince, activitiesSince: 0,
                logSince: watermarks.logSince)
        }
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
        defaults: LocalPersistence = .standard
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
        defaults: LocalPersistence
    ) -> StateSnapshotTicket? {
        guard current.revision < UInt64.max else { return nil }
        let reserved = StoredStateSnapshot(
            revision: current.revision + 1,
            state: current.state,
            invalidated: current.invalidated,
            latestFullRequestRevision: current.revision + 1,
            mutationGeneration: current.mutationGeneration ?? 0,
            watermarks: current.watermarks,
            setsCommittedThrough: current.setsCommittedThrough,
            planGroupsVersion: current.planGroupsVersion)
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
        defaults: LocalPersistence = .standard
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
        defaults: LocalPersistence = .standard
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
        defaults: LocalPersistence = .standard
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
        defaults: LocalPersistence = .standard
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
        defaults: LocalPersistence = .standard
    ) -> StateSnapshotValue? {
        guard isCurrent(ticket, defaults: defaults),
              let current = storedSnapshot(
                  userID: ticket.userID, defaults: defaults),
              let state = mergedState(
                  current: current.state,
                  response: response,
                  watermarks: ticket.watermarks)
        else { return nil }
        let planGroupsVersion = committedPlanGroupsVersion(
            response: response, current: current, ticket: ticket)
        let nextWatermarks = groupAwareWatermarks(
            StateSyncWatermarks.next(after: response),
            certifiedVersion: planGroupsVersion)
        let stored = StoredStateSnapshot(
            revision: ticket.revision,
            state: state,
            invalidated: false,
            latestFullRequestRevision: ticket.revision,
            mutationGeneration: ticket.mutationGeneration,
            watermarks: nextWatermarks,
            setsCommittedThrough: response.server_time,
            planGroupsVersion: planGroupsVersion)
        guard write(stored, userID: ticket.userID, defaults: defaults) else { return nil }
        return load(userID: ticket.userID, defaults: defaults)
    }

    /// Accepted mutation responses have no full-state ticket. Advance the
    /// shared revision and transform the newest stored snapshot (not the
    /// calling model's potentially stale projection) in one main-actor turn.
    @discardableResult
    static func mergeAcknowledgement(
        userID: String?,
        fallback: StateResponse,
        defaults: LocalPersistence = .standard,
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
        let samePlan = current.state?.plan == state.plan
            && current.state?.plan_version == state.plan_version
        let planGroupsVersion = samePlan ? current.planGroupsVersion : nil
        let stored = StoredStateSnapshot(
            revision: current.revision + 1,
            state: state,
            invalidated: false,
            latestFullRequestRevision: current.latestFullRequestRevision,
            mutationGeneration: mutationGeneration + 1,
            watermarks: current.watermarks.map {
                groupAwareWatermarks($0, certifiedVersion: planGroupsVersion)
            },
            setsCommittedThrough: current.setsCommittedThrough,
            planGroupsVersion: planGroupsVersion)
        guard write(stored, userID: userID, defaults: defaults) else {
            return nil
        }
        return load(userID: userID, defaults: defaults)
    }

    /// Advance the shared ordering revision while removing presentation data.
    /// Outstanding full pulls and delayed ACK fallbacks are both rejected.
    @discardableResult
    static func invalidate(
        userID: String?,
        defaults: LocalPersistence = .standard
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
        defaults: LocalPersistence = .standard
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

    @discardableResult
    static func clear(userID: String, defaults: LocalPersistence = .standard,
                      afterAccountDeletion: Bool = false) -> Bool {
        let erased: Bool
        if afterAccountDeletion {
            erased = defaults.eraseAfterAccountDeletion(forKey: scopedKey(userID: userID))
        } else {
            erased = defaults.removeObject(forKey: scopedKey(userID: userID))
        }
        if decodedCache?.userID == userID { decodedCache = nil }
        return erased
    }

    private static func storedSnapshot(
        userID: String,
        defaults: LocalPersistence
    ) -> StoredStateSnapshot? {
        guard let data = defaults.data(forKey: scopedKey(userID: userID)) else {
            decodedCache = nil
            return nil
        }
        if let cached = decodedCache, cached.defaults === defaults,
           cached.userID == userID, cached.data == data { return cached.stored }
        decodedCache = nil
        guard let json = decodedEnvelope(data) else { return nil }
        if let stored = try? JSONDecoder().decode(
            StoredStateSnapshot.self, from: json)
        {
            decodedCache = DecodedCache(defaults: defaults, userID: userID, data: data, stored: stored)
            return stored
        }
        // In-place v1 migration: the previous implementation stored a raw
        // StateResponse at this same account-scoped key.
        if let legacy = try? JSONDecoder().decode(StateResponse.self, from: json) {
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
        // A requested full plan must include its tree or explicitly report no
        // active plan. Do not erase the offline baseline or advance cursors on
        // a thin response that cannot satisfy a representation upgrade.
        guard watermarks.planVersion != 0 || response.plan != nil
            || response.plan_version == 0
        else { return nil }
        let baseline = current ?? response
        let plan = watermarks.planVersion == 0 || response.plan_version == 0
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
                response.externalSyncCursorsVersion,
            planGroupsVersion: response.planGroupsVersion, freestyleVersion: response.freestyleVersion)
    }

    /// A representation upgrade resets only the plan cursor. Other collections
    /// keep their independently committed cursors and overlap semantics.
    private static func groupAwareWatermarks(
        _ watermarks: StateSyncWatermarks, certifiedVersion: Int?
    ) -> StateSyncWatermarks {
        guard certifiedVersion == StateResponse.planGroupsCapabilityVersion else {
            return StateSyncWatermarks(
                planVersion: 0, setsSince: watermarks.setsSince,
                eventsSince: watermarks.eventsSince,
                activitiesSince: watermarks.activitiesSince,
                logSince: watermarks.logSince)
        }
        return watermarks
    }

    private static func committedPlanGroupsVersion(
        response: StateResponse,
        current: StoredStateSnapshot,
        ticket: StateSnapshotTicket
    ) -> Int? {
        let supported = StateResponse.planGroupsCapabilityVersion
        // Version zero is the server's authoritative absence of an active plan.
        if response.plan == nil && response.plan_version == 0 { return supported }
        if let plan = response.plan {
            guard (response.planGroupsVersion ?? 0) >= supported,
                  plan.version == response.plan_version,
                  response.plan_version > 0
            else { return nil }
            return supported
        }
        // A proof on a plan-less delta cannot bless an older flat cache. It may
        // only retain a certificate already attached to this unchanged plan.
        guard ticket.watermarks.planVersion != 0,
              response.plan_version == current.state?.plan_version
        else { return nil }
        return current.planGroupsVersion
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
        defaults: LocalPersistence
    ) -> Bool {
        guard let json = try? JSONEncoder().encode(stored) else { return false }
        let data: Data
        let live: StoredStateSnapshot
        if let packed = encodedEnvelope(json) {
            data = packed
            live = stored
        } else {
            guard let state = stored.state else { return false }
            // The durable marker preserves every ordering field, but never
            // claims a browse snapshot or delta cursors survived this write.
            let marker = StoredStateSnapshot(
                revision: stored.revision, state: nil, invalidated: true,
                latestFullRequestRevision: stored.latestFullRequestRevision,
                mutationGeneration: stored.mutationGeneration,
                watermarks: nil, setsCommittedThrough: nil)
            guard let markerData = try? JSONEncoder().encode(marker) else { return false }
            data = markerData
            live = StoredStateSnapshot(
                revision: stored.revision, state: state,
                invalidated: stored.invalidated,
                latestFullRequestRevision: stored.latestFullRequestRevision,
                mutationGeneration: stored.mutationGeneration,
                watermarks: nil, setsCommittedThrough: stored.setsCommittedThrough,
                planGroupsVersion: stored.planGroupsVersion)
        }
        guard defaults.set(data, forKey: scopedKey(userID: userID)) else { return false }
        decodedCache = DecodedCache(defaults: defaults, userID: userID, data: data, stored: live)
        return true
    }
}
