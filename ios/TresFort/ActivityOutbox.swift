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

    /// Drop all entries (e.g. on sign-out — outbox is per-user-implicit
    /// because the UserDefaults key is process-global; this clears it).
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
    private static let key = "com.nmarkspdx.liftcoach.activity-outbox.v1"

    static func load() -> ActivityOutbox {
        guard let data = UserDefaults.standard.data(forKey: key) else {
            return ActivityOutbox()
        }
        return (try? JSONDecoder().decode(ActivityOutbox.self, from: data))
            ?? ActivityOutbox()
    }

    static func save(_ outbox: ActivityOutbox) {
        guard let data = try? JSONEncoder().encode(outbox) else { return }
        UserDefaults.standard.set(data, forKey: key)
    }

    /// Drop the persisted outbox entirely. Called on sign-out so a future
    /// sign-in (potentially a different Apple user) does not inherit the
    /// previous account's pending activity POSTs — those would otherwise
    /// drain through the next user's JWT and mis-attribute the rows.
    static func clear() {
        UserDefaults.standard.removeObject(forKey: key)
    }
}
