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
        try await post("auth/apple",
                        body: ["identityToken": identityToken, "fullName": fullName as Any],
                        jwt: nil)
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

    // MARK: - transport

    private func get<T: Decodable>(_ path: String, jwt: String) async throws -> T {
        // Build the URL by string so query strings aren't percent-escaped.
        var req = URLRequest(url: URL(string: baseURL.absoluteString + "/" + path)!)
        req.httpMethod = "GET"
        req.setValue("Bearer \(jwt)", forHTTPHeaderField: "Authorization")
        req.setValue(TimeZone.current.identifier, forHTTPHeaderField: "X-Device-TZ")
        return try await send(req)
    }

    private func post<T: Decodable>(_ path: String, body: [String: Any], jwt: String?) async throws -> T {
        var req = URLRequest(url: URL(string: baseURL.absoluteString + "/" + path)!)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if let jwt { req.setValue("Bearer \(jwt)", forHTTPHeaderField: "Authorization") }
        req.setValue(TimeZone.current.identifier, forHTTPHeaderField: "X-Device-TZ")
        req.httpBody = try JSONSerialization.data(
            withJSONObject: body.compactMapValues { $0 is NSNull ? nil : $0 })
        return try await send(req)
    }

    private func patch<T: Decodable>(_ path: String, body: [String: Any], jwt: String) async throws -> T {
        var req = URLRequest(url: URL(string: baseURL.absoluteString + "/" + path)!)
        req.httpMethod = "PATCH"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue("Bearer \(jwt)", forHTTPHeaderField: "Authorization")
        req.setValue(TimeZone.current.identifier, forHTTPHeaderField: "X-Device-TZ")
        req.httpBody = try JSONSerialization.data(withJSONObject: body)
        return try await send(req)
    }

    private func send<T: Decodable>(_ req: URLRequest) async throws -> T {
        let (data, resp) = try await URLSession.shared.data(for: req)
        let code = (resp as? HTTPURLResponse)?.statusCode ?? -1
        guard (200..<300).contains(code) else {
            throw APIError.http(code, String(data: data, encoding: .utf8) ?? "")
        }
        do { return try JSONDecoder().decode(T.self, from: data) }
        catch { throw APIError.decoding("\(error)") }
    }
}
