import Foundation
import Network

/// One small recovery hook for the set outbox. Launch and foreground remain
/// explicit in MainTabView; this monitor only reports a transition from an
/// unsatisfied path to a satisfied one.
@MainActor
final class SetConnectivityMonitor: ObservableObject {
    var onSatisfiedTransition: (() -> Void)?

    private let monitor = NWPathMonitor()
    private let queue = DispatchQueue(
        label: "com.nmarkspdx.tresfort.set-connectivity")
    private var previousStatus: NWPath.Status?

    init() {
        monitor.pathUpdateHandler = { [weak self] path in
            let status = path.status
            Task { @MainActor in
                guard let self else { return }
                let transitioned = self.previousStatus != nil
                    && self.previousStatus != .satisfied
                    && status == .satisfied
                self.previousStatus = status
                if transitioned { self.onSatisfiedTransition?() }
            }
        }
        monitor.start(queue: queue)
    }

    deinit {
        monitor.cancel()
    }
}
