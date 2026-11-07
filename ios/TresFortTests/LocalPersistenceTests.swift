import Foundation
import XCTest
@testable import TresFort

/// Every failure targets real protected-file replacement. Tests never replace
/// the persistence implementation with an in-memory success stub.
final class LocalPersistenceTestHarness {
    final class Faults {
        var failWrites = false
        var failedFiles: Set<String> = []
    }
    let faults = Faults()
    let suite = "LocalPersistenceTests." + UUID().uuidString
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent("LocalPersistenceTests-" + UUID().uuidString)
    let preferences: UserDefaults
    let store: ProtectedTrainingStore

    init() {
        preferences = UserDefaults(suiteName: suite)!
        let faults = self.faults
        store = ProtectedTrainingStore(directory: directory, replace: { source, destination in
            if faults.failWrites || faults.failedFiles.contains(destination.lastPathComponent) {
                throw CocoaError(.fileWriteOutOfSpace)
            }
            try ProtectedTrainingStore.atomicReplace(source, destination)
        })
    }

    func open() -> LocalPersistence {
        LocalPersistence(preferences: preferences, trainingStore: store, suiteName: suite)
    }

    func cleanup() {
        preferences.removePersistentDomain(forName: suite)
        try? FileManager.default.removeItem(at: directory)
    }
}

@MainActor
final class LocalPersistenceTests: XCTestCase {
    private func harness() -> LocalPersistenceTestHarness {
        let result = LocalPersistenceTestHarness()
        addTeardownBlock { result.cleanup() }
        return result
    }

    func testEagerMigrationIncludesInactiveAccountsAndKeepsOnlySettingsInPreferences() throws {
        let h = harness()
        let keys = [SetOutboxStore.scopedKey(userID: "active"),
                    StateSnapshotStore.scopedKey(userID: "inactive"),
                    PlanChangeDismissalStore.key(userID: "inactive"),
                    AccountLocalState.healthAnchorKey(userID: "inactive"),
                    WorkoutRunnerCheckpointStore.scopedKey(userID: "inactive")]
        for (index, key) in keys.enumerated() { h.preferences.set(Data([UInt8(index)]), forKey: key) }
        h.preferences.set("active", forKey: AuthModel.userIDKey)
        h.preferences.set(true, forKey: AccountLocalState.healthEnabledKey(userID: "active"))
        _ = h.open()
        XCTAssertFalse(h.preferences.dictionaryRepresentation().contains {
            ($0.key.hasPrefix("com.nmarkspdx.liftcoach.")
             || $0.key.hasPrefix("com.nmarkspdx.tresfort.")) && $0.value is Data
        })
        let cold = h.open()
        for (index, key) in keys.enumerated() {
            XCTAssertNil(h.preferences.data(forKey: key))
            XCTAssertEqual(cold.data(forKey: key), Data([UInt8(index)]))
            XCTAssertEqual(try h.store.fileURL(forKey: key)
                .resourceValues(forKeys: [.isExcludedFromBackupKey]).isExcludedFromBackup, true)
        }
        XCTAssertEqual(cold.string(forKey: AuthModel.userIDKey), "active")
        XCTAssertTrue(cold.bool(forKey: AccountLocalState.healthEnabledKey(userID: "active")))
    }

    func testFailedMigrationPreservesPreferenceAndRetryRecoversOriginal() {
        let h = harness(), key = SetOutboxStore.scopedKey(userID: "a")
        let original = Data("saved training".utf8)
        h.preferences.set(original, forKey: key)
        h.faults.failWrites = true
        let local = h.open()
        XCTAssertTrue(local.hasFailure(userID: "a"))
        XCTAssertFalse(local.set(Data(), forKey: key))
        XCTAssertEqual(h.preferences.data(forKey: key), original)
        XCTAssertFalse(local.retry(userID: "a"))
        h.faults.failWrites = false
        XCTAssertTrue(local.retry(userID: "a"))
        XCTAssertEqual(local.recoveryGeneration, 1)
        XCTAssertEqual(h.open().data(forKey: key), original)
        XCTAssertNil(h.preferences.data(forKey: key))
    }

    func testCorruptDurableQueueCannotBeOverwrittenOrDiscardedByRetry() throws {
        let h = harness(), local = h.open(), key = SetOutboxStore.scopedKey(userID: "a")
        let original = Data("undecodable queued workout".utf8)
        XCTAssertTrue(local.set(original, forKey: key))
        XCTAssertTrue(SetOutboxStore.load(userID: "a", defaults: local).isEmpty)
        XCTAssertTrue(local.hasFailure(userID: "a"))
        XCTAssertFalse(SetOutboxStore.save(SetOutbox(), userID: "a", defaults: local))
        XCTAssertFalse(local.removeObject(forKey: key))
        XCTAssertFalse(local.retry(userID: "a"))
        XCTAssertEqual(try h.store.data(forKey: key), original)
        // Explicit account cleanup is permitted to erase the corrupt bytes.
        XCTAssertTrue(AccountLocalState.clear(userID: "a", defaults: local))
        XCTAssertNil(try h.store.data(forKey: key))
    }

    func testInvalidEnvelopeKeepsDurableBytesButReplaceableCacheCanReload() throws {
        let h = harness(), local = h.open()
        let queue = SetOutboxStore.scopedKey(userID: "a")
        let cache = StateSnapshotStore.scopedKey(userID: "b")
        for key in [queue, cache] {
            XCTAssertTrue(local.set(Data([1]), forKey: key))
            try Data([255]).write(to: h.store.fileURL(forKey: key))
            XCTAssertNil(local.data(forKey: key))
        }
        XCTAssertTrue(local.hasFailure(userID: "a"))
        XCTAssertFalse(local.hasFailure(userID: "b"))
        XCTAssertEqual(try Data(contentsOf: h.store.fileURL(forKey: queue)), Data([255]))
        XCTAssertTrue(local.set(Data([2]), forKey: cache))
    }

    func testCorruptDisposableMetadataCanReloadWithoutBlockingTheAccount() throws {
        let h = harness(), local = h.open()
        let keys = [PlanChangeDismissalStore.key(userID: "a"),
                    AccountLocalState.intervalsConnectionKey(userID: "a"),
                    AccountLocalState.legacyIntervalsConnectionKey]
        for key in keys {
            XCTAssertTrue(local.set(Data([1]), forKey: key))
            h.preferences.set(Data([2]), forKey: key)
            try Data([255]).write(to: h.store.fileURL(forKey: key))
            XCTAssertNil(local.data(forKey: key))
            XCTAssertFalse(local.hasFailure(userID: "a"))
            XCTAssertNil(h.preferences.data(forKey: key))
            XCTAssertNil(try h.store.data(forKey: key))
            XCTAssertTrue(local.set(Data([3]), forKey: key))
            XCTAssertEqual(h.open().data(forKey: key), Data([3]))
        }
    }

    func testDisposableCorruptionRetriesCleanupAfterStorageBecomesWritable() throws {
        let h = harness(), local = h.open(), key = PlanChangeDismissalStore.key(userID: "a")
        XCTAssertTrue(local.set(Data([1]), forKey: key))
        try Data([255]).write(to: h.store.fileURL(forKey: key))
        h.faults.failWrites = true
        XCTAssertNil(local.data(forKey: key))
        XCTAssertTrue(local.hasFailure(userID: "a"))
        XCTAssertFalse(local.retry(userID: "a"))
        XCTAssertEqual(try Data(contentsOf: h.store.fileURL(forKey: key)), Data([255]))
        h.faults.failWrites = false
        XCTAssertTrue(local.retry(userID: "a"))
        XCTAssertFalse(local.hasFailure(userID: "a"))
        XCTAssertNil(try h.store.data(forKey: key))
        PlanChangeDismissalStore.dismiss(through: 4, userID: "a", planID: "plan", defaults: local)
        XCTAssertEqual(PlanChangeDismissalStore.load(userID: "a", planID: "plan", defaults: h.open()), 4)
    }

    func testDisposableRecoveryNeverErasesCorruptDurableWorkOrHealthAnchors() throws {
        let h = harness(), local = h.open()
        let keys = [SetOutboxStore.scopedKey(userID: "a"), ActivityOutboxStore.legacyKey,
                    AccountLocalState.healthAnchorKey(userID: "a"), AccountLocalState.legacyHealthAnchorKey,
                    WorkoutRunnerCheckpointStore.scopedKey(userID: "a"), AuthModel.pendingEntryKey]
        for key in keys {
            XCTAssertTrue(local.set(Data([1]), forKey: key))
            try Data([255]).write(to: h.store.fileURL(forKey: key))
            XCTAssertNil(local.data(forKey: key))
        }
        XCTAssertFalse(local.retry(userID: "a"))
        for key in keys {
            XCTAssertTrue(local.hasFailure(forKey: key))
            XCTAssertEqual(try Data(contentsOf: h.store.fileURL(forKey: key)), Data([255]))
        }
    }

    func testExplicitHealthResetErasesOnlyOwnedAnchorsAndPreservesFailedTraining() throws {
        let h = harness(), local = h.open()
        XCTAssertTrue(AccountLocalState.claimLegacyState(userID: "a", defaults: local))
        let legacy = AccountLocalState.legacyHealthAnchorKey
        let anchorA = AccountLocalState.healthAnchorKey(userID: "a")
        let anchorB = AccountLocalState.healthAnchorKey(userID: "b")
        let queue = SetOutboxStore.scopedKey(userID: "a")
        for key in [legacy, anchorA, anchorB, queue] {
            XCTAssertTrue(local.set(Data([1]), forKey: key))
            try Data([255]).write(to: h.store.fileURL(forKey: key))
            XCTAssertNil(local.data(forKey: key))
        }
        XCTAssertTrue(local.resetHealthAnchors(userID: "b"))
        XCTAssertNil(try h.store.data(forKey: anchorB))
        for key in [legacy, anchorA, queue] {
            XCTAssertEqual(try Data(contentsOf: h.store.fileURL(forKey: key)), Data([255]))
        }
        XCTAssertTrue(local.resetHealthAnchors(userID: "a"))
        XCTAssertNil(try h.store.data(forKey: legacy))
        XCTAssertNil(try h.store.data(forKey: anchorA))
        XCTAssertTrue(local.hasFailure(forKey: queue))
        XCTAssertFalse(local.retry(userID: "a"))
        XCTAssertEqual(try Data(contentsOf: h.store.fileURL(forKey: queue)), Data([255]))
    }

    func testFailedLegacyMergeKeepsBothQueuesAndCannotTransferToAnotherAccount() throws {
        let h = harness(), local = h.open()
        var legacy = ActivityOutbox(), scoped = ActivityOutbox()
        legacy.enqueue(activity("legacy")); scoped.enqueue(activity("scoped"))
        let legacyBytes = try JSONEncoder().encode(legacy)
        XCTAssertTrue(local.set(legacyBytes, forKey: ActivityOutboxStore.legacyKey))
        XCTAssertTrue(ActivityOutboxStore.save(scoped, userID: "a", defaults: local))
        h.faults.failWrites = true
        AccountLocalState.bindLegacyState(userID: "a", defaults: local)
        XCTAssertEqual(local.data(forKey: ActivityOutboxStore.legacyKey), legacyBytes)
        XCTAssertEqual(ActivityOutboxStore.load(userID: "b", defaults: local).count, 0)
        h.faults.failWrites = false
        XCTAssertTrue(local.retry(userID: "a"))
        let migrated = ActivityOutboxStore.load(userID: "a", defaults: local)
        XCTAssertEqual(migrated.pending.map(\.id), ["scoped", "legacy"])
        XCTAssertNil(local.data(forKey: ActivityOutboxStore.legacyKey))
        XCTAssertEqual(ActivityOutboxStore.load(userID: "b", defaults: local).count, 0)
    }

    func testFailedActivityReplacementKeepsPriorIntentAcrossColdOpen() throws {
        let h = harness(), local = h.open()
        XCTAssertTrue(ActivityOutboxStore.enqueue(activity("first"), userID: "a", defaults: local))
        h.faults.failWrites = true
        XCTAssertFalse(ActivityOutboxStore.enqueue(activity("second"), userID: "a", defaults: local))
        XCTAssertEqual(ActivityOutboxStore.load(userID: "a", defaults: h.open()).pending.map(\.id), ["first"])
        h.faults.failWrites = false
        XCTAssertTrue(local.retry(userID: "a"))
        XCTAssertTrue(ActivityOutboxStore.enqueue(activity("second"), userID: "a", defaults: local))
        XCTAssertEqual(ActivityOutboxStore.load(userID: "a", defaults: h.open()).pending.map(\.id), ["first", "second"])
    }

    func testOtherAccountCleanupCannotEraseFailedLegacyMigration() throws {
        let h = harness(), local = h.open()
        var legacy = ActivityOutbox()
        legacy.enqueue(activity("owned-by-a"))
        let original = try JSONEncoder().encode(legacy)
        XCTAssertTrue(local.set(original, forKey: ActivityOutboxStore.legacyKey))
        h.faults.failedFiles = [h.store.fileURL(forKey: ActivityOutboxStore.legacyKey).lastPathComponent]
        AccountLocalState.bindLegacyState(userID: "a", defaults: local)
        XCTAssertTrue(local.hasFailure(userID: "a"))
        XCTAssertFalse(local.hasFailure(userID: "b"))
        XCTAssertTrue(AccountLocalState.clear(userID: "b", defaults: local))
        XCTAssertEqual(local.data(forKey: ActivityOutboxStore.legacyKey), original)
        XCTAssertEqual(ActivityOutboxStore.load(userID: "a", defaults: local).pending.map(\.id), ["owned-by-a"])
    }

    func testDeletionRetainsLegacyOwnerUntilCleanupSucceedsThenRemovesIdentity() throws {
        let h = harness(), local = h.open()
        let ownerKey = "com.nmarkspdx.liftcoach.legacy-state-owner.v1"
        XCTAssertTrue(AccountLocalState.claimLegacyState(userID: "a", defaults: local))
        XCTAssertNotNil(h.preferences.string(forKey: ownerKey))
        h.faults.failedFiles = [h.store.fileURL(forKey: AccountLocalState.legacyHealthAnchorKey).lastPathComponent]
        XCTAssertFalse(AccountLocalState.clear(userID: "a", defaults: local))
        XCTAssertFalse(AccountLocalState.claimLegacyState(userID: "b", defaults: local))
        XCTAssertNotNil(h.preferences.string(forKey: ownerKey))
        h.faults.failedFiles = []
        XCTAssertTrue(AccountLocalState.clear(userID: "a", defaults: local))
        XCTAssertNil(h.preferences.string(forKey: ownerKey))
        XCTAssertTrue(AccountLocalState.claimLegacyState(userID: "b", defaults: local))
        var legacy = ActivityOutbox()
        legacy.enqueue(activity("new-account-legacy"))
        XCTAssertTrue(local.set(try JSONEncoder().encode(legacy), forKey: ActivityOutboxStore.legacyKey))
        XCTAssertEqual(ActivityOutboxStore.load(userID: "b", defaults: local).pending.map(\.id), ["new-account-legacy"])
        XCTAssertTrue(ActivityOutboxStore.load(userID: "a", defaults: local).isEmpty)
    }

    func testAccountDeletionErasesTheRunRecordersThresholds() throws {
        let h = harness(), local = h.open()
        let mine = AccountLocalState.runThresholdsKey(userID: "a")
        let other = AccountLocalState.runThresholdsKey(userID: "b")
        h.preferences.set(Data("[threshold rows]".utf8), forKey: mine)
        h.preferences.set(Data("[other rows]".utf8), forKey: other)
        XCTAssertTrue(AccountLocalState.clear(userID: "a", defaults: local))
        XCTAssertNil(h.preferences.object(forKey: mine))
        XCTAssertNotNil(h.preferences.object(forKey: other))
    }

    private func activity(_ id: String) -> PendingActivity {
        PendingActivity(id: id, date: "2026-09-10", type: "walk", title: nil,
                        duration_minutes: 10, notes: "Private training", logged_at: 2_000_000_000_000)
    }
}
