import Foundation
import Security

struct PartnerCheckpoint: Codable, Equatable {
    enum Phase: String, Codable { case reviewing, saving, ready, starting, active, cancelling, leaving }
    let id: UUID
    let lane: PartnerLane
    let offer: PartnerOffer
    var name: String
    var phase: Phase
    var slotMap: [String: String]
    var copy: PartnerCopyRequest?
    var receipt: PartnerCopyReceipt?
    var startRound: UUID?
    var start: PartnerStartRequest?
    var sessionID: String?
    var attempt: Int?
    var shared: PartnerSharedState?
}

enum PartnerCheckpointStore {
    static func key(_ accountID: String) -> String { "com.nmarkspdx.tresfort.partner.v1.\(accountID)" }
    static func load(_ accountID: String, defaults: LocalPersistence = .standard) -> PartnerCheckpoint? {
        guard let data = defaults.data(forKey: key(accountID)) else { return nil }
        guard let checkpoint = try? JSONDecoder().decode(PartnerCheckpoint.self, from: data) else {
            defaults.recordInvalidData(data, forKey: key(accountID)); return nil
        }
        return checkpoint
    }
    @discardableResult
    static func replace(_ value: PartnerCheckpoint?, expected: PartnerCheckpoint?, accountID: String,
                        defaults: LocalPersistence = .standard) -> Bool {
        guard !defaults.hasFailure(forKey: key(accountID)), load(accountID, defaults: defaults) == expected else { return false }
        guard let value else { return defaults.removeObject(forKey: key(accountID)) }
        guard let data = try? JSONEncoder().encode(value) else { return false }
        return defaults.set(data, forKey: key(accountID))
    }
}

/// One current lane per account, device-only. The iPad's copies never persist.
enum PartnerLaneKeyStore {
    private static let service = "com.nmarkspdx.tresfort.partner-lane"
    private struct Value: Codable { let id: UUID; let key: Data }
    private static func query(_ accountID: String) -> [String: Any] {
        [kSecClass as String:kSecClassGenericPassword,kSecAttrService as String:service,kSecAttrAccount as String:accountID]
    }
    static func load(_ id: UUID, accountID: String) -> Data? {
        var q=query(accountID); q[kSecReturnData as String]=true; q[kSecMatchLimit as String]=kSecMatchLimitOne
        var item: CFTypeRef?
        guard SecItemCopyMatching(q as CFDictionary,&item)==errSecSuccess, let data=item as? Data,
              let value=try? JSONDecoder().decode(Value.self,from:data),value.id==id,value.key.count==32 else {return nil}
        return value.key
    }
    static func save(_ key: Data,id: UUID,accountID: String) -> Bool {
        guard key.count==32, let data=try? JSONEncoder().encode(Value(id:id,key:key)) else {return false}
        let q=query(accountID)
        let status=SecItemUpdate(q as CFDictionary,[kSecValueData as String:data] as CFDictionary)
        if status==errSecSuccess {return true}
        guard status==errSecItemNotFound else {return false}
        var add=q;add[kSecValueData as String]=data
        add[kSecAttrAccessible as String]=kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        return SecItemAdd(add as CFDictionary,nil)==errSecSuccess
    }
    static func clear(accountID: String) {SecItemDelete(query(accountID) as CFDictionary)}
}
