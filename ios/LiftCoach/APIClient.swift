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

    /// Exchange Apple's identity token for a Worker-issued app JWT.
    func authApple(identityToken: String, fullName: String?) async throws -> AuthResponse {
        try await post("/auth/apple",
                        body: ["identityToken": identityToken, "fullName": fullName as Any],
                        jwt: nil)
    }

    /// The sync pull. Milestone (d) just proves auth works end-to-end.
    func getState(jwt: String) async throws -> StateResponse {
        var req = URLRequest(url: baseURL.appendingPathComponent("api/state"))
        req.httpMethod = "GET"
        req.setValue("Bearer \(jwt)", forHTTPHeaderField: "Authorization")
        return try await send(req)
    }

    private func post<T: Decodable>(_ path: String, body: [String: Any], jwt: String?) async throws -> T {
        var req = URLRequest(url: baseURL.appendingPathComponent(String(path.dropFirst())))
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if let jwt { req.setValue("Bearer \(jwt)", forHTTPHeaderField: "Authorization") }
        req.httpBody = try JSONSerialization.data(withJSONObject: body.compactMapValues { $0 is NSNull ? nil : $0 })
        return try await send(req)
    }

    private func send<T: Decodable>(_ req: URLRequest) async throws -> T {
        let (data, resp) = try await URLSession.shared.data(for: req)
        let code = (resp as? HTTPURLResponse)?.statusCode ?? -1
        guard (200..<300).contains(code) else {
            throw APIError.http(code, String(data: data, encoding: .utf8) ?? "")
        }
        do {
            return try JSONDecoder().decode(T.self, from: data)
        } catch {
            throw APIError.decoding("\(error)")
        }
    }
}
