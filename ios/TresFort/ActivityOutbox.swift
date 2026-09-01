import Foundation

/// Tiny FIFO of pending `POST /api/activities` bodies. The only piece of
/// group-feature state that needs to survive an app kill: a gym session
/// logged on flaky WiFi must reach the server eventually.
///
/// POST /api/activities is idempotent on the row's client-generated UUID
/// (server dedups), so the same outbox entry can be retried any number of
/// times without producing duplicates. The outbox simply remembers WHAT
/// to send; GroupModel decides WHEN.
struct ActivityOutbox: Codable {
    private(set) var pending: [PendingActivity] = []

    /// Append a body to the tail of the queue.
    mutating func enqueue(_ activity: PendingActivity) {
        pending.append(activity)
    }

    /// Drop an entry by id (after a successful POST, or to give up).
    mutating func remove(id: String) {
        pending.removeAll { $0.id == id }
    }

    /// Drop all in-memory entries. Persisted queues are account-scoped and
    /// removed separately only when that account explicitly discards them.
    mutating func clear() {
        pending.removeAll()
    }

    /// Merge a legacy queue into an already-scoped queue without replaying an
    /// activity that was persisted in both locations during an interrupted
    /// app upgrade.
    mutating func merge(_ other: ActivityOutbox) {
        var knownIDs = Set(pending.map(\.id))
        for activity in other.pending where knownIDs.insert(activity.id).inserted {
            pending.append(activity)
        }
    }

    var isEmpty: Bool { pending.isEmpty }
    var count: Int { pending.count }
}

/// UserDefaults-backed persistence for the outbox. Encoded as a JSON blob
/// under a versioned key so a future schema bump can introduce v2 without
/// silently mis-decoding v1 entries.
enum ActivityOutboxStore {
    static let legacyKey = "com.nmarkspdx.liftcoach.activity-outbox.v1"

    static func scopedKey(userID: String) -> String {
        "com.nmarkspdx.liftcoach.activity-outbox.v2.\(userID)"
    }

    static func load(
        userID: String?,
        defaults: UserDefaults = .standard
    ) -> ActivityOutbox {
        guard let userID else { return ActivityOutbox() }
        bindLegacyState(userID: userID, defaults: defaults)
        let key = scopedKey(userID: userID)
        guard let data = defaults.data(forKey: key) else {
            return ActivityOutbox()
        }
        return (try? JSONDecoder().decode(ActivityOutbox.self, from: data))
            ?? ActivityOutbox()
    }

    static func save(
        _ outbox: ActivityOutbox,
        userID: String?,
        defaults: UserDefaults = .standard
    ) {
        guard let userID else { return }
        guard let data = try? JSONEncoder().encode(outbox) else { return }
        defaults.set(data, forKey: scopedKey(userID: userID))
    }

    /// Reload-before-mutate helpers prevent a stale GroupModel from replacing
    /// a newer same-account model's whole queue after reauthentication. The
    /// activity id is the server idempotency key, so enqueue never duplicates
    /// an existing id and a late acknowledgement removes only that exact row.
    static func enqueue(
        _ activity: PendingActivity,
        userID: String?,
        defaults: UserDefaults = .standard
    ) {
        update(userID: userID, defaults: defaults) { outbox in
            guard !outbox.pending.contains(where: { $0.id == activity.id })
            else { return }
            outbox.enqueue(activity)
        }
    }

    static func remove(
        id: String,
        userID: String?,
        defaults: UserDefaults = .standard
    ) {
        update(userID: userID, defaults: defaults) { $0.remove(id: id) }
    }

    private static func update(
        userID: String?,
        defaults: UserDefaults,
        mutation: (inout ActivityOutbox) -> Void
    ) {
        guard let userID else { return }
        var current = load(userID: userID, defaults: defaults)
        mutation(&current)
        if current.isEmpty {
            clear(userID: userID, defaults: defaults)
        } else {
            save(current, userID: userID, defaults: defaults)
        }
    }

    /// Bind the old process-global queue to its known account. This is called
    /// by AuthModel before it evaluates a saved bearer, because an unusable or
    /// mismatched bearer may otherwise be followed by a different Apple
    /// sign-in that could claim the first account's pending writes.
    static func bindLegacyState(
        userID: String,
        defaults: UserDefaults = .standard
    ) {
        guard let legacyData = defaults.data(forKey: legacyKey) else { return }
        let key = scopedKey(userID: userID)
        if let scopedData = defaults.data(forKey: key) {
            let decoder = JSONDecoder()
            if var scoped = try? decoder.decode(ActivityOutbox.self, from: scopedData),
               let legacy = try? decoder.decode(ActivityOutbox.self, from: legacyData) {
                scoped.merge(legacy)
                if let merged = try? JSONEncoder().encode(scoped) {
                    defaults.set(merged, forKey: key)
                }
            } else if (try? decoder.decode(ActivityOutbox.self, from: legacyData)) != nil {
                // A corrupt scoped value is unusable; retain the decodable
                // legacy queue under the correct account instead.
                defaults.set(legacyData, forKey: key)
            }
        } else {
            defaults.set(legacyData, forKey: key)
        }
        // Move, don't copy, so no later Apple account can inherit this queue.
        defaults.removeObject(forKey: legacyKey)
    }

    static func clear(userID: String, defaults: UserDefaults = .standard) {
        defaults.removeObject(forKey: scopedKey(userID: userID))
        // Defensive for an upgraded install that has not loaded/migrated the
        // legacy queue yet. Account deletion must not leave it for a future
        // Apple account to claim.
        defaults.removeObject(forKey: legacyKey)
    }
}
