import Foundation
import XCTest
@testable import TresFort

private final class RecordingUploadStub: RecordingUploadAPI {
    var failures: [UUID: Error] = [:]
    private(set) var uploaded: [UUID] = []

    func uploadRecording(_ run: RecordedRun, jwt: String) async throws -> RecordingUploadResult {
        if let error = failures[run.id] { throw error }
        uploaded.append(run.id)
        return RecordingUploadResult(
            ok: true, deduplicated: false, recording_id: run.uploadID, intervals_activity_id: "i1")
    }
}

final class RunRecordingTests: XCTestCase {
    private var base: URL!

    override func setUpWithError() throws {
        base = FileManager.default.temporaryDirectory.appendingPathComponent("run-recordings-\(UUID())")
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: base)
    }

    private func makeRun(
        startedAt: Date = Date(timeIntervalSince1970: 1_793_000_000),
        finished: Bool = true,
        name: String? = "Morning Run"
    ) -> RecordedRun {
        var run = RecordedRun(startedAt: startedAt, timeZone: TimeZone(identifier: "America/Los_Angeles")!, name: name)
        run.points = [
            .init(timestamp: startedAt, latitude: 45.5231, longitude: -122.6765, altitude: 15.24, horizontalAccuracy: 5),
            .init(timestamp: startedAt.addingTimeInterval(10), latitude: 45.5232, longitude: -122.6766,
                  altitude: nil, horizontalAccuracy: 6),
            .init(timestamp: startedAt.addingTimeInterval(20), latitude: 45.5233, longitude: -122.6767,
                  altitude: 16, horizontalAccuracy: 5),
        ]
        run.heartRates = [
            .init(timestamp: startedAt.addingTimeInterval(1), beatsPerMinute: 140.4),
            .init(timestamp: startedAt.addingTimeInterval(11), beatsPerMinute: 151.6),
        ]
        run.movingSeconds = 20
        run.distanceMeters = 28
        if finished { run.endedAt = startedAt.addingTimeInterval(20) }
        return run
    }

    func testCivilDateUsesTheRecordingTimeZone() {
        // 2026-10-27T05:30:00Z is still Oct 26 in Portland.
        let start = Date(timeIntervalSince1970: 1_793_079_000)
        XCTAssertEqual(RecordedRun(startedAt: start, timeZone: TimeZone(identifier: "UTC")!).date, "2026-10-27")
        XCTAssertEqual(
            RecordedRun(startedAt: start, timeZone: TimeZone(identifier: "America/Los_Angeles")!).date, "2026-10-26")
    }

    func testTCXCarriesTheBuilderTotalsTrackTimesElevationAndNearbyHeartRate() throws {
        var recorded = makeRun()
        recorded.movingSeconds = 19.5
        // A sample 9s from the last point is outside the match window.
        recorded.heartRates.append(.init(timestamp: recorded.startedAt.addingTimeInterval(29), beatsPerMinute: 160))
        let tcx = try XCTUnwrap(String(data: RecordedRunTCX.encode(recorded), encoding: .utf8))

        XCTAssertTrue(tcx.hasPrefix("<?xml version=\"1.0\" encoding=\"UTF-8\"?>\n<TrainingCenterDatabase"))
        XCTAssertTrue(tcx.contains("<Activity Sport=\"Running\">\n      <Id>2026-10-26T07:33:20Z</Id>"))
        // The lap carries the builder's moving time and distance, not GPS's 27.2 m.
        XCTAssertTrue(tcx.contains(
            "<TotalTimeSeconds>19.5</TotalTimeSeconds>\n        <DistanceMeters>28.0</DistanceMeters>"))
        XCTAssertEqual(tcx.components(separatedBy: "<Track>").count - 1, 1)
        XCTAssertEqual(tcx.components(separatedBy: "<Trackpoint>").count - 1, 3)
        XCTAssertTrue(tcx.contains(
            "<Trackpoint><Time>2026-10-26T07:33:20Z</Time><Position><LatitudeDegrees>45.5231000</LatitudeDegrees>"
            + "<LongitudeDegrees>-122.6765000</LongitudeDegrees></Position><AltitudeMeters>15.2</AltitudeMeters>"
            + "<DistanceMeters>0.0</DistanceMeters><HeartRateBpm><Value>140</Value></HeartRateBpm></Trackpoint>"))
        // No altitude: no <AltitudeMeters>. Point distance is scaled to the
        // builder total. HR 151.6 rounds to 152.
        XCTAssertTrue(tcx.contains(
            "<LongitudeDegrees>-122.6766000</LongitudeDegrees></Position>"
            + "<DistanceMeters>14.0</DistanceMeters><HeartRateBpm><Value>152</Value></HeartRateBpm></Trackpoint>"))
        // The third point's nearest samples (151.6 at 11s, 160 at 29s) are both 9s away.
        XCTAssertTrue(tcx.contains(
            "<AltitudeMeters>16.0</AltitudeMeters><DistanceMeters>28.0</DistanceMeters></Trackpoint>"))
        XCTAssertTrue(tcx.hasSuffix("</Lap>\n    </Activity>\n  </Activities>\n</TrainingCenterDatabase>\n"))
    }

    func testTCXFallsBackToGPSDistanceWithoutABuilderTotal() throws {
        var recorded = makeRun()
        recorded.distanceMeters = 0
        recorded.heartRates = []
        let tcx = try XCTUnwrap(String(data: RecordedRunTCX.encode(recorded), encoding: .utf8))
        XCTAssertTrue(tcx.contains("</TotalTimeSeconds>\n        <DistanceMeters>27.2</DistanceMeters>"))
        XCTAssertTrue(tcx.contains("<DistanceMeters>13.6</DistanceMeters></Trackpoint>"))
        XCTAssertFalse(tcx.contains("<HeartRateBpm>"))
    }

    func testTCXStartsANewTrackAfterAPauseAndSkipsPausedDistance() throws {
        var recorded = makeRun()
        let start = recorded.startedAt
        recorded.distanceMeters = 20
        recorded.heartRates = []
        recorded.pauses = [.init(start: start.addingTimeInterval(12), end: start.addingTimeInterval(18))]
        let tcx = try XCTUnwrap(String(data: RecordedRunTCX.encode(recorded), encoding: .utf8))
        XCTAssertEqual(RecordedRunTCX.segments(recorded).map(\.count), [2, 1])
        XCTAssertEqual(tcx.components(separatedBy: "<Track>").count - 1, 2)
        // Only the first segment's 13.6 m counts, scaled to the builder's 20 m.
        XCTAssertTrue(tcx.contains(
            "<DistanceMeters>20.0</DistanceMeters></Trackpoint>\n        </Track>\n        <Track>\n"))
        XCTAssertTrue(tcx.contains("<AltitudeMeters>16.0</AltitudeMeters><DistanceMeters>20.0</DistanceMeters>"))

        // Points inside a pause, or after one that never ended, are dropped.
        recorded.pauses = [
            .init(start: start.addingTimeInterval(5), end: start.addingTimeInterval(15)),
            .init(start: start.addingTimeInterval(15), end: nil),
        ]
        XCTAssertEqual(RecordedRunTCX.segments(recorded).map(\.count), [1])
    }

    func testTCXWithoutPointsIsStillOneLap() throws {
        var recorded = makeRun()
        recorded.points = []
        let tcx = try XCTUnwrap(String(data: RecordedRunTCX.encode(recorded), encoding: .utf8))
        XCTAssertTrue(tcx.contains("<DistanceMeters>28.0</DistanceMeters>"))
        XCTAssertFalse(tcx.contains("<Track>"))
    }

    func testMultipartBodyCarriesTheFieldsAndTCXFile() throws {
        let recorded = makeRun(name: "  Morning Run ")
        let tcx = Data("<TrainingCenterDatabase/>".utf8)
        let body = try XCTUnwrap(String(
            data: APIClient.recordingMultipartBody(recorded, tcx: tcx, boundary: "B"), encoding: .utf8))
        let id = recorded.id.uuidString.lowercased()
        XCTAssertEqual(body, [
            "--B\r\nContent-Disposition: form-data; name=\"id\"\r\n\r\n\(id)\r\n",
            "--B\r\nContent-Disposition: form-data; name=\"date\"\r\n\r\n2026-10-26\r\n",
            "--B\r\nContent-Disposition: form-data; name=\"name\"\r\n\r\nMorning Run\r\n",
            "--B\r\nContent-Disposition: form-data; name=\"file\"; filename=\"\(id).tcx\"\r\n",
            "Content-Type: application/vnd.garmin.tcx+xml\r\n\r\n<TrainingCenterDatabase/>\r\n--B--\r\n",
        ].joined())
    }

    func testMultipartBodyOmitsABlankName() throws {
        let body = try XCTUnwrap(String(
            data: APIClient.recordingMultipartBody(makeRun(name: "  "), tcx: Data(), boundary: "B"), encoding: .utf8))
        XCTAssertFalse(body.contains("name=\"name\""))
    }

    func testStoreKeepsRunsPerAccountUntilRemoved() throws {
        let store = try RunRecordingStore(accountID: "user-a", baseURL: base)
        let other = try RunRecordingStore(accountID: "user-b", baseURL: base)
        let earlier = makeRun(startedAt: Date(timeIntervalSince1970: 1_793_000_000))
        let inProgress = makeRun(startedAt: Date(timeIntervalSince1970: 1_793_100_000), finished: false)
        try store.save(inProgress)
        try store.save(earlier)

        XCTAssertEqual(try store.all().map(\.id), [earlier.id, inProgress.id])
        XCTAssertEqual(try store.pendingUploads().map(\.id), [earlier.id])
        XCTAssertEqual(try store.unfinished()?.id, inProgress.id)
        XCTAssertEqual(try store.load(id: earlier.id), earlier)
        XCTAssertEqual(try other.all(), [])
        XCTAssertFalse(store.rootURL.path.contains("user-a"))

        // A checkpoint replaces the earlier copy of the same run.
        var checkpoint = inProgress
        checkpoint.distanceMeters = 500
        try store.save(checkpoint)
        XCTAssertEqual(try store.load(id: inProgress.id)?.distanceMeters, 500)

        try store.remove(id: earlier.id)
        XCTAssertEqual(try store.all().map(\.id), [inProgress.id])
        try store.remove(id: earlier.id) // Removing twice is harmless.
    }

    func testStoreReportsADamagedRunInsteadOfHidingIt() throws {
        let store = try RunRecordingStore(accountID: "user-a", baseURL: base)
        let id = UUID()
        try Data("not json".utf8).write(to: store.rootURL.appendingPathComponent(id.uuidString.lowercased() + ".json"))
        XCTAssertThrowsError(try store.all()) { error in
            XCTAssertEqual(error as? RunRecordingStoreError, .damagedRecording(id))
        }
    }

    func testAccountDeletionRemovesOnlyThatAccountsRuns() throws {
        let store = try RunRecordingStore(accountID: "user-a", baseURL: base)
        let other = try RunRecordingStore(accountID: "user-b", baseURL: base)
        try store.save(makeRun())
        try other.save(makeRun())
        try RunRecordingStore.deleteAccountRecordings(accountID: "user-a", baseURL: base)
        XCTAssertFalse(FileManager.default.fileExists(atPath: store.rootURL.path))
        XCTAssertEqual(try other.all().count, 1)
    }

    func testUploaderRemovesAcknowledgedRunsAndKeepsFailures() async throws {
        let store = try RunRecordingStore(accountID: "user-a", baseURL: base)
        let first = makeRun(startedAt: Date(timeIntervalSince1970: 1_793_000_000))
        let second = makeRun(startedAt: Date(timeIntervalSince1970: 1_793_100_000))
        let third = makeRun(startedAt: Date(timeIntervalSince1970: 1_793_200_000))
        let inProgress = makeRun(startedAt: Date(timeIntervalSince1970: 1_793_300_000), finished: false)
        for r in [first, second, third, inProgress] { try store.save(r) }
        let api = RecordingUploadStub()
        api.failures[second.id] = APIError.http(502, "unavailable")

        let summary = try await RunRecordingUploader.uploadPending(store: store, api: api, jwt: "jwt")

        XCTAssertEqual(summary, .init(uploaded: [first.id, third.id], failed: [second.id], unauthorized: false))
        XCTAssertEqual(api.uploaded, [first.id, third.id])
        XCTAssertEqual(try store.all().map(\.id), [second.id, inProgress.id])
    }

    func testUploaderStopsWhenTheBearerIsRejected() async throws {
        let store = try RunRecordingStore(accountID: "user-a", baseURL: base)
        let first = makeRun(startedAt: Date(timeIntervalSince1970: 1_793_000_000))
        let second = makeRun(startedAt: Date(timeIntervalSince1970: 1_793_100_000))
        try store.save(first)
        try store.save(second)
        let api = RecordingUploadStub()
        api.failures[first.id] = APIError.http(401, "expired")

        let summary = try await RunRecordingUploader.uploadPending(store: store, api: api, jwt: "jwt")

        XCTAssertEqual(summary, .init(uploaded: [], failed: [first.id], unauthorized: true))
        XCTAssertEqual(api.uploaded, [])
        XCTAssertEqual(try store.all().count, 2)
    }
}
