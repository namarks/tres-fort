import UIKit
import XCTest
@testable import TresFort

private actor StationDeferred<Value> {
    private var continuation: CheckedContinuation<Value, Never>?
    private var resolved: Value?
    func value() async -> Value {
        if let resolved { return resolved }
        return await withCheckedContinuation { continuation = $0 }
    }
    func resolve(_ value: Value) {
        resolved = value
        continuation?.resume(returning: value)
        continuation = nil
    }
}

@MainActor
final class StationPrivacyTests: XCTestCase {
    private func temporaryRoot() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("station-privacy-\(UUID())")
    }

    private func access(_ accountID: String, epoch: UInt64 = 1) -> StationAccess {
        StationAccess(accountID: accountID, epoch: epoch, isCurrentSession: { true }, observeBoundary: { _ in })
    }

    private func fixture(in store: StationRecordingStore) throws -> StationRecording {
        let recording = StationRecording(schemaVersion: 1, id: UUID(), createdAt: Date(), exerciseRawValue: "squat",
            durationSeconds: 1, frameCount: 2, droppedFrameCount: 0, orientation: 1,
            width: 640, height: 480, imageAspectRatio: 4.0 / 3.0,
            finishReason: .userStopped, appBuild: "privacy-test", actualReps: nil)
        let pending = try store.prepare(id: recording.id)
        try Data([1, 2, 3]).write(to: pending.appendingPathComponent("clip.mov"))
        try Data().write(to: pending.appendingPathComponent("measurements.jsonl"))
        try store.publish(recording)
        return recording
    }

    private func report(for recording: StationRecording) -> StationReplayReport {
        StationReplayReport(schemaVersion: 1, recordingID: recording.id, createdAt: Date(), appleRevision: 1,
            mediaPipeModel: "test", mediaPipeRuntime: "test", mediaPipeModelSHA256: "test",
            osVersion: "test", appBuild: "test", frames: [])
    }

    func testDifferentAccountsCannotReadEditDeleteOrShareEachOthersRecording() throws {
        let root = temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let a = access("A-\(UUID())")
        let b = access("B-\(UUID())")
        let storeA = try StationRecordingStore(session: a.session, baseURL: root)
        let storeB = try StationRecordingStore(session: b.session, baseURL: root)
        let saved = try fixture(in: storeA)
        XCTAssertFalse(storeA.rootURL.path.contains(a.session.accountID))
        XCTAssertNotEqual(storeA.rootURL, storeB.rootURL)
        XCTAssertTrue(try storeB.list().isEmpty)
        XCTAssertThrowsError(try storeB.load(id: saved.id))
        XCTAssertThrowsError(try storeB.updateActualReps(5, for: saved.id))
        XCTAssertThrowsError(try storeB.shareURLs(for: saved.id))
        try storeB.delete(id: saved.id)
        XCTAssertEqual(try storeA.load(id: saved.id), saved)
    }

    func testSameAccountNewSessionRetainsClipsButRevokedSessionCannotResume() throws {
        let root = temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let accountID = UUID().uuidString
        let original = access(accountID, epoch: 3)
        let oldStore = try StationRecordingStore(session: original.session, baseURL: root)
        let saved = try fixture(in: oldStore)
        original.invalidate()
        let replacement = access(accountID, epoch: 4)
        let newStore = try StationRecordingStore(session: replacement.session, baseURL: root)
        XCTAssertEqual(try newStore.list().map(\.id), [saved.id])
        XCTAssertThrowsError(try oldStore.list())
        XCTAssertThrowsError(try oldStore.videoURL(for: saved.id))
        XCTAssertThrowsError(try oldStore.updateActualReps(9, for: saved.id))
        XCTAssertThrowsError(try oldStore.delete(id: saved.id))
        XCTAssertThrowsError(try oldStore.saveComparison(report(for: saved), for: saved.id))
        XCTAssertNil(try newStore.load(id: saved.id).actualReps)
    }

    func testBoundaryNotificationRevokesBeforeAuthValidatorChanges() throws {
        var boundary: (() -> Bool)?
        let current = true
        let access = StationAccess(accountID: UUID().uuidString, epoch: 7,
                                   isCurrentSession: { current }, observeBoundary: { boundary = $0 })
        var clearedWhileValidatorStillTrue = false
        access.observeInvalidation {
            clearedWhileValidatorStillTrue = current
            XCTAssertFalse(access.validate(), "A synchronous UI callback cannot revive or recursively invalidate the session")
            return true
        }
        XCTAssertTrue(access.validate())
        XCTAssertTrue(try XCTUnwrap(boundary)())
        XCTAssertTrue(current)
        XCTAssertTrue(clearedWhileValidatorStillTrue)
        XCTAssertFalse(access.isActive)
        XCTAssertFalse(access.validate())
        XCTAssertThrowsError(try access.session.requireActive())
    }

    func testBoundaryRegistrationDoesNotRetainClosedFeature() {
        var boundary: (() -> Bool)?
        weak var observed: StationAccess?
        autoreleasepool {
            let access = StationAccess(accountID: UUID().uuidString, epoch: 0,
                                       isCurrentSession: { true }, observeBoundary: { boundary = $0 })
            observed = access
            XCTAssertNotNil(observed)
        }
        XCTAssertNil(observed)
        XCTAssertEqual(boundary?(), false)
    }

    func testBoundaryStillRevokesPendingWriterGateAfterFeatureHasClosed() throws {
        var boundary: (() -> Bool)?
        var pendingWriterGate: StationSessionGate?
        weak var observed: StationAccess?
        autoreleasepool {
            let access = StationAccess(accountID: UUID().uuidString, epoch: 0,
                                       isCurrentSession: { true }, observeBoundary: { boundary = $0 })
            observed = access
            pendingWriterGate = access.session
        }
        XCTAssertNil(observed)
        XCTAssertTrue(try XCTUnwrap(pendingWriterGate).isActive)
        XCTAssertEqual(boundary?(), false)
        XCTAssertFalse(try XCTUnwrap(pendingWriterGate).isActive)
    }

    func testAccountDeletionRejectsLatePublishWithoutRecreatingFilesAndPreservesOtherAccount() throws {
        let root = temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let accountID = UUID().uuidString
        let a = access(accountID)
        let b = access(UUID().uuidString)
        let storeA = try StationRecordingStore(session: a.session, baseURL: root)
        let storeB = try StationRecordingStore(session: b.session, baseURL: root)
        let savedA = try fixture(in: storeA)
        let savedB = try fixture(in: storeB)
        let late = try fixture(in: storeA)
        try storeA.delete(id: late.id)
        let pending = try storeA.prepare(id: late.id)
        try Data([4]).write(to: pending.appendingPathComponent("clip.mov"))
        try Data().write(to: pending.appendingPathComponent("measurements.jsonl"))
        try StationRecordingStore.deleteAccountRecordings(accountID: accountID, baseURL: root)
        XCTAssertFalse(a.isActive)
        XCTAssertTrue(b.isActive)
        XCTAssertFalse(FileManager.default.fileExists(atPath: storeA.rootURL.path))
        XCTAssertEqual(try storeB.load(id: savedB.id), savedB)
        XCTAssertThrowsError(try storeA.publish(late))
        XCTAssertThrowsError(try storeA.saveComparison(report(for: savedA), for: savedA.id))
        XCTAssertFalse(FileManager.default.fileExists(atPath: storeA.rootURL.path))
        let newAccess = access(accountID, epoch: 2)
        let replacement = try StationRecordingStore(session: newAccess.session, baseURL: root)
        XCTAssertThrowsError(try storeA.publish(late))
        XCTAssertTrue(try replacement.list().isEmpty)
    }

    func testUnattributedLegacyClipsAreNeitherAdoptedNorDeleted() throws {
        let root = temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let legacy = root.appendingPathComponent(UUID().uuidString).appendingPathComponent("clip.mov")
        try FileManager.default.createDirectory(at: legacy.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data([7, 8, 9]).write(to: legacy)
        let account = access(UUID().uuidString)
        let store = try StationRecordingStore(session: account.session, baseURL: root)
        XCTAssertTrue(try store.list().isEmpty)
        try StationRecordingStore.deleteAccountRecordings(accountID: account.session.accountID, baseURL: root)
        XCTAssertEqual(try Data(contentsOf: legacy), Data([7, 8, 9]))
    }

    func testInvalidSessionCannotCreateAStorageDirectory() throws {
        let root = temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let account = access(UUID().uuidString)
        account.invalidate()
        XCTAssertThrowsError(try StationRecordingStore(session: account.session, baseURL: root))
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.path))
    }

    func testShareProviderStopsReturningPrivateURLsAfterRevocation() throws {
        let root = temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let account = access(UUID().uuidString)
        let store = try StationRecordingStore(session: account.session, baseURL: root)
        let saved = try fixture(in: store)
        let url = try store.videoURL(for: saved.id)
        let item = StationShareItem(url: url, session: account.session)
        let controller = UIActivityViewController(activityItems: [], applicationActivities: nil)
        XCTAssertEqual(item.activityViewController(controller, itemForActivityType: nil) as? URL, url)
        account.invalidate()
        XCTAssertNil(item.activityViewController(controller, itemForActivityType: nil))
    }

    func testLateImageCannotReappearAfterSessionBoundary() async throws {
        let root = temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let account = access(UUID().uuidString)
        let store = try StationRecordingStore(session: account.session, baseURL: root)
        let saved = try fixture(in: store)
        let started = expectation(description: "Image decoding started")
        let delayed = StationDeferred<UIImage>()
        let still = StationRecordingStill(access: account) { _, _ in
            started.fulfill()
            return await delayed.value()
        }
        let loading = Task { await still.load(recording: saved, at: 0, store: store) }
        await fulfillment(of: [started], timeout: 3)
        account.invalidate()
        XCTAssertNil(still.image)
        await delayed.resolve(UIImage())
        await loading.value
        XCTAssertNil(still.image)
        XCTAssertNil(still.error)
    }

    func testLateReplayCannotPublishProgressReportOrFileAfterDeletion() async throws {
        let root = temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let account = access(UUID().uuidString)
        let store = try StationRecordingStore(session: account.session, baseURL: root)
        let saved = try fixture(in: store)
        let value = report(for: saved)
        let started = expectation(description: "Replay started")
        let delayed = StationDeferred<StationReplayReport>()
        let replay = StationReplayModel(access: account) { _, _, _, progress in
            started.fulfill()
            let result = await delayed.value()
            progress(99)
            return result
        }
        let task = try XCTUnwrap(replay.start(recording: saved, store: store))
        await fulfillment(of: [started], timeout: 3)
        try StationRecordingStore.deleteAccountRecordings(accountID: account.session.accountID, baseURL: root)
        XCTAssertFalse(replay.isRunning)
        XCTAssertEqual(replay.completedFrames, 0)
        XCTAssertNil(replay.report)
        await delayed.resolve(value)
        await task.value
        XCTAssertNil(replay.report)
        XCTAssertNil(replay.error)
        XCTAssertEqual(replay.completedFrames, 0)
        XCTAssertFalse(FileManager.default.fileExists(atPath: store.rootURL.path))
    }

    func testDisplayedImageAndReplayEvidenceClearSynchronouslyAtBoundary() async throws {
        let root = temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let account = access(UUID().uuidString)
        let store = try StationRecordingStore(session: account.session, baseURL: root)
        let saved = try fixture(in: store)
        let value = report(for: saved)
        let still = StationRecordingStill(access: account) { _, _ in UIImage() }
        let replay = StationReplayModel(access: account) { _, _, _, _ in value }
        await still.load(recording: saved, at: 0, store: store)
        await replay.start(recording: saved, store: store)?.value
        XCTAssertNotNil(still.image)
        XCTAssertNotNil(replay.report)
        account.invalidate()
        XCTAssertNil(still.image)
        XCTAssertNil(replay.report)
        XCTAssertNil(replay.error)
        XCTAssertFalse(replay.isRunning)
    }
}
