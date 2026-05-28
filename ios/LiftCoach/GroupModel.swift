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

    // MARK: Per-group caches (keyed by group.id)

    @Published var feed: [String: [FeedItem]] = [:]
    @Published var stats: [String: [MemberStat]] = [:]
    @Published var feedNextSince: [String: Int?] = [:]
    @Published var isRefreshingFeed: [String: Bool] = [:]
    @Published var isRefreshingStats: [String: Bool] = [:]

    // MARK: Intervals.icu connection

    /// What the user last successfully PATCHed. There's no GET endpoint
    /// today, so this is the only place iOS knows about a connection.
    /// Persisted in @AppStorage by IntervalsSettingsView itself; mirrored
    /// here for convenience reads.
    @AppStorage("com.nmarkspdx.liftcoach.intervals-connection.v1")
    var intervalsConnectionRaw: Data = Data()
    var intervalsConnection: IntervalsConnection? {
        get {
            guard !intervalsConnectionRaw.isEmpty else { return nil }
            return try? JSONDecoder().decode(IntervalsConnection.self,
                                             from: intervalsConnectionRaw)
        }
        set {
            if let v = newValue {
                intervalsConnectionRaw = (try? JSONEncoder().encode(v)) ?? Data()
            } else {
                intervalsConnectionRaw = Data()
            }
        }
    }

    // MARK: Activity outbox (the one persisted piece)

    @Published private(set) var outbox: ActivityOutbox

    // MARK: Latest-error reporting (one slot — last error wins)

    @Published var lastError: String?

    // MARK: Deps

    private let api = APIClient()
    private unowned let auth: AuthModel

    init(auth: AuthModel) {
        self.auth = auth
        self.outbox = ActivityOutboxStore.load()
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
        guard let jwt = auth.jwt else { phase = .loading; return }
        phase = .loading
        do {
            let list = try await api.listGroups(jwt: jwt)
            groups = list
            // Honor a fresh-after-redeem invite from /auth/apple — pre-
            // select the group the user just joined so the tab opens to it
            // instead of (potentially) some older group.
            if let pending = auth.pendingGroupID,
               list.contains(where: { $0.id == pending }) {
                selectedGroupID = pending
                auth.pendingGroupID = nil
            } else {
                ensureSelection()
            }
            phase = list.isEmpty ? .none : .ready
            lastError = nil
            // Refresh the visible group's feed/stats so the tab is hot.
            if let id = selectedGroupID {
                await refreshGroup(groupID: id)
            }
            // Drain any pending activity POSTs that survived a relaunch.
            await drainOutbox()
        } catch {
            handle(error)
            phase = .error(error.localizedDescription)
        }
    }

    /// Refresh BOTH the feed and the stats for one group. Used by
    /// pull-to-refresh and after a `logActivity` succeeds.
    func refreshGroup(groupID: String) async {
        async let feedTask: Void = refreshFeed(groupID: groupID)
        async let statsTask: Void = refreshStats(groupID: groupID)
        _ = await (feedTask, statsTask)
    }

    func refreshFeed(groupID: String) async {
        guard let jwt = auth.jwt else { return }
        isRefreshingFeed[groupID] = true
        defer { isRefreshingFeed[groupID] = false }
        do {
            let res = try await api.getGroupFeed(groupID: groupID, limit: 30, jwt: jwt)
            feed[groupID] = res.items
            feedNextSince[groupID] = res.next_since
            lastError = nil
        } catch {
            handle(error)
        }
    }

    func refreshStats(groupID: String) async {
        guard let jwt = auth.jwt else { return }
        isRefreshingStats[groupID] = true
        defer { isRefreshingStats[groupID] = false }
        do {
            let res = try await api.getGroupStats(groupID: groupID, range: "7d", jwt: jwt)
            stats[groupID] = res.members
            lastError = nil
        } catch {
            handle(error)
        }
    }

    // MARK: - Mutations

    /// Create a new group; refresh the list and select it. Returns the
    /// created group on success; throws (and stays put) on failure.
    @discardableResult
    func createGroup(name: String) async throws -> GroupSummary {
        guard let jwt = auth.jwt else {
            throw APIError.http(401, "not_signed_in")
        }
        let g = try await api.createGroup(name: name, jwt: jwt)
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
        guard let jwt = auth.jwt else {
            throw APIError.http(401, "not_signed_in")
        }
        let res = try await api.joinGroup(code: code, jwt: jwt)
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

    /// Leave a group. Drops local cache; the server doesn't 404 on
    /// already-gone so this is idempotent.
    func leaveGroup(id: String) async throws {
        guard let jwt = auth.jwt else { return }
        try await api.leaveGroup(id: id, jwt: jwt)
        groups.removeAll { $0.id == id }
        feed[id] = nil
        stats[id] = nil
        feedNextSince[id] = nil
        ensureSelection()
        phase = groups.isEmpty ? .none : .ready
    }

    /// Set the caller's per-group nickname. Returns the freshly-hydrated
    /// group (with the new name baked into the members list) — we splice
    /// it back into our cache.
    @discardableResult
    func setMyDisplayName(groupID: String, name: String?) async throws -> GroupSummary {
        guard let jwt = auth.jwt else {
            throw APIError.http(401, "not_signed_in")
        }
        let updated = try await api.setGroupDisplayName(
            groupID: groupID, displayName: name, jwt: jwt)
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
        guard let jwt = auth.jwt else {
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
        // 1. Optimistic insert. We construct a fake FeedItem from the
        //    pending payload so the row renders immediately. The display
        //    name comes from the user's own entry in the currently-selected
        //    group's stats (server-resolved); fall back to "You" if stats
        //    haven't loaded yet.
        let myName = currentSelfDisplayName(in: selectedGroupID) ?? "You"
        let optimistic = FeedItem.activity(.init(
            id: pending.id,
            user_id: auth.userID ?? "self",
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
        guard let jwt = auth.jwt else {
            // Not signed in — enqueue so it goes out next time. Should be
            // unreachable from a signed-in UI but defensive.
            enqueue(pending)
            return
        }
        do {
            _ = try await api.logActivity(pending, jwt: jwt)
            // Success — remove from outbox if we had previously enqueued
            // it on a prior attempt (no-op if not present).
            outbox.remove(id: pending.id)
            ActivityOutboxStore.save(outbox)
            // 5. Refresh so the optimistic row is replaced by the
            // server-truth row (same id).
            if let gid = selectedGroupID {
                await refreshFeed(groupID: gid)
            }
        } catch let APIError.http(code, _) where (400..<500).contains(code) && code != 401 {
            // Validation failure → roll back the optimistic insert and
            // surface the error. 401 falls through to handle() → invalidate().
            if let gid = selectedGroupID {
                feed[gid]?.removeAll { $0.id == pending.id }
            }
            lastError = "Couldn't save activity (server rejected it)."
        } catch {
            // Network failure (incl. 5xx) → enqueue; the optimistic row
            // stays visible. Surface a soft hint.
            enqueue(pending)
            lastError = "Will sync when online."
            handle(error)
        }
    }

    private func enqueue(_ pending: PendingActivity) {
        outbox.enqueue(pending)
        ActivityOutboxStore.save(outbox)
    }

    /// Drain the outbox. Called on `.task` (mount), on scene-foreground,
    /// and after every successful logActivity. POST is idempotent on
    /// id, so a retry of an already-sent row is safe.
    func drainOutbox() async {
        guard let jwt = auth.jwt, !outbox.isEmpty else { return }
        // Snapshot the pending list so we can mutate `outbox` as we go
        // without invalidating the iteration.
        let pending = outbox.pending
        for entry in pending {
            do {
                _ = try await api.logActivity(entry, jwt: jwt)
                outbox.remove(id: entry.id)
                ActivityOutboxStore.save(outbox)
            } catch {
                // Stop on the first network failure — no point hammering a
                // dead network. Server-side 4xx is a permanent failure;
                // drop those so they don't loop forever.
                if case let APIError.http(code, _) = error,
                   (400..<500).contains(code) && code != 401 {
                    outbox.remove(id: entry.id)
                    ActivityOutboxStore.save(outbox)
                    continue
                }
                handle(error)
                break
            }
        }
        // Refresh the visible feed so any newly-sent rows surface from
        // the server (replacing the optimistic ones by id-match).
        if let gid = selectedGroupID {
            await refreshFeed(groupID: gid)
        }
    }

    /// Delete a manual activity (my own row only — the server enforces).
    func deleteActivity(id: String) async {
        guard let jwt = auth.jwt else { return }
        do {
            try await api.deleteActivity(id: id, jwt: jwt)
            // Strip the row from every group's cache (it could be in
            // any of them).
            for gid in feed.keys {
                feed[gid]?.removeAll { $0.id == id }
            }
        } catch {
            handle(error)
        }
    }

    // MARK: - Intervals.icu

    /// PATCH /api/me/integrations/intervals. Persists the connection
    /// locally on success so the settings view can render "Connected"
    /// across app restarts.
    func setIntervalsCredentials(apiKey: String, athleteID: String) async throws {
        guard let jwt = auth.jwt else {
            throw APIError.http(401, "not_signed_in")
        }
        _ = try await api.setIntervalsCredentials(
            apiKey: apiKey, athleteID: athleteID, jwt: jwt)
        intervalsConnection = IntervalsConnection(
            athlete_id: athleteID,
            connected_at: Int(Date().timeIntervalSince1970 * 1000))
    }

    func disconnectIntervals() async throws {
        guard let jwt = auth.jwt else {
            throw APIError.http(401, "not_signed_in")
        }
        _ = try await api.setIntervalsCredentials(
            apiKey: nil, athleteID: nil, jwt: jwt)
        intervalsConnection = nil
    }

    // MARK: - Helpers

    /// The caller's effective display name in a given group — pull from
    /// the GroupSummary members (server resolves override OR global).
    /// Used for the optimistic `logActivity` insert.
    func currentSelfDisplayName(in groupID: String?) -> String? {
        guard let gid = groupID, let g = groups.first(where: { $0.id == gid }) else {
            return nil
        }
        let uid = auth.userID
        if let me = g.members.first(where: { $0.user_id == uid }) {
            return me.effective_display_name
        }
        return nil
    }

    private func handle(_ error: Error) {
        if case let APIError.http(code, _) = error, code == 401 {
            auth.invalidate()
        } else {
            lastError = error.localizedDescription
        }
    }
}
