import Foundation
import XCTest
@testable import TresFort

@MainActor
final class GroupSafetyTests: XCTestCase {
    private final class TokenStore: AppTokenStore {
        var token: String?
        func save(_ token: String) { self.token = token }
        func load() -> String? { token }
        func clear() { token = nil }
    }

    func testReportDraftContainsOnlyCategoryAndReferencesAndEncodesURLCharacters() throws {
        let report = GroupReport(groupID: "group-reference", memberID: "member-reference",
                                 itemID: "intervals:activity:42", itemType: "ride")
        let url = try XCTUnwrap(report.emailURL(reason: .threats))
        let parts = try XCTUnwrap(URLComponents(url: url, resolvingAgainstBaseURL: false))
        XCTAssertEqual(parts.scheme, "mailto")
        XCTAssertEqual(parts.path, "nick@tresfort.app")
        let query = Dictionary(uniqueKeysWithValues: (parts.queryItems ?? []).map { ($0.name, $0.value ?? "") })
        XCTAssertEqual(query["body"], "Category: Threats\nGroup: group-reference\nMember: member-reference\nItem: ride / intervals:activity:42\n\nPlease describe the concern before sending:\n")
        XCTAssertEqual(Set(query.keys), ["subject", "body"])
        XCTAssertFalse(url.absoluteString.contains("\n"))
    }

    func testAcknowledgedBlockCannotBeUndoneByAnEarlierRosterResponse() async throws {
        let suite = "GroupSafetyTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(LocalPersistence(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let auth = AuthModel(tokenStore: TokenStore(), defaults: defaults)
        auth.userID = "user-a"
        let payload = try JSONSerialization.data(withJSONObject: ["sub": "user-a", "exp": 4_000_000_000])
        auth.jwt = "header." + payload.base64EncodedString().replacingOccurrences(of: "=", with: "") + ".signature"
        var oldRead: CheckedContinuation<[GroupSummary], Error>?
        var calls = 0
        let model = GroupModel(auth: auth, defaults: defaults, groupLister: { _ in
            calls += 1
            if calls == 1 { return try await withCheckedThrowingContinuation { oldRead = $0 } }
            return []
        }, profileLoader: { _ in throw URLError(.notConnectedToInternet) }, groupBlockWriter: { id, active, _ in
            XCTAssertEqual(id, "user-b"); XCTAssertTrue(active)
        }, groupSafetyLoader: { _ in throw URLError(.notConnectedToInternet) })
        let loading = Task { await model.load() }
        for _ in 0..<100 where oldRead == nil { await Task.yield() }
        let continuation = try XCTUnwrap(oldRead)
        // A later refresh failure does not revoke the successful block.
        try await model.setGroupBlock(userID: "user-b", active: true)
        continuation.resume(returning: [.init(id: "stale-group", name: "Old crew", created_by: "user-b", created_at: 1,
            members: [.init(group_id: "stale-group", user_id: "user-b", display_name: "Hidden member", joined_at: 1, effective_display_name: "Hidden member")])])
        await loading.value
        XCTAssertTrue(model.groups.isEmpty)
        XCTAssertTrue(model.feed.isEmpty)
        XCTAssertTrue(model.stats.isEmpty)
        XCTAssertTrue(model.activitySeries.isEmpty)
        XCTAssertEqual(model.phase, .none)
    }

    func testSafetyInvalidationClearsSecondaryGroupsBeforeNetworkAndRejectsEarlierRead() async throws {
        let suite = "GroupSafetyTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(LocalPersistence(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let auth = AuthModel(tokenStore: TokenStore(), defaults: defaults)
        auth.userID = "user-a"
        let payload = try JSONSerialization.data(withJSONObject: ["sub": "user-a", "exp": 4_000_000_000])
        auth.jwt = "header." + payload.base64EncodedString().replacingOccurrences(of: "=", with: "") + ".signature"
        var oldRead: CheckedContinuation<[GroupSummary], Error>?
        var calls = 0
        let model = GroupModel(auth: auth, defaults: defaults, groupLister: { _ in
            calls += 1
            if calls == 1 { return try await withCheckedThrowingContinuation { oldRead = $0 } }
            throw URLError(.notConnectedToInternet)
        })
        let reading = Task { await model.load() }
        for _ in 0..<100 where oldRead == nil { await Task.yield() }
        let continuation = try XCTUnwrap(oldRead)
        let cached = ["selected", "secondary"].map { id in
            GroupSummary(id: id, name: "Cached crew", created_by: "user-b", created_at: 1,
                members: [.init(group_id: id, user_id: "user-b", display_name: "Hidden member",
                                joined_at: 1, effective_display_name: "Hidden member")])
        }
        model.groups = cached
        model.selectedGroupID = "selected"
        for group in cached {
            model.feed[group.id] = [.unknown(.init(id: group.id, user_id: "user-b",
                user_display_name: "Hidden member", is_me: false, date: "2026-09-10", occurred_at: 1))]
            model.stats[group.id] = [.init(user_id: "user-b", display_name: "Hidden member",
                avatar_initials: "HM", is_me: false, workout_count: 1, streak_days: 1, last_active: 1)]
            model.activitySeries[group.id] = [.init(user_id: "user-b", days: [])]
        }
        // Safety changes invoke this synchronously before awaiting the network.
        model.invalidateSharedGroups()
        XCTAssertTrue(model.groups.isEmpty)
        XCTAssertTrue(model.feed.isEmpty)
        XCTAssertTrue(model.stats.isEmpty)
        XCTAssertTrue(model.activitySeries.isEmpty)
        await model.load() // The reload is unavailable; stale data stays hidden.
        continuation.resume(returning: cached)
        await reading.value
        XCTAssertTrue(model.groups.isEmpty)
        XCTAssertTrue(model.feed.isEmpty)
        if case .error = model.phase {} else { XCTFail("Expected the current offline error") }
    }


    func testRejectedBlockRevalidatesMembershipOrShowsRetryableLoadError() async throws {
        for offline in [false, true] {
            let suite = "GroupSafetyTests.\(UUID().uuidString)"
            let defaults = try XCTUnwrap(LocalPersistence(suiteName: suite))
            defer { defaults.removePersistentDomain(forName: suite) }
            let auth = AuthModel(tokenStore: TokenStore(), defaults: defaults)
            auth.userID = "user-a"
            let payload = try JSONSerialization.data(withJSONObject: ["sub": "user-a", "exp": 4_000_000_000])
            auth.jwt = "header." + payload.base64EncodedString().replacingOccurrences(of: "=", with: "") + ".signature"
            var reloads = 0
            let model = GroupModel(auth: auth, defaults: defaults, groupLister: { _ in
                reloads += 1
                if offline { throw URLError(.notConnectedToInternet) }
                return [] // Server confirms membership ended; only then show no groups.
            }, profileLoader: { _ in throw URLError(.notConnectedToInternet) }, groupBlockWriter: { _, _, _ in
                throw APIError.http(404, "member_unavailable")
            }, groupSafetyLoader: { _ in
                if offline { throw URLError(.notConnectedToInternet) }
                return .init(blocks: [.init(user_id: "existing-block", created_at: 1)], restriction: nil, can_moderate: true)
            })
            model.phase = .ready
            model.groups = [.init(id: "old-group", name: "Old crew", created_by: "user-b", created_at: 1, members: [])]
            do {
                try await model.setGroupBlock(userID: "user-b", active: true)
                XCTFail("The rejected block must remain an error")
            } catch {
                guard case APIError.http(404, _) = error else { return XCTFail("Original block error was lost: \(error)") }
            }
            XCTAssertEqual(reloads, 1)
            XCTAssertTrue(model.groups.isEmpty)
            if offline {
                XCTAssertNil(model.groupSafety)
                if case .error = model.phase {} else { XCTFail("Unavailable membership must offer retry") }
            } else {
                XCTAssertEqual(model.phase, .none)
                XCTAssertEqual(model.groupSafety?.blocks.first?.user_id, "existing-block")
                XCTAssertEqual(model.groupSafety?.can_moderate, true)
            }
        }
    }


    func testLostRestrictionResponseClearsSharedDataBeforeWriteAndReconciles() async throws {
        let suite = "GroupSafetyTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(LocalPersistence(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let auth = AuthModel(tokenStore: TokenStore(), defaults: defaults)
        auth.userID = "user-a"
        let payload = try JSONSerialization.data(withJSONObject: ["sub": "user-a", "exp": 4_000_000_000])
        auth.jwt = "header." + payload.base64EncodedString().replacingOccurrences(of: "=", with: "") + ".signature"
        var reloads = 0
        var model: GroupModel!
        model = GroupModel(auth: auth, defaults: defaults, groupLister: { _ in
            reloads += 1
            return []
        }, profileLoader: { _ in throw URLError(.notConnectedToInternet) }, groupRestrictionWriter: { _, _, _, _ in
            XCTAssertTrue(model.groups.isEmpty)
            XCTAssertTrue(model.feed.isEmpty)
            XCTAssertTrue(model.stats.isEmpty)
            throw URLError(.networkConnectionLost)
        }, groupSafetyLoader: { _ in
            .init(blocks: [], restriction: .init(active: 1, reason: "harassment", updated_at: 2), can_moderate: true)
        })
        model.phase = .ready
        model.groups = [.init(id: "group", name: "Crew", created_by: "user-b", created_at: 1, members: [])]
        model.feed["group"] = [.unknown(.init(id: "activity", user_id: "user-b", user_display_name: "Restricted member",
            is_me: false, date: "2026-09-10", occurred_at: 1))]
        model.stats["group"] = [.init(user_id: "user-b", display_name: "Restricted member", avatar_initials: "RM",
            is_me: false, workout_count: 1, streak_days: 1, last_active: 1)]
        do {
            try await model.setSharingRestriction(userID: "user-b", active: true, reason: .harassment)
            XCTFail("The lost response must remain an error")
        } catch { XCTAssertEqual((error as? URLError)?.code, .networkConnectionLost) }
        XCTAssertEqual(reloads, 1)
        XCTAssertTrue(model.groups.isEmpty)
        XCTAssertTrue(model.feed.isEmpty)
        XCTAssertTrue(model.stats.isEmpty)
        XCTAssertEqual(model.phase, .none)
        XCTAssertEqual(model.groupSafety?.restriction?.active, 1)
        XCTAssertEqual(model.groupSafety?.can_moderate, true)
        model = nil
    }

    func testForegroundRefreshRevalidatesMountedSafetySettings() async throws {
        let suite = "GroupSafetyTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(LocalPersistence(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let auth = AuthModel(tokenStore: TokenStore(), defaults: defaults)
        auth.userID = "user-a"
        let payload = try JSONSerialization.data(withJSONObject: ["sub": "user-a", "exp": 4_000_000_000])
        auth.jwt = "header." + payload.base64EncodedString().replacingOccurrences(of: "=", with: "") + ".signature"
        var calls = 0
        let model = GroupModel(auth: auth, defaults: defaults, groupLister: { _ in [] },
            profileLoader: { _ in throw URLError(.notConnectedToInternet) }, groupSafetyLoader: { _ in
                calls += 1
                return .init(blocks: calls == 1 ? [.init(user_id: "user-b", created_at: 1)] : [],
                             restriction: calls == 1 ? nil : .init(active: 1, reason: "harassment", updated_at: 2),
                             can_moderate: false)
            })
        try await model.refreshGroupSafety()
        XCTAssertEqual(model.groupSafety?.blocks.count, 1)
        model.invalidateSharedGroups()
        XCTAssertNil(model.groupSafety, "Old safety settings must disappear before foreground network waits")
        await model.reloadGroupState()
        XCTAssertEqual(calls, 2)
        XCTAssertEqual(model.groupSafety?.blocks.count, 0)
        XCTAssertEqual(model.groupSafety?.restriction?.active, 1)
    }

    func testFailedRosterRefreshShowsRetryInsteadOfAnEmptyGroup() async throws {
        let suite = "GroupSafetyTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(LocalPersistence(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let auth = AuthModel(tokenStore: TokenStore(), defaults: defaults)
        auth.userID = "user-a"
        let payload = try JSONSerialization.data(withJSONObject: ["sub": "user-a", "exp": 4_000_000_000])
        auth.jwt = "header." + payload.base64EncodedString().replacingOccurrences(of: "=", with: "") + ".signature"
        let model = GroupModel(auth: auth, defaults: defaults, groupLister: { _ in [] },
            groupLoader: { _, _ in throw URLError(.notConnectedToInternet) },
            profileLoader: { _ in throw URLError(.notConnectedToInternet) })
        model.groups = [.init(id: "group", name: "Cached crew", created_by: "user-b", created_at: 1, members: [])]
        model.selectedGroupID = "group"
        model.phase = .ready
        model.feed["group"] = [.unknown(.init(id: "activity", user_id: "user-b", user_display_name: "Member",
            is_me: false, date: "2026-09-10", occurred_at: 1))]
        await model.refreshGroup(groupID: "group")
        XCTAssertNil(model.feed["group"])
        XCTAssertTrue(model.groups[0].members.isEmpty)
        XCTAssertEqual(model.groups[0].created_by, "")
        if case .error = model.phase {} else { XCTFail("Failed roster verification must show the existing retry screen") }
        await model.load()
        XCTAssertEqual(model.phase, .none, "A successful Retry must leave the error state")
    }

    func testDetailRefreshDoesNotSupersedeALoadedOrLoadingGroup() async throws {
        let suite = "GroupSafetyTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(LocalPersistence(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let auth = AuthModel(tokenStore: TokenStore(), defaults: defaults)
        auth.userID = "user-a"
        let payload = try JSONSerialization.data(withJSONObject: ["sub": "user-a", "exp": 4_000_000_000])
        auth.jwt = "header." + payload.base64EncodedString().replacingOccurrences(of: "=", with: "") + ".signature"
        var rosterRead: CheckedContinuation<GroupSummary, Error>?
        var rosterReads = 0
        let model = GroupModel(auth: auth, defaults: defaults, groupLoader: { _, _ in
            rosterReads += 1
            return try await withCheckedThrowingContinuation { rosterRead = $0 }
        })
        model.groups = [.init(id: "group", name: "Crew", created_by: "user-a", created_at: 1, members: [])]
        model.selectedGroupID = "group"
        model.phase = .ready
        model.feed["group"] = []
        model.stats["group"] = []
        model.activitySeries["group"] = []

        // Already loaded: the detail view's appearance leaves it alone.
        await model.refreshGroupIfNeeded(groupID: "group")
        XCTAssertEqual(rosterReads, 0)
        XCTAssertEqual(model.feed["group"]?.isEmpty, true)

        // Loading (e.g. started by load()): the detail view doesn't restart it.
        let refreshing = Task { await model.refreshGroup(groupID: "group") }
        for _ in 0..<100 where rosterRead == nil { await Task.yield() }
        let continuation = try XCTUnwrap(rosterRead)
        XCTAssertNil(model.feed["group"], "A refresh hides the feed until it reloads")
        await model.refreshGroupIfNeeded(groupID: "group")
        XCTAssertEqual(rosterReads, 1)
        continuation.resume(throwing: URLError(.notConnectedToInternet))
        await refreshing.value

        // Nothing loaded or loading: the detail view refreshes.
        rosterRead = nil
        model.groups = [.init(id: "group", name: "Crew", created_by: "user-a", created_at: 1, members: [])]
        let retry = Task { await model.refreshGroupIfNeeded(groupID: "group") }
        for _ in 0..<100 where rosterRead == nil { await Task.yield() }
        XCTAssertEqual(rosterReads, 2)
        try XCTUnwrap(rosterRead).resume(throwing: URLError(.notConnectedToInternet))
        await retry.value
    }

    func testOpeningTheTabKeepsShownGroupsUntilTheFreshListPrunesThem() async throws {
        for revalidate in [true, false] {
            let suite = "GroupSafetyTests.\(UUID().uuidString)"
            let defaults = try XCTUnwrap(LocalPersistence(suiteName: suite))
            defer { defaults.removePersistentDomain(forName: suite) }
            let auth = AuthModel(tokenStore: TokenStore(), defaults: defaults)
            auth.userID = "user-a"
            let payload = try JSONSerialization.data(withJSONObject: ["sub": "user-a", "exp": 4_000_000_000])
            auth.jwt = "header." + payload.base64EncodedString().replacingOccurrences(of: "=", with: "") + ".signature"
            var listRead: CheckedContinuation<[GroupSummary], Error>?
            let model = GroupModel(auth: auth, defaults: defaults, groupLister: { _ in
                try await withCheckedThrowingContinuation { listRead = $0 }
            }, profileLoader: { _ in throw URLError(.notConnectedToInternet) })
            model.groups = [.init(id: "group", name: "Crew", created_by: "user-b", created_at: 1,
                members: [.init(group_id: "group", user_id: "user-b", display_name: "Member",
                                joined_at: 1, effective_display_name: "Member")])]
            model.selectedGroupID = "group"
            model.phase = .ready
            model.feed["group"] = [.unknown(.init(id: "activity", user_id: "user-b", user_display_name: "Member",
                is_me: false, date: "2026-09-10", occurred_at: 1))]
            model.stats["group"] = []
            model.activitySeries["group"] = []

            let loading = Task { await model.load(revalidate: revalidate) }
            for _ in 0..<100 where listRead == nil { await Task.yield() }
            let continuation = try XCTUnwrap(listRead)
            if revalidate {
                XCTAssertEqual(model.phase, .ready, "Opening the tab keeps the group on screen")
                XCTAssertEqual(model.feed["group"]?.count, 1)
                XCTAssertEqual(model.groups.count, 1)
            } else {
                XCTAssertEqual(model.phase, .loading, "A full reload still starts from nothing")
                XCTAssertTrue(model.feed.isEmpty)
                XCTAssertTrue(model.groups.isEmpty)
            }
            // The server no longer lists the group (left, removed or restricted).
            continuation.resume(returning: [])
            await loading.value
            XCTAssertTrue(model.groups.isEmpty)
            XCTAssertTrue(model.feed.isEmpty)
            XCTAssertTrue(model.stats.isEmpty)
            XCTAssertTrue(model.activitySeries.isEmpty)
            XCTAssertEqual(model.phase, .none)
        }
    }

    func testSwitchingGroupsDuringTabRevalidationKeepsTheFreshList() async throws {
        let suite = "GroupSafetyTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(LocalPersistence(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let auth = AuthModel(tokenStore: TokenStore(), defaults: defaults)
        auth.userID = "user-a"
        let payload = try JSONSerialization.data(withJSONObject: ["sub": "user-a", "exp": 4_000_000_000])
        auth.jwt = "header." + payload.base64EncodedString().replacingOccurrences(of: "=", with: "") + ".signature"
        var listRead: CheckedContinuation<[GroupSummary], Error>?
        let model = GroupModel(auth: auth, defaults: defaults, groupLister: { _ in
            try await withCheckedThrowingContinuation { listRead = $0 }
        }, groupLoader: { _, _ in throw URLError(.cancelled) },
        profileLoader: { _ in throw URLError(.notConnectedToInternet) })
        model.groups = ["a", "b"].map {
            .init(id: $0, name: "Crew \($0)", created_by: "user-a", created_at: 1, members: [])
        }
        model.selectedGroupID = "a"
        model.phase = .ready
        model.feed["a"] = []

        let loading = Task { await model.load(revalidate: true) }
        for _ in 0..<100 where listRead == nil { await Task.yield() }
        let continuation = try XCTUnwrap(listRead)
        // The title switcher stays usable while the list is pending.
        await model.refreshGroup(groupID: "b")
        // The fresh list (no longer including either group) still applies.
        continuation.resume(returning: [])
        await loading.value
        XCTAssertTrue(model.groups.isEmpty)
        XCTAssertTrue(model.feed.isEmpty)
        XCTAssertEqual(model.phase, .none)
    }

    func testGroupRequestStartedBeforeTheFreshListCannotOverrideIt() async throws {
        let suite = "GroupSafetyTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(LocalPersistence(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let auth = AuthModel(tokenStore: TokenStore(), defaults: defaults)
        auth.userID = "user-a"
        let payload = try JSONSerialization.data(withJSONObject: ["sub": "user-a", "exp": 4_000_000_000])
        auth.jwt = "header." + payload.base64EncodedString().replacingOccurrences(of: "=", with: "") + ".signature"
        var listRead: CheckedContinuation<[GroupSummary], Error>?
        var rosterRead: CheckedContinuation<GroupSummary, Error>?
        let model = GroupModel(auth: auth, defaults: defaults, groupLister: { _ in
            try await withCheckedThrowingContinuation { listRead = $0 }
        }, groupLoader: { _, _ in
            try await withCheckedThrowingContinuation { rosterRead = $0 }
        }, profileLoader: { _ in throw URLError(.notConnectedToInternet) })
        model.groups = ["a", "b"].map {
            .init(id: $0, name: "Crew \($0)", created_by: "user-a", created_at: 1, members: [])
        }
        model.selectedGroupID = "a"
        model.phase = .ready
        model.feed["a"] = []

        let loading = Task { await model.load(revalidate: true) }
        for _ in 0..<100 where listRead == nil { await Task.yield() }
        let list = try XCTUnwrap(listRead)
        // Switch groups; its roster request is still out when the list lands.
        let switching = Task { await model.refreshGroup(groupID: "b") }
        for _ in 0..<100 where rosterRead == nil { await Task.yield() }
        let roster = try XCTUnwrap(rosterRead)
        list.resume(returning: [])   // memberships were removed
        await loading.value
        XCTAssertEqual(model.phase, .none)
        roster.resume(throwing: APIError.http(403, "not_a_member"))
        await switching.value
        XCTAssertEqual(model.phase, .none, "A request from the old membership can't show an error")
        XCTAssertTrue(model.groups.isEmpty)
        XCTAssertTrue(model.feed.isEmpty)
    }

    func testCancelledTabLoadDoesNotShowTheErrorScreen() async throws {
        let suite = "GroupSafetyTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(LocalPersistence(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let auth = AuthModel(tokenStore: TokenStore(), defaults: defaults)
        auth.userID = "user-a"
        let payload = try JSONSerialization.data(withJSONObject: ["sub": "user-a", "exp": 4_000_000_000])
        auth.jwt = "header." + payload.base64EncodedString().replacingOccurrences(of: "=", with: "") + ".signature"
        let model = GroupModel(auth: auth, defaults: defaults, groupLister: { _ in
            throw URLError(.cancelled)
        })
        model.groups = [.init(id: "group", name: "Crew", created_by: "user-a", created_at: 1, members: [])]
        model.selectedGroupID = "group"
        model.phase = .ready
        model.feed["group"] = []
        await model.load(revalidate: true)
        XCTAssertEqual(model.phase, .ready)
        XCTAssertEqual(model.feed["group"]?.isEmpty, true)
    }

}
