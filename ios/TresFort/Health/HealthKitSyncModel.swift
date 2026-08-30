import SwiftUI
import HealthKit

/// On-device Apple Health (HealthKit) reader + pusher.
///
/// HealthKit lives ONLY on the phone — the Cloudflare Worker can never read it
/// (`docs/MULTISOURCE-INGESTION.md` §2.5). So unlike the intervals.icu PULL
/// (server-side), this is a client PUSH: we read `HKWorkout`s and POST each to
/// `POST /api/activities/healthkit`, where they land in the SAME
/// `external_activities` cache the intervals sync writes (`source='healthkit'`).
/// That means they ride `/api/state` and the personal calendar with zero new
/// sync surface, and the backend's source-scoped reconcile (migration 0027)
/// never tombstones them.
///
/// Design choices that matter:
///   * **Anchored foreground sync is the source of truth.** An
///     `HKAnchoredObjectQuery` does a full backfill on first connect (HealthKit
///     retains years of history) and an incremental delta thereafter, keyed by a
///     persisted anchor. An `HKObserverQuery` + background delivery is layered on
///     for opportunistic near-real-time, but it is documented-as-flaky and does
///     not fire when the app is force-quit — so we never rely on it alone.
///   * **"Connected" is OUR flag, not a HealthKit truth.** Apple deliberately
///     hides read-authorization status (you cannot tell if a read was denied),
///     so we record the user's intent (`enabled`) when they tap Connect and the
///     authorization sheet returns. Reads that come back empty degrade
///     gracefully (no HR → the coach still gets duration).
///   * **Idempotent push.** The id we send is `HKWorkout.uuid` — the server PK
///     embeds it, so a re-push (a later anchored pass re-seeing the same
///     workout, or a HealthKit revision of its totals) lands on ON CONFLICT and
///     updates in place instead of duplicating.
@MainActor
final class HealthKitSyncModel: ObservableObject {
    /// False on iPad / unsupported hardware. Gate every HealthKit call on this.
    let isAvailable: Bool = HKHealthStore.isHealthDataAvailable()

    static let legacyEnabledKey = AccountLocalState.legacyHealthEnabledKey
    static let legacyAnchorKey = AccountLocalState.legacyHealthAnchorKey

    static func enabledKey(userID: String) -> String {
        AccountLocalState.healthEnabledKey(userID: userID)
    }

    static func anchorKey(userID: String) -> String {
        AccountLocalState.healthAnchorKey(userID: userID)
    }

    /// User intent — the only durable "is Apple Health connected" signal we
    /// have (Apple hides read-auth status). Drives the Connections UI and gates
    /// background sync. Persisted so it survives relaunch; reset on disconnect.
    @Published var enabled: Bool

    @Published private(set) var isSyncing = false
    @Published private(set) var lastSyncedAt: Date?
    @Published var lastError: String?

    /// Bridge to the personal calendar: after a sync persists rows, the owner
    /// (MainTabView) refreshes SyncModel so the new HealthKit activities surface
    /// on the calendar/agenda (they ride `/api/state` external_activities).
    /// Mirrors `GroupModel.onActivityPersisted` — peers, no shared state.
    var onActivitiesPersisted: (() async -> Void)?

    private let store = HKHealthStore()
    private let api = APIClient()
    private unowned let auth: AuthModel
    private let accountID: String?
    private let defaults: UserDefaults

    /// Held so we can stop it on disconnect / sign-out.
    private var observerQuery: HKObserverQuery?

    init(auth: AuthModel, defaults: UserDefaults = .standard) {
        self.auth = auth
        self.accountID = auth.userID
        self.defaults = defaults
        if let userID = auth.userID {
            AccountLocalState.bindLegacyState(userID: userID, defaults: defaults)
            self.enabled = defaults.bool(forKey: Self.enabledKey(userID: userID))
        } else {
            self.enabled = false
        }
    }

    private var currentJWT: String? {
        guard let accountID, auth.userID == accountID else { return nil }
        return auth.featureJWT
    }

    private func isCurrentAccount(using jwt: String) -> Bool {
        guard let accountID, auth.userID == accountID else { return false }
        return auth.featureJWT == jwt
    }

    // MARK: - Read scope

    /// Read-only scope. Workouts are the spine; HR/energy/distance enrich each
    /// one (HR is NOT a workout property — it's queried separately by time
    /// range). We never request write access (`toShare: []`).
    private var readTypes: Set<HKObjectType> {
        var t: Set<HKObjectType> = [HKObjectType.workoutType()]
        let ids: [HKQuantityTypeIdentifier] = [
            .heartRate, .activeEnergyBurned,
            .distanceWalkingRunning, .distanceCycling, .distanceSwimming,
        ]
        for id in ids {
            if let q = HKObjectType.quantityType(forIdentifier: id) { t.insert(q) }
        }
        return t
    }

    // MARK: - Connect / disconnect

    /// Request HealthKit read access, mark connected, register the observer,
    /// and kick the first (full-backfill) sync. Apple hides read denial, so a
    /// returned-but-denied authorization still flips `enabled` — empty reads
    /// just produce thin rows. Throwing here means the user dismissed or the
    /// system errored before any prompt.
    ///
    /// The backfill sync is fired-and-forgotten on purpose: the FIRST sync reads
    /// the user's whole workout history and pushes each one sequentially (an HR
    /// query + a network POST per workout), which can take many seconds. We do
    /// NOT `await` it here so `connect()` returns the instant authorization
    /// completes — the UI flips to "Connected" immediately and surfaces the
    /// ongoing import via `isSyncing` ("Syncing…"), instead of leaving the
    /// connect spinner spinning through the whole backfill (which read as a
    /// hang/failure).
    func connect() async {
        guard isAvailable else {
            lastError = "Apple Health isn’t available on this device."
            return
        }
        guard let jwt = currentJWT else { return }
        do {
            try await store.requestAuthorization(toShare: [], read: readTypes)
        } catch {
            lastError = "Couldn’t access Apple Health. \(error.localizedDescription)"
            return
        }
        guard isCurrentAccount(using: jwt) else { return }
        enabled = true
        if let accountID {
            defaults.set(true, forKey: Self.enabledKey(userID: accountID))
        }
        lastError = nil
        registerObserver()
        Task { await sync() }
    }

    /// Stop syncing Apple Health. Clears intent + the anchor + the observer.
    /// Does NOT delete already-pushed rows — that's a server-side purge concern
    /// (and the coach keeps the history). A later reconnect re-backfills from a
    /// fresh anchor; the idempotent push means re-seen workouts just no-op.
    func disconnect() {
        enabled = false
        if let accountID {
            defaults.set(false, forKey: Self.enabledKey(userID: accountID))
            defaults.removeObject(forKey: Self.anchorKey(userID: accountID))
        }
        if let q = observerQuery {
            store.stop(q)
            observerQuery = nil
        }
        if isAvailable {
            store.disableAllBackgroundDelivery { _, _ in }
        }
    }

    // MARK: - Lifecycle hooks (called by MainTabView)

    /// Called on launch + foreground. No-op unless connected; otherwise
    /// (re)registers the observer and kicks an incremental sync.
    func start() {
        guard enabled, isAvailable, currentJWT != nil else { return }
        registerObserver()
        Task { await sync() }
    }

    /// Explicitly disconnect this account's HealthKit state. Ordinary sign-out
    /// and same-user reauthentication retain the account-scoped values.
    func reset() {
        disconnect()
        lastSyncedAt = nil
        lastError = nil
    }

    // MARK: - Sync

    /// Page size for the anchored query. Bounds the first-connect backfill (which
    /// can be years of mirrored history) into checkpointable chunks.
    private static let pageLimit = 250

    /// Pull new/changed workouts since the stored anchor and push each, paging
    /// so a large backfill is checkpointable. The anchor advances ONLY after a
    /// whole page has been pushed successfully — so an interrupted sync resumes
    /// at the last fully-pushed page, not from zero, and a failed push mid-page
    /// leaves that page's anchor put for a clean retry (the push is idempotent,
    /// so re-sending already-saved rows is harmless).
    func sync() async {
        guard enabled, isAvailable, let jwt = currentJWT, !isSyncing else { return }
        isSyncing = true
        defer { isSyncing = false }
        var anchor = loadAnchor()
        let hadStoredAnchor = anchor != nil
        var pushedAny = false
        do {
            while true {
                guard isCurrentAccount(using: jwt) else { return }
                let (workouts, newAnchor) =
                    try await fetchNewWorkouts(anchor: anchor, limit: Self.pageLimit)
                guard isCurrentAccount(using: jwt) else { return }
                if workouts.isEmpty {
                    // Only checkpoint an empty result once we KNOW reads work —
                    // i.e. we already had a stored anchor, or we've pushed a page
                    // this run. On the very FIRST sync HealthKit reports a DENIED
                    // workout read as an empty set (not an error), so persisting
                    // that anchor would skip the historical backfill if the user
                    // later grants permission in Settings. Leaving it unset means
                    // the next sync retries from scratch and backfills.
                    if (hadStoredAnchor || pushedAny), let newAnchor {
                        saveAnchor(newAnchor); anchor = newAnchor
                    }
                    break
                }
                for w in workouts {
                    let body = await buildPush(for: w)
                    guard isCurrentAccount(using: jwt) else { return }
                    _ = try await api.pushHealthKitActivity(body, jwt: jwt)
                }
                // Whole page pushed — checkpoint the anchor before the next page.
                guard isCurrentAccount(using: jwt) else { return }
                if let newAnchor { saveAnchor(newAnchor); anchor = newAnchor }
                pushedAny = true
                if workouts.count < Self.pageLimit { break } // last page
            }
            guard isCurrentAccount(using: jwt) else { return }
            lastSyncedAt = Date()
            lastError = nil
            if pushedAny { await onActivitiesPersisted?() }
        } catch let APIError.http(code, _) where code == 401 {
            // Token died mid-sync — let AuthModel handle it. Anchor is already
            // checkpointed at the last good page, so a re-auth resumes cleanly.
            if isCurrentAccount(using: jwt) {
                auth.requireReauthentication()
            }
        } catch {
            lastError = "Apple Health sync didn’t finish. It’ll retry."
        }
    }

    // MARK: - HealthKit queries

    /// One-shot anchored fetch over the workout type, up to `limit` samples.
    /// With no update handler the results handler fires exactly once with the
    /// next page since `anchor`; re-run with the returned anchor for the next.
    private func fetchNewWorkouts(
        anchor: HKQueryAnchor?,
        limit: Int
    ) async throws -> ([HKWorkout], HKQueryAnchor?) {
        try await withCheckedThrowingContinuation { cont in
            let q = HKAnchoredObjectQuery(
                type: HKObjectType.workoutType(),
                predicate: nil,
                anchor: anchor,
                limit: limit
            ) { _, samples, _, newAnchor, error in
                if let error { cont.resume(throwing: error); return }
                let workouts = (samples as? [HKWorkout]) ?? []
                cont.resume(returning: (workouts, newAnchor))
            }
            store.execute(q)
        }
    }

    /// Average + max heart rate over a workout's time range. HR is a separate
    /// sample stream, not a workout property. Read denial / no samples → (nil,
    /// nil): non-fatal, the coach reads duration instead.
    private func heartRate(during w: HKWorkout) async -> (Double?, Int?) {
        guard let hrType = HKObjectType.quantityType(forIdentifier: .heartRate) else {
            return (nil, nil)
        }
        let pred = HKQuery.predicateForSamples(
            withStart: w.startDate, end: w.endDate, options: .strictStartDate)
        return await withCheckedContinuation { cont in
            let q = HKStatisticsQuery(
                quantityType: hrType,
                quantitySamplePredicate: pred,
                options: [.discreteAverage, .discreteMax]
            ) { _, stats, _ in
                let unit = HKUnit.count().unitDivided(by: .minute())
                let avg = stats?.averageQuantity()?.doubleValue(for: unit)
                let mx = stats?.maximumQuantity()?.doubleValue(for: unit)
                cont.resume(returning: (avg, mx.map { Int($0.rounded()) }))
            }
            store.execute(q)
        }
    }

    /// Normalize one `HKWorkout` into the push body. `statistics(for:)` is the
    /// iOS-18-blessed replacement for the deprecated `totalEnergyBurned` /
    /// `totalDistance` initializer properties.
    private func buildPush(for w: HKWorkout) async -> HealthKitActivityPush {
        let kind = Self.kind(for: w.workoutActivityType)
        let (date, startLocalMs) = Self.civilDateAndLocalMs(w.startDate)

        // duration excludes paused time → "moving"; wall-clock span → "elapsed".
        let movingSec = Int(w.duration.rounded())
        let elapsedSec = Int(w.endDate.timeIntervalSince(w.startDate).rounded())

        var calories: Int?
        if let energyType = HKObjectType.quantityType(forIdentifier: .activeEnergyBurned),
           let kcal = w.statistics(for: energyType)?.sumQuantity()?.doubleValue(for: .kilocalorie()) {
            calories = Int(kcal.rounded())
        }

        var distanceM: Double?
        if let distId = Self.distanceIdentifier(for: w.workoutActivityType),
           let distType = HKObjectType.quantityType(forIdentifier: distId),
           let m = w.statistics(for: distType)?.sumQuantity()?.doubleValue(for: .meter()) {
            distanceM = m
        }

        let (avgHR, maxHR) = await heartRate(during: w)

        let elevationM = (w.metadata?[HKMetadataKeyElevationAscended] as? HKQuantity)?
            .doubleValue(for: .meter())

        // Lightweight provenance so the coach/UI can later say "from Garmin
        // Connect / Apple Watch". Best-effort — never blocks the push.
        let sourceName = w.sourceRevision.source.name
        let raw = Self.encodeRaw([
            "hk_activity_type": w.workoutActivityType.rawValue,
            "source": sourceName,
        ])

        return HealthKitActivityPush(
            id: w.uuid.uuidString,
            date: date,
            start_date_local_ms: startLocalMs,
            kind: kind,
            name: Self.displayName(for: w.workoutActivityType, source: sourceName),
            moving_time_sec: movingSec,
            elapsed_time_sec: elapsedSec,
            distance_m: distanceM,
            average_hr: avgHR,
            max_hr: maxHR,
            calories: calories,
            elevation_gain_m: elevationM,
            raw: raw)
    }

    // MARK: - Observer / background delivery

    /// Register the observer once. The handler hops to the main actor, runs an
    /// incremental sync, then calls `completion()` (required, or iOS throttles
    /// future deliveries). Background delivery is requested at `.immediate`, but
    /// true force-quit wakeups would need an AppDelegate registration — out of
    /// scope; anchored foreground sync is the source of truth.
    private func registerObserver() {
        guard isAvailable, observerQuery == nil else { return }
        let q = HKObserverQuery(
            sampleType: HKObjectType.workoutType(), predicate: nil
        ) { [weak self] _, completion, error in
            guard error == nil else { completion(); return }
            Task { @MainActor in
                await self?.sync()
                completion()
            }
        }
        observerQuery = q
        store.execute(q)
        store.enableBackgroundDelivery(
            for: HKObjectType.workoutType(), frequency: .immediate) { _, _ in }
    }

    // MARK: - Anchor persistence

    private func loadAnchor() -> HKQueryAnchor? {
        guard let accountID,
              let data = defaults.data(forKey: Self.anchorKey(userID: accountID))
        else { return nil }
        return try? NSKeyedUnarchiver.unarchivedObject(ofClass: HKQueryAnchor.self, from: data)
    }

    private func saveAnchor(_ anchor: HKQueryAnchor) {
        guard let accountID,
              auth.userID == accountID,
              auth.featureJWT != nil else { return }
        guard let data = try? NSKeyedArchiver.archivedData(
            withRootObject: anchor, requiringSecureCoding: true) else { return }
        defaults.set(data, forKey: Self.anchorKey(userID: accountID))
    }

    // MARK: - Mapping (keep the kind vocab in sync with backend kindOf)

    /// Map an `HKWorkoutActivityType` to our coarse kind. CRITICAL: these must
    /// match the strings `kindOf` emits in `src/intervals.ts` (ride/run/swim/
    /// walk/hike/row/ski/yoga/elliptical/strength/other) — the backend's
    /// cross-source dedup (`dedupeHealthKitAgainstIntervals`) matches a
    /// HealthKit row to an intervals row on `kind` + start-within-2-min, so a
    /// mismatch (e.g. "cycling" vs "ride") would double-count the same ride.
    static func kind(for t: HKWorkoutActivityType) -> String {
        switch t {
        case .cycling: return "ride"
        case .running: return "run"
        case .swimming: return "swim"
        case .walking: return "walk"
        case .hiking: return "hike"
        case .rowing: return "row"
        case .downhillSkiing, .crossCountrySkiing, .snowSports: return "ski"
        case .yoga: return "yoga"
        case .elliptical: return "elliptical"
        case .traditionalStrengthTraining, .functionalStrengthTraining: return "strength"
        default: return "other"
        }
    }

    /// Which distance series to sum for a workout type (nil → no distance).
    private static func distanceIdentifier(
        for t: HKWorkoutActivityType
    ) -> HKQuantityTypeIdentifier? {
        switch t {
        case .cycling: return .distanceCycling
        case .swimming: return .distanceSwimming
        case .running, .walking, .hiking: return .distanceWalkingRunning
        default: return nil
        }
    }

    /// A friendly default title (the backend keeps it verbatim; nil → it falls
    /// back to the capitalized kind).
    private static func displayName(for t: HKWorkoutActivityType, source: String) -> String {
        switch kind(for: t) {
        case "ride": return "Ride"
        case "run": return "Run"
        case "swim": return "Swim"
        case "walk": return "Walk"
        case "hike": return "Hike"
        case "row": return "Row"
        case "ski": return "Ski"
        case "yoga": return "Yoga"
        case "elliptical": return "Elliptical"
        case "strength": return "Strength"
        default: return "Workout"
        }
    }

    /// Civil date (`YYYY-MM-DD`, device-local) + start time as a UTC epoch-ms of
    /// the LOCAL wall clock. The ms representation deliberately matches
    /// intervals.icu's `start_date_local` (which the backend parses as if UTC),
    /// so the cross-source dedup lines the same ride up across sources. Using a
    /// raw `timeIntervalSince1970` instead would be off by the tz offset and the
    /// 2-minute dedup window would miss the match.
    static func civilDateAndLocalMs(_ start: Date) -> (String, Int) {
        let f = DateFormatter()
        f.calendar = Calendar(identifier: .gregorian)
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = .current
        f.dateFormat = "yyyy-MM-dd"
        let date = f.string(from: start)
        let offset = TimeZone.current.secondsFromGMT(for: start)
        let localMs = Int((start.timeIntervalSince1970 + Double(offset)) * 1000)
        return (date, localMs)
    }

    private static func encodeRaw(_ dict: [String: Any]) -> String? {
        guard let data = try? JSONSerialization.data(withJSONObject: dict),
              let s = String(data: data, encoding: .utf8) else { return nil }
        return s
    }
}

/// Push body for `POST /api/activities/healthkit`. Field names match the
/// backend `HealthKitActivityInput` 1:1. `id` (= HKWorkout.uuid) is the
/// idempotency key; nil numeric fields are omitted (server treats absent as
/// null). `training_load` / `intensity` are intentionally absent — HealthKit
/// has no native TSS and the backend leaves them NULL (no fabricated load).
struct HealthKitActivityPush {
    let id: String
    let date: String
    let start_date_local_ms: Int?
    let kind: String
    let name: String?
    let moving_time_sec: Int?
    let elapsed_time_sec: Int?
    let distance_m: Double?
    let average_hr: Double?
    let max_hr: Int?
    let calories: Int?
    let elevation_gain_m: Double?
    let raw: String?

    /// JSON body for `APIClient.post`. Required keys always present; optionals
    /// omitted when nil (the endpoint maps absent → null identically).
    var jsonBody: [String: Any] {
        var b: [String: Any] = ["id": id, "date": date, "kind": kind]
        if let v = start_date_local_ms { b["start_date_local_ms"] = v }
        if let v = name { b["name"] = v }
        if let v = moving_time_sec { b["moving_time_sec"] = v }
        if let v = elapsed_time_sec { b["elapsed_time_sec"] = v }
        if let v = distance_m { b["distance_m"] = v }
        if let v = average_hr { b["average_hr"] = v }
        if let v = max_hr { b["max_hr"] = v }
        if let v = calories { b["calories"] = v }
        if let v = elevation_gain_m { b["elevation_gain_m"] = v }
        if let v = raw { b["raw"] = v }
        return b
    }
}
