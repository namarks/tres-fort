import XCTest
@testable import TresFort

final class StationPoseFeedbackTests: XCTestCase {
    func testMissingLegCannotLookReadyForSquatsWhileArmIsVisible() {
        let joints = Dictionary(uniqueKeysWithValues: [StationJoint.leftShoulder, .leftElbow, .leftWrist]
            .map { ($0, StationJointPoint(x: 0.5, y: 0.5, confidence: 0.9)) })
        let sample = StationPoseSample(timestamp: 1, joints: joints, personCount: 1)
        XCTAssertFalse(StationPoseFeedback(sample: sample, exercise: .squat).isReady)
        XCTAssertTrue(StationPoseFeedback(sample: sample, exercise: .curl).isReady)
        XCTAssertTrue(StationPoseFeedback(sample: sample, exercise: .squat).message.contains("hip, knee and ankle"))
    }

    func testWeakAndMultiplePersonPosesAreNotReady() {
        let joints = Dictionary(uniqueKeysWithValues: [StationJoint.leftHip, .leftKnee, .leftAnkle]
            .map { ($0, StationJointPoint(x: 0.5, y: 0.5, confidence: 0.59)) })
        XCTAssertFalse(StationPoseFeedback(sample: .init(timestamp: 1, joints: joints, personCount: 1), exercise: .squat).isReady)
        let clear = joints.mapValues { StationJointPoint(x: $0.x, y: $0.y, confidence: 0.9) }
        XCTAssertTrue(StationPoseFeedback(sample: .init(timestamp: 1, joints: clear, personCount: 1), exercise: .squat).isReady)
        XCTAssertFalse(StationPoseFeedback(sample: .init(timestamp: 1, joints: clear, personCount: 2), exercise: .squat).isReady)
    }

    func testLandscapeProjectionIncludesLetterboxingAndInvertsVisionY() throws {
        let point = try XCTUnwrap(StationPoseProjection.point(.init(x: 0, y: 1, confidence: 1),
                                                             imageAspectRatio: 4.0 / 3, in: CGSize(width: 600, height: 300)))
        XCTAssertEqual(point.x, 100, accuracy: 0.001)
        XCTAssertEqual(point.y, 0, accuracy: 0.001)
        let lowerRight = try XCTUnwrap(StationPoseProjection.point(.init(x: 4.0 / 3, y: 0, confidence: 1),
                                                                  imageAspectRatio: 4.0 / 3, in: CGSize(width: 600, height: 300)))
        XCTAssertEqual(lowerRight.x, 500, accuracy: 0.001)
        XCTAssertEqual(lowerRight.y, 300, accuracy: 0.001)
    }

    func testPortraitProjectionAndInvalidCoordinates() throws {
        let point = try XCTUnwrap(StationPoseProjection.point(.init(x: 0.375, y: 0.5, confidence: 1),
                                                             imageAspectRatio: 0.75, in: CGSize(width: 600, height: 300)))
        XCTAssertEqual(point.x, 300, accuracy: 0.001)
        XCTAssertEqual(point.y, 150, accuracy: 0.001)
        XCTAssertNil(StationPoseProjection.point(.init(x: .nan, y: 0.5, confidence: 1), imageAspectRatio: 1, in: CGSize(width: 100, height: 100)))
    }
}
