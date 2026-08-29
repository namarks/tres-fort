import Foundation

enum APIError: Error, LocalizedError {
    case http(Int, String)
    case decoding(String)

    var errorDescription: String? {
        switch self {
        case let .http(code, body): return "HTTP \(code): \(body)"
        case let .decoding(msg): return "Decode failed: \(msg)"
        }
    }
}

struct APIClient {
    var baseURL = Config.apiBaseURL

    func authApple(identityToken: String, fullName: String?) async throws -> AuthResponse {
        // Open sign-in: identityToken (required) + optional display name.
        // Invite redemption is NOT bundled into sign-in — invited users
        // sign in first, then redeem via POST /api/groups/join (see
        // APIClient+Groups.joinGroup).
        var body: [String: Any] = ["identityToken": identityToken]
        if let fullName { body["fullName"] = fullName }
        return try await post("auth/apple", body: body, jwt: nil)
    }

    /// Roll a still-valid app JWT forward before its fixed expiry. Sign in
    /// with Apple remains the recovery path after the bearer has expired.
    func renewAppSession(jwt: String) async throws -> SessionRenewalResponse {
        try await post("auth/renew", body: [:], jwt: jwt)
    }

    /// Permanently delete the authenticated account. The Profile UI owns the
    /// destructive confirmation; AuthModel clears local account state only
    /// after this response is acknowledged.
    func deleteAccount(
        jwt: String,
        idempotencyKey: String
    ) async throws -> AccountDeletionResponse {
        try await delete(
            "api/me",
            jwt: jwt,
            headers: ["X-Account-Deletion-Key": idempotencyKey])
    }

    /// Full sync pull (since=0 → everything; the app dedupes locally).
    ///
    /// `events_since=0` / `activities_since=0` are passed explicitly (not
    /// omitted) so the external_events + external_activities contracts are
    /// greppable here. The app does a FULL reload every sync — all
    /// watermarks are 0 — and the server returns the full current
    /// non-deleted sets. No client-side watermark / tombstone-merge /
    /// incremental-delta sync is used (by design: server is truth).
    func getState(jwt: String) async throws -> StateResponse {
        try await get(
            "api/state?since=0&sets_since=0&events_since=0&activities_since=0",
            jwt: jwt)
    }

    func getExercises(jwt: String) async throws -> [ExerciseCatalog] {
        try await get("api/exercises", jwt: jwt)
    }

    /// `day_template_id` is an OPTIONAL field of the existing
    /// `POST /api/sessions` contract (not a new endpoint) — passing it lets
    /// the calendar/agenda resolve the one-off session as the right workout.
    func createSession(date: String, dayTemplateID: String? = nil,
                       jwt: String) async throws -> SessionRow {
        var body: [String: Any] = ["date": date]
        if let dayTemplateID { body["day_template_id"] = dayTemplateID }
        return try await post("api/sessions", body: body, jwt: jwt)
    }

    /// Idempotent on `id` — safe to retry after a flaky gym connection.
    func logSet(sessionId: String, body: [String: Any], jwt: String) async throws -> SetLogResult {
        try await post("api/sessions/\(sessionId)/sets", body: body, jwt: jwt)
    }

    struct SetLogResult: Decodable { let set: SetLog; let deduped: Bool }

    func completeSession(sessionId: String, jwt: String) async throws -> SessionRow {
        try await patch("api/sessions/\(sessionId)", body: ["status": "completed"], jwt: jwt)
    }

    /// Discard a session — "I didn't really do this." Soft-deletes its sets
    /// and marks it discarded server-side (vanishes from the projection).
    /// Restarting the same day resurrects a fresh planned session.
    func discardSession(sessionId: String, jwt: String) async throws -> SessionRow {
        try await post("api/sessions/\(sessionId)/discard", body: [:], jwt: jwt)
    }

    struct EmptyResponse: Decodable {}
    func deleteSet(setId: String, jwt: String) async throws {
        let _: SetLog = try await patch("api/sets/\(setId)", body: ["deleted": true], jwt: jwt)
    }

    // MARK: - in-app plan editing
    //
    // Add / edit / remove an exercise slot in the active plan's day template.
    // Thin wrappers over the REST editor endpoints (POST/PATCH/DELETE
    // /api/days/:dayId/exercises[/:teId]) — the app-side counterpart to the
    // MCP add_exercise / update_exercise / delete_exercise tools. The caller
    // reloads /api/state afterwards, so these return just the slot id.

    /// Minimal decode of an edited slot row (the response carries the full
    /// template_exercises row; the caller only needs the id and reloads).
    struct SlotIDRow: Decodable { let id: String }

    @discardableResult
    func addExercise(dayID: String, exercise: String, isWarmup: Bool,
                     targetSets: Int, targetReps: Int, restSeconds: Int,
                     targetDurationS: Int?, jwt: String) async throws -> SlotIDRow {
        var body: [String: Any] = [
            "exercise": exercise,
            "target_sets": targetSets,
            "target_reps": targetReps,
            "rest_seconds": restSeconds,
            "is_warmup": isWarmup,
        ]
        if let targetDurationS { body["target_duration_s"] = targetDurationS }
        return try await post("api/days/\(dayID)/exercises", body: body, jwt: jwt)
    }

    @discardableResult
    func updateExerciseSlot(dayID: String, teID: String,
                            fields: [String: Any], jwt: String) async throws -> SlotIDRow {
        try await patch("api/days/\(dayID)/exercises/\(teID)", body: fields, jwt: jwt)
    }

    func deleteExerciseSlot(dayID: String, teID: String, jwt: String) async throws {
        let _: SlotIDRow = try await delete("api/days/\(dayID)/exercises/\(teID)", jwt: jwt)
    }

    // MARK: - transport
    //
    // INTERNAL (not private) so extension files (APIClient+Groups.swift,
    // etc.) can add new endpoint methods without re-implementing the
    // URLSession + JWT + JSON plumbing.

    func get<T: Decodable>(_ path: String, jwt: String) async throws -> T {
        // Build the URL by string so query strings aren't percent-escaped.
        var req = URLRequest(url: URL(string: baseURL.absoluteString + "/" + path)!)
        req.httpMethod = "GET"
        req.setValue("Bearer \(jwt)", forHTTPHeaderField: "Authorization")
        req.setValue(TimeZone.current.identifier, forHTTPHeaderField: "X-Device-TZ")
        return try await send(req)
    }

    func post<T: Decodable>(_ path: String, body: [String: Any], jwt: String?) async throws -> T {
        var req = URLRequest(url: URL(string: baseURL.absoluteString + "/" + path)!)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if let jwt { req.setValue("Bearer \(jwt)", forHTTPHeaderField: "Authorization") }
        req.setValue(TimeZone.current.identifier, forHTTPHeaderField: "X-Device-TZ")
        // NSNull must round-trip as JSON `null` — some POST endpoints
        // distinguish `null` from an omitted key (POST /groups/:id/invites
        // treats `expires_at: null` as "never expires" but `expires_at`
        // absent as "default 30d"). Call sites that want to OMIT a field
        // build the dict conditionally (see e.g. createSession), so
        // dropping NSNull here would silently re-map the explicit-null
        // contract to the default-value path.
        req.httpBody = try JSONSerialization.data(withJSONObject: body)
        return try await send(req)
    }

    func patch<T: Decodable>(_ path: String, body: [String: Any], jwt: String) async throws -> T {
        var req = URLRequest(url: URL(string: baseURL.absoluteString + "/" + path)!)
        req.httpMethod = "PATCH"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue("Bearer \(jwt)", forHTTPHeaderField: "Authorization")
        req.setValue(TimeZone.current.identifier, forHTTPHeaderField: "X-Device-TZ")
        // No NSNull stripping here — PATCH bodies need to send explicit
        // `null` (e.g. the intervals.icu disconnect path sends both fields
        // null to clear credentials). JSONSerialization writes Swift's
        // NSNull as JSON null.
        req.httpBody = try JSONSerialization.data(withJSONObject: body)
        return try await send(req)
    }

    /// DELETE with no request body. Decodes the JSON response into T (the
    /// backend mostly returns `{ok: true}` for deletes; use `EmptyResponse`
    /// when you don't care about the body).
    func delete<T: Decodable>(
        _ path: String,
        jwt: String,
        headers: [String: String] = [:]
    ) async throws -> T {
        var req = URLRequest(url: URL(string: baseURL.absoluteString + "/" + path)!)
        req.httpMethod = "DELETE"
        req.setValue("Bearer \(jwt)", forHTTPHeaderField: "Authorization")
        req.setValue(TimeZone.current.identifier, forHTTPHeaderField: "X-Device-TZ")
        for (field, value) in headers {
            req.setValue(value, forHTTPHeaderField: field)
        }
        return try await send(req)
    }

    func send<T: Decodable>(_ req: URLRequest) async throws -> T {
        let (data, resp) = try await URLSession.shared.data(for: req)
        let code = (resp as? HTTPURLResponse)?.statusCode ?? -1
        guard (200..<300).contains(code) else {
            throw APIError.http(code, String(data: data, encoding: .utf8) ?? "")
        }
        do { return try JSONDecoder().decode(T.self, from: data) }
        catch { throw APIError.decoding("\(error)") }
    }
}

/// Narrow auth surface injected into AuthModel so expiry, offline renewal,
/// and same-user recovery are covered without real Apple/network calls.
protocol AuthAPI {
    func authApple(identityToken: String, fullName: String?) async throws -> AuthResponse
    func renewAppSession(jwt: String) async throws -> SessionRenewalResponse
    func deleteAccount(
        jwt: String,
        idempotencyKey: String
    ) async throws -> AccountDeletionResponse
}

extension APIClient: AuthAPI {}
