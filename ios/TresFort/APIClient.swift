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

struct AccountExportFile: Equatable {
    let data: Data
    let filename: String
}

struct APIClient {
    var baseURL = Config.apiBaseURL

    func authApple(
        identityToken: String,
        authorizationCode: String? = nil,
        fullName: String?
    ) async throws -> AuthResponse {
        // Open sign-in: identityToken (required), the short-lived Apple
        // authorization code when the native UI supplied one, and an optional
        // display name. The code is sent directly to the Worker for provider
        // revocation support and is never persisted on-device.
        // Invite redemption is NOT bundled into sign-in — invited users
        // sign in first, then redeem via POST /api/groups/join (see
        // APIClient+Groups.joinGroup).
        var body: [String: Any] = ["identityToken": identityToken]
        if let authorizationCode { body["authorizationCode"] = authorizationCode }
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

    /// Download the authenticated caller's portable account snapshot. The
    /// server chooses the attachment filename; validate that the successful
    /// response is actually JSON before offering it to the Files picker.
    func downloadAccountExport(jwt: String) async throws -> AccountExportFile {
        var req = URLRequest(
            url: URL(string: baseURL.absoluteString + "/api/me/export")!)
        req.httpMethod = "GET"
        req.setValue("Bearer \(jwt)", forHTTPHeaderField: "Authorization")
        req.setValue(TimeZone.current.identifier, forHTTPHeaderField: "X-Device-TZ")
        let (data, response) = try await URLSession.shared.data(for: req)
        guard let http = response as? HTTPURLResponse else {
            throw APIError.http(-1, "missing HTTP response")
        }
        guard (200..<300).contains(http.statusCode) else {
            throw APIError.http(
                http.statusCode,
                String(data: data, encoding: .utf8) ?? "")
        }
        guard
            http.value(forHTTPHeaderField: "Content-Type")?
                .lowercased().hasPrefix("application/json") == true
        else {
            throw APIError.decoding("account export was not JSON")
        }
        do {
            let value = try JSONSerialization.jsonObject(with: data)
            guard value is [String: Any] else {
                throw APIError.decoding("account export was not a JSON object")
            }
        } catch let error as APIError {
            throw error
        } catch {
            throw APIError.decoding("account export was invalid JSON: \(error)")
        }
        return AccountExportFile(
            data: data,
            filename: response.suggestedFilename
                ?? "tres-fort-account-export.json")
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
        try await createSession(
            date: date,
            dayTemplateID: dayTemplateID,
            expectedAttempt: nil,
            restartDiscardedAttempt: nil,
            jwt: jwt)
    }

    /// A discarded date is revived only when the runner persisted explicit
    /// user restart provenance. The prior attempt is a compare-and-swap token:
    /// a commit-then-timeout retry returns the same next generation, while a
    /// delayed request can never revive a later discard.
    func createSession(
        date: String,
        dayTemplateID: String? = nil,
        expectedAttempt: Int?,
        restartDiscardedAttempt: Int?,
        jwt: String
    ) async throws -> SessionRow {
        var body: [String: Any] = ["date": date]
        if let dayTemplateID { body["day_template_id"] = dayTemplateID }
        if let restartDiscardedAttempt {
            body["restart_discarded"] = true
            body["expected_attempt"] = restartDiscardedAttempt
        } else if let expectedAttempt {
            body["expected_attempt"] = expectedAttempt
        }
        return try await post("api/sessions", body: body, jwt: jwt)
    }

    /// Idempotent on the immutable body's `id`. The typed body prevents a
    /// retry from accidentally minting a new UUID or tap timestamp.
    func logSet(
        sessionId: String,
        body: SetRequestBody,
        jwt: String
    ) async throws -> SetLogResult {
        try await post("api/sessions/\(sessionId)/sets", body: body, jwt: jwt)
    }

    struct SetLogResult: Decodable {
        let set: SetLog
        let deduped: Bool
        /// Canonical session observed in the same D1 batch/read as the set
        /// acknowledgement. Optional only for rolling compatibility with an
        /// older Worker; the client never infers a terminal-sensitive status
        /// when it is absent.
        let session: SessionRow?

        init(set: SetLog, deduped: Bool, session: SessionRow? = nil) {
            self.set = set
            self.deduped = deduped
            self.session = session
        }
    }

    func completeSession(sessionId: String, jwt: String) async throws -> SessionRow {
        try await patch("api/sessions/\(sessionId)", body: ["status": "completed"], jwt: jwt)
    }

    /// Explicitly reopen a skipped/rest override. The Worker advances the
    /// reused date row's attempt, so delayed writes from the prior skipped
    /// generation cannot join this newly started workout.
    func reopenSkippedSession(
        sessionId: String,
        dayTemplateID: String?,
        expectedAttempt: Int?,
        jwt: String
    ) async throws -> SessionRow {
        var body: [String: Any] = ["status": "planned"]
        if let dayTemplateID { body["day_template_id"] = dayTemplateID }
        return try await patch(
            attemptScopedPath(
                "api/sessions/\(sessionId)", expectedAttempt: expectedAttempt),
            body: body,
            jwt: jwt)
    }

    func completeSession(
        sessionId: String,
        expectedAttempt: Int?,
        jwt: String
    ) async throws -> SessionRow {
        try await patch(
            attemptScopedPath(
                "api/sessions/\(sessionId)", expectedAttempt: expectedAttempt),
            body: ["status": "completed"],
            jwt: jwt)
    }

    /// Discard a session — "I didn't really do this." Soft-deletes its sets
    /// and marks it discarded server-side (vanishes from the projection).
    /// Restarting the same day resurrects a fresh planned session.
    func discardSession(sessionId: String, jwt: String) async throws -> SessionRow {
        try await post("api/sessions/\(sessionId)/discard", body: [:], jwt: jwt)
    }

    func discardSession(
        sessionId: String,
        expectedAttempt: Int?,
        jwt: String
    ) async throws -> SessionRow {
        try await post(
            attemptScopedPath(
                "api/sessions/\(sessionId)/discard",
                expectedAttempt: expectedAttempt),
            body: [:],
            jwt: jwt)
    }

    private func attemptScopedPath(
        _ path: String,
        expectedAttempt: Int?
    ) -> String {
        guard let expectedAttempt else { return path }
        return "\(path)?expected_attempt=\(expectedAttempt)"
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

    /// Typed JSON-body variant used by the durable set writer. Keep this
    /// overload narrow: other endpoints intentionally retain their existing
    /// dictionary construction for explicit-null/omitted-field semantics.
    func post<T: Decodable, Body: Encodable>(
        _ path: String,
        body: Body,
        jwt: String?
    ) async throws -> T {
        var req = URLRequest(url: URL(string: baseURL.absoluteString + "/" + path)!)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if let jwt { req.setValue("Bearer \(jwt)", forHTTPHeaderField: "Authorization") }
        req.setValue(TimeZone.current.identifier, forHTTPHeaderField: "X-Device-TZ")
        req.httpBody = try JSONEncoder().encode(body)
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
    func authApple(
        identityToken: String,
        authorizationCode: String?,
        fullName: String?
    ) async throws -> AuthResponse
    func renewAppSession(jwt: String) async throws -> SessionRenewalResponse
    func deleteAccount(
        jwt: String,
        idempotencyKey: String
    ) async throws -> AccountDeletionResponse
    func downloadAccountExport(jwt: String) async throws -> AccountExportFile
}

extension APIClient: AuthAPI {}

/// Only the calls required to settle a set intent and the shared full-state
/// pull are injectable. The rest of SyncModel continues using APIClient
/// directly, avoiding a broad sync abstraction while making persistence,
/// retry identity, and response-ordering deterministic in model tests.
@MainActor
protocol SetWriteAPI {
    func createSession(
        date: String,
        dayTemplateID: String?,
        jwt: String
    ) async throws -> SessionRow
    func createSession(
        date: String,
        dayTemplateID: String?,
        expectedAttempt: Int?,
        restartDiscardedAttempt: Int?,
        jwt: String
    ) async throws -> SessionRow
    func logSet(
        sessionId: String,
        body: SetRequestBody,
        jwt: String
    ) async throws -> APIClient.SetLogResult
    func reopenSkippedSession(
        sessionId: String,
        dayTemplateID: String?,
        expectedAttempt: Int?,
        jwt: String
    ) async throws -> SessionRow
    func logSet(
        sessionId: String,
        body: SetRequestBody,
        expectedAttempt: Int?,
        jwt: String
    ) async throws -> APIClient.SetLogResult
    func deleteSet(setId: String, jwt: String) async throws
    func getState(jwt: String) async throws -> StateResponse
}

extension SetWriteAPI {
    func createSession(
        date: String,
        dayTemplateID: String?,
        expectedAttempt: Int?,
        restartDiscardedAttempt: Int?,
        jwt: String
    ) async throws -> SessionRow {
        try await createSession(
            date: date, dayTemplateID: dayTemplateID, jwt: jwt)
    }

    func logSet(
        sessionId: String,
        body: SetRequestBody,
        expectedAttempt: Int?,
        jwt: String
    ) async throws -> APIClient.SetLogResult {
        try await logSet(
            sessionId: sessionId,
            body: body.scoped(to: expectedAttempt),
            jwt: jwt)
    }

    func reopenSkippedSession(
        sessionId: String,
        dayTemplateID: String?,
        expectedAttempt: Int?,
        jwt: String
    ) async throws -> SessionRow {
        throw APIError.decoding("Skipped-session reopen is unavailable")
    }
}

extension APIClient: SetWriteAPI {}

@MainActor
protocol ExerciseCatalogAPI {
    func getExercises(jwt: String) async throws -> [ExerciseCatalog]
}

extension APIClient: ExerciseCatalogAPI {}

/// Narrow terminal-session seam used only to prove the P0 exclusion between
/// destructive/completing session mutations and new set persistence.
@MainActor
protocol WorkoutTerminalAPI {
    func completeSession(sessionId: String, jwt: String) async throws -> SessionRow
    func discardSession(sessionId: String, jwt: String) async throws -> SessionRow
    func completeSession(
        sessionId: String,
        expectedAttempt: Int?,
        jwt: String
    ) async throws -> SessionRow
    func discardSession(
        sessionId: String,
        expectedAttempt: Int?,
        jwt: String
    ) async throws -> SessionRow
}

extension WorkoutTerminalAPI {
    func completeSession(
        sessionId: String,
        expectedAttempt: Int?,
        jwt: String
    ) async throws -> SessionRow {
        try await completeSession(sessionId: sessionId, jwt: jwt)
    }

    func discardSession(
        sessionId: String,
        expectedAttempt: Int?,
        jwt: String
    ) async throws -> SessionRow {
        try await discardSession(sessionId: sessionId, jwt: jwt)
    }
}

extension APIClient: WorkoutTerminalAPI {}
