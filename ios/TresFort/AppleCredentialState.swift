import AuthenticationServices

enum AppAppleCredentialState: Equatable {
    case authorized
    case revoked
    case notFound
    case transferred
    case unavailable
}

protocol AppleCredentialStateChecking {
    func state(for appleUserID: String) async -> AppAppleCredentialState
}

struct AppleCredentialStateChecker: AppleCredentialStateChecking {
    func state(for appleUserID: String) async -> AppAppleCredentialState {
        await withCheckedContinuation { continuation in
            ASAuthorizationAppleIDProvider().getCredentialState(
                forUserID: appleUserID
            ) { state, error in
                guard error == nil else {
                    continuation.resume(returning: .unavailable)
                    return
                }
                switch state {
                case .authorized:
                    continuation.resume(returning: .authorized)
                case .revoked:
                    continuation.resume(returning: .revoked)
                case .notFound:
                    continuation.resume(returning: .notFound)
                case .transferred:
                    continuation.resume(returning: .transferred)
                @unknown default:
                    continuation.resume(returning: .unavailable)
                }
            }
        }
    }
}
