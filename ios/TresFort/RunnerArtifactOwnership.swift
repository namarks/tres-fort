import Foundation

/// Process-local ownership for ActivityKit and the single rest notification.
/// The durable checkpoint is value-based, so a replacement model can resume
/// to an identical value; this token closes that in-process ABA gap.
@MainActor
enum RunnerArtifactOwnership {
    private struct Key: Hashable {
        let defaults: ObjectIdentifier
        let userID: String
    }

    final class Owner {
        weak var defaults: LocalPersistence?
        let id: UUID
        let featureSessionEpoch: UInt64

        init(defaults: LocalPersistence, id: UUID, featureSessionEpoch: UInt64) {
            self.defaults = defaults
            self.id = id
            self.featureSessionEpoch = featureSessionEpoch
        }

        func permitsClaim(featureSessionEpoch: UInt64, defaults: LocalPersistence) -> Bool {
            // ObjectIdentifier can be reused after the old namespace dies.
            // Its epoch fences only that live namespace, never a new object
            // that happens to occupy the same address.
            guard let currentDefaults = self.defaults else { return true }
            return currentDefaults === defaults && self.featureSessionEpoch <= featureSessionEpoch
        }
    }

    private static var owners: [Key: Owner] = [:]

    static func claim(
        _ owner: UUID,
        featureSessionEpoch: UInt64,
        userID: String?,
        defaults: LocalPersistence
    ) {
        guard let userID else { return }
        let key = Key(defaults: ObjectIdentifier(defaults), userID: userID)
        guard owners[key]?.permitsClaim(
            featureSessionEpoch: featureSessionEpoch, defaults: defaults) != false else {
            return
        }
        owners[key] = Owner(
            defaults: defaults,
            id: owner,
            featureSessionEpoch: featureSessionEpoch)
    }

    static func isOwned(
        by owner: UUID,
        featureSessionEpoch: UInt64,
        userID: String?,
        defaults: LocalPersistence
    ) -> Bool {
        guard let userID else { return false }
        guard let current = owners[Key(
            defaults: ObjectIdentifier(defaults), userID: userID)],
              current.defaults === defaults
        else { return false }
        return current.id == owner
            && current.featureSessionEpoch == featureSessionEpoch
    }

    static func isOwnedByOther(
        than owner: UUID,
        featureSessionEpoch: UInt64,
        userID: String?,
        defaults: LocalPersistence
    ) -> Bool {
        guard let userID,
              let current = owners[Key(
                  defaults: ObjectIdentifier(defaults), userID: userID)],
              current.defaults === defaults
        else { return false }
        return current.featureSessionEpoch > featureSessionEpoch
            || (current.featureSessionEpoch == featureSessionEpoch
                && current.id != owner)
    }

    static func release(
        _ owner: UUID,
        featureSessionEpoch: UInt64,
        userID: String?,
        defaults: LocalPersistence
    ) {
        guard let userID else { return }
        let key = Key(defaults: ObjectIdentifier(defaults), userID: userID)
        if let current = owners[key],
           current.defaults === defaults,
           current.id == owner,
           current.featureSessionEpoch == featureSessionEpoch {
            owners.removeValue(forKey: key)
        }
    }
}

