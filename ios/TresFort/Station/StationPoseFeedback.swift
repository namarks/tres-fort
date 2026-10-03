import CoreGraphics
import Foundation
import SwiftUI

/// Setup feedback uses the same confidence requirement as the two counters.
/// Lower-confidence points are shown in orange so an empty count has context.
struct StationPoseFeedback {
    let sample: StationPoseSample?
    let exercise: StationExercise

    private var limbs: [[StationJoint]] {
        exercise == .squat
            ? [[.leftHip, .leftKnee, .leftAnkle], [.rightHip, .rightKnee, .rightAnkle]]
            : [[.leftShoulder, .leftElbow, .leftWrist], [.rightShoulder, .rightElbow, .rightWrist]]
    }

    var isReady: Bool {
        guard sample?.personCount == 1 else { return false }
        return limbs.contains { $0.allSatisfy(isClear) }
    }

    var message: String {
        guard let sample else { return "Waiting for the camera…" }
        if sample.personCount > 1 { return "Keep just one person in view." }
        let joints = exercise == .squat ? "hip, knee and ankle" : "shoulder, elbow and wrist"
        if sample.personCount == 0 { return "Step into view. Show your \(joints) from the side." }
        if isReady { return "Your \(joints) are visible. Hold your starting position." }
        return "Move back or adjust the iPad until your \(joints) are clear on one side."
    }

    private func isClear(_ joint: StationJoint) -> Bool {
        guard let point = sample?.joints[joint] else { return false }
        return point.x.isFinite && point.y.isFinite && point.confidence.isFinite
            && point.confidence >= 0.6 && point.confidence <= 1
    }
}

enum StationPoseProjection {
    /// Match the preview's aspect-fit frame, including portrait letterboxing.
    static func point(_ joint: StationJointPoint, imageAspectRatio: Double, in size: CGSize) -> CGPoint? {
        guard imageAspectRatio.isFinite, imageAspectRatio > 0,
              joint.x.isFinite, joint.y.isFinite,
              joint.x >= 0, joint.x <= imageAspectRatio, joint.y >= 0, joint.y <= 1,
              size.width > 0, size.height > 0 else { return nil }
        let height = min(size.height, size.width / imageAspectRatio)
        let width = height * imageAspectRatio
        return CGPoint(x: (size.width - width) / 2 + joint.x * height,
                       y: (size.height - height) / 2 + (1 - joint.y) * height)
    }
}

struct StationPoseOverlay: View {
    let frame: StationComparisonFrame?

    private static let edges: [(StationJoint, StationJoint)] = [
        (.leftShoulder, .rightShoulder), (.leftShoulder, .leftElbow), (.leftElbow, .leftWrist),
        (.rightShoulder, .rightElbow), (.rightElbow, .rightWrist),
        (.leftShoulder, .leftHip), (.rightShoulder, .rightHip), (.leftHip, .rightHip),
        (.leftHip, .leftKnee), (.leftKnee, .leftAnkle),
        (.rightHip, .rightKnee), (.rightKnee, .rightAnkle)
    ]

    var body: some View {
        Canvas { context, size in
            guard let frame, frame.sample.personCount == 1 else { return }
            func visible(_ name: StationJoint) -> (CGPoint, Float)? {
                guard let joint = frame.sample.joints[name], joint.confidence.isFinite,
                      joint.confidence >= 0.2, joint.confidence <= 1,
                      let point = StationPoseProjection.point(joint, imageAspectRatio: frame.imageAspectRatio, in: size)
                else { return nil }
                return (point, joint.confidence)
            }
            for (a, b) in Self.edges {
                guard let first = visible(a), let second = visible(b) else { continue }
                var path = Path()
                path.move(to: first.0)
                path.addLine(to: second.0)
                context.stroke(path, with: .color(min(first.1, second.1) >= 0.6 ? .green : .orange),
                               style: StrokeStyle(lineWidth: 3, lineCap: .round))
            }
            for joint in StationJoint.allCases {
                guard let (point, confidence) = visible(joint) else { continue }
                let circle = Path(ellipseIn: CGRect(x: point.x - 4, y: point.y - 4, width: 8, height: 8))
                context.fill(circle, with: .color(confidence >= 0.6 ? .green : .orange))
            }
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}
