import XCTest
@testable import TresFort

private final class CoachTokenStore: AppTokenStore {
    func save(_ token: String) {}
    func load() -> String? { nil }
    func clear() {}
}

private final class CoachApprovalStub: CoachApprovalAPI {
    var preview = CoachApprovalPreview(client_name: "Synthetic AI app",
        redirect_uri: "https://client.example/callback", expires_at: Date.distantFuture.timeIntervalSince1970 * 1000)
    var calls = 0
    var previewCalls = 0
    var previewHandler: (() async throws -> CoachApprovalPreview)?
    var handler: (() async throws -> CoachApprovalDecision)?
    func coachApproval(id: String, jwt: String) async throws -> CoachApprovalPreview {
        previewCalls += 1
        if let previewHandler { return try await previewHandler() }
        return preview
    }
    func decideCoachApproval(id: String, allow: Bool, jwt: String) async throws -> CoachApprovalDecision {
        calls += 1
        if let handler { return try await handler() }
        return CoachApprovalDecision(redirect_uri: "https://client.example/callback?code=synthetic", allowed: allow)
    }
}

@MainActor
final class CoachApprovalTests: XCTestCase {
    private func auth() -> AuthModel {
        let name = "CoachApprovalTests.\(UUID().uuidString)"
        let defaults = LocalPersistence(suiteName: name)!
        addTeardownBlock { [preferences = defaults.preferences, directory = defaults.trainingStore.directory] in
            preferences.removePersistentDomain(forName: name)
            try? FileManager.default.removeItem(at: directory)
        }
        let auth = AuthModel(tokenStore: CoachTokenStore(), defaults: defaults)
        auth.userID = "member-a"
        auth.jwt = "synthetic-bearer"
        auth.phase = .signedIn
        return auth
    }

    func testLinkParserAcceptsOnlyExactVerifiedOriginAndOneOpaqueRequest() {
        let id = String(repeating: "a", count: 64)
        let base = "https://tresfort.app/coach/authorize?request=\(id)"
        XCTAssertEqual(AuthModel.coachApprovalID(from: URL(string: base)!), id)
        for value in [base.replacingOccurrences(of: "https:", with: "http:"),
                      base.replacingOccurrences(of: "tresfort.app", with: "evil.tresfort.app"),
                      base.replacingOccurrences(of: "tresfort.app", with: "user@tresfort.app"),
                      base.replacingOccurrences(of: "tresfort.app", with: "tresfort.app:443"),
                      base + "&request=\(id)", base + "#extra", base + "&redirect=https://evil.test",
                      "https://tresfort.app/coach/authorize?request=short"] {
            XCTAssertNil(AuthModel.coachApprovalID(from: URL(string: value)!), value)
        }
    }

    func testLinkIsNavigationOnlyAndRemainsBoundToItsAccount() {
        let auth = auth()
        let id = String(repeating: "a", count: 64)
        let url = URL(string: "https://tresfort.app/coach/authorize?request=\(id)")!
        auth.handleDeepLink(url)
        auth.handleDeepLink(url)
        XCTAssertEqual(auth.pendingEntryIntents.count, 1)
        XCTAssertEqual(auth.pendingEntryIntents.first?.destination, .coachApproval(id))
        XCTAssertEqual(auth.pendingEntryIntents.first?.accountID, "member-a")
        auth.signOut()
        XCTAssertTrue(auth.pendingEntryIntents.isEmpty)
    }

    func testLoadingNeverAuthorizesAndDoubleTapHasOneDecision() async {
        let auth = auth(), api = CoachApprovalStub()
        let model = CoachApprovalModel(auth: auth, requestID: "request", api: api)
        await model.load()
        XCTAssertEqual(api.calls, 0)
        XCTAssertEqual(model.state, .review(api.preview))
        await model.decide(allow: true)
        await model.decide(allow: true)
        XCTAssertEqual(api.calls, 1)
        guard case .finished = model.state else { return XCTFail("Expected acknowledgement") }
    }

    func testExpiredRequestCannotBeApproved() async {
        let api = CoachApprovalStub()
        api.preview = CoachApprovalPreview(client_name: "App", redirect_uri: "https://client.example/callback", expires_at: 0)
        let model = CoachApprovalModel(auth: auth(), requestID: "request", api: api)
        await model.load()
        await model.decide(allow: true)
        XCTAssertEqual(api.calls, 0)
        guard case .failed = model.state else { return XCTFail("Expected expiry") }
    }

    func testUncertainWriteIsNotRetried() async {
        let api = CoachApprovalStub()
        api.handler = { throw URLError(.networkConnectionLost) }
        let model = CoachApprovalModel(auth: auth(), requestID: "request", api: api)
        await model.load()
        await model.decide(allow: true)
        await model.decide(allow: true)
        XCTAssertEqual(api.calls, 1)
        guard case .failed = model.state else { return XCTFail("Expected uncertainty") }
    }

    func testLateAcknowledgementCannotOpenLinkForAnotherSession() async {
        let auth = auth(), api = CoachApprovalStub()
        api.handler = {
            auth.signOut()
            auth.userID = "member-b"
            auth.jwt = "other-bearer"
            return CoachApprovalDecision(redirect_uri: "https://client.example/callback?code=synthetic", allowed: true)
        }
        let model = CoachApprovalModel(auth: auth, requestID: "request", api: api)
        await model.load()
        await model.decide(allow: true)
        XCTAssertEqual(model.state, .sending)
        XCTAssertEqual(auth.activityPersistenceGeneration, 0)
    }

    func testOldBearer401ReloadsConsentWithoutRepeatingTheDecision() async {
        for failDuringLoad in [true, false] {
            let auth = auth(), api = CoachApprovalStub()
            if failDuringLoad {
                api.previewHandler = { [unowned api] in
                    if api.previewCalls == 1 {
                        auth.jwt = "renewed-bearer"
                        throw APIError.http(401, "invalid_token")
                    }
                    return api.preview
                }
            } else {
                api.handler = {
                    auth.jwt = "renewed-bearer"
                    throw APIError.http(401, "invalid_token")
                }
            }
            let model = CoachApprovalModel(auth: auth, requestID: "request", api: api)
            await model.load()
            if !failDuringLoad { await model.decide(allow: true) }
            XCTAssertEqual(auth.featureJWT, "renewed-bearer")
            XCTAssertEqual(auth.phase, .signedIn)
            XCTAssertEqual(model.state, .review(api.preview))
            XCTAssertEqual(api.previewCalls, 2)
            XCTAssertEqual(api.calls, failDuringLoad ? 0 : 1)
            api.handler = nil
            await model.decide(allow: false)
            XCTAssertEqual(api.calls, failDuringLoad ? 1 : 2)
        }
    }

    func testLate401CannotInvalidateAReplacementFeatureSession() async {
        for failDuringLoad in [true, false] {
            for nextAccount in ["member-a", "member-b"] {
                let auth = auth(), api = CoachApprovalStub()
                let replaceSession = {
                    auth.signOut()
                    auth.userID = nextAccount
                    auth.jwt = "synthetic-bearer"
                    auth.phase = .signedIn
                }
                if failDuringLoad {
                    api.previewHandler = { replaceSession(); throw APIError.http(401, "invalid_token") }
                } else {
                    api.handler = { replaceSession(); throw APIError.http(401, "invalid_token") }
                }
                let model = CoachApprovalModel(auth: auth, requestID: "request", api: api)
                await model.load()
                if !failDuringLoad { await model.decide(allow: true) }
                XCTAssertEqual(auth.featureJWT, "synthetic-bearer")
                XCTAssertEqual(auth.userID, nextAccount)
                XCTAssertEqual(auth.phase, .signedIn)
            }
        }
    }

    func testCurrentBearer401RetainsApprovalThroughSameAccountSignIn() async {
        for failDuringLoad in [true, false] {
            let auth = auth(), api = CoachApprovalStub()
            auth.onboardingComplete = true
            let request = String(repeating: "a", count: 64)
            auth.handleDeepLink(URL(string: "https://tresfort.app/coach/authorize?request=\(request)")!)
            let intent = auth.pendingEntryIntents[0], epoch = auth.featureSessionEpoch
            if failDuringLoad {
                api.previewHandler = { throw APIError.http(401, "invalid_token") }
            } else {
                api.handler = { throw APIError.http(401, "invalid_token") }
            }
            let model = CoachApprovalModel(auth: auth, requestID: request, api: api)
            await model.load()
            if !failDuringLoad { await model.decide(allow: true) }
            XCTAssertNil(auth.featureJWT)
            XCTAssertEqual(auth.phase, .signedOut)
            XCTAssertEqual(auth.userID, "member-a")
            XCTAssertEqual(auth.pendingEntryIntents, [intent])
            XCTAssertFalse(auth.finishEntry(intent, epoch: epoch))
            XCTAssertEqual(api.calls, failDuringLoad ? 0 : 1)

            // The old sheet's dismissal cannot consume the retained intent.
            auth.jwt = "new-bearer"
            auth.phase = .signedIn
            XCTAssertEqual(auth.nextEntryIntent, intent)
            api.previewHandler = nil
            api.handler = nil
            let resumed = CoachApprovalModel(auth: auth, requestID: request, api: api)
            await resumed.load()
            XCTAssertEqual(resumed.state, .review(api.preview))
            XCTAssertEqual(api.calls, failDuringLoad ? 0 : 1)
            await resumed.decide(allow: true)
            guard case .finished = resumed.state else { return XCTFail("Expected explicit approval after sign-in") }
            XCTAssertTrue(auth.finishEntry(intent, epoch: auth.featureSessionEpoch))
        }
    }
}
