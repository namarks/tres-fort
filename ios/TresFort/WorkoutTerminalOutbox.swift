import Foundation

/// The terminal action the user chose for one civil-date workout.
enum WorkoutTerminalAction: String, Codable, Equatable {
    case finish
    case discard
}

enum WorkoutTerminalDeliveryState: String, Codable, Equatable {
    /// Waiting for its first attempt or for an automatic retry after a
    /// transient/authentication failure.
    case queued
    /// A non-authentication 4xx requires an explicit user retry. The intent is
    /// retained so the UI never claims the terminal action was accepted.
    case failed
    /// The Worker acknowledged the terminal action. Acknowledged discards stay
    /// in the outbox as tombstone-like barriers until explicitly cleared.
    case acknowledged
}

/// One immutable user choice plus the mutable delivery metadata needed to
/// recover it after process death. `id` is local concurrency identity, not a
/// server idempotency key: exact-id replacement makes stale callbacks no-ops
/// after a newer discard supersedes a finish.
struct WorkoutTerminalIntent: Codable, Identifiable, Equatable {
    let id: String
    let action: WorkoutTerminalAction
    let date: String
    let dayTemplateID: String?
    var resolvedSessionID: String?
    var deliveryState: WorkoutTerminalDeliveryState
    var failedHTTPStatus: Int?
}

/// Account-local terminal intents, with at most one current intent or discard
/// barrier per civil date.
///
/// Invariants:
/// - discard has monotonic precedence: it replaces finish, while finish never
///   replaces discard;
/// - callbacks may mutate/remove only the exact current local id and never
///   insert a missing id;
/// - acknowledgement is monotonic for a given id; and
/// - no generic removal path can erase a discard barrier.
struct WorkoutTerminalOutbox: Codable, Equatable {
    private var intentsByDate: [String: WorkoutTerminalIntent] = [:]

    /// Deterministic order is useful to callers draining more than one date.
    var intents: [WorkoutTerminalIntent] {
        intentsByDate.values.sorted {
            if $0.date == $1.date { return $0.id < $1.id }
            return $0.date < $1.date
        }
    }

    func intent(for date: String) -> WorkoutTerminalIntent? {
        intentsByDate[date]
    }

    /// Records a fresh user intent. Repeated finish taps retain the first
    /// immutable intent, and an existing discard always wins over later input.
    mutating func enqueue(_ intent: WorkoutTerminalIntent) {
        guard let existing = intentsByDate[intent.date] else {
            intentsByDate[intent.date] = intent
            return
        }

        guard existing.action == .finish,
              intent.action == .discard
        else { return }

        intentsByDate[intent.date] = intent
    }

    /// Replaces delivery metadata only when this is still the exact current
    /// intent. Missing ids are deliberately not inserted. A resolved session
    /// id and an acknowledgement cannot regress due to an older callback.
    mutating func replace(_ intent: WorkoutTerminalIntent) {
        guard let current = intentsByDate[intent.date],
              current.id == intent.id,
              current.action == intent.action,
              current.dayTemplateID == intent.dayTemplateID,
              !(current.deliveryState == .acknowledged
                  && intent.deliveryState != .acknowledged)
        else { return }

        var replacement = intent
        if replacement.resolvedSessionID == nil {
            replacement.resolvedSessionID = current.resolvedSessionID
        }
        intentsByDate[intent.date] = replacement
    }

    /// Removes an acknowledged finish (or an abandoned finish) only if the id
    /// is still current. Discards are durable barriers and use the explicit
    /// date-based clearing method below.
    mutating func remove(id: String) {
        guard let match = intentsByDate.first(where: { $0.value.id == id }),
              match.value.action == .finish
        else { return }
        intentsByDate.removeValue(forKey: match.key)
    }

    /// Erases a discard barrier only after server acknowledgement and an
    /// explicit reconciliation decision by the caller.
    mutating func clearAcknowledgedDiscard(date: String) {
        guard let current = intentsByDate[date],
              current.action == .discard,
              current.deliveryState == .acknowledged
        else { return }
        intentsByDate.removeValue(forKey: date)
    }

    /// The one intentional acknowledgement-regression path. A full state pull
    /// may prove that a late session create revived a date after discard was
    /// acknowledged. In that evidence-backed case, retain the same barrier id
    /// and requeue it against the newly observed canonical session.
    mutating func requeueAcknowledgedDiscard(
        date: String,
        resolvedSessionID: String
    ) {
        guard var current = intentsByDate[date],
              current.action == .discard,
              current.deliveryState == .acknowledged
        else { return }
        current.resolvedSessionID = resolvedSessionID
        current.deliveryState = .queued
        current.failedHTTPStatus = nil
        intentsByDate[date] = current
    }

    var isEmpty: Bool { intentsByDate.isEmpty }
    var count: Int { intentsByDate.count }
}

/// Synchronous, account-scoped persistence. Callers should use the granular
/// mutation helpers once network work begins; they reload the latest stored
/// value before each mutation so a stale model generation cannot overwrite a
/// newer discard barrier with a whole-outbox save.
enum WorkoutTerminalOutboxStore {
    static func scopedKey(userID: String) -> String {
        "com.nmarkspdx.liftcoach.workout-terminal-outbox.v1.\(userID)"
    }

    static func load(
        userID: String?,
        defaults: UserDefaults = .standard
    ) -> WorkoutTerminalOutbox {
        guard let userID,
              let data = defaults.data(forKey: scopedKey(userID: userID))
        else { return WorkoutTerminalOutbox() }
        return (try? JSONDecoder().decode(WorkoutTerminalOutbox.self, from: data))
            ?? WorkoutTerminalOutbox()
    }

    static func save(
        _ outbox: WorkoutTerminalOutbox,
        userID: String?,
        defaults: UserDefaults = .standard
    ) {
        guard let userID,
              let data = try? JSONEncoder().encode(outbox)
        else { return }
        defaults.set(data, forKey: scopedKey(userID: userID))
    }

    static func enqueue(
        _ intent: WorkoutTerminalIntent,
        userID: String?,
        defaults: UserDefaults = .standard
    ) {
        update(userID: userID, defaults: defaults) { $0.enqueue(intent) }
    }

    static func replace(
        _ intent: WorkoutTerminalIntent,
        userID: String?,
        defaults: UserDefaults = .standard
    ) {
        update(userID: userID, defaults: defaults) { $0.replace(intent) }
    }

    static func remove(
        id: String,
        userID: String?,
        defaults: UserDefaults = .standard
    ) {
        update(userID: userID, defaults: defaults) { $0.remove(id: id) }
    }

    static func clearAcknowledgedDiscard(
        date: String,
        userID: String?,
        defaults: UserDefaults = .standard
    ) {
        update(userID: userID, defaults: defaults) {
            $0.clearAcknowledgedDiscard(date: date)
        }
    }

    static func requeueAcknowledgedDiscard(
        date: String,
        resolvedSessionID: String,
        userID: String?,
        defaults: UserDefaults = .standard
    ) {
        update(userID: userID, defaults: defaults) {
            $0.requeueAcknowledgedDiscard(
                date: date,
                resolvedSessionID: resolvedSessionID)
        }
    }

    private static func update(
        userID: String?,
        defaults: UserDefaults,
        mutation: (inout WorkoutTerminalOutbox) -> Void
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
