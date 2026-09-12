import CryptoKit
import Foundation

/// One owner for every account-scoped value persisted outside the Keychain.
/// Feature models use these keys for ordinary reads/writes; AuthModel invokes
/// `clear` only after DELETE /api/me terminally confirms the account is gone.
/// Keeping the namespace in one pure type makes account switching and
/// permanent deletion auditable.
enum AccountLocalState {
    private static let legacyOwnerKey = "com.nmarkspdx.liftcoach.legacy-state-owner.v1"

    /// A failed migration must never let a later Apple account claim the
    /// original install's queue or Health anchor on the next load.
    static func claimLegacyState(userID: String, defaults: LocalPersistence) -> Bool {
        guard !defaults.bool(forKey: reviewAccountKey(userID: userID)) else { return false }
        if defaults.string(forKey: legacyOwnerKey) != nil {
            return legacyStateBelongs(to: userID, defaults: defaults)
        }
        defaults.set(legacyOwnerDigest(userID), forKey: legacyOwnerKey)
        return true
    }

    static func legacyStateBelongs(to userID: String, defaults: LocalPersistence) -> Bool {
        guard !defaults.bool(forKey: reviewAccountKey(userID: userID)) else { return false }
        guard let owner = defaults.string(forKey: legacyOwnerKey) else { return true }
        return owner == legacyOwnerDigest(userID)
    }

    private static func legacyOwnerDigest(_ userID: String) -> String {
        SHA256.hash(data: Data(userID.utf8)).map { String(format: "%02x", $0) }.joined()
    }

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

    static func healthResetPendingKey(userID: String) -> String {
        "com.nmarkspdx.liftcoach.healthkit-reset-pending.v1.\(userID)"
    }

    static func appleCredentialUserKey(userID: String) -> String {
        "com.nmarkspdx.liftcoach.apple-credential-user.v1.\(userID)"
    }

    static func reviewAccountKey(userID: String) -> String {
        "com.nmarkspdx.liftcoach.review-account.v1.\(userID)"
    }

    static func onboardedKey(userID: String) -> String {
        "com.nmarkspdx.liftcoach.onboarded.v2.\(userID)"
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
        defaults: LocalPersistence = .standard
    ) {
        guard claimLegacyState(userID: userID, defaults: defaults) else { return }
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
        defaults: LocalPersistence
    ) {
        guard let legacy = defaults.object(forKey: legacyKey) else { return }
        // If a scoped value already exists it is newer and authoritative. The
        // legacy value still belongs to this account, so consume it rather
        // than leaving it available for a later account to claim.
        if defaults.object(forKey: scopedKey) == nil {
            guard defaults.set(legacy, forKey: scopedKey) else { return }
        }
        guard !defaults.hasFailure(forKey: scopedKey) else { return }
        defaults.removeObject(forKey: legacyKey)
    }

    @MainActor
    @discardableResult
    static func clear(userID: String, defaults: LocalPersistence = .standard) -> Bool {
        let protectedKeys = [
            PlanChangeDismissalStore.key(userID: userID),
            ActivityOutboxStore.scopedKey(userID: userID),
            SetOutboxStore.scopedKey(userID: userID),
            SetCorrectionOutboxStore.key(userID: userID),
            WorkoutTerminalOutboxStore.scopedKey(userID: userID),
            WorkoutRunnerCheckpointStore.scopedKey(userID: userID),
            ExerciseCatalogSnapshotStore.scopedKey(userID: userID),
            WorkoutWriteRetryDeadlineStore.scopedKey(userID: userID),
            intervalsConnectionKey(userID: userID),
            healthEnabledKey(userID: userID),
            healthAnchorKey(userID: userID),
            healthResetPendingKey(userID: userID),
        ]
        var erased = true
        for key in protectedKeys {
            if !defaults.eraseAfterAccountDeletion(forKey: key) { erased = false }
        }
        if !StateSnapshotStore.clear(userID: userID, defaults: defaults, afterAccountDeletion: true) {
            erased = false
        }
        if defaults.string(forKey: StateSyncAccountStore.activeAccountKey) == userID,
           !defaults.removeObject(forKey: StateSyncAccountStore.activeAccountKey) {
            erased = false
        }

        // Defensive upgrade cleanup: if this account never mounted the feature
        // models after updating, the process-global v1 values may not have been
        // migrated yet. They must not survive permanent deletion for a future
        // Apple account to inherit.
        let ownsLegacy = claimLegacyState(userID: userID, defaults: defaults)
        if ownsLegacy {
            for key in [ActivityOutboxStore.legacyKey, legacyIntervalsConnectionKey,
                        legacyHealthEnabledKey, legacyHealthAnchorKey] {
                if !defaults.eraseAfterAccountDeletion(forKey: key) { erased = false }
            }
        }
        // Retain the deletion receipt key and auth context until protected
        // cleanup succeeds. Retrying DELETE safely resumes its server receipt.
        // Check only this cleanup's keys: a replacement account's global
        // navigation failure cannot prevent the deleted account's completion.
        guard erased else { return false }
        if ownsLegacy, !defaults.removeObject(forKey: legacyOwnerKey) { return false }
        guard defaults.removeObject(forKey: appleCredentialUserKey(userID: userID)),
              defaults.removeObject(forKey: onboardedKey(userID: userID)),
              defaults.removeObject(forKey: accountDeletionKey(userID: userID)) else { return false }
        // Keep the review marker through every fallible cleanup step. A
        // retry must never mistake this account for the legacy data owner.
        if defaults.bool(forKey: reviewAccountKey(userID: userID)) {
            return defaults.removeObject(forKey: reviewAccountKey(userID: userID))
        }
        return true
    }
}
