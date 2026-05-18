import Foundation

// Codable mirrors of the REST DTOs. Milestone (d) only needs auth + the
// /api/state shape enough to prove the JWT round-trip; the full plan/set
// models arrive with the Today screen (milestone e).

struct AuthResponse: Decodable {
    let jwt: String
    let user: UserDTO
}

struct UserDTO: Decodable {
    let id: String
    let display_name: String?
    let email: String?
}

/// Empty decodable: lets us count array rows without modeling them yet.
struct AnyRow: Decodable {}

struct PlanLite: Decodable {
    let name: String
    let version: Int
}

struct StateResponse: Decodable {
    let plan: PlanLite?
    let plan_version: Int
    let sessions: [AnyRow]
    let sets: [AnyRow]
    let server_time: Int
}
