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
    /// Attempt-scoped CAS token. Stored outbox envelopes own the durable value
    /// separately because the session may not exist when the tap is first
    /// saved; APIClient binds it into the otherwise immutable request on send.
    let expected_attempt: Int?

    init(
        id: String,
        exercise_id: String,
        template_exercise_id: String,
        set_index: Int,
        weight: Double,
        reps: Int,
        is_warmup: Bool,
        logged_at: Int,
        duration_s: Int?,
        is_timed: Bool,
        expected_attempt: Int? = nil
    ) {
        self.id = id
        self.exercise_id = exercise_id
        self.template_exercise_id = template_exercise_id
        self.set_index = set_index
        self.weight = weight
        self.reps = reps
        self.is_warmup = is_warmup
        self.logged_at = logged_at
        self.duration_s = duration_s
        self.is_timed = is_timed
        self.expected_attempt = expected_attempt
    }

    func scoped(to expectedAttempt: Int?) -> SetRequestBody {
        SetRequestBody(
            id: id,
            exercise_id: exercise_id,
            template_exercise_id: template_exercise_id,
            set_index: set_index,
            weight: weight,
            reps: reps,
            is_warmup: is_warmup,
            logged_at: logged_at,
            duration_s: duration_s,
            is_timed: is_timed,
            expected_attempt: expectedAttempt ?? expected_attempt)
    }
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
    /// Bound once the target session is known. Optional only for decoding
    /// queues written by older app builds / rolling old Worker responses.
    var expectedAttempt: Int?
    /// Prior discarded generation that the user explicitly chose to restart.
    /// Nil for ordinary unresolved writes, which must never revive a tombstone.
    let restartDiscardedAttempt: Int?
    var deliveryState: SetIntentDeliveryState
    var failedHTTPStatus: Int?

    init(
        body: SetRequestBody,
        date: String,
        dayTemplateID: String?,
        resolvedSessionID: String?,
        deliveryState: SetIntentDeliveryState,
        failedHTTPStatus: Int?,
        expectedAttempt: Int? = nil,
        restartDiscardedAttempt: Int? = nil
    ) {
        self.body = body
        self.date = date
        self.dayTemplateID = dayTemplateID
        self.resolvedSessionID = resolvedSessionID
        self.expectedAttempt = expectedAttempt
        self.restartDiscardedAttempt = restartDiscardedAttempt
        self.deliveryState = deliveryState
        self.failedHTTPStatus = failedHTTPStatus
    }

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
        var replacement = intent
        // The attempt token is write-once for one immutable set UUID. A stale
        // same-account model may fill nil, but it can never regress or retarget
        // an intent that another model already bound.
        if let expectedAttempt = pending[index].expectedAttempt {
            replacement.expectedAttempt = expectedAttempt
        }
        pending[index] = replacement
    }

    mutating func remove(id: String) {
        pending.removeAll { $0.id == id }
    }

    mutating func remove(date: String) {
        pending.removeAll { $0.date == date }
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

    /// Discard is a durable date-level barrier. Once that barrier is saved,
    /// every set intent for the same workout is superseded as one logical
    /// operation, regardless of whether the set was queued or visibly failed.
    static func remove(
        date: String,
        userID: String?,
        defaults: UserDefaults = .standard
    ) {
        update(userID: userID, defaults: defaults) { $0.remove(date: date) }
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

/// Account-scoped server admission floor for durable workout writes. Unlike a
/// model-owned retry task, this deadline must survive same-user reauthentication
/// and process replacement so a newly mounted sender cannot bypass Retry-After.
enum WorkoutWriteRetryDeadlineStore {
    static func scopedKey(userID: String) -> String {
        "com.nmarkspdx.liftcoach.workout-write-retry-deadline.v1.\(userID)"
    }

    static func load(
        userID: String?,
        defaults: UserDefaults = .standard
    ) -> Date? {
        guard let userID,
              let value = defaults.object(
                forKey: scopedKey(userID: userID)) as? NSNumber
        else { return nil }
        let timestamp = value.doubleValue
        guard timestamp.isFinite else {
            clear(userID: userID, defaults: defaults)
            return nil
        }
        return Date(timeIntervalSince1970: timestamp)
    }

    /// Never shorten a deadline written by another same-account model.
    @discardableResult
    static func extend(
        to proposed: Date,
        userID: String?,
        defaults: UserDefaults = .standard
    ) -> Date? {
        guard let userID, proposed.timeIntervalSince1970.isFinite else {
            return load(userID: userID, defaults: defaults)
        }
        let deadline = max(
            load(userID: userID, defaults: defaults) ?? proposed,
            proposed)
        defaults.set(
            deadline.timeIntervalSince1970,
            forKey: scopedKey(userID: userID))
        return deadline
    }

    /// Clear only the deadline this sender actually waited for. A later floor
    /// installed while it slept remains authoritative.
    static func clear(
        through completedDeadline: Date,
        userID: String?,
        defaults: UserDefaults = .standard
    ) {
        guard let userID,
              let current = load(userID: userID, defaults: defaults),
              current <= completedDeadline
        else { return }
        clear(userID: userID, defaults: defaults)
    }

    static func clear(userID: String, defaults: UserDefaults = .standard) {
        defaults.removeObject(forKey: scopedKey(userID: userID))
    }
}
