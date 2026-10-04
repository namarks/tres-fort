import Foundation
import XCTest
@testable import TresFort

final class StationCurlRecordingTests: XCTestCase {
    private func fixture(_ exercise: StationExercise = .curl, actualReps: Int? = nil) -> StationRecording {
        StationRecording(schemaVersion: 1, id: UUID(), createdAt: Date(timeIntervalSince1970: 1_000),
            exerciseRawValue: exercise.rawValue, durationSeconds: 1, frameCount: 16, droppedFrameCount: 2,
            orientation: 1, width: 640, height: 480, imageAspectRatio: 4.0 / 3.0,
            finishReason: .userStopped, appBuild: "curl-test", actualReps: actualReps, detector: .mediaPipe)
    }

    private func publish(_ recording: StationRecording, in store: StationRecordingStore) throws {
        let pending = try store.prepare(id: recording.id)
        try Data([1, 2, 3]).write(to: pending.appendingPathComponent("clip.mov"))
        try Data().write(to: pending.appendingPathComponent("measurements.jsonl"))
        try store.publish(recording)
    }

    private func withStore(_ operation: (StationRecordingStore, URL) throws -> Void) throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("station-curl-labels-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try StationRecordingStore(session: StationSessionGate(accountID: UUID().uuidString, epoch: 1), baseURL: root)
        try operation(store, root)
    }

    func testLegacyCurlSingleCountRemainsUnspecifiedAndDoesNotPopulateEitherArm() throws {
        var legacy = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(fixture(actualReps: 10))) as? [String: Any])
        legacy.removeValue(forKey: "actualLeftReps")
        legacy.removeValue(forKey: "actualRightReps")
        legacy.removeValue(forKey: "detector")
        let decoded = try JSONDecoder().decode(StationRecording.self, from: JSONSerialization.data(withJSONObject: legacy))
        XCTAssertEqual(decoded.exercise, .curl)
        XCTAssertEqual(decoded.actualReps, 10)
        XCTAssertNil(decoded.actualLeftReps)
        XCTAssertNil(decoded.actualRightReps)
        XCTAssertNil(decoded.detector)
    }

    func testSeparateArmLabelsRoundTripWithoutReplacingOldLabelOrOtherMetadata() throws {
        try withStore { store, _ in
            let original = fixture(actualReps: 10)
            try publish(original, in: store)
            let beforeVideo = try Data(contentsOf: store.videoURL(for: original.id))
            let result = try store.updateActualCurlReps(left: 4, right: 7, for: original.id)
            var expected = original
            expected.actualLeftReps = 4
            expected.actualRightReps = 7
            XCTAssertEqual(result, expected)
            XCTAssertEqual(try store.load(id: original.id), expected)
            XCTAssertEqual(result.actualReps, 10)
            XCTAssertEqual(try Data(contentsOf: store.videoURL(for: original.id)), beforeVideo)
            XCTAssertEqual(try JSONDecoder().decode(StationRecording.self, from: JSONEncoder().encode(result)), expected)
        }
    }

    func testUnknownArmIsNilRatherThanZeroAndLabelsCanBeClearedIndependently() throws {
        try withStore { store, _ in
            let saved = fixture()
            try publish(saved, in: store)
            let zero = try store.updateActualCurlReps(left: 0, right: nil, for: saved.id)
            XCTAssertEqual(zero.actualLeftReps, 0)
            XCTAssertNil(zero.actualRightReps)
            let rightOnly = try store.updateActualCurlReps(left: nil, right: 1_000, for: saved.id)
            XCTAssertNil(rightOnly.actualLeftReps)
            XCTAssertEqual(rightOnly.actualRightReps, 1_000)
            XCTAssertNil(rightOnly.actualReps)
            let cleared = try store.updateActualCurlReps(left: nil, right: nil, for: saved.id)
            XCTAssertNil(cleared.actualLeftReps)
            XCTAssertNil(cleared.actualRightReps)
        }
    }

    func testInvalidEitherArmRejectsTheWholeUpdateAndKeepsBothPreviousLabels() throws {
        try withStore { store, _ in
            let saved = fixture(actualReps: 12)
            try publish(saved, in: store)
            _ = try store.updateActualCurlReps(left: 5, right: 6, for: saved.id)
            let previous = try Data(contentsOf: store.manifestURL(for: saved.id))
            for (left, right) in [(-1, 8), (8, -1), (1_001, 8), (8, 1_001)] {
                XCTAssertThrowsError(try store.updateActualCurlReps(left: left, right: right, for: saved.id))
                XCTAssertEqual(try Data(contentsOf: store.manifestURL(for: saved.id)), previous)
            }
            XCTAssertEqual(try store.load(id: saved.id).actualLeftReps, 5)
            XCTAssertEqual(try store.load(id: saved.id).actualRightReps, 6)
        }
    }

    func testPersistedOutOfRangeArmLabelsAreRejectedWhenLoading() throws {
        try withStore { store, _ in
            let saved = fixture()
            try publish(saved, in: store)
            let original = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(saved)) as? [String: Any])
            for key in ["actualLeftReps", "actualRightReps"] {
                for value in [-1, 1_001] {
                    var malformed = original
                    malformed[key] = value
                    try JSONSerialization.data(withJSONObject: malformed).write(to: store.manifestURL(for: saved.id), options: .atomic)
                    XCTAssertThrowsError(try store.load(id: saved.id), "Accepted \(key)=\(value)")
                }
            }
        }
    }

    func testArmLabelsCannotBeWrittenToAnotherExercise() throws {
        try withStore { store, _ in
            for exercise in [StationExercise.squat, .benchPress] {
                let saved = fixture(exercise, actualReps: 9)
                try publish(saved, in: store)
                XCTAssertThrowsError(try store.updateActualCurlReps(left: 2, right: 3, for: saved.id)) { error in
                    guard case StationRecordingError.perArmRepsRequireCurl = error else { return XCTFail("Unexpected error: \(error)") }
                }
                XCTAssertEqual(try store.load(id: saved.id), saved)
                XCTAssertEqual(try store.updateActualReps(8, for: saved.id).actualReps, 8)
            }
        }
    }

    func testArmLabelWritesRemainAccountAndSessionScoped() throws {
        try withStore { ownerStore, root in
            let saved = fixture(actualReps: 10)
            try publish(saved, in: ownerStore)
            let other = try StationRecordingStore(session: StationSessionGate(accountID: UUID().uuidString, epoch: 1), baseURL: root)
            XCTAssertThrowsError(try other.updateActualCurlReps(left: 4, right: 4, for: saved.id))
            XCTAssertEqual(try ownerStore.load(id: saved.id), saved)
            ownerStore.session.invalidate()
            XCTAssertThrowsError(try ownerStore.updateActualCurlReps(left: 4, right: 4, for: saved.id))
            let returned = try StationRecordingStore(session: StationSessionGate(accountID: ownerStore.session.accountID, epoch: 2), baseURL: root)
            XCTAssertEqual(try returned.load(id: saved.id), saved)
            let updated = try returned.updateActualCurlReps(left: 0, right: 8, for: saved.id)
            XCTAssertEqual(updated.actualLeftReps, 0)
            XCTAssertEqual(updated.actualRightReps, 8)
            XCTAssertEqual(updated.actualReps, 10)
        }
    }
}
