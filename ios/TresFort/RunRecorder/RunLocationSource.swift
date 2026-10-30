import CoreLocation
import Foundation

enum RunLocationAccess: Equatable {
    case granted
    case denied
    /// Precise Location is off, so fixes are kilometers wide.
    case approximate
}

@MainActor
protocol RunLocationSource: AnyObject {
    var onLocations: (([CLLocation]) -> Void)? { get set }
    func requestAccess() async -> RunLocationAccess
    /// Foreground fixes while the recorder is open, so GPS has locked on
    /// before the run starts.
    func warmUp()
    /// Recording: keeps going with the phone locked.
    func start()
    func stop()
}

/// GPS for the route map and the uploaded track. "When In Use" access is
/// enough: updates that start on screen continue with the phone locked
/// through the `location` background mode and a background activity session,
/// which shows the system's location indicator.
@MainActor
final class CoreLocationRunSource: NSObject, RunLocationSource, CLLocationManagerDelegate {
    var onLocations: (([CLLocation]) -> Void)?

    private let manager = CLLocationManager()
    private var backgroundSession: CLBackgroundActivitySession?
    private var accessWaiters: [CheckedContinuation<RunLocationAccess, Never>] = []

    /// The App Store build strips the background mode; enabling background
    /// updates without it raises an exception.
    static var hasBackgroundLocationMode: Bool {
        (Bundle.main.object(forInfoDictionaryKey: "UIBackgroundModes") as? [String])?.contains("location") == true
    }

    override init() {
        super.init()
        manager.delegate = self
        manager.activityType = .fitness
        manager.desiredAccuracy = kCLLocationAccuracyBest
        manager.distanceFilter = kCLDistanceFilterNone
        manager.pausesLocationUpdatesAutomatically = false
    }

    private var access: RunLocationAccess? {
        switch manager.authorizationStatus {
        case .authorizedAlways, .authorizedWhenInUse:
            manager.accuracyAuthorization == .fullAccuracy ? .granted : .approximate
        case .denied, .restricted:
            .denied
        default:
            nil
        }
    }

    func requestAccess() async -> RunLocationAccess {
        if let access { return access }
        return await withCheckedContinuation { continuation in
            accessWaiters.append(continuation)
            manager.requestWhenInUseAuthorization()
        }
    }

    func warmUp() {
        manager.startUpdatingLocation()
    }

    func start() {
        if Self.hasBackgroundLocationMode, backgroundSession == nil {
            manager.allowsBackgroundLocationUpdates = true
            manager.showsBackgroundLocationIndicator = true
            backgroundSession = CLBackgroundActivitySession()
        }
        manager.startUpdatingLocation()
    }

    func stop() {
        manager.stopUpdatingLocation()
        backgroundSession?.invalidate()
        backgroundSession = nil
        if Self.hasBackgroundLocationMode {
            manager.allowsBackgroundLocationUpdates = false
        }
    }

    // The manager is created on the main thread, so it calls back there.
    nonisolated func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        MainActor.assumeIsolated { onLocations?(locations) }
    }

    nonisolated func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        MainActor.assumeIsolated {
            guard let access else { return }
            let waiters = accessWaiters
            accessWaiters = []
            waiters.forEach { $0.resume(returning: access) }
        }
    }

    nonisolated func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {}
}
