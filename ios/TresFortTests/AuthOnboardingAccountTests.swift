import Foundation
import XCTest
@testable import TresFort

@MainActor
final class OnboardingAccountReaderStub: OnboardingAccountReading {
    var training = TrainingProfileState(profile: nil, version: 0, updated_at: nil)
    var profile = MeProfile(display_name: "Apple-supplied name", email: "member@example.invalid",
        intervals: .init(connected: false, athlete_id: nil, needs_reauth: false,
            credential_generation: 0),
        coach: .init(is_owner: true, connected: false, last_active: nil),
        health: .init(sharing_in_group: false))
    var groups: [GroupSummary] = []
    var profileHandler: (() async throws -> MeProfile)?
    var failure: Error?
    private(set) var reads: [String] = []
    private(set) var tokens: [String] = []

    func trainingProfile(jwt: String) async throws -> TrainingProfileState {
        reads.append("training-profile"); tokens.append(jwt)
        if let failure { throw failure }
        return training
    }

    func getMe(jwt: String) async throws -> MeProfile {
        reads.append("me"); tokens.append(jwt)
        if let profileHandler { return try await profileHandler() }
        return profile
    }

    func listGroups(jwt: String) async throws -> [GroupSummary] {
        reads.append("groups"); tokens.append(jwt)
        return groups
    }
}

private final class OnboardingTokenStore: AppTokenStore {
    var token: String?
    init(_ token: String) { self.token = token }
    func load() -> String? { token }
    func save(_ token: String) { self.token = token }
    func clear() { token = nil }
}

@MainActor
final class AuthOnboardingAccountTests: XCTestCase {
    private func auth(_ reader: OnboardingAccountReaderStub,
                      state: StateResponse? = nil) -> (AuthModel, LocalPersistence) {
        let name = "AuthOnboardingAccountTests.\(UUID().uuidString)"
        let local = LocalPersistence(suiteName: name)!
        addTeardownBlock { [preferences = local.preferences, directory = local.trainingStore.directory] in
            preferences.removePersistentDomain(forName: name)
            try? FileManager.default.removeItem(at: directory)
        }
        local.set("member", forKey: AuthModel.userIDKey)
        local.set(false, forKey: AccountLocalState.onboardedKey(userID: "member"))
        let claims = Data(#"{"sub":"member","exp":4000000000}"#.utf8)
            .base64EncodedString().replacingOccurrences(of: "=", with: "")
        let token = "header.\(claims).signature"
        let empty = StateResponse(plan: nil, plan_version: 0, sessions: [], sets: [],
            external_events: [], external_activities: [], activities: [], server_time: 1)
        return (AuthModel(tokenStore: OnboardingTokenStore(token), defaults: local,
            onboardingStateReader: { _ in state ?? empty }, onboardingAccountReader: reader), local)
    }

    func testSavedTrainingProfileRestoresPlanlessAccountWithoutFurtherReads() async {
        let reader = OnboardingAccountReaderStub()
        reader.training = TrainingProfileState(profile: TrainingProfile(), version: 1, updated_at: 1)
        let (auth, local) = auth(reader)
        await auth.resolveOnboarding()
        XCTAssertTrue(auth.onboardingComplete)
        XCTAssertTrue(local.bool(forKey: AccountLocalState.onboardedKey(userID: "member")))
        XCTAssertEqual(reader.reads, ["training-profile"])
        XCTAssertEqual(reader.tokens, [auth.jwt!])
    }

    func testJoinedGroupRestoresPlanlessAccountWithoutActivity() async {
        let reader = OnboardingAccountReaderStub()
        reader.groups = [GroupSummary(id: "group", name: "Crew", created_by: "member",
            created_at: 1, members: [GroupMemberRow(group_id: "group", user_id: "member",
                display_name: nil, joined_at: 1, effective_display_name: nil)])]
        let (auth, _) = auth(reader)
        await auth.resolveOnboarding()
        XCTAssertTrue(auth.onboardingComplete)
        XCTAssertEqual(reader.reads, ["training-profile", "me", "groups"])
        XCTAssertTrue(reader.tokens.allSatisfy { $0 == auth.jwt })
    }

    func testExplicitIntegrationSignalsRestorePlanlessAccountBeforeFirstImport() async {
        let disconnected = MeProfile.IntervalsStatus(connected: false, athlete_id: nil, needs_reauth: false)
        let intervals: [MeProfile.IntervalsStatus] = [
            .init(connected: true, athlete_id: "athlete", needs_reauth: false, sync_pending: true),
            .init(connected: false, athlete_id: nil, needs_reauth: true),
            .init(connected: false, athlete_id: nil, needs_reauth: false, credential_generation: 2),
            .init(connected: false, athlete_id: nil, needs_reauth: false, last_synced_at: 1)
        ]
        let profiles = intervals.map {
            MeProfile(display_name: nil, email: nil, intervals: $0,
                coach: .init(is_owner: false, connected: false, last_active: nil), health: nil)
        } + [
            MeProfile(display_name: nil, email: nil, intervals: disconnected,
                coach: .init(is_owner: false, connected: true, last_active: nil), health: nil),
            MeProfile(display_name: nil, email: nil, intervals: disconnected,
                coach: .init(is_owner: false, connected: false, last_active: 1), health: nil),
            MeProfile(display_name: nil, email: nil, intervals: disconnected,
                coach: .init(is_owner: false, connected: false, last_active: nil),
                health: .init(sharing_in_group: true))
        ]
        for profile in profiles {
            let reader = OnboardingAccountReaderStub()
            reader.profile = profile
            let (auth, _) = auth(reader)
            await auth.resolveOnboarding()
            XCTAssertTrue(auth.onboardingComplete, "\(profile)")
            XCTAssertEqual(reader.reads, ["training-profile", "me"])
        }
    }

    func testDefaultMeNameEmailAndOwnerFlagDoNotProvePriorSetup() async {
        let reader = OnboardingAccountReaderStub()
        let (auth, _) = auth(reader)
        await auth.resolveOnboarding()
        XCTAssertFalse(auth.onboardingComplete)
        XCTAssertEqual(auth.onboardingResolution, .needsSetup)
        XCTAssertTrue(auth.canContinueWithoutSetup)
        XCTAssertEqual(reader.reads, ["training-profile", "me", "groups"])
    }

    func testUnsavedTrainingProfileCannotProvePriorSetup() async {
        let reader = OnboardingAccountReaderStub()
        reader.training = TrainingProfileState(profile: TrainingProfile(), version: 0, updated_at: nil)
        let (auth, _) = auth(reader)
        await auth.resolveOnboarding()
        XCTAssertFalse(auth.onboardingComplete)
        XCTAssertTrue(auth.canContinueWithoutSetup)
    }

    func testAccountReadFailureOffersRetryWithoutClaimingEmptyAccount() async {
        let reader = OnboardingAccountReaderStub()
        reader.failure = URLError(.notConnectedToInternet)
        let (auth, _) = auth(reader)
        await auth.resolveOnboarding()
        guard case .failed = auth.onboardingResolution else { return XCTFail("Expected retry") }
        XCTAssertFalse(auth.onboardingComplete)
        XCTAssertFalse(auth.canContinueWithoutSetup)
        reader.failure = nil
        reader.training = TrainingProfileState(profile: TrainingProfile(), version: 1, updated_at: 1)
        await auth.resolveOnboarding()
        XCTAssertTrue(auth.onboardingComplete)
    }

    func testUnauthorizedAccountReadUsesExistingReauthenticationPath() async {
        let reader = OnboardingAccountReaderStub()
        reader.failure = APIError.http(401, "expired")
        let (auth, _) = auth(reader)
        auth.requestEntry(.invite("ABC234"))
        await auth.resolveOnboarding()
        XCTAssertEqual(auth.phase, .signedOut)
        XCTAssertNil(auth.jwt)
        XCTAssertEqual(auth.pendingInviteCode, "ABC234")
        XCTAssertFalse(auth.canContinueWithoutSetup)
    }

    func testLateAccountResponseCannotCompleteAfterSignOut() async {
        let reader = OnboardingAccountReaderStub()
        let started = expectation(description: "Profile read started")
        var continuation: CheckedContinuation<MeProfile, Never>?
        reader.profileHandler = {
            await withCheckedContinuation { continuation = $0; started.fulfill() }
        }
        let (auth, local) = auth(reader)
        let task = Task { await auth.resolveOnboarding() }
        await fulfillment(of: [started], timeout: 2)
        auth.signOut()
        continuation?.resume(returning: reader.profile)
        await task.value
        XCTAssertFalse(auth.onboardingComplete)
        XCTAssertFalse(auth.canContinueWithoutSetup)
        XCTAssertEqual(auth.onboardingResolution, .unresolved)
        XCTAssertFalse(local.bool(forKey: AccountLocalState.onboardedKey(userID: "member")))
        XCTAssertEqual(reader.reads, ["training-profile", "me"])
    }

    func testCancelledAccountReadCannotOfferSetupOrContinue() async {
        let reader = OnboardingAccountReaderStub()
        let started = expectation(description: "Profile read started")
        var continuation: CheckedContinuation<MeProfile, Never>?
        reader.profileHandler = {
            await withCheckedContinuation { continuation = $0; started.fulfill() }
        }
        let (auth, _) = auth(reader)
        let task = Task { await auth.resolveOnboarding() }
        await fulfillment(of: [started], timeout: 2)
        task.cancel()
        continuation?.resume(returning: reader.profile)
        await task.value
        XCTAssertFalse(auth.onboardingComplete)
        XCTAssertFalse(auth.canContinueWithoutSetup)
        XCTAssertEqual(auth.onboardingResolution, .unresolved)
        XCTAssertEqual(reader.reads, ["training-profile", "me"])
    }

    func testSkipOnlyAccountHasNoServerMarkerButCanContinueAndKeepsEntryIntent() async {
        let reader = OnboardingAccountReaderStub()
        let (firstDevice, _) = auth(reader)
        firstDevice.completeOnboarding()
        // Completion is local today. A fresh device cannot distinguish this
        // skip-only account from a new one without a future server marker.
        let (freshDevice, _) = auth(reader)
        freshDevice.requestEntry(.invite("ABC234"))
        await freshDevice.resolveOnboarding()
        XCTAssertFalse(freshDevice.onboardingComplete)
        XCTAssertTrue(freshDevice.canContinueWithoutSetup)
        freshDevice.continueWithoutSetup()
        XCTAssertTrue(freshDevice.onboardingComplete)
        XCTAssertEqual(freshDevice.nextEntryIntent?.destination, .invite("ABC234"))
        XCTAssertFalse(freshDevice.canContinueWithoutSetup)
    }

    func testUnfinishedLocalDraftDoesNotOfferBypassOrReadAccountEvidence() async {
        let reader = OnboardingAccountReaderStub()
        let (auth, local) = auth(reader)
        local.set(Data("draft".utf8), forKey: AccountLocalState.trainingProfileDraftKey(userID: "member"))
        await auth.resolveOnboarding()
        XCTAssertEqual(auth.onboardingResolution, .needsSetup)
        XCTAssertFalse(auth.canContinueWithoutSetup)
        XCTAssertTrue(reader.reads.isEmpty)
    }

    func testDraftCreatedAfterAccountCheckCannotBeBypassed() async {
        let reader = OnboardingAccountReaderStub()
        let (auth, local) = auth(reader)
        await auth.resolveOnboarding()
        XCTAssertTrue(auth.canContinueWithoutSetup)
        let draft = Data("pending starter acceptance".utf8)
        let key = AccountLocalState.trainingProfileDraftKey(userID: "member")
        local.set(draft, forKey: key)
        auth.continueWithoutSetup()
        XCTAssertFalse(auth.onboardingComplete)
        XCTAssertFalse(auth.canContinueWithoutSetup)
        XCTAssertEqual(local.data(forKey: key), draft)
    }

    func testTrainingStateStillShortCircuitsAdditionalAccountReads() async {
        let reader = OnboardingAccountReaderStub()
        reader.failure = URLError(.notConnectedToInternet)
        let state = StateResponse(plan: PlanTree(id: "plan", name: "Training", version: 1,
            workouts: [], meta: nil), plan_version: 1, sessions: [], sets: [],
            external_events: [], external_activities: [], activities: [], server_time: 1)
        let (auth, _) = auth(reader, state: state)
        await auth.resolveOnboarding()
        XCTAssertTrue(auth.onboardingComplete)
        XCTAssertTrue(reader.reads.isEmpty)
    }
}
