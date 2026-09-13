import XCTest
@testable import TresFort

private final class HealthSharingTokenStore: AppTokenStore {
    func load() -> String? { nil }
    func save(_ token: String) {}
    func clear() {}
}

@MainActor
final class HealthSharingReadTests: XCTestCase {
    private func profile(_ sharing: Bool?) -> MeProfile {
        MeProfile(display_name: nil, email: nil,
                  intervals: .init(connected: false, athlete_id: nil, needs_reauth: nil),
                  coach: .init(is_owner: false, connected: false, last_active: nil),
                  health: sharing.map { .init(sharing_in_group: $0) })
    }

    private func makeAuth() -> (AuthModel, LocalPersistence) {
        let name = "HealthSharingReadTests.\(UUID().uuidString)"
        let defaults = LocalPersistence(suiteName: name)!
        addTeardownBlock { [preferences = defaults.preferences, directory = defaults.trainingStore.directory] in
            preferences.removePersistentDomain(forName: name)
            try? FileManager.default.removeItem(at: directory)
        }
        let auth = AuthModel(tokenStore: HealthSharingTokenStore(), defaults: defaults)
        auth.userID = "sharing-user"
        auth.jwt = "synthetic-test-bearer"
        return (auth, defaults)
    }

    func testFreshReadOverridesAbsentOrCachedOffProfileAndRecoversFromFailure() async throws {
        let (auth, defaults) = makeAuth()
        var fail = true
        let fresh = profile(true)
        let model = GroupModel(auth: auth, defaults: defaults, profileLoader: { _ in
            if fail { throw URLError(.notConnectedToInternet) }
            return fresh
        })
        model.me = profile(false)
        do {
            _ = try await model.readHealthSharing()
            XCTFail("Failed reads must not fall back to the cached off value")
        } catch {}
        fail = false
        let sharing = try await model.readHealthSharing()
        XCTAssertTrue(sharing)
        model.me = nil
        let withoutCache = try await model.readHealthSharing()
        XCTAssertTrue(withoutCache)
    }

    func testMissingHealthFieldRemainsUnknown() async {
        let (auth, defaults) = makeAuth()
        let missing = profile(nil)
        let model = GroupModel(auth: auth, defaults: defaults, profileLoader: { _ in missing })
        do {
            _ = try await model.readHealthSharing()
            XCTFail("A missing field is not proof that sharing is off")
        } catch {}
    }

    func testReadCannotReturnAnotherAccountsSharingAfterAccountChange() async {
        let (auth, defaults) = makeAuth()
        let fresh = profile(true)
        let model = GroupModel(auth: auth, defaults: defaults, profileLoader: { _ in
            auth.userID = "different-user"
            return fresh
        })
        do {
            _ = try await model.readHealthSharing()
            XCTFail("Account changes must invalidate the pending sharing result")
        } catch {}
    }
}
