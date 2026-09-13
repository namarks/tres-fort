import XCTest
@testable import TresFort

final class BodyWeightHistoryTests: XCTestCase {
    private func date(_ string: String) -> Date { ISO8601DateFormatter().date(from: string)! }
    private var calendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "America/Los_Angeles")!
        return calendar
    }
    private func reading(_ instant: String, _ kg: Double) -> BodyWeightMeasurement {
        BodyWeightMeasurement(id: UUID(), date: date(instant), kilograms: kg, source: "Synthetic scale")
    }

    func testDailyLatestAndAverageDoNotOverweightRepeatedWeighIns() throws {
        let early = reading("2026-09-12T08:00:00Z", 70)
        let latest = reading("2026-09-12T09:00:00Z", 80)
        let previous = reading("2026-09-11T09:00:00Z", 78)
        let history = BodyWeightHistory([latest, previous, early, latest],
            asOf: date("2026-09-12T12:00:00Z"), calendar: calendar)
        XCTAssertEqual(history.measurements.count, 3)
        XCTAssertEqual(history.latest, latest)
        XCTAssertEqual(history.recentDays(30), [previous, latest])
        XCTAssertEqual(try XCTUnwrap(history.average(ending: history.asOf)), 79)
    }

    func testSevenCivilDaysAcrossSpringDSTExcludeOlderDayAndFutureSamples() throws {
        let history = BodyWeightHistory([
            reading("2026-03-02T07:59:00Z", 500), // March 1 local; outside window
            reading("2026-03-02T08:01:00Z", 70), // March 2; six days ago
            reading("2026-03-08T10:01:00Z", 80), // after spring-forward
            reading("2026-03-09T10:00:00Z", 100),
            reading("2026-03-08T11:00:00Z", .nan),
            reading("2026-03-08T11:00:00Z", 0),
        ], asOf: date("2026-03-08T20:00:00Z"), calendar: calendar)
        XCTAssertEqual(history.recentDays(7).count, 2)
        XCTAssertEqual(try XCTUnwrap(history.average(ending: history.asOf)), 75)
        XCTAssertEqual(history.latest?.kilograms, 80)
    }

    func testOldWeightRetainsDateWithoutInventingRecentTrend() {
        let old = reading("2025-01-01T12:00:00Z", 80)
        let history = BodyWeightHistory([old], asOf: date("2026-09-12T12:00:00Z"), calendar: calendar)
        XCTAssertEqual(history.latest, old)
        XCTAssertTrue(history.recentDays(90).isEmpty)
        XCTAssertNil(history.average(ending: history.asOf))
    }

    func testMassConversion() {
        XCTAssertEqual(BodyWeightUnit.pounds.value(80), 176.3698, accuracy: 0.0001)
        XCTAssertEqual(BodyWeightUnit.kilograms.value(80), 80)
    }
}

private final class WeightTokenStore: AppTokenStore {
    func load() -> String? { nil }
    func save(_ token: String) {}
    func clear() {}
}

@MainActor
private final class WeightReaderStub: BodyWeightReading {
    var isAvailable = true
    var authorizationError: Error?
    var result: [BodyWeightMeasurement] = []
    var readHandler: (() async throws -> [BodyWeightMeasurement])?
    var authorizeHandler: (() async throws -> Void)?
    var requests = 0
    var reads = 0
    func requestAuthorization() async throws {
        requests += 1
        if let authorizationError { throw authorizationError }
        try await authorizeHandler?()
    }
    func read(from: Date, through: Date) async throws -> [BodyWeightMeasurement] {
        reads += 1
        if let readHandler { return try await readHandler() }
        return result
    }
}

@MainActor
final class BodyWeightModelTests: XCTestCase {
    private struct Harness {
        let auth: AuthModel
        let model: BodyWeightModel
        let reader: WeightReaderStub
        let defaults: LocalPersistence
    }

    private func harness() -> Harness {
        let name = "BodyWeightTests.\(UUID().uuidString)"
        let defaults = LocalPersistence(suiteName: name)!
        addTeardownBlock { [preferences = defaults.preferences, directory = defaults.trainingStore.directory] in
            preferences.removePersistentDomain(forName: name)
            try? FileManager.default.removeItem(at: directory)
        }
        let auth = AuthModel(tokenStore: WeightTokenStore(), defaults: defaults)
        auth.userID = "weight-user"
        auth.jwt = "synthetic-test-bearer"
        let reader = WeightReaderStub()
        return Harness(auth: auth, model: BodyWeightModel(auth: auth, defaults: defaults, reader: reader),
                       reader: reader, defaults: defaults)
    }

    private func reading(_ kg: Double) -> BodyWeightMeasurement {
        BodyWeightMeasurement(id: UUID(), date: Date().addingTimeInterval(-60), kilograms: kg, source: "Test scale")
    }

    func testOptInIsSeparateAndDeniedEmptyReadsCanRecover() async {
        let h = harness()
        await h.model.refresh()
        XCTAssertEqual(h.reader.reads, 0)
        await h.model.connect()
        XCTAssertTrue(h.model.enabled)
        XCTAssertNil(h.model.history?.latest)
        XCTAssertFalse(h.defaults.bool(forKey: AccountLocalState.healthEnabledKey(userID: "weight-user")))
        h.reader.result = [reading(80)]
        await h.model.refresh()
        XCTAssertEqual(h.model.history?.latest?.kilograms, 80)
        XCTAssertEqual(h.reader.requests, 1)
        h.reader.result = [] // source deletion or access revocation
        await h.model.refresh()
        XCTAssertNil(h.model.history?.latest)
    }

    func testAuthorizationFailureDoesNotEnableWeight() async {
        let h = harness()
        h.reader.authorizationError = URLError(.cancelled)
        await h.model.connect()
        XCTAssertFalse(h.model.enabled)
        XCTAssertFalse(h.model.isBusy)
        XCTAssertEqual(h.reader.reads, 0)
        XCTAssertNotNil(h.model.errorMessage)
    }

    func testUnavailableHealthDoesNotRequestOrRead() async {
        let h = harness()
        h.reader.isAvailable = false
        await h.model.connect()
        await h.model.refresh()
        XCTAssertFalse(h.model.enabled)
        XCTAssertEqual(h.reader.requests, 0)
        XCTAssertEqual(h.reader.reads, 0)
    }

    func testSharedReviewAccountCannotReadPersonalHealth() async {
        let h = harness()
        let claims = Data("{\"app_review\":true}".utf8).base64EncodedString()
        h.auth.jwt = "e30.\(claims).synthetic"
        XCTAssertTrue(h.model.requiresPersonalSignIn)
        await h.model.connect()
        XCTAssertEqual(h.reader.requests, 0)
        XCTAssertEqual(h.reader.reads, 0)
    }

    func testDisconnectRejectsLateReadEvenAfterReconnect() async {
        let h = harness()
        await h.model.connect()
        let started = expectation(description: "Read started")
        var pending: CheckedContinuation<[BodyWeightMeasurement], Error>?
        h.reader.readHandler = {
            try await withCheckedThrowingContinuation { continuation in
                pending = continuation
                started.fulfill()
            }
        }
        let oldRead = Task { await h.model.refresh() }
        await fulfillment(of: [started], timeout: 2)
        h.model.disconnect()
        XCTAssertNil(h.model.history)
        h.reader.readHandler = nil
        h.reader.result = [reading(75)]
        await h.model.connect()
        pending?.resume(returning: [reading(90)])
        await oldRead.value
        XCTAssertEqual(h.model.history?.latest?.kilograms, 75)
        XCTAssertTrue(h.model.enabled)
        XCTAssertFalse(h.model.isBusy)
    }

    func testDisconnectDuringAuthorizationDoesNotRestoreOptIn() async {
        let h = harness()
        let started = expectation(description: "Authorization started")
        var pending: CheckedContinuation<Void, Error>?
        h.reader.authorizeHandler = {
            try await withCheckedThrowingContinuation { continuation in
                pending = continuation
                started.fulfill()
            }
        }
        let connect = Task { await h.model.connect() }
        await fulfillment(of: [started], timeout: 2)
        h.model.disconnect()
        pending?.resume()
        await connect.value
        XCTAssertFalse(h.model.enabled)
        XCTAssertEqual(h.reader.reads, 0)
    }

    func testSignOutClearsDisplayAndOldSessionCannotReconnect() async {
        let h = harness()
        h.reader.result = [reading(80)]
        await h.model.connect()
        h.auth.signOut()
        XCTAssertNil(h.model.history)
        h.auth.userID = "weight-user"
        h.auth.jwt = "replacement-synthetic-bearer"
        await h.model.connect()
        XCTAssertEqual(h.reader.requests, 1)
        XCTAssertNil(h.model.history)
        // A new same-account model can restore the preference, but another
        // account has no permission intent just because Health is on the phone.
        let replacement = BodyWeightModel(auth: h.auth, defaults: h.defaults, reader: h.reader)
        XCTAssertTrue(replacement.enabled)
        h.auth.userID = "another-user"
        let other = BodyWeightModel(auth: h.auth, defaults: h.defaults, reader: h.reader)
        XCTAssertFalse(other.enabled)
    }

    func testReadFailureClearsPreviouslyDisplayedMeasurements() async {
        let h = harness()
        h.reader.result = [reading(80)]
        await h.model.connect()
        h.reader.readHandler = { throw URLError(.cannotLoadFromNetwork) }
        await h.model.refresh()
        XCTAssertNil(h.model.history)
        XCTAssertNotNil(h.model.errorMessage)
        XCTAssertFalse(h.model.isBusy)
    }

    func testAccountDeletionCleanupRemovesWeightPreference() async {
        let h = harness()
        await h.model.connect()
        XCTAssertTrue(AccountLocalState.clear(userID: "weight-user", defaults: h.defaults))
        XCTAssertFalse(h.defaults.bool(forKey: AccountLocalState.bodyWeightEnabledKey(userID: "weight-user")))
    }
}
