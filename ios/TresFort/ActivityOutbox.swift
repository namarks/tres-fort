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
        let key = scopedKey(userID: userID)
        // One-time upgrade: the legacy process-global queue belonged to the
        // account that is authenticated during migration. Move, don't copy,
        // so another Apple account can never inherit it later.
        if defaults.data(forKey: key) == nil,
           let legacy = defaults.data(forKey: legacyKey) {
            defaults.set(legacy, forKey: key)
            defaults.removeObject(forKey: legacyKey)
        }
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

    static func clear(userID: String, defaults: UserDefaults = .standard) {
        defaults.removeObject(forKey: scopedKey(userID: userID))
        // Defensive for an upgraded install that has not loaded/migrated the
        // legacy queue yet. Account deletion must not leave it for a future
        // Apple account to claim.
        defaults.removeObject(forKey: legacyKey)
    }
}
