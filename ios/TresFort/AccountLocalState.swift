import Foundation

/// One owner for every account-scoped value persisted outside the Keychain.
/// Feature models use these keys for ordinary reads/writes; AuthModel invokes
/// `clear` only after DELETE /api/me terminally confirms the account is gone.
/// Keeping the namespace in one pure type makes account switching and
/// permanent deletion auditable.
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

    static func accountDeletionKey(userID: String) -> String {
        "com.nmarkspdx.liftcoach.account-deletion-key.v1.\(userID)"
    }

    /// Move every pre-account-scoping value into the namespace of the account
    /// that owned this install before migration. AuthModel calls this before
    /// bearer validation so a rejected saved token followed by a different
    /// Apple sign-in cannot transfer the prior account's local data.
    static func bindLegacyState(
        userID: String,
        defaults: UserDefaults = .standard
    ) {
        ActivityOutboxStore.bindLegacyState(userID: userID, defaults: defaults)
        bindLegacyValue(
            legacyKey: legacyIntervalsConnectionKey,
            scopedKey: intervalsConnectionKey(userID: userID),
            defaults: defaults)
        bindLegacyValue(
            legacyKey: legacyHealthEnabledKey,
            scopedKey: healthEnabledKey(userID: userID),
            defaults: defaults)
        bindLegacyValue(
            legacyKey: legacyHealthAnchorKey,
            scopedKey: healthAnchorKey(userID: userID),
            defaults: defaults)
    }

    private static func bindLegacyValue(
        legacyKey: String,
        scopedKey: String,
        defaults: UserDefaults
    ) {
        guard let legacy = defaults.object(forKey: legacyKey) else { return }
        // If a scoped value already exists it is newer and authoritative. The
        // legacy value still belongs to this account, so consume it rather
        // than leaving it available for a later account to claim.
        if defaults.object(forKey: scopedKey) == nil {
            defaults.set(legacy, forKey: scopedKey)
        }
        defaults.removeObject(forKey: legacyKey)
    }

    @MainActor
    static func clear(userID: String, defaults: UserDefaults = .standard) {
        ActivityOutboxStore.clear(userID: userID, defaults: defaults)
        SetOutboxStore.clear(userID: userID, defaults: defaults)
        WorkoutTerminalOutboxStore.clear(userID: userID, defaults: defaults)
        WorkoutWriteRetryDeadlineStore.clear(
            userID: userID, defaults: defaults)
        WorkoutRunnerCheckpointStore.clear(userID: userID, defaults: defaults)
        StateSnapshotStore.clear(userID: userID, defaults: defaults)
        ExerciseCatalogSnapshotStore.clear(userID: userID, defaults: defaults)
        defaults.removeObject(forKey: intervalsConnectionKey(userID: userID))
        defaults.removeObject(forKey: healthEnabledKey(userID: userID))
        defaults.removeObject(forKey: healthAnchorKey(userID: userID))
        defaults.removeObject(forKey: appleCredentialUserKey(userID: userID))
        defaults.removeObject(forKey: accountDeletionKey(userID: userID))

        // Defensive upgrade cleanup: if this account never mounted the feature
        // models after updating, the process-global v1 values may not have been
        // migrated yet. They must not survive permanent deletion for a future
        // Apple account to inherit.
        defaults.removeObject(forKey: legacyIntervalsConnectionKey)
        defaults.removeObject(forKey: legacyHealthEnabledKey)
        defaults.removeObject(forKey: legacyHealthAnchorKey)
    }
}
