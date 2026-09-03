import SwiftUI

/// Owns all group-accountability state. Peer to `SyncModel` (the existing
/// strength-world model) — by design these don't share state, only the
/// `AuthModel` reference. Per `.context/m5-ios-spec.md` §4a:
///
///   * Volumes are tiny (<10 members per group, <30 feed items per pull),
///     so everything lives in @Published in-memory arrays — no SwiftData
///     mirror, full-replace on every refresh.
///   * The only persisted piece is `ActivityOutbox` (UserDefaults), so a
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
    /// server-derived intervals + Claude-connector status.
    @Published var me: MeProfile?

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

    // MARK: Activity outbox (the one persisted piece)

    @Published private(set) var outbox: ActivityOutbox

    // MARK: Latest-error reporting (one slot — last error wins)

    @Published var lastError: String?

    // MARK: Deps

    private let api = APIClient()
    private unowned let auth: AuthModel
    private let accountID: String?
    private let defaults: UserDefaults
    private let activityLogger: ((PendingActivity, String) async throws -> ActivityRow)?
    private let activityDeleter: ((String, String) async throws -> Void)?
    private let groupLister: ((String) async throws -> [GroupSummary])?
    private let profileLoader: ((String) async throws -> MeProfile)?
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
        defaults: UserDefaults = .standard,
        activityLogger: ((PendingActivity, String) async throws -> ActivityRow)? = nil,
        activityDeleter: ((String, String) async throws -> Void)? = nil,
        groupLister: ((String) async throws -> [GroupSummary])? = nil,
        profileLoader: ((String) async throws -> MeProfile)? = nil
    ) {
        self.auth = auth
        self.accountID = auth.userID
        self.defaults = defaults
        self.activityLogger = activityLogger
        self.activityDeleter = activityDeleter
        self.groupLister = groupLister
        self.profileLoader = profileLoader
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
        defaults: UserDefaults = .standard
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
        defaults: UserDefaults = .standard
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

    /// Pull the groups list + drain the outbox. Sets `phase` to
    /// `.none` / `.ready` / `.error` accordingly. Called on tab `.task`
    /// and on scene-foreground transitions.
    func load() async {
        guard let jwt = currentJWT else { phase = .loading; return }
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
                await refreshGroup(groupID: id)
            }
            // Drain any pending activity POSTs that survived a relaunch.
            await drainOutbox()
            // Account/setup snapshot for the Profile tab.
            await refreshMe()
        } catch {
            guard isCurrentAccount else { return }
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

    /// Refresh BOTH the feed and the stats for one group. Used by
    /// pull-to-refresh and after a `logActivity` succeeds.
    func refreshGroup(groupID: String) async {
        async let feedTask: Void = refreshFeed(groupID: groupID)
        async let statsTask: Void = refreshStats(groupID: groupID)
        async let seriesTask: Void = refreshActivitySeries(groupID: groupID)
        _ = await (feedTask, statsTask, seriesTask)
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
            guard isCurrentAccount else { return }
            handle(error, jwt: jwt)
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
            guard isCurrentAccount else { return }
            handle(error, jwt: jwt)
        }
    }

    /// Pull the per-member daily activity series (year window) that backs
    /// the week/month/year zoom strip. Failure leaves the cached series in
    /// place (same forgiving stance as feed/stats).
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
            guard isCurrentAccount else { return }
            handle(error, jwt: jwt)
        }
    }

    /// Pull the account/setup snapshot (intervals + Claude status) for the
    /// Profile tab. Failure leaves any cached `me` in place.
    func refreshMe() async {
        guard let jwt = currentJWT else { return }
        let generation = identityCacheGeneration
        do {
            let profile = try await loadProfile(jwt: jwt)
            guard isCurrentAccount,
                  generation == identityCacheGeneration else { return }
            me = profile
            lastError = nil
        } catch {
            guard isCurrentAccount else { return }
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
    ///   1. Optimistically append to the current group's feed cache (the
    ///      row appears immediately, even before the server confirms).
    ///   2. POST; on success replace the optimistic row with the server
    ///      row (matches by id, since id IS the idempotency key).
    ///   3. On network failure → enqueue to the outbox; the optimistic
    ///      row stays so the user still sees their entry.
    ///   4. On 4xx → roll back the optimistic insert, surface the error.
    ///   5. Refresh the feed so the activity becomes the server-truth
    ///      version (top sets, etc., for a session-typed activity in the
    ///      future will be backend-computed).
    func logActivity(_ pending: PendingActivity) async {
        guard let accountID,
              auth.userID == accountID,
              auth.featureJWT != nil else { return }
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
            current.insert(optimistic, at: 0)
            feed[gid] = current
        }
        // 2/3/4. Network.
        guard let jwt = currentJWT else {
            // Not signed in — enqueue so it goes out next time. Should be
            // unreachable from a signed-in UI but defensive.
            enqueue(pending)
            return
        }
        do {
            _ = try await persistActivity(pending, jwt: jwt)
            guard isCurrentAccount else { return }
            // Success — remove from outbox if we had previously enqueued
            // it on a prior attempt (no-op if not present).
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
            lastError = "Couldn't save activity (server rejected it)."
        } catch {
            guard isCurrentAccount else { return }
            // Network failure (incl. 5xx) → enqueue; the optimistic row
            // stays visible. Surface a soft hint.
            enqueue(pending)
            lastError = "Will sync when online."
            handle(error, jwt: jwt)
        }
    }

    private func enqueue(_ pending: PendingActivity) {
        guard let accountID,
              auth.userID == accountID,
              auth.featureJWT != nil else { return }
        ActivityOutboxStore.enqueue(
            pending, userID: accountID, defaults: defaults)
        outbox = ActivityOutboxStore.load(
            userID: accountID, defaults: defaults)
    }

    /// Drain the outbox. Called on `.task` (mount), on scene-foreground,
    /// and after every successful logActivity. POST is idempotent on
    /// id, so a retry of an already-sent row is safe.
    func drainOutbox() async {
        guard let jwt = currentJWT, !outbox.isEmpty else { return }
        // Snapshot the pending list so we can mutate `outbox` as we go
        // without invalidating the iteration.
        let pending = outbox.pending
        var didPersist = false
        for entry in pending {
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

    // MARK: - Intervals.icu

    /// PATCH /api/me/integrations/intervals. Persists the connection
    /// locally on success so the settings view can render "Connected"
    /// across app restarts.
    func setIntervalsCredentials(apiKey: String, athleteID: String) async throws {
        guard let jwt = currentJWT else {
            throw APIError.http(401, "not_signed_in")
        }
        // intervals.icu supports athlete id "0" = the athlete that owns the
        // API key, so a blank Athlete ID is valid (#1094). Send "0" and the
        // backend's .../athlete/{id}/... path resolves to the key's owner.
        let resolvedAthlete =
            athleteID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                ? "0" : athleteID
        _ = try await api.setIntervalsCredentials(
            apiKey: apiKey, athleteID: resolvedAthlete, jwt: jwt)
        guard isCurrentBearer(jwt) else { return }
        intervalsConnection = IntervalsConnection(
            athlete_id: resolvedAthlete,
            connected_at: Int(Date().timeIntervalSince1970 * 1000))
        Self.saveIntervalsConnection(
            intervalsConnection, userID: accountID, defaults: defaults)
        await refreshMe()
    }

    func disconnectIntervals() async throws {
        guard let jwt = currentJWT else {
            throw APIError.http(401, "not_signed_in")
        }
        _ = try await api.setIntervalsCredentials(
            apiKey: nil, athleteID: nil, jwt: jwt)
        guard isCurrentBearer(jwt) else { return }
        intervalsConnection = nil
        Self.saveIntervalsConnection(
            nil, userID: accountID, defaults: defaults)
        await refreshMe()
    }

    /// One-tap intervals.icu connect via OAuth: fetch the authorize URL, run
    /// the ASWebAuthenticationSession sheet, and refresh the profile on a
    /// connected callback. The bearer token is exchanged + stored server-side
    /// (the app never sees it), so success is reflected purely by re-reading
    /// `/api/me` (`me.intervals.connected`). Returns false when the user
    /// dismissed the sheet — the caller treats that as a no-op, not an error.
    @discardableResult
    func connectIntervalsViaOAuth() async throws -> Bool {
        guard let jwt = currentJWT else {
            throw APIError.http(401, "not_signed_in")
        }
        let url = try await api.startIntervalsOAuth(jwt: jwt)
        guard isCurrentBearer(jwt) else { return false }
        let web = IntervalsWebAuth()
        let connected = try await web.authorize(url)
        guard isCurrentBearer(jwt) else { return false }
        if connected { await refreshMe() }
        return connected
    }

    // MARK: - Apple Health

    /// Flip the Apple Health group-feed opt-in (PATCH /api/me/health-sharing,
    /// migration 0028) and refresh `me` so the toggle reflects server truth.
    /// HealthKit reading/pushing itself lives in HealthKitSyncModel — this only
    /// controls cross-user VISIBILITY of those activities in the group feed.
    func setHealthSharing(_ enabled: Bool) async throws {
        guard let jwt = currentJWT else {
            throw APIError.http(401, "not_signed_in")
        }
        _ = try await api.setHealthSharing(enabled: enabled, jwt: jwt)
        guard isCurrentBearer(jwt) else { return }
        await refreshMe()
    }

    // MARK: - Claude connect code (M3)

    /// Generate a fresh MCP connect code, store it server-side, and return the
    /// plaintext for one-time display. The user copies it into Claude's custom
    /// connector to bind their own AI coach to this account. The server keeps
    /// only a PBKDF2 hash, so the plaintext lives only here and on the user's
    /// screen — regenerating just rotates it (existing linked Claude sessions
    /// keep working, since their token was already bound at authorize time).
    func generateClaudeConnectCode() async throws -> String {
        guard let jwt = currentJWT else {
            throw APIError.http(401, "not_signed_in")
        }
        let code = Self.makeConnectCode()
        try await api.setMcpConnectCode(code, jwt: jwt)
        await refreshMe()
        return code
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
