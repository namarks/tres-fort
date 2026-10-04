import Combine
import Foundation

enum StationAccessError: LocalizedError {
    case sessionEnded
    var errorDescription: String? { "This account session ended. Reopen Station after signing in." }
}

/// A revocable local-file capability, with no credentials or workout writers.
/// File operations and revocation share a lock, so a finish callback cannot
/// publish after account deletion has removed the account's directory.
final class StationSessionGate: @unchecked Sendable {
    private final class WeakGate {
        weak var value: StationSessionGate?
        init(_ value: StationSessionGate) { self.value = value }
    }
    private static let lock = NSRecursiveLock()
    private static var gates: [WeakGate] = []
    let accountID: String
    let epoch: UInt64
    private var active = true

    init(accountID: String, epoch: UInt64) {
        self.accountID = accountID
        self.epoch = epoch
        Self.lock.lock()
        Self.gates.removeAll { $0.value == nil }
        Self.gates.append(WeakGate(self))
        Self.lock.unlock()
    }

    var isActive: Bool {
        Self.lock.lock()
        defer { Self.lock.unlock() }
        return active && !accountID.isEmpty
    }

    func withAccess<T>(_ operation: () throws -> T) throws -> T {
        Self.lock.lock()
        defer { Self.lock.unlock() }
        guard active, !accountID.isEmpty else { throw StationAccessError.sessionEnded }
        return try operation()
    }

    func requireActive() throws { try withAccess {} }

    func invalidate() {
        Self.lock.lock()
        active = false
        Self.lock.unlock()
    }

    func cleanup(_ operation: () -> Void) {
        Self.lock.lock()
        defer { Self.lock.unlock() }
        operation()
    }

    static func revokeAccount<T>(_ accountID: String, operation: () throws -> T) rethrows -> T {
        lock.lock()
        defer { lock.unlock() }
        gates.removeAll { $0.value == nil }
        for gate in gates.compactMap(\.value) where gate.accountID == accountID { gate.active = false }
        return try operation()
    }
}

/// UI lifetime is fenced separately from AuthModel's epoch because its boundary
/// notification intentionally arrives before AuthModel changes that epoch.
@MainActor
final class StationAccess: ObservableObject {
    private final class WeakAccess {
        weak var value: StationAccess?
        init(_ value: StationAccess) { self.value = value }
    }
    private static var instances: [WeakAccess] = []
    let session: StationSessionGate
    @Published private(set) var isActive: Bool
    private let isCurrentSession: @MainActor () -> Bool
    private var observers: [() -> Bool] = []
    private var hasInvalidated = false

    init(accountID: String?, epoch: UInt64,
         isCurrentSession: @escaping @MainActor () -> Bool,
         observeBoundary: (@escaping () -> Bool) -> Void) {
        session = StationSessionGate(accountID: accountID ?? "", epoch: epoch)
        self.isCurrentSession = isCurrentSession
        isActive = accountID != nil && isCurrentSession()
        if !isActive { session.invalidate() }
        Self.instances.removeAll { $0.value == nil }
        Self.instances.append(WeakAccess(self))
        observeBoundary { [weak self, weak session = self.session] in
            // A writer may be finishing after its view/access object closed.
            // Revocation must still reach that remaining local-file capability.
            session?.invalidate()
            guard let self else { return false }
            self.invalidate()
            return true
        }
    }

    @discardableResult
    func validate() -> Bool {
        guard isActive, session.isActive, isCurrentSession() else { invalidate(); return false }
        return true
    }

    func observeInvalidation(_ observer: @escaping () -> Bool) {
        if !isActive || hasInvalidated { _ = observer() }
        else { observers.append(observer) }
    }

    func invalidate() {
        session.invalidate()
        guard !hasInvalidated else { return }
        hasInvalidated = true
        // Clear mounted feature state synchronously, before publishing the UI
        // invalidation or allowing AuthModel to move to the next account.
        for observer in observers { _ = observer() }
        observers.removeAll()
        isActive = false
    }

    static func invalidateAccount(_ accountID: String) {
        instances.removeAll { $0.value == nil }
        for access in instances.compactMap(\.value) where access.session.accountID == accountID {
            access.invalidate()
        }
    }
}
