import AVFoundation
import SwiftUI
import UIKit

/// The preview and Vision input are both unmirrored. Aspect fit keeps the full
/// camera frame visible, including feet near its edges.
struct StationCameraPreview: UIViewRepresentable {
    let session: AVCaptureSession

    func makeUIView(context: Context) -> PreviewView {
        let view = PreviewView()
        view.setSession(session)
        return view
    }

    func updateUIView(_ uiView: PreviewView, context: Context) {
        uiView.setSession(session)
    }

    static func dismantleUIView(_ uiView: PreviewView, coordinator: ()) {
        uiView.setSession(nil)
    }

    final class PreviewView: UIView {
        override class var layerClass: AnyClass { AVCaptureVideoPreviewLayer.self }
        private var previewLayer: AVCaptureVideoPreviewLayer { layer as! AVCaptureVideoPreviewLayer }
        private var rotationCoordinator: AVCaptureDevice.RotationCoordinator?
        private var rotationObservation: NSKeyValueObservation?
        private var runningObserver: NSObjectProtocol?

        override init(frame: CGRect) {
            super.init(frame: frame)
            backgroundColor = .black
            previewLayer.videoGravity = .resizeAspect
        }

        required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

        func setSession(_ session: AVCaptureSession?) {
            guard previewLayer.session !== session else { return }
            clearObservers()
            previewLayer.session = session
            guard let session else { return }
            runningObserver = NotificationCenter.default.addObserver(
                forName: AVCaptureSession.didStartRunningNotification, object: session, queue: .main
            ) { [weak self] _ in
                MainActor.assumeIsolated { self?.configureRotation() }
            }
            configureRotation()
        }

        override func didMoveToWindow() {
            super.didMoveToWindow()
            configureRotation()
        }

        override func layoutSubviews() {
            super.layoutSubviews()
            // This view's backing layer already tracks its bounds. Reapply the
            // coordinator angle after interface rotations change the layer hierarchy.
            if rotationCoordinator == nil { configureRotation() }
            applyRotation()
        }

        private func configureRotation() {
            guard window != nil, let session = previewLayer.session, session.isRunning,
                  let input = session.inputs.compactMap({ $0 as? AVCaptureDeviceInput }).first else { return }
            rotationObservation?.invalidate()
            let coordinator = AVCaptureDevice.RotationCoordinator(device: input.device, previewLayer: previewLayer)
            rotationCoordinator = coordinator
            applyRotation()
            rotationObservation = coordinator.observe(
                \.videoRotationAngleForHorizonLevelPreview, options: [.new]
            ) { [weak self] _, _ in
                // AVFoundation delivers this observation on the main queue.
                MainActor.assumeIsolated { self?.applyRotation() }
            }
        }

        private func applyRotation() {
            guard let coordinator = rotationCoordinator, let connection = previewLayer.connection else { return }
            let angle = coordinator.videoRotationAngleForHorizonLevelPreview
            if connection.isVideoRotationAngleSupported(angle) { connection.videoRotationAngle = angle }
            if connection.isVideoMirroringSupported {
                connection.automaticallyAdjustsVideoMirroring = false
                connection.isVideoMirrored = false
            }
        }

        private func clearObservers() {
            rotationObservation?.invalidate()
            rotationObservation = nil
            rotationCoordinator = nil
            if let runningObserver { NotificationCenter.default.removeObserver(runningObserver) }
            runningObserver = nil
        }

        deinit {
            if let runningObserver { NotificationCenter.default.removeObserver(runningObserver) }
        }
    }
}
