import Foundation

// REST surface for the M1/M2/M3/M4 group accountability endpoints.
//
// All methods are JWT-authed (the M2 routes mount `requireAppJwt` at the
// top), match the wire shape in src/routes/api.ts verbatim, and return
// already-decoded models from `GroupModels.swift`. Network errors / HTTP
// non-2xx surface as `APIError.http` — callers can pattern-match the
// status code (401 → AuthModel.invalidate(), 409/410 → "expired code",
// etc.) at the call site.

extension APIClient {

    // MARK: - M1: Intervals.icu credentials

    /// PATCH /api/me/integrations/intervals — connect or disconnect.
    /// Pass both args non-nil to connect; pass both nil to disconnect.
    /// Returns `{ connected: bool }`. Side effect: backend starts polling
    /// (or stops) on the next sync tick.
    func setIntervalsCredentials(apiKey: String?,
                                 athleteID: String?,
                                 jwt: String) async throws -> IntervalsConnectResult {
        // Both keys must be present in the body (the route 400s on missing
        // keys to defend against a typo accidentally clearing creds). Use
        // NSNull so the JSON literally contains `null`.
        let body: [String: Any] = [
            "api_key": apiKey as Any? ?? NSNull(),
            "athlete_id": athleteID as Any? ?? NSNull(),
        ]
        return try await patch("api/me/integrations/intervals", body: body, jwt: jwt)
    }

    struct IntervalsConnectResult: Decodable, Equatable {
        let connected: Bool
    }

    // MARK: - M2: Groups CRUD

    /// POST /api/groups — create a new group, auto-add the creator as the
    /// sole member. Backend audits the write; returns the full hydrated
    /// shape so the caller can route directly to it.
    func createGroup(name: String, jwt: String) async throws -> GroupSummary {
        try await post("api/groups", body: ["name": name], jwt: jwt)
    }

    /// GET /api/groups — list groups the caller belongs to (stable order).
    func listGroups(jwt: String) async throws -> [GroupSummary] {
        let r: GroupsListResponse = try await get("api/groups", jwt: jwt)
        return r.groups
    }

    /// GET /api/groups/:id — single group with members hydrated.
    func getGroup(id: String, jwt: String) async throws -> GroupSummary {
        try await get("api/groups/\(id)", jwt: jwt)
    }

    /// POST /api/groups/:id/invites — mint a new 6-char invite code (TTL
    /// default 30d). Caller must already be a member; non-members 403.
    func createGroupInvite(groupID: String,
                           expiresAt: Int? = nil,
                           jwt: String) async throws -> GroupInviteCode {
        // Spec contract: undefined => server default (30d); null => never
        // expires; number => exact epoch. We only support the first case
        // from the UI today (no "advanced" expiry picker), so always send
        // an empty body — the route's catch falls back to {} on parse fail.
        var body: [String: Any] = [:]
        if let expiresAt { body["expires_at"] = expiresAt }
        return try await post("api/groups/\(groupID)/invites", body: body, jwt: jwt)
    }

    /// POST /api/groups/join — redeem an invite code. Maps server status
    /// codes:
    ///   404 → invalid code ('unknown')
    ///   410 → code expired or already consumed ('expired' / 'used')
    ///   409 → already in this group ('already_member'; not an error UX-wise)
    func joinGroup(code: String, jwt: String) async throws -> JoinGroupResponse {
        try await post("api/groups/join", body: ["code": code], jwt: jwt)
    }

    /// DELETE /api/groups/:id/members/me — leave a group. Idempotent: 200
    /// regardless of prior membership status (don't surface "not a member"
    /// as an error to the UI).
    func leaveGroup(id: String, jwt: String) async throws {
        let _: APIClient.EmptyResponse =
            try await delete("api/groups/\(id)/members/me", jwt: jwt)
    }

    /// PATCH /api/groups/:id/members/me — set your per-group nickname.
    /// Pass nil/"" to clear (revert to the global users.display_name).
    /// Returns the freshly-hydrated group so the caller can update its
    /// model without a follow-up GET.
    func setGroupDisplayName(groupID: String,
                             displayName: String?,
                             jwt: String) async throws -> GroupSummary {
        // The backend requires the key to be present, value may be string|null.
        let body: [String: Any] = [
            "display_name": displayName as Any? ?? NSNull(),
        ]
        return try await patch("api/groups/\(groupID)/members/me", body: body, jwt: jwt)
    }

    // MARK: - M3: Manual activities

    /// POST /api/activities — log a manual activity. The `id` IS the
    /// idempotency key (server dedups on it), so retries from the outbox
    /// are safe and won't duplicate. Returns the canonical server row.
    ///
    /// NOTE: the body field is `type` (NOT `kind`) and `duration_minutes`
    /// (NOT `duration_min`). Feed inner shape uses different names; don't
    /// mix them.
    func logActivity(_ a: PendingActivity, jwt: String) async throws -> ActivityRow {
        var body: [String: Any] = [
            "id": a.id,
            "date": a.date,
            "type": a.type,
            "logged_at": a.logged_at,
        ]
        if let t = a.title { body["title"] = t }
        if let d = a.duration_minutes { body["duration_minutes"] = d }
        if let n = a.notes { body["notes"] = n }
        return try await post("api/activities", body: body, jwt: jwt)
    }

    /// DELETE /api/activities/:id — soft-delete a manual activity by id.
    /// Scoped to the caller (won't delete other users' rows). 404 if the
    /// row is unknown or already deleted.
    func deleteActivity(id: String, jwt: String) async throws {
        let _: APIClient.EmptyResponse =
            try await delete("api/activities/\(id)", jwt: jwt)
    }

    // MARK: - M4: Feed + stats

    /// GET /api/groups/:id/feed — interleaved session/ride/activity stream
    /// ordered by `occurred_at` DESC. Default limit 30, max 100. Pass
    /// `since` (= the `next_since` from a previous page) AND `sinceID`
    /// (= the `next_since_id` from the same page) to paginate back through
    /// history; pass nil for "most recent N". The composite cursor is
    /// required: omitting `sinceID` makes the server fall back to strict
    /// older-than semantics on `since`, which silently drops every row
    /// tied at the page-boundary `occurred_at`.
    func getGroupFeed(groupID: String,
                      since: Int? = nil,
                      sinceID: String? = nil,
                      limit: Int = 30,
                      jwt: String) async throws -> GroupFeedResponse {
        var path = "api/groups/\(groupID)/feed?limit=\(limit)"
        if let since { path += "&since=\(since)" }
        if let sinceID { path += "&since_id=\(sinceID)" }
        return try await get(path, jwt: jwt)
    }

    /// GET /api/groups/:id/stats — per-member workout_count + streak over
    /// a rolling civil-date window. Valid ranges: "7d" | "14d" | "30d" (any
    /// 1-365 day count works; we pick 7d as the M5 default).
    func getGroupStats(groupID: String,
                       range: String = "7d",
                       jwt: String) async throws -> GroupStatsResponse {
        try await get("api/groups/\(groupID)/stats?range=\(range)", jwt: jwt)
    }

    /// GET /api/groups/:id/activity — per-member daily activity series for
    /// the week/month/year zoom. Default window (371d ≈ 53 weeks) covers
    /// the year view, so the client never refetches on a range toggle.
    func getGroupActivity(groupID: String,
                          days: Int = 371,
                          jwt: String) async throws -> GroupActivityResponse {
        try await get("api/groups/\(groupID)/activity?days=\(days)", jwt: jwt)
    }
}
