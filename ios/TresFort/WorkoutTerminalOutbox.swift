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
    /// Session generation this user choice targets. It is bound before the
    /// terminal request and retained across retries/relaunches.
    var expectedAttempt: Int?
    /// Prior discarded generation explicitly restarted by the mounted runner.
    /// Only that durable user action may authorize date-level revival.
    let restartDiscardedAttempt: Int?
    var deliveryState: WorkoutTerminalDeliveryState
    var failedHTTPStatus: Int?

    init(
        id: String,
        action: WorkoutTerminalAction,
        date: String,
        dayTemplateID: String?,
        resolvedSessionID: String?,
        deliveryState: WorkoutTerminalDeliveryState,
        failedHTTPStatus: Int?,
        expectedAttempt: Int? = nil,
        restartDiscardedAttempt: Int? = nil
    ) {
        self.id = id
        self.action = action
        self.date = date
        self.dayTemplateID = dayTemplateID
        self.resolvedSessionID = resolvedSessionID
        self.expectedAttempt = expectedAttempt
        self.restartDiscardedAttempt = restartDiscardedAttempt
        self.deliveryState = deliveryState
        self.failedHTTPStatus = failedHTTPStatus
    }
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
        if replacement.expectedAttempt == nil {
            replacement.expectedAttempt = current.expectedAttempt
        } else if current.expectedAttempt != nil {
            replacement.expectedAttempt = current.expectedAttempt
        }
        if replacement.restartDiscardedAttempt
            != current.restartDiscardedAttempt
        {
            // The restart authorization is part of the immutable user intent,
            // not delivery metadata. A callback built from an older/minimal
            // payload may omit it, but may never erase or retarget it.
            replacement = WorkoutTerminalIntent(
                id: replacement.id,
                action: replacement.action,
                date: replacement.date,
                dayTemplateID: replacement.dayTemplateID,
                resolvedSessionID: replacement.resolvedSessionID,
                deliveryState: replacement.deliveryState,
                failedHTTPStatus: replacement.failedHTTPStatus,
                expectedAttempt: replacement.expectedAttempt,
                restartDiscardedAttempt: current.restartDiscardedAttempt)
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

    /// Retire an exact stale discard after the Worker proves that its attempt
    /// was superseded. Unlike generic removal, this evidence-bound path may
    /// remove a queued/failed discard; it cannot touch a replacement id.
    mutating func retireSupersededDiscard(id: String) {
        guard let match = intentsByDate.first(where: { $0.value.id == id }),
              match.value.action == .discard
        else { return }
        intentsByDate.removeValue(forKey: match.key)
    }

    /// Bind an exact discard barrier to an authoritative discarded server row.
    /// This may advance the attempt when another device already discarded a
    /// later generation; generic `replace` intentionally remains write-once.
    mutating func acknowledgeDiscard(
        id: String,
        resolvedSessionID: String,
        expectedAttempt: Int?
    ) {
        guard var current = intentsByDate.values.first(where: {
            $0.id == id && $0.action == .discard
        }) else { return }
        current.resolvedSessionID = resolvedSessionID
        current.expectedAttempt = expectedAttempt
        current.deliveryState = .acknowledged
        current.failedHTTPStatus = nil
        intentsByDate[current.date] = current
    }

    /// The one intentional acknowledgement-regression path. A full state pull
    /// may prove that a late session create revived a date after discard was
    /// acknowledged. In that evidence-backed case, retain the same barrier id
    /// and requeue it against the newly observed canonical session.
    mutating func requeueAcknowledgedDiscard(
        date: String,
        resolvedSessionID: String,
        expectedAttempt: Int?
    ) {
        guard var current = intentsByDate[date],
              current.action == .discard,
              current.deliveryState == .acknowledged
        else { return }
        current.resolvedSessionID = resolvedSessionID
        current.expectedAttempt = expectedAttempt
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

    static func retireSupersededDiscard(
        id: String,
        userID: String?,
        defaults: UserDefaults = .standard
    ) {
        update(userID: userID, defaults: defaults) {
            $0.retireSupersededDiscard(id: id)
        }
    }

    static func acknowledgeDiscard(
        id: String,
        resolvedSessionID: String,
        expectedAttempt: Int?,
        userID: String?,
        defaults: UserDefaults = .standard
    ) {
        update(userID: userID, defaults: defaults) {
            $0.acknowledgeDiscard(
                id: id,
                resolvedSessionID: resolvedSessionID,
                expectedAttempt: expectedAttempt)
        }
    }

    static func requeueAcknowledgedDiscard(
        date: String,
        resolvedSessionID: String,
        expectedAttempt: Int?,
        userID: String?,
        defaults: UserDefaults = .standard
    ) {
        update(userID: userID, defaults: defaults) {
            $0.requeueAcknowledgedDiscard(
                date: date,
                resolvedSessionID: resolvedSessionID,
                expectedAttempt: expectedAttempt)
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
