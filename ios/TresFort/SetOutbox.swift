import Foundation

/// The immutable body of one user set-log intent. `id` is both the local
/// identity and the Worker's idempotency key; `logged_at` is captured at tap
/// time. Neither value is regenerated while retrying.
struct SetRequestBody: Codable, Equatable {
    let id: String
    let exercise_id: String
    let template_exercise_id: String
    let set_index: Int
    let weight: Double
    let reps: Int
    let is_warmup: Bool
    let logged_at: Int
    let duration_s: Int?
    let is_timed: Bool
}

enum SetIntentDeliveryState: String, Codable, Equatable {
    /// Includes writes waiting for their first attempt and transient/401
    /// failures. A relaunch always resumes these with the same request body.
    case queued
    /// A non-401 4xx is not retryable automatically, but the intent remains
    /// visible until the user explicitly retries it.
    case failed
}

/// Small durable envelope around the immutable request body. Session creation
/// is itself networked, so an unresolved intent carries enough information to
/// create/recover that day's canonical session after relaunch.
struct PendingSetIntent: Codable, Identifiable, Equatable {
    let body: SetRequestBody
    let date: String
    var dayTemplateID: String?
    var resolvedSessionID: String?
    var deliveryState: SetIntentDeliveryState
    var failedHTTPStatus: Int?

    var id: String { body.id }
    var slotID: String { body.template_exercise_id }
}

/// Account-local FIFO. Acknowledged `SetLog` rows never live here; the model
/// removes an intent only after the Worker acknowledges the id (including a
/// deduped acknowledgement).
struct SetOutbox: Codable, Equatable {
    private(set) var pending: [PendingSetIntent] = []

    mutating func enqueue(_ intent: PendingSetIntent) {
        guard !pending.contains(where: { $0.id == intent.id }) else { return }
        pending.append(intent)
    }

    mutating func replace(_ intent: PendingSetIntent) {
        guard let index = pending.firstIndex(where: { $0.id == intent.id }) else {
            return
        }
        pending[index] = intent
    }

    mutating func remove(id: String) {
        pending.removeAll { $0.id == id }
    }

    var isEmpty: Bool { pending.isEmpty }
    var count: Int { pending.count }
}

/// UserDefaults persistence is deliberately narrow and account-scoped. Writes
/// are synchronous at the call site and always happen before the first network
/// `await`, which closes the app-kill window between a tap and session creation.
enum SetOutboxStore {
    static func scopedKey(userID: String) -> String {
        "com.nmarkspdx.liftcoach.set-outbox.v1.\(userID)"
    }

    static func load(
        userID: String?,
        defaults: UserDefaults = .standard
    ) -> SetOutbox {
        guard let userID,
              let data = defaults.data(forKey: scopedKey(userID: userID))
        else { return SetOutbox() }
        return (try? JSONDecoder().decode(SetOutbox.self, from: data))
            ?? SetOutbox()
    }

    static func save(
        _ outbox: SetOutbox,
        userID: String?,
        defaults: UserDefaults = .standard
    ) {
        guard let userID,
              let data = try? JSONEncoder().encode(outbox)
        else { return }
        defaults.set(data, forKey: scopedKey(userID: userID))
    }

    /// Intent-granular updates prevent a stale SyncModel generation from
    /// replacing a newer same-account model's whole queue after reauth.
    /// `replace` and `remove` deliberately never insert a missing id, so a
    /// late callback cannot recreate a queue cleared by confirmed deletion.
    static func enqueue(
        _ intent: PendingSetIntent,
        userID: String?,
        defaults: UserDefaults = .standard
    ) {
        update(userID: userID, defaults: defaults) { $0.enqueue(intent) }
    }

    static func replace(
        _ intent: PendingSetIntent,
        userID: String?,
        defaults: UserDefaults = .standard
    ) {
        update(userID: userID, defaults: defaults) { $0.replace(intent) }
    }

    static func remove(
        ids: Set<String>,
        userID: String?,
        defaults: UserDefaults = .standard
    ) {
        guard !ids.isEmpty else { return }
        update(userID: userID, defaults: defaults) { outbox in
            for id in ids { outbox.remove(id: id) }
        }
    }

    private static func update(
        userID: String?,
        defaults: UserDefaults,
        mutation: (inout SetOutbox) -> Void
    ) {
        guard let userID else { return }
        var current = load(userID: userID, defaults: defaults)
        let previous = current
        mutation(&current)
        guard current != previous else { return }
        if current.isEmpty {
            clear(userID: userID, defaults: defaults)
        } else {
            save(current, userID: userID, defaults: defaults)
        }
    }

    static func clear(userID: String, defaults: UserDefaults = .standard) {
        defaults.removeObject(forKey: scopedKey(userID: userID))
    }
}
