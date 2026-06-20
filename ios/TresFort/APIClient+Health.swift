import Foundation

// Apple Health (HealthKit) REST surface. HealthKit is on-device only, so the
// app reads HKWorkouts and PUSHes them here; the matching group-feed opt-in
// (migration 0028) is flipped via PATCH /api/me/health-sharing. Both are
// JWT-authed and match src/routes/api.ts verbatim.

extension APIClient {

    /// POST /api/activities/healthkit — push one HealthKit workout. `id`
    /// (= HKWorkout.uuid) is the idempotency key, so a re-push (a later anchored
    /// pass, or a HealthKit revision of the workout's totals) lands on ON
    /// CONFLICT and updates in place rather than duplicating. Returns the
    /// canonical server row (we only need its id).
    @discardableResult
    func pushHealthKitActivity(_ a: HealthKitActivityPush,
                               jwt: String) async throws -> HealthKitPushResult {
        try await post("api/activities/healthkit", body: a.jsonBody, jwt: jwt)
    }

    struct HealthKitPushResult: Decodable { let id: String }

    /// PATCH /api/me/health-sharing — flip whether THIS user's Apple Health
    /// activities surface in the group feed (opt-in, default off — migration
    /// 0028). Off = the group feed/stats/series exclude this user's healthkit
    /// rows. Returns the resulting state.
    @discardableResult
    func setHealthSharing(enabled: Bool, jwt: String) async throws -> HealthSharingResult {
        try await patch("api/me/health-sharing", body: ["enabled": enabled], jwt: jwt)
    }

    struct HealthSharingResult: Decodable, Equatable { let sharing_in_group: Bool }
}
