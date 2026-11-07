import CoreMotion
import Foundation

/// The iPhone's barometer while a run records (docs/plans/run-recorder P7).
/// A protocol so the recorder's own logic is tested without one.
@MainActor
protocol RunAltimeter: AnyObject {
    /// Meters relative to the first reading since `start()`.
    var onAltitude: ((RecordedRun.AltitudeSample) -> Void)? { get set }
    /// Asks for Motion & Fitness before the run starts, so the prompt never
    /// lands mid-run. A refusal only leaves the run without a climb.
    func requestAccess() async
    func start()
    func stop()
}

/// CoreMotion's relative altitude, which reads the barometer roughly once a
/// second while the app runs, also with the phone locked during a run.
@MainActor
final class BarometerRunAltimeter: RunAltimeter {
    var onAltitude: ((RecordedRun.AltitudeSample) -> Void)?

    private let altimeter = CMAltimeter()
    private var running = false
    private var accessAnswer: CheckedContinuation<Void, Never>?

    static var isAvailable: Bool { CMAltimeter.isRelativeAltitudeAvailable() }

    private static var allowed: Bool {
        let status = CMAltimeter.authorizationStatus()
        return status != .denied && status != .restricted
    }

    func requestAccess() async {
        guard Self.isAvailable, CMAltimeter.authorizationStatus() == .notDetermined,
              !running, accessAnswer == nil else { return }
        // The first update asks; it answers with a reading or a refusal.
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            accessAnswer = continuation
            altimeter.startRelativeAltitudeUpdates(to: .main) { [weak self] _, _ in
                MainActor.assumeIsolated { self?.answered() }
            }
            // A start never waits on the barometer for long.
            Task { @MainActor [weak self] in
                try? await Task.sleep(for: .seconds(BarometerRunAltimeter.accessTimeout))
                self?.answered()
            }
        }
    }

    /// Seconds the run's start waits for the Motion & Fitness answer.
    static let accessTimeout: TimeInterval = 30

    private func answered() {
        guard let accessAnswer else { return }
        self.accessAnswer = nil
        altimeter.stopRelativeAltitudeUpdates()
        accessAnswer.resume()
    }

    func start() {
        guard !running, Self.isAvailable, Self.allowed else { return }
        running = true
        altimeter.startRelativeAltitudeUpdates(to: .main) { [weak self] data, _ in
            guard let data else { return }
            let meters = data.relativeAltitude.doubleValue
            // CoreMotion stamps readings in seconds since the device booted.
            let age = ProcessInfo.processInfo.systemUptime - data.timestamp
            MainActor.assumeIsolated {
                let sample = RecordedRun.AltitudeSample(timestamp: Date().addingTimeInterval(-age), meters: meters)
                self?.onAltitude?(sample)
            }
        }
    }

    func stop() {
        guard running else { return }
        running = false
        altimeter.stopRelativeAltitudeUpdates()
    }
}
