import AVFoundation
import Combine
import CreateMLComponents
import Foundation
import ImageIO
import Vision

enum StationCameraState: Equatable {
    case idle
    case requestingPermission
    case running
    case denied
    case unavailable
    case interrupted
    case failed(String)

    var message: String {
        switch self {
        case .idle: return "Camera is off."
        case .requestingPermission: return "Starting camera. Allow camera access if prompted."
        case .running: return "Camera is on. Keep the moving joints in view."
        case .denied: return "Camera access is off. Allow it in Settings to try the station."
        case .unavailable: return "A front camera is not available on this device."
        case .interrupted: return "Camera interrupted. Start again when you are ready."
        case .failed(let message): return message
        }
    }
}

/// Capture is opt-in and transient. This type never records, stores, or sends images.
@MainActor
final class StationCamera: ObservableObject {
    let session: AVCaptureSession
    @Published private(set) var state: StationCameraState = .idle
    @Published private(set) var latestPose: StationPoseSample?
    @Published private(set) var latestFrame: StationComparisonFrame?

    private let capture: StationCaptureWorker
    private var run: StationCaptureRun?
    private var rotationCoordinator: AVCaptureDevice.RotationCoordinator?
    private var rotationObservation: NSKeyValueObservation?
    private var imageOrientation: CGImagePropertyOrientation = .up

    init() {
        let session = AVCaptureSession()
        self.session = session
        capture = StationCaptureWorker(session: session)
    }

    /// Called by the explicit start control, never by view construction.
    func start() {
        guard run == nil else { return }
        // Device discovery does not open the camera or require permission. Avoid
        // presenting a permission prompt when there is no usable camera (Simulator).
        guard AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .front) != nil else {
            latestPose = nil
            latestFrame = nil
            state = .unavailable
            return
        }
        let run = StationCaptureRun()
        self.run = run
        latestPose = nil
        latestFrame = nil
        state = .requestingPermission

        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized:
            prepare(run)
        case .notDetermined:
            AVCaptureDevice.requestAccess(for: .video) { [weak self] granted in
                DispatchQueue.main.async {
                    guard let self, self.run === run, run.isActive else { return }
                    if granted {
                        self.prepare(run)
                    } else {
                        self.finish(.denied, run: run)
                    }
                }
            }
        case .denied, .restricted:
            finish(.denied, run: run)
        @unknown default:
            finish(.unavailable, run: run)
        }
    }

    func stop() {
        run?.cancel()
        run = nil
        clearRotation()
        latestPose = nil
        latestFrame = nil
        state = .idle
        capture.stop()
    }

    private func prepare(_ run: StationCaptureRun) {
        capture.prepare(run: run) { [weak self] event in
            guard let self, self.run === run else { return }
            switch event {
            case .prepared(let device):
                guard run.isActive else { return }
                self.observeRotation(device: device, run: run)
                self.capture.start(run: run, orientation: self.imageOrientation, revision: run.orientationRevision)
            case .running:
                guard run.isActive else { return }
                self.state = .running
            case .pose(let frame, let revision):
                guard run.isActive, run.orientationRevision == revision, self.state == .running else { return }
                self.latestPose = frame.sample
                self.latestFrame = frame
            case .ended(let state):
                self.finish(state, run: run)
            }
        }
    }

    private func observeRotation(device: AVCaptureDevice, run: StationCaptureRun) {
        clearRotation()
        let coordinator = AVCaptureDevice.RotationCoordinator(device: device, previewLayer: nil)
        rotationCoordinator = coordinator
        imageOrientation = Self.orientation(for: coordinator.videoRotationAngleForHorizonLevelCapture)
        rotationObservation = coordinator.observe(
            \.videoRotationAngleForHorizonLevelCapture, options: [.new]
        ) { [weak self] coordinator, _ in
            // AVFoundation documents rotation-coordinator KVO delivery on the main queue.
            MainActor.assumeIsolated {
                guard let self, self.run === run, run.isActive else { return }
                let orientation = Self.orientation(for: coordinator.videoRotationAngleForHorizonLevelCapture)
                guard orientation != self.imageOrientation else { return }
                self.imageOrientation = orientation
                // A rep must never span two camera coordinate systems.
                let revision = run.advanceOrientation()
                self.latestPose = nil
                self.latestFrame = nil
                self.capture.setOrientation(orientation, revision: revision, run: run)
            }
        }
    }

    private static func orientation(for degrees: CGFloat) -> CGImagePropertyOrientation {
        // Data output is explicitly unrotated and unmirrored. Vision receives the
        // sensor-to-upright transform; the preview applies its own coordinator angle.
        let quarterTurns = (Int((degrees / 90).rounded()) % 4 + 4) % 4
        switch quarterTurns {
        case 1: return .right
        case 2: return .down
        case 3: return .left
        default: return .up
        }
    }

    private func finish(_ state: StationCameraState, run: StationCaptureRun) {
        guard self.run === run else { return }
        run.cancel()
        self.run = nil
        clearRotation()
        latestPose = nil
        latestFrame = nil
        self.state = state
        capture.stop()
    }

    private func clearRotation() {
        rotationObservation?.invalidate()
        rotationObservation = nil
        rotationCoordinator = nil
    }

    deinit {
        run?.cancel()
        capture.stop()
    }
}

/// Cancellation crosses the main/capture queues immediately, including while
/// permission, startRunning, or Vision is still in flight.
private final class StationCaptureRun: @unchecked Sendable {
    private let lock = NSLock()
    private var active = true
    private var revision: UInt64 = 0

    var isActive: Bool {
        lock.lock()
        defer { lock.unlock() }
        return active
    }

    func cancel() {
        lock.lock()
        active = false
        lock.unlock()
    }

    var orientationRevision: UInt64 {
        lock.lock()
        defer { lock.unlock() }
        return revision
    }

    func advanceOrientation() -> UInt64 {
        lock.lock()
        defer { lock.unlock() }
        revision += 1
        return revision
    }
}

private enum StationCaptureEvent {
    case prepared(AVCaptureDevice)
    case running
    case pose(StationComparisonFrame, revision: UInt64)
    case ended(StationCameraState)
}

/// All session mutations and inference occur on this serial queue. Only value
/// snapshots leave it; neither a sample buffer nor a pixel buffer is retained.
private final class StationCaptureWorker: NSObject, AVCaptureVideoDataOutputSampleBufferDelegate, @unchecked Sendable {
    private let session: AVCaptureSession
    private let queue = DispatchQueue(label: "com.nmarkspdx.tresfort.station.capture", qos: .userInitiated)
    private let output = AVCaptureVideoDataOutput()
    private var device: AVCaptureDevice?
    private var run: StationCaptureRun?
    private var eventHandler: (@MainActor (StationCaptureEvent) -> Void)?
    private var observers: [NSObjectProtocol] = []
    private var orientation: CGImagePropertyOrientation = .up
    private var orientationRevision: UInt64 = 0
    private var lastFrameTime: TimeInterval?

    init(session: AVCaptureSession) {
        self.session = session
        super.init()
    }

    func prepare(run: StationCaptureRun, handler: @escaping @MainActor (StationCaptureEvent) -> Void) {
        queue.async { [self] in
            guard run.isActive else { return }
            stopOnQueue()
            self.run = run
            eventHandler = handler
            do {
                guard let device = try configure() else {
                    end(.unavailable, run: run)
                    return
                }
                guard run.isActive else { stopOnQueue(); return }
                emit(.prepared(device), run: run)
            } catch {
                end(.failed("The camera could not start. Try again."), run: run)
            }
        }
    }

    func start(run: StationCaptureRun, orientation: CGImagePropertyOrientation, revision: UInt64) {
        queue.async { [self] in
            guard self.run === run, run.isActive else { return }
            self.orientation = orientation
            orientationRevision = revision
            lastFrameTime = nil
            output.setSampleBufferDelegate(self, queue: queue)
            observeInterruptions(run: run)
            session.startRunning()
            // The queued explicit stop or interruption handler owns cleanup. Do
            // not erase its terminal event if cancellation happened in startRunning.
            guard run.isActive else { return }
            guard session.isRunning else {
                end(.failed("The camera could not start. Try again."), run: run)
                return
            }
            emit(.running, run: run)
        }
    }

    func setOrientation(_ orientation: CGImagePropertyOrientation, revision: UInt64, run: StationCaptureRun) {
        queue.async { [self] in
            guard self.run === run, run.isActive else { return }
            self.orientation = orientation
            orientationRevision = revision
            lastFrameTime = nil
        }
    }

    func stop() {
        queue.async { [self] in stopOnQueue() }
    }

    private func configure() throws -> AVCaptureDevice? {
        if let device { return device }
        guard let device = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .front) else {
            return nil
        }
        let input = try AVCaptureDeviceInput(device: device)
        session.beginConfiguration()
        defer { session.commitConfiguration() }
        if session.canSetSessionPreset(.hd1280x720) { session.sessionPreset = .hd1280x720 }
        guard session.canAddInput(input) else { return nil }
        session.addInput(input)
        guard session.canAddOutput(output) else {
            session.removeInput(input)
            return nil
        }
        output.alwaysDiscardsLateVideoFrames = true
        output.videoSettings = [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA]
        session.addOutput(output)
        if let connection = output.connection(with: .video) {
            // Newer landscape-camera iPads default to a 180-degree data-output
            // rotation. Force native pixels so the coordinator angle is applied once.
            if connection.isVideoRotationAngleSupported(0) { connection.videoRotationAngle = 0 }
            if connection.isVideoMirroringSupported {
                connection.automaticallyAdjustsVideoMirroring = false
                connection.isVideoMirrored = false
            }
        }
        self.device = device
        return device
    }

    private func observeInterruptions(run: StationCaptureRun) {
        let center = NotificationCenter.default
        for name in [AVCaptureSession.wasInterruptedNotification, AVCaptureSession.runtimeErrorNotification,
                     AVCaptureSession.didStopRunningNotification] {
            observers.append(center.addObserver(forName: name, object: session, queue: nil) { [weak self] _ in
                guard let self, run.isActive else { return }
                // Invalidate even a currently executing Vision request before queuing cleanup.
                run.cancel()
                self.queue.async { [weak self] in
                    guard let self, self.run === run else { return }
                    let state: StationCameraState = name == AVCaptureSession.runtimeErrorNotification
                        ? .failed("The camera stopped unexpectedly. Start again to retry.") : .interrupted
                    self.end(state, run: run)
                }
            })
        }
    }

    private func end(_ state: StationCameraState, run: StationCaptureRun) {
        run.cancel()
        emit(.ended(state), run: run)
        stopOnQueue()
    }

    private func stopOnQueue() {
        run?.cancel()
        run = nil
        eventHandler = nil
        for observer in observers { NotificationCenter.default.removeObserver(observer) }
        observers.removeAll()
        output.setSampleBufferDelegate(nil, queue: nil)
        if session.isRunning { session.stopRunning() }
        lastFrameTime = nil
    }

    private func emit(_ event: StationCaptureEvent, run: StationCaptureRun) {
        guard self.run === run, let eventHandler else { return }
        DispatchQueue.main.async { eventHandler(event) }
    }

    func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer,
                       from connection: AVCaptureConnection) {
        guard let run, run.isActive, run.orientationRevision == orientationRevision else { return }
        let frameRevision = orientationRevision
        let time = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
        guard time.isNumeric else { return }
        let timestamp = CMTimeGetSeconds(time)
        guard timestamp.isFinite else { return }
        if let lastFrameTime, timestamp - lastFrameTime < 1.0 / 15.0 { return }
        lastFrameTime = timestamp
        guard let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }

        autoreleasepool {
            do {
                let request = VNDetectHumanBodyPoseRequest()
                let handler = VNImageRequestHandler(cvPixelBuffer: pixelBuffer, orientation: orientation)
                let inferenceStartedAt = ProcessInfo.processInfo.systemUptime
                try handler.perform([request])
                let visionMilliseconds = (ProcessInfo.processInfo.systemUptime - inferenceStartedAt) * 1_000
                guard run.isActive else { return }
                let observations = request.results ?? []
                var joints: [StationJoint: StationJointPoint] = [:]
                var applePose: Pose?
                // Never silently choose one person from a crowded frame.
                if observations.count == 1, let observation = observations.first {
                    // Preserve the complete original normalized observation for
                    // Apple's model before adapting coordinates for angle math.
                    applePose = try Pose(observation)
                    let points = try observation.recognizedPoints(.all)
                    let width = Double(CVPixelBufferGetWidth(pixelBuffer))
                    let height = Double(CVPixelBufferGetHeight(pixelBuffer))
                    let swapsAxes = orientation == .left || orientation == .right
                    let uprightAspect = swapsAxes ? height / width : width / height
                    for (joint, name) in Self.jointNames {
                        guard let point = points[name], point.x.isFinite, point.y.isFinite else { continue }
                        // Upright, unmirrored, bottom-left origin. Both axes use image
                        // height as their unit so joint angles survive portrait/landscape.
                        joints[joint] = StationJointPoint(
                            x: Double(point.x) * uprightAspect, y: Double(point.y), confidence: point.confidence
                        )
                    }
                }
                let sample = StationPoseSample(timestamp: timestamp, joints: joints, personCount: observations.count)
                let frame = StationComparisonFrame(sample: sample, applePose: applePose,
                                                   visionMilliseconds: visionMilliseconds)
                emit(.pose(frame, revision: frameRevision), run: run)
            } catch {
                end(.failed("Movement tracking stopped. Start again to retry."), run: run)
            }
        }
    }

    private static let jointNames: [(StationJoint, VNHumanBodyPoseObservation.JointName)] = [
        (.leftShoulder, .leftShoulder), (.rightShoulder, .rightShoulder),
        (.leftElbow, .leftElbow), (.rightElbow, .rightElbow),
        (.leftWrist, .leftWrist), (.rightWrist, .rightWrist),
        (.leftHip, .leftHip), (.rightHip, .rightHip),
        (.leftKnee, .leftKnee), (.rightKnee, .rightKnee),
        (.leftAnkle, .leftAnkle), (.rightAnkle, .rightAnkle)
    ]
}
