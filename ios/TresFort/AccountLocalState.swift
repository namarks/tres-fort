import Foundation

/// One owner for every account-scoped value persisted outside the Keychain.
/// Feature models use these keys for ordinary reads/writes; AuthModel invokes
/// `clear` only after DELETE /api/me is acknowledged. Keeping the namespace in
/// one pure type makes account switching and permanent deletion auditable.
enum AccountLocalState {
    static let legacyIntervalsConnectionKey =
        "com.nmarkspdx.liftcoach.intervals-connection.v1"
    static let legacyHealthEnabledKey =
        "com.nmarkspdx.liftcoach.healthkit-enabled.v1"
    static let legacyHealthAnchorKey =
        "com.nmarkspdx.liftcoach.healthkit-anchor.v1"

    static func intervalsConnectionKey(userID: String) -> String {
        "com.nmarkspdx.liftcoach.intervals-connection.v2.\(userID)"
    }

    static func healthEnabledKey(userID: String) -> String {
        "com.nmarkspdx.liftcoach.healthkit-enabled.v2.\(userID)"
    }

    static func healthAnchorKey(userID: String) -> String {
        "com.nmarkspdx.liftcoach.healthkit-anchor.v2.\(userID)"
    }

    static func appleCredentialUserKey(userID: String) -> String {
        "com.nmarkspdx.liftcoach.apple-credential-user.v1.\(userID)"
    }

    static func clear(userID: String, defaults: UserDefaults = .standard) {
        ActivityOutboxStore.clear(userID: userID, defaults: defaults)
        defaults.removeObject(forKey: intervalsConnectionKey(userID: userID))
        defaults.removeObject(forKey: healthEnabledKey(userID: userID))
        defaults.removeObject(forKey: healthAnchorKey(userID: userID))
        defaults.removeObject(forKey: appleCredentialUserKey(userID: userID))

        // Defensive upgrade cleanup: if this account never mounted the feature
        // models after updating, the process-global v1 values may not have been
        // migrated yet. They must not survive permanent deletion for a future
        // Apple account to inherit.
        defaults.removeObject(forKey: legacyIntervalsConnectionKey)
        defaults.removeObject(forKey: legacyHealthEnabledKey)
        defaults.removeObject(forKey: legacyHealthAnchorKey)
    }
}
