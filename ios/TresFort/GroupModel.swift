import SwiftUI

/// Owns all group-accountability state. Peer to `SyncModel` (the existing
/// strength-world model) — by design these don't share state, only the
/// `AuthModel` reference. Per `.context/m5-ios-spec.md` §4a:
///
///   * Volumes are tiny (<10 members per group, <30 feed items per pull),
///     so everything lives in @Published in-memory arrays — no SwiftData
///     mirror, full-replace on every refresh.
///   * The only persisted piece is `ActivityOutbox` (LocalPersistence), so a
///     POST that fails offline survives an app kill.
///   * `@MainActor` so SwiftUI views can mutate freely; APIClient calls
///     are `async throws` and return on the main actor.
@MainActor
final class GroupModel: ObservableObject {
    // MARK: Phase / selection

    enum Phase: Equatable {
        case loading
        case error(String)
        /// Signed in, not in any group yet — show create/join CTAs.
        case none
        /// In ≥1 group — selectedGroupID is set to one of them.
        case ready
    }

    @Published var phase: Phase = .loading
    @Published var groups: [GroupSummary] = []
    @Published var selectedGroupID: String?
    /// Account + setup snapshot (GET /api/me) for the Profile tab. Holds
    /// server-derived intervals + coach-connector status.
    @Published var me: MeProfile?
    @Published private(set) var groupSafety: GroupSafetyState?

    // MARK: Per-group caches (keyed by group.id)

    @Published var feed: [String: [FeedItem]] = [:]
    @Published var stats: [String: [MemberStat]] = [:]
    /// Per-member daily activity series (keyed by group.id) for the
    /// week/month/year zoom strip. Pulled once per refresh over a year
    /// window so the range toggle is instant (no refetch).
    @Published var activitySeries: [String: [MemberActivitySeries]] = [:]
    @Published var feedNextSince: [String: Int?] = [:]
    /// Tie-breaker companion to `feedNextSince`: server returns BOTH
    /// `next_since` and `next_since_id`, and the paginated call must echo
    /// both back. iOS doesn't paginate today (full-replace at limit=30),
    /// but we mirror the field so the moment a caller switches on
    /// pagination they can pass `sinceID:` without a re-plumb.
    @Published var feedNextSinceID: [String: String?] = [:]
    @Published var isRefreshingFeed: [String: Bool] = [:]
    @Published var isRefreshingStats: [String: Bool] = [:]

    // MARK: Intervals.icu connection

    static let legacyIntervalsConnectionKey =
        AccountLocalState.legacyIntervalsConnectionKey

    static func intervalsConnectionKey(userID: String) -> String {
        AccountLocalState.intervalsConnectionKey(userID: userID)
    }

    /// Local mirror of the last app-managed connection. The authoritative
    /// profile status still comes from /api/me; this mirror is account-scoped
    /// so switching Apple accounts cannot display another athlete id.
    @Published var intervalsConnection: IntervalsConnection?
    /// Only a current server response can establish connection authority.
    /// The persisted mirror is historical and cannot override this status.
    @Published private(set) var intervalsStatus: MeProfile.IntervalsStatus?
    @Published private(set) var intervalsBusy = false
    @Published private(set) var intervalsImportStatus: IntervalsImportStatus?
    @Published private(set) var intervalsStatusUnavailable = false
    private var intervalsOperation = 0
    private let intervalsPollDelays: [UInt64]

    // MARK: Activity outbox (the one persisted piece)

    @Published private(set) var outbox: ActivityOutbox

    // MARK: Latest-error reporting (one slot — last error wins)

    @Published var lastError: String?

    // MARK: Deps

    private let api = APIClient()
    private unowned let auth: AuthModel
    private let accountID: String?
    private let defaults: LocalPersistence
    private let activityLogger: ((PendingActivity, String) async throws -> ActivityRow)?
    private let activityDeleter: ((String, String) async throws -> Void)?
    private let groupLister: ((String) async throws -> [GroupSummary])?
    private let groupLoader: ((String, String) async throws -> GroupSummary)?
    private let groupSafetyLoader: ((String) async throws -> GroupSafetyState)?
    private let groupBlockWriter: ((String, Bool, String) async throws -> Void)?
    private let groupRestrictionWriter: ((String, Bool, GroupReportReason, String) async throws -> Void)?
    private let profileLoader: ((String) async throws -> MeProfile)?
    private let coachCodeWriter: ((String, String) async throws -> Void)?
    private let intervalsConnector: ((String?, String?, String) async throws -> APIClient.IntervalsConnectResult)?
    private let intervalsImporter: ((Int, String) async throws -> IntervalsImportResult)?
    private let intervalsAuthorizer: ((String) async throws -> IntervalsOAuthResult)?
    /// Invalidates identity-bearing responses that began before a global
    /// profile-name update. Without this, an older in-flight feed or stats
    /// response could restore the previous effective display name.
    private var identityCacheGeneration = 0

    /// Fired after a manual activity is persisted, drained from the
    /// outbox, or deleted. The owner (MainTabView) sets this to refresh
    /// the SyncModel so the personal calendar reflects the change —
    /// GroupModel and SyncModel are peers (no direct reference), so this
    /// closure is the one-way bridge. A logged Pilates class must show on
    /// the calendar whether it was logged from the Today tab, the group
    /// FAB, or replayed from the offline outbox.
    var onActivityPersisted: (() async -> Void)?

    init(
        auth: AuthModel,
        defaults: LocalPersistence = .standard,
        activityLogger: ((PendingActivity, String) async throws -> ActivityRow)? = nil,
        activityDeleter: ((String, String) async throws -> Void)? = nil,
        groupLister: ((String) async throws -> [GroupSummary])? = nil,
        groupLoader: ((String, String) async throws -> GroupSummary)? = nil,
        profileLoader: ((String) async throws -> MeProfile)? = nil,
        coachCodeWriter: ((String, String) async throws -> Void)? = nil,
        groupBlockWriter: ((String, Bool, String) async throws -> Void)? = nil,
        groupRestrictionWriter: ((String, Bool, GroupReportReason, String) async throws -> Void)? = nil,
        groupSafetyLoader: ((String) async throws -> GroupSafetyState)? = nil,
        intervalsConnector: ((String?, String?, String) async throws -> APIClient.IntervalsConnectResult)? = nil,
        intervalsImporter: ((Int, String) async throws -> IntervalsImportResult)? = nil,
        intervalsAuthorizer: ((String) async throws -> IntervalsOAuthResult)? = nil,
        intervalsPollDelays: [UInt64] = [0, 500_000_000, 1_500_000_000, 3_000_000_000, 5_000_000_000]
    ) {
        self.auth = auth
        self.accountID = auth.userID
        self.defaults = defaults
        self.activityLogger = activityLogger
        self.activityDeleter = activityDeleter
        self.groupLister = groupLister
        self.groupLoader = groupLoader
        self.profileLoader = profileLoader
        self.coachCodeWriter = coachCodeWriter
        self.groupBlockWriter = groupBlockWriter
        self.groupRestrictionWriter = groupRestrictionWriter
        self.groupSafetyLoader = groupSafetyLoader
        self.intervalsConnector = intervalsConnector
        self.intervalsImporter = intervalsImporter
        self.intervalsAuthorizer = intervalsAuthorizer
        self.intervalsPollDelays = intervalsPollDelays
        self.intervalsConnection = Self.loadIntervalsConnection(
            userID: auth.userID, defaults: defaults)
        self.outbox = ActivityOutboxStore.load(
            userID: auth.userID, defaults: defaults)
    }

    /// This model is scoped to the account that created it. MainTabView can
    /// retain in-flight tasks briefly while rebuilding for a newly signed-in
    /// account, so never borrow that new account's bearer.
    private var currentJWT: String? {
        guard let accountID, auth.userID == accountID else { return nil }
        return auth.featureJWT
    }

    /// Exact bearer identity is only relevant to a 401: an old request must
    /// never invalidate a newer bearer installed by same-account renewal.
    private func isCurrentBearer(_ jwt: String) -> Bool {
        guard let accountID, auth.userID == accountID else { return false }
        return auth.featureJWT == jwt
    }

    /// Successful responses and id-granular local finalization belong to the
    /// same account even when renewal replaces its bearer. Reserve exact-token
    /// equality for deciding whether a 401 may invalidate the current bearer.
    private var isCurrentAccount: Bool {
        guard let accountID, auth.userID == accountID else { return false }
        return auth.featureJWT != nil
    }

    private func persistActivity(
        _ pending: PendingActivity,
        jwt: String
    ) async throws -> ActivityRow {
        if let activityLogger {
            return try await activityLogger(pending, jwt)
        }
        return try await api.logActivity(pending, jwt: jwt)
    }

    private func listGroups(jwt: String) async throws -> [GroupSummary] {
        if let groupLister { return try await groupLister(jwt) }
        return try await api.listGroups(jwt: jwt)
    }

    private func removeActivity(id: String, jwt: String) async throws {
        if let activityDeleter {
            try await activityDeleter(id, jwt)
            return
        }
        try await api.deleteActivity(id: id, jwt: jwt)
    }

    private func loadProfile(jwt: String) async throws -> MeProfile {
        if let profileLoader { return try await profileLoader(jwt) }
        return try await api.getMe(jwt: jwt)
    }

    private static func loadIntervalsConnection(
        userID: String?,
        defaults: LocalPersistence = .standard
    ) -> IntervalsConnection? {
        guard let userID else { return nil }
        AccountLocalState.bindLegacyState(userID: userID, defaults: defaults)
        let key = intervalsConnectionKey(userID: userID)
        guard let data = defaults.data(forKey: key), !data.isEmpty else { return nil }
        return try? JSONDecoder().decode(IntervalsConnection.self, from: data)
    }

    private static func saveIntervalsConnection(
        _ connection: IntervalsConnection?,
        userID: String?,
        defaults: LocalPersistence = .standard
    ) {
        guard let userID else { return }
        let key = intervalsConnectionKey(userID: userID)
        if let connection,
           let data = try? JSONEncoder().encode(connection) {
            defaults.set(data, forKey: key)
        } else {
            defaults.removeObject(forKey: key)
        }
    }

    // MARK: - Selection

    var selectedGroup: GroupSummary? {
        guard let id = selectedGroupID else { return nil }
        return groups.first { $0.id == id }
    }

    /// Pick the first group when nothing is selected (single-group lands
    /// on detail; multi-group lands on first-in-the-stable-order until the
    /// user picks one explicitly).
    private func ensureSelection() {
        if selectedGroupID == nil || groups.first(where: { $0.id == selectedGroupID }) == nil {
            selectedGroupID = groups.first?.id
        }
    }

    // MARK: - Load / refresh

    /// Reconcile both group content and the mounted Profile safety screen.
    func reloadGroupState() async {
        await load()
        try? await refreshGroupSafety()
    }

    /// Pull the groups list + drain the outbox. Sets `phase` to
    /// `.none` / `.ready` / `.error` accordingly. Called on tab `.task`
    /// and on scene-foreground transitions.
    func load() async {
        guard let jwt = currentJWT else { phase = .loading; return }
        invalidateSharedGroups()
        let generation = identityCacheGeneration
        phase = .loading
        do {
            let list = try await listGroups(jwt: jwt)
            guard isCurrentAccount,
                  generation == identityCacheGeneration else { return }
            groups = list
            ensureSelection()
            phase = list.isEmpty ? .none : .ready
            lastError = nil
            // Refresh the visible group's feed/stats so the tab is hot.
            if let id = selectedGroupID {
                await refreshGroup(groupID: id, refreshRoster: false)
            }
            // Drain any pending activity POSTs that survived a relaunch.
            await drainOutbox()
            // Account/setup snapshot for the Profile tab.
            await refreshMe()
        } catch {
            guard isCurrentAccount, generation == identityCacheGeneration else { return }
            if case let APIError.http(code, _) = error,
               code == 401,
               !isCurrentBearer(jwt) {
                // Renewal won while this request was in flight. Retry with
                // the current bearer instead of leaving launch stuck in loading
                // or presenting an error from the superseded credential.
                await load()
                return
            }
            handle(error, jwt: jwt)
            phase = .error(error.localizedDescription)
        }
    }

    /// Revalidate the roster, feed and stats for one group. Used by
    /// pull-to-refresh and after a `logActivity` succeeds.
    func refreshGroup(groupID: String, refreshRoster: Bool = true) async {
        // A removed detail view can still start its queued task while a full
        // roster reload is in flight. It must not supersede that reload.
        guard groups.contains(where: { $0.id == groupID }), let jwt = currentJWT else { return }
        identityCacheGeneration += 1
        let generation = identityCacheGeneration
        feed[groupID] = nil
        stats[groupID] = nil
        activitySeries[groupID] = nil
        if refreshRoster {
            if let index = groups.firstIndex(where: { $0.id == groupID }) {
                let group = groups[index]
                groups[index] = GroupSummary(id: group.id, name: "Private group", created_by: "",
                                             created_at: group.created_at, members: [])
            }
            do {
                let current: GroupSummary
                if let groupLoader { current = try await groupLoader(groupID, jwt) }
                else { current = try await api.getGroup(id: groupID, jwt: jwt) }
                guard isCurrentAccount, generation == identityCacheGeneration else { return }
                if let index = groups.firstIndex(where: { $0.id == groupID }) { groups[index] = current }
            } catch {
                guard isCurrentAccount, generation == identityCacheGeneration else { return }
                handleGroupRefreshFailure(error, jwt: jwt, generation: generation)
                return
            }
        }
        async let feedTask: Void = refreshFeed(groupID: groupID)
        async let statsTask: Void = refreshStats(groupID: groupID)
        async let seriesTask: Void = refreshActivitySeries(groupID: groupID)
        _ = await (feedTask, statsTask, seriesTask)
    }

    private func handleGroupRefreshFailure(_ error: Error, jwt: String, generation: Int) {
        guard isCurrentAccount, generation == identityCacheGeneration else { return }
        handle(error, jwt: jwt)
        phase = .error(error.localizedDescription)
    }

    func refreshFeed(groupID: String) async {
        guard let jwt = currentJWT else { return }
        let generation = identityCacheGeneration
        isRefreshingFeed[groupID] = true
        defer { isRefreshingFeed[groupID] = false }
        do {
            let res = try await api.getGroupFeed(groupID: groupID, limit: 30, jwt: jwt)
            guard isCurrentAccount,
                  generation == identityCacheGeneration else { return }
            feed[groupID] = res.items
            feedNextSince[groupID] = res.next_since
            feedNextSinceID[groupID] = res.next_since_id
            lastError = nil
        } catch {
            handleGroupRefreshFailure(error, jwt: jwt, generation: generation)
        }
    }

    func refreshStats(groupID: String) async {
        guard let jwt = currentJWT else { return }
        let generation = identityCacheGeneration
        isRefreshingStats[groupID] = true
        defer { isRefreshingStats[groupID] = false }
        do {
            let res = try await api.getGroupStats(groupID: groupID, range: "7d", jwt: jwt)
            guard isCurrentAccount,
                  generation == identityCacheGeneration else { return }
            stats[groupID] = res.members
            lastError = nil
        } catch {
            handleGroupRefreshFailure(error, jwt: jwt, generation: generation)
        }
    }

    /// Pull the per-member daily activity series (year window) that backs
    /// the week/month/year zoom strip. Unavailable shared data uses the same
    /// retryable error state as a failed roster or feed refresh.
    func refreshActivitySeries(groupID: String) async {
        guard let jwt = currentJWT else { return }
        let generation = identityCacheGeneration
        do {
            let res = try await api.getGroupActivity(groupID: groupID, jwt: jwt)
            guard isCurrentAccount,
                  generation == identityCacheGeneration else { return }
            activitySeries[groupID] = res.members
            lastError = nil
        } catch {
            handleGroupRefreshFailure(error, jwt: jwt, generation: generation)
        }
    }

    /// Pull the account/setup snapshot (intervals + coach status) for the
    /// Profile tab. Failure leaves any cached `me` in place.
    func refreshMe() async {
        guard let jwt = currentJWT else { return }
        let generation = identityCacheGeneration
        let operation = intervalsOperation
        do {
            let profile = try await loadProfile(jwt: jwt)
            guard isCurrentAccount,
                  generation == identityCacheGeneration else { return }
            me = profile
            if operation == intervalsOperation && !intervalsBusy {
                acceptIntervalsStatus(profile.intervals)
            }
            lastError = nil
        } catch {
            guard isCurrentAccount else { return }
            if operation == intervalsOperation && !intervalsBusy { intervalsStatusUnavailable = true }
            handle(error, jwt: jwt)
        }
    }

    /// Make `id` the active group and refresh its feed/stats/series. Used by
    /// the Group-tab title switcher and the Profile groups list.
    func selectGroup(_ id: String) {
        guard id != selectedGroupID else { return }
        selectedGroupID = id
        Task { await refreshGroup(groupID: id) }
    }

    // MARK: - Mutations

    /// Create a new group; refresh the list and select it. Returns the
    /// created group on success; throws (and stays put) on failure.
    @discardableResult
    func createGroup(name: String) async throws -> GroupSummary {
        guard let jwt = currentJWT else {
            throw APIError.http(401, "not_signed_in")
        }
        let generation = identityCacheGeneration
        let g = try await api.createGroup(name: name, jwt: jwt)
        guard isCurrentBearer(jwt) else { return g }
        if generation != identityCacheGeneration {
            await load()
            guard isCurrentBearer(jwt) else { return g }
            if let refreshed = groups.first(where: { $0.id == g.id }) {
                selectedGroupID = refreshed.id
                await refreshGroup(groupID: refreshed.id)
                return refreshed
            }
            return g
        }
        // Append + select rather than re-pulling — saves a roundtrip and
        // the server already gave us the hydrated shape.
        if !groups.contains(where: { $0.id == g.id }) { groups.append(g) }
        selectedGroupID = g.id
        phase = .ready
        await refreshGroup(groupID: g.id)
        return g
    }

    /// Redeem an invite code; refresh the list and select the freshly-
    /// joined group. Throws on bad codes (the caller maps the error to a
    /// user-facing string).
    @discardableResult
    func joinGroup(code: String) async throws -> GroupSummary {
        guard let jwt = currentJWT else {
            throw APIError.http(401, "not_signed_in")
        }
        let generation = identityCacheGeneration
        let res = try await api.joinGroup(code: code, jwt: jwt)
        guard isCurrentBearer(jwt) else { return res.group }
        if generation != identityCacheGeneration {
            await load()
            guard isCurrentBearer(jwt) else { return res.group }
            if let refreshed = groups.first(where: { $0.id == res.group.id }) {
                selectedGroupID = refreshed.id
                await refreshGroup(groupID: refreshed.id)
                return refreshed
            }
            return res.group
        }
        if !groups.contains(where: { $0.id == res.group.id }) {
            groups.append(res.group)
        } else {
            // Refresh the hydrated row (e.g. members may have changed
            // between when we last loaded and now).
            if let idx = groups.firstIndex(where: { $0.id == res.group.id }) {
                groups[idx] = res.group
            }
        }
        selectedGroupID = res.group.id
        phase = .ready
        await refreshGroup(groupID: res.group.id)
        return res.group
    }

    /// Result of previewing a deep-linked invite code for the confirm sheet.
    enum InvitePreviewResult: Equatable {
        case valid(groupName: String)
        case used
        case expired
        case unknown
        case failed // network / decode / no-JWT — distinct from a known-bad code
    }

    /// Preview an invite (group name + state) WITHOUT consuming it, for the
    /// Universal-Link join-confirm sheet. Never throws — the sheet renders
    /// each case directly; `failed` (vs `unknown`) lets the UI offer a retry.
    func invitePreview(code: String) async -> InvitePreviewResult {
        guard let jwt = currentJWT else { return .failed }
        do {
            let p = try await api.getInvitePreview(code: code, jwt: jwt)
            switch p.status {
            case "valid": return .valid(groupName: p.group_name ?? "this group")
            case "used": return .used
            case "expired": return .expired
            default: return .unknown
            }
        } catch {
            return .failed
        }
    }

    /// Leave a group. Drops local cache; the server doesn't 404 on
    /// already-gone so this is idempotent.
    func leaveGroup(id: String) async throws {
        guard let jwt = currentJWT else { return }
        try await api.leaveGroup(id: id, jwt: jwt)
        guard isCurrentBearer(jwt) else { return }
        groups.removeAll { $0.id == id }
        feed[id] = nil
        stats[id] = nil
        activitySeries[id] = nil
        feedNextSince[id] = nil
        feedNextSinceID[id] = nil
        ensureSelection()
        phase = groups.isEmpty ? .none : .ready
    }

    /// Set the caller's per-group nickname. Returns the freshly-hydrated
    /// group (with the new name baked into the members list) — we splice
    /// it back into our cache.
    @discardableResult
    func setMyDisplayName(groupID: String, name: String?) async throws -> GroupSummary {
        guard let jwt = currentJWT else {
            throw APIError.http(401, "not_signed_in")
        }
        let generation = identityCacheGeneration
        let updated = try await api.setGroupDisplayName(
            groupID: groupID, displayName: name, jwt: jwt)
        guard isCurrentBearer(jwt) else { return updated }
        if generation != identityCacheGeneration {
            await load()
            return groups.first(where: { $0.id == groupID }) ?? updated
        }
        if let idx = groups.firstIndex(where: { $0.id == groupID }) {
            groups[idx] = updated
        }
        // Stats names are server-resolved on /stats; refresh so the
        // chip-strip shows the new name immediately.
        await refreshStats(groupID: groupID)
        return updated
    }

    /// Mint a new invite code.
    func createInvite(groupID: String) async throws -> GroupInviteCode {
        guard let jwt = currentJWT else {
            throw APIError.http(401, "not_signed_in")
        }
        return try await api.createGroupInvite(groupID: groupID, jwt: jwt)
    }

    // MARK: - Manual activities

    /// Log a manual activity. The flow per spec §6e:
    ///   1. Save to the outbox, then append to the group's feed cache (the
    ///      row appears immediately, even before the server confirms).
    ///   2. POST; on success replace the optimistic row with the server
    ///      row (matches by id, since id IS the idempotency key).
    ///   3. On network failure → retain the outbox entry; the optimistic
    ///      row stays so the user still sees their entry.
    ///   4. On 4xx → roll back the optimistic insert, surface the error.
    ///   5. Refresh the feed so the activity becomes the server-truth
    ///      version (top sets, etc., for a session-typed activity in the
    ///      future will be backend-computed).
    func logActivity(_ pending: PendingActivity) async {
        guard let accountID,
              auth.userID == accountID,
              auth.featureJWT != nil else { return }
        // Persist before optimistic UI or network work so an app kill cannot
        // lose a tap and a failed disk write cannot claim it was queued.
        guard enqueue(pending) else {
            lastError = "Couldn't save this activity on your iPhone. Retry saved data, then try again."
            return
        }
        // 1. Optimistic insert. We construct a fake FeedItem from the
        //    pending payload so the row renders immediately. The display
        //    name comes from the user's own entry in the currently-selected
        //    group's stats (server-resolved); fall back to "You" if stats
        //    haven't loaded yet.
        let myName = currentSelfDisplayName(in: selectedGroupID) ?? "You"
        let optimistic = FeedItem.activity(.init(
            id: pending.id,
            user_id: accountID,
            user_display_name: myName,
            is_me: true,
            date: pending.date,
            occurred_at: pending.logged_at,
            activity: .init(
                kind: pending.type,
                title: pending.title,
                duration_min: pending.duration_minutes,
                notes: pending.notes)))
        if let gid = selectedGroupID {
            var current = feed[gid] ?? []
            current.removeAll { $0.id == pending.id }
            current.insert(optimistic, at: 0)
            feed[gid] = current
        }
        // 2/3/4. Network.
        guard let jwt = currentJWT else {
            return
        }
        do {
            _ = try await persistActivity(pending, jwt: jwt)
            guard isCurrentAccount else { return }
            // A failed removal retains the durable id for a deduplicated retry.
            ActivityOutboxStore.remove(
                id: pending.id, userID: accountID, defaults: defaults)
            outbox = ActivityOutboxStore.load(
                userID: accountID, defaults: defaults)
            // 5. Refresh so the optimistic row is replaced by the
            // server-truth row (same id). Refresh the zoom series too so
            // the new activity lights up its day cell.
            if let gid = selectedGroupID {
                await refreshFeed(groupID: gid)
                await refreshActivitySeries(groupID: gid)
            }
            // Bridge to the personal calendar (SyncModel) — the activity
            // must surface on the day it happened regardless of group.
            await onActivityPersisted?()
        } catch let APIError.http(code, _) where (400..<500).contains(code) && code != 401 {
            guard isCurrentAccount else { return }
            // Validation failure → roll back the optimistic insert and
            // surface the error. 401 falls through to same-user reauthentication.
            if let gid = selectedGroupID {
                feed[gid]?.removeAll { $0.id == pending.id }
            }
            ActivityOutboxStore.remove(id: pending.id, userID: accountID, defaults: defaults)
            outbox = ActivityOutboxStore.load(userID: accountID, defaults: defaults)
            lastError = "Couldn't save activity (server rejected it)."
        } catch {
            guard isCurrentAccount else { return }
            // Already durably queued; the optimistic row stays visible.
            lastError = "Will sync when online."
            handle(error, jwt: jwt)
        }
    }

    private func enqueue(_ pending: PendingActivity) -> Bool {
        guard let accountID,
              auth.userID == accountID,
              auth.featureJWT != nil else { return false }
        let saved = ActivityOutboxStore.enqueue(
            pending, userID: accountID, defaults: defaults)
        outbox = ActivityOutboxStore.load(
            userID: accountID, defaults: defaults)
        return saved && !defaults.hasFailure(userID: accountID)
    }

    /// Drain the outbox. Called on `.task` (mount), on scene-foreground,
    /// and after every successful logActivity. POST is idempotent on
    /// id, so a retry of an already-sent row is safe.
    func drainOutbox() async {
        outbox = ActivityOutboxStore.load(userID: accountID, defaults: defaults)
        guard let jwt = currentJWT, !outbox.isEmpty else { return }
        // Snapshot the pending list so we can mutate `outbox` as we go
        // without invalidating the iteration.
        let pending = outbox.pending
        var didPersist = false
        for entry in pending {
            guard isCurrentAccount else { return }
            do {
                _ = try await persistActivity(entry, jwt: jwt)
                guard isCurrentAccount else { return }
                ActivityOutboxStore.remove(
                    id: entry.id, userID: accountID, defaults: defaults)
                outbox = ActivityOutboxStore.load(
                    userID: accountID, defaults: defaults)
                didPersist = true
            } catch {
                guard isCurrentAccount else { return }
                // Stop on the first network failure — no point hammering a
                // dead network. Server-side 4xx is a permanent failure;
                // drop those so they don't loop forever.
                if case let APIError.http(code, _) = error,
                   (400..<500).contains(code) && code != 401 {
                    ActivityOutboxStore.remove(
                        id: entry.id, userID: accountID, defaults: defaults)
                    outbox = ActivityOutboxStore.load(
                        userID: accountID, defaults: defaults)
                    continue
                }
                handle(error, jwt: jwt)
                break
            }
        }
        guard isCurrentAccount else { return }
        // Only refresh when something actually reached the server. If every
        // item failed on a dead network (the `break` path), the feed +
        // calendar are unchanged — kicking sync.load() here would just fire
        // another doomed request and flash a transient load error on Today.
        guard didPersist else { return }
        // Refresh the visible feed so any newly-sent rows surface from
        // the server (replacing the optimistic ones by id-match).
        if let gid = selectedGroupID {
            await refreshFeed(groupID: gid)
        }
        // Newly-drained rows are now server-truth — refresh the calendar.
        await onActivityPersisted?()
    }

    /// Delete a manual activity (my own row only — the server enforces).
    func deleteActivity(id: String) async {
        guard let jwt = currentJWT else { return }
        do {
            try await removeActivity(id: id, jwt: jwt)
            if !isCurrentBearer(jwt) {
                // The server mutation still belongs to this account after a
                // same-user renewal/reauthentication. Signal the replacement
                // calendar even though this retired model must not touch UI.
                if isCurrentAccount { await onActivityPersisted?() }
                return
            }
            // Strip the row from every group's cache (it could be in
            // any of them).
            for gid in feed.keys {
                feed[gid]?.removeAll { $0.id == id }
            }
            // Re-pull the zoom series for the visible group so the deleted
            // day-cell updates (the series is server-derived, not spliced).
            if let gid = selectedGroupID {
                await refreshActivitySeries(groupID: gid)
            }
            // And drop it from the personal calendar.
            await onActivityPersisted?()
        } catch {
            guard isCurrentBearer(jwt) else { return }
            handle(error, jwt: jwt)
        }
    }

    // MARK: - Account profile

    func updateDisplayName(_ displayName: String) async throws {
        guard let jwt = currentJWT else {
            throw APIError.http(401, "not_signed_in")
        }
        let profile = try await api.updateDisplayName(displayName, jwt: jwt)
        guard isCurrentBearer(jwt) else { return }
        me = profile

        // The global name is materialized as effective_display_name in group
        // summaries, feeds, and stats. Drop every old projection, invalidate
        // in-flight responses, and reload from the server so no group surface
        // can keep rendering the former identity.
        identityCacheGeneration += 1
        groups.removeAll()
        feed.removeAll()
        stats.removeAll()
        activitySeries.removeAll()
        feedNextSince.removeAll()
        feedNextSinceID.removeAll()
        await load()
    }

    // MARK: - Group safety

    /// Drop every shared projection and fence earlier requests. Private history
    /// and the activity outbox are separate and remain intact.
    func invalidateSharedGroups() {
        identityCacheGeneration += 1
        groupSafety = nil
        groups.removeAll()
        feed.removeAll()
        stats.removeAll()
        activitySeries.removeAll()
        feedNextSince.removeAll()
        feedNextSinceID.removeAll()
    }

    func refreshGroupSafety() async throws {
        guard let jwt = currentJWT else { throw APIError.http(401, "not_signed_in") }
        let generation = identityCacheGeneration
        groupSafety = nil
        do {
            let state: GroupSafetyState
            if let groupSafetyLoader { state = try await groupSafetyLoader(jwt) }
            else { state = try await api.getGroupSafety(jwt: jwt) }
            guard isCurrentAccount, generation == identityCacheGeneration else { return }
            groupSafety = state
        } catch {
            guard isCurrentAccount else { return }
            handle(error, jwt: jwt)
            throw error
        }
    }

    func setGroupBlock(userID: String, active: Bool) async throws {
        try await changeGroupSafety { jwt in
            if let groupBlockWriter { try await groupBlockWriter(userID, active, jwt) }
            else { try await api.setGroupBlock(userID: userID, active: active, jwt: jwt) }
        }
    }

    func setSharingRestriction(userID: String, active: Bool, reason: GroupReportReason) async throws {
        try await changeGroupSafety { jwt in
            if let groupRestrictionWriter { try await groupRestrictionWriter(userID, active, reason, jwt) }
            else { try await api.setSharingRestriction(userID: userID, active: active, reason: reason, jwt: jwt) }
        }
    }

    /// Both safety writes share the same uncertain-response and refresh rules.
    private func changeGroupSafety(_ write: (String) async throws -> Void) async throws {
        guard let jwt = currentJWT else { throw APIError.http(401, "not_signed_in") }
        invalidateSharedGroups()
        do {
            try await write(jwt)
        } catch {
            guard isCurrentAccount else { return }
            handle(error, jwt: jwt)
            // Reconcile an unavailable member or uncertain write without
            // restoring the old cache. Offline reloads expose the retry state.
            await reloadGroupState()
            throw error
        }
        guard isCurrentAccount else { return }
        invalidateSharedGroups()
        // A failed refresh cannot turn an acknowledged write into a failed
        // mutation. Retain empty projections until a later successful load.
        await reloadGroupState()
    }

    // MARK: - Intervals.icu

    private func acceptIntervalsStatus(_ status: MeProfile.IntervalsStatus) {
        intervalsStatus = status
        intervalsStatusUnavailable = false
        if !status.connected {
            intervalsConnection = nil
            Self.saveIntervalsConnection(nil, userID: accountID, defaults: defaults)
        }
        if status.needs_reauth == true { intervalsImportStatus = .reconnect }
        else if status.sync_pending == true { intervalsImportStatus = .retry }
        else { intervalsImportStatus = nil }
    }

    private func beginIntervalsOperation() -> Int {
        intervalsOperation += 1
        intervalsBusy = true
        return intervalsOperation
    }

    private func finishIntervalsOperation(_ operation: Int) {
        guard operation == intervalsOperation else { return }
        // Invalidate profile reads that started during the mutation, too.
        intervalsOperation += 1
        intervalsBusy = false
    }

    private func isCurrentIntervalsOperation(_ operation: Int) -> Bool {
        isCurrentAccount && operation == intervalsOperation
    }

    private func writeIntervalsCredentials(
        apiKey: String?, athleteID: String?, jwt: String
    ) async throws -> APIClient.IntervalsConnectResult {
        if let intervalsConnector { return try await intervalsConnector(apiKey, athleteID, jwt) }
        return try await api.setIntervalsCredentials(apiKey: apiKey, athleteID: athleteID, jwt: jwt)
    }

    private func publishIntervalsImport(_ result: IntervalsImportResult, operation: Int) async {
        guard isCurrentIntervalsOperation(operation) else { return }
        if let connection = result.connection { acceptIntervalsStatus(connection) }
        else { intervalsStatusUnavailable = true }
        if result.connection?.needs_reauth == true { intervalsImportStatus = .reconnect }
        else if result.connection?.connected == false { intervalsImportStatus = .disconnected }
        else { intervalsImportStatus = result.status }
        if result.status == .synced {
            await onActivityPersisted?()
            guard isCurrentIntervalsOperation(operation) else { return }
            if let id = selectedGroupID { await refreshGroup(groupID: id) }
        }
    }

    /// A credential acknowledgement is retained even if the initial import
    /// needs retry. Neither a failed import nor a profile read asks for a
    /// second credential write.
    func setIntervalsCredentials(apiKey: String, athleteID: String) async throws {
        guard let jwt = currentJWT else { throw APIError.http(401, "not_signed_in") }
        let operation = beginIntervalsOperation()
        defer { finishIntervalsOperation(operation) }
        let resolvedAthlete = athleteID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "0" : athleteID
        do {
            let receipt = try await writeIntervalsCredentials(apiKey: apiKey, athleteID: resolvedAthlete, jwt: jwt)
            guard isCurrentIntervalsOperation(operation) else { return }
            acceptIntervalsStatus(.init(connected: receipt.connected,
                athlete_id: receipt.connected ? resolvedAthlete : nil, needs_reauth: false,
                credential_generation: receipt.credential_generation, sync_pending: receipt.connected))
            await loadIntervalsAfterAcknowledgement(jwt: jwt, operation: operation,
                expectedGeneration: receipt.credential_generation, syncAfter: receipt.activity_sync_after)
        } catch {
            guard isCurrentIntervalsOperation(operation) else { return }
            handle(error, jwt: jwt)
            throw error
        }
    }

    func disconnectIntervals() async throws {
        guard let jwt = currentJWT else { throw APIError.http(401, "not_signed_in") }
        let operation = beginIntervalsOperation()
        defer { finishIntervalsOperation(operation) }
        do {
            let receipt = try await writeIntervalsCredentials(apiKey: nil, athleteID: nil, jwt: jwt)
            guard isCurrentIntervalsOperation(operation) else { return }
            acceptIntervalsStatus(.init(connected: false, athlete_id: nil, needs_reauth: false,
                credential_generation: receipt.credential_generation, sync_pending: false))
        } catch {
            guard isCurrentIntervalsOperation(operation) else { return }
            handle(error, jwt: jwt)
            throw error
        }
    }

    /// Explicit retry is pinned to the current server connection generation.
    func retryIntervalsSync() async {
        guard let jwt = currentJWT else { return }
        guard let generation = intervalsStatus?.credential_generation,
              !intervalsStatusUnavailable else { await refreshMe(); return }
        let operation = beginIntervalsOperation()
        defer { finishIntervalsOperation(operation) }
        do {
            let result: IntervalsImportResult
            if let intervalsImporter { result = try await intervalsImporter(generation, jwt) }
            else { result = try await api.syncIntervals(expectedGeneration: generation, jwt: jwt) }
            await publishIntervalsImport(result, operation: operation)
        } catch {
            guard isCurrentIntervalsOperation(operation) else { return }
            intervalsImportStatus = .retry
            handle(error, jwt: jwt)
        }
    }

    /// Observe the bounded background import after the write was acknowledged.
    /// Polls never repeat credentials or start a competing provider import.
    private func loadIntervalsAfterAcknowledgement(
        jwt: String, operation: Int, expectedGeneration: Int?, syncAfter: Int?
    ) async {
        for delay in intervalsPollDelays {
            var requestJWT = jwt
            do {
                if delay > 0 { try await Task.sleep(nanoseconds: delay) }
                guard isCurrentIntervalsOperation(operation) else { return }
                requestJWT = currentJWT ?? jwt
                let profile = try await loadProfile(jwt: requestJWT)
                guard isCurrentIntervalsOperation(operation) else { return }
                let connection = profile.intervals
                acceptIntervalsStatus(connection)
                if let expectedGeneration, connection.credential_generation != expectedGeneration { return }
                if !connection.connected { return }
                let hasNewSync = connection.last_synced_at.map { $0 > (syncAfter ?? -1) } ?? false
                if connection.sync_pending != true && (syncAfter == nil || hasNewSync) {
                    if connection.sync_pending == false && hasNewSync {
                        await publishIntervalsImport(.init(status: .synced, connection: connection), operation: operation)
                    }
                    return
                }
            } catch {
                guard isCurrentIntervalsOperation(operation) else { return }
                intervalsStatusUnavailable = true
                // A status read failure cannot become a second connect attempt.
                handle(error, jwt: requestJWT)
                return
            }
        }
        intervalsImportStatus = .retry
    }

    @discardableResult
    func connectIntervalsViaOAuth() async throws -> Bool {
        guard let jwt = currentJWT else { throw APIError.http(401, "not_signed_in") }
        let operation = beginIntervalsOperation()
        defer { finishIntervalsOperation(operation) }
        do {
            let result: IntervalsOAuthResult
            if let intervalsAuthorizer { result = try await intervalsAuthorizer(jwt) }
            else {
                let url = try await api.startIntervalsOAuth(jwt: jwt)
                guard isCurrentIntervalsOperation(operation) else { return false }
                result = try await IntervalsWebAuth().authorize(url)
            }
            guard isCurrentIntervalsOperation(operation), result.connected else { return false }
            // The redirect acknowledges a saved connection, but only a fresh
            // profile can say whether it remains connected after import.
            intervalsStatus = nil
            await loadIntervalsAfterAcknowledgement(jwt: jwt, operation: operation, expectedGeneration: result.credentialGeneration, syncAfter: result.activitySyncAfter)
            guard isCurrentIntervalsOperation(operation) else { return false }
            return true
        } catch {
            guard isCurrentIntervalsOperation(operation) else { return false }
            handle(error, jwt: jwt)
            throw error
        }
    }

    // MARK: - Apple Health

    /// Flip the Apple Health group-feed opt-in (PATCH /api/me/health-sharing,
    /// migration 0028) and refresh `me` so the toggle reflects server truth.
    /// HealthKit reading/pushing itself lives in HealthKitSyncModel — this only
    /// controls cross-user VISIBILITY of those activities in the group feed.
    /// A settings entry must establish fresh sharing truth even when Profile
    /// has never appeared. A missing/failed profile is unknown, never off.
    func readHealthSharing() async throws -> Bool {
        guard let jwt = currentJWT else { throw APIError.http(401, "not_signed_in") }
        let epoch = auth.featureSessionEpoch
        do {
            let profile = try await loadProfile(jwt: jwt)
            guard auth.isCurrentFeatureSession(accountID: accountID, epoch: epoch),
                  !Task.isCancelled else { throw CancellationError() }
            guard let health = profile.health else { throw URLError(.cannotParseResponse) }
            return health.sharing_in_group
        } catch {
            if isCurrentAccount { handle(error, jwt: jwt) }
            throw error
        }
    }

    func setHealthSharing(_ enabled: Bool) async throws {
        guard let jwt = currentJWT else {
            throw APIError.http(401, "not_signed_in")
        }
        _ = try await api.setHealthSharing(enabled: enabled, jwt: jwt)
        guard isCurrentBearer(jwt) else { return }
        await refreshMe()
    }

    // MARK: - Coach connect code (M3)

    /// Generate a fresh MCP connect code, store it server-side, and return the
    /// plaintext for one-time display. The user copies it into their AI app's
    /// connection flow to bind their own AI coach to this account. The server keeps
    /// only a PBKDF2 hash, so the plaintext lives only here and on the user's
    /// screen — regenerating just rotates it (existing linked AI app sessions
    /// keep working, since their token was already bound at authorize time).
    func generateCoachConnectCode() async throws -> String {
        guard let jwt = currentJWT else {
            throw APIError.http(401, "not_signed_in")
        }
        let epoch = auth.featureSessionEpoch
        let code = Self.makeConnectCode()
        if let coachCodeWriter {
            try await coachCodeWriter(code, jwt)
        } else {
            try await api.setMcpConnectCode(code, jwt: jwt)
        }
        // Renewal can replace the bearer while this one-time code is being
        // saved. Retain it for the same feature session, but never after a
        // sign-out or reauthentication, even when the same account returns.
        guard auth.isCurrentFeatureSession(accountID: accountID, epoch: epoch) else {
            throw CancellationError()
        }
        await refreshMe()
        guard auth.isCurrentFeatureSession(accountID: accountID, epoch: epoch) else {
            throw CancellationError()
        }
        return code
    }

    /// Returns true when the post-revocation profile refresh also succeeded.
    /// A false result still means revocation committed; callers must not retry
    /// the destructive request merely because the follow-up read failed.
    func disconnectCoach() async throws -> Bool {
        guard let jwt = currentJWT else {
            throw APIError.http(401, "not_signed_in")
        }
        _ = try await api.disconnectCoach(jwt: jwt)
        guard isCurrentBearer(jwt) else { return true }
        if let current = me {
            me = MeProfile(
                display_name: current.display_name,
                email: current.email,
                intervals: current.intervals,
                coach: .init(
                    is_owner: current.coach.is_owner,
                    connected: false,
                    last_active: current.coach.last_active),
                health: current.health)
        }
        do {
            me = try await loadProfile(jwt: jwt)
            lastError = nil
            return true
        } catch {
            handle(error, jwt: jwt)
            return false
        }
    }

    /// 16 chars of an unambiguous base-32 alphabet (no I/L/O/0/1), grouped
    /// 4×4 with dashes for legibility — e.g. `K7M4-PQ2R-9XTW-6NBV`. ~78 bits of
    /// entropy: far above the server's 8-char minimum and collision-safe
    /// against other users' codes. Copy-paste preserves the dashes, which are
    /// part of the stored code.
    private static func makeConnectCode() -> String {
        let alphabet = Array("ABCDEFGHJKMNPQRSTUVWXYZ23456789")
        let groups = (0..<4).map { _ in
            String((0..<4).map { _ in alphabet.randomElement()! })
        }
        return groups.joined(separator: "-")
    }

    // MARK: - Helpers

    /// The caller's effective display name in a given group — pull from
    /// the GroupSummary members (server resolves override OR global).
    /// Used for the optimistic `logActivity` insert.
    func currentSelfDisplayName(in groupID: String?) -> String? {
        guard let accountID,
              let gid = groupID,
              let g = groups.first(where: { $0.id == gid })
        else {
            return nil
        }
        if let me = g.members.first(where: { $0.user_id == accountID }) {
            return me.effective_display_name
        }
        return nil
    }

    private func handle(_ error: Error, jwt: String) {
        if case let APIError.http(code, _) = error, code == 401 {
            if isCurrentBearer(jwt) {
                auth.requireReauthentication()
            }
        } else {
            lastError = error.localizedDescription
        }
    }
}
